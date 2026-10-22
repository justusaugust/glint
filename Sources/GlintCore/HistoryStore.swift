import Foundation
import SQLite3

@MainActor public final class HistoryStore {
    public struct StoreError: LocalizedError {
        public let message: String
        public init(message: String) { self.message = message }
        public var errorDescription: String? { message }
    }
    private var database: OpaquePointer?
    public init(url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let database { sqlite3_close(database) }
            database = nil
            throw StoreError(message: "Couldn’t open Glint’s local learning database.")
        }
        sqlite3_busy_timeout(database, 1_000)
        do {
            try execute("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL; CREATE TABLE IF NOT EXISTS switches (time REAL NOT NULL, previous TEXT, source TEXT NOT NULL, target TEXT NOT NULL, PRIMARY KEY(time,source,target));")
        } catch { sqlite3_close(database); database = nil; throw error }
    }
    isolated deinit { if let database { sqlite3_close(database) } }

    private func execute(_ sql: String) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }
    private func error() -> StoreError { StoreError(message: String(cString: sqlite3_errmsg(database))) }

    @discardableResult public func append(_ event: SwitchEvent) throws -> Bool {
        guard event.isValid else { return false }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "INSERT OR IGNORE INTO switches(time,previous,source,target) VALUES(?,?,?,?)", -1, &statement, nil) == SQLITE_OK else { throw error() }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, event.timestamp)
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        if let previous = event.previous { sqlite3_bind_text(statement, 2, previous, -1, transient) }
        sqlite3_bind_text(statement, 3, event.source, -1, transient)
        sqlite3_bind_text(statement, 4, event.target, -1, transient)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw error() }
        return sqlite3_changes(database) > 0
    }

    // shortcut: warm-start from the latest 100,000 switches; persist the model if startup replay becomes costly.
    public func events(limit: Int = 100_000) throws -> [SwitchEvent] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT time,previous,source,target FROM switches ORDER BY time DESC LIMIT ?", -1, &statement, nil) == SQLITE_OK else { throw error() }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(clamping: max(0, limit)))
        var events: [SwitchEvent] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            func string(_ column: Int32) -> String? { sqlite3_column_text(statement, column).map { String(cString: $0) } }
            if let source = string(2), let target = string(3) {
                let event = SwitchEvent(timestamp: sqlite3_column_double(statement, 0), previous: string(1), source: source, target: target)
                if event.isValid { events.append(event) }
            }
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { throw error() }
        return events.reversed()
    }

    @discardableResult public func importApplight(from url: URL) throws -> Int {
        var source: OpaquePointer?
        guard sqlite3_open_v2(url.path, &source, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            if let source { sqlite3_close(source) }
            throw StoreError(message: "Couldn’t read the selected Applight database.")
        }
        defer { sqlite3_close(source) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(source, "SELECT ZDATE,ZPREVIOUS,ZFROM,ZTO FROM ZRECORD ORDER BY ZDATE,Z_PK", -1, &statement, nil) == SQLITE_OK else {
            throw StoreError(message: "Couldn’t read Applight’s history: \(String(cString: sqlite3_errmsg(source))). Choose its containing folder so SQLite can read the journal.")
        }
        defer { sqlite3_finalize(statement) }
        try execute("BEGIN IMMEDIATE")
        do {
            var count = 0
            var result = sqlite3_step(statement)
            while result == SQLITE_ROW {
                func string(_ column: Int32) -> String? { sqlite3_column_text(statement, column).map { String(cString: $0) } }
                if let from = string(2), let to = string(3) {
                    let event = SwitchEvent(timestamp: sqlite3_column_double(statement, 0) + 978_307_200,
                                            previous: string(1), source: from, target: to)
                    if try append(event) { count += 1 }
                }
                result = sqlite3_step(statement)
            }
            guard result == SQLITE_DONE else { throw StoreError(message: "Applight’s history could not be read completely.") }
            try execute("COMMIT")
            return count
        } catch { try? execute("ROLLBACK"); throw error }
    }
}
