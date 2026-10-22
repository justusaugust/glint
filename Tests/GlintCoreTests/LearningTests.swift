import Foundation
import SQLite3
import Testing
@testable import GlintCore

@Test func learnsAppPairsAndSequences() {
    var model = Predictor()
    let now = Date().timeIntervalSince1970
    for i in 0..<100 {
        model.observe(SwitchEvent(timestamp: now + Double(i), previous: "terminal", source: "code", target: "browser"))
        model.observe(SwitchEvent(timestamp: now + Double(i), previous: "browser", source: "code", target: "terminal"))
    }
    let fromTerminal = model.probabilities(appIDs: ["code", "browser", "terminal", "notes"], source: "code", previous: "terminal", recent: [], at: now + 101)
    let fromBrowser = model.probabilities(appIDs: ["code", "browser", "terminal", "notes"], source: "code", previous: "browser", recent: [], at: now + 101)
    #expect(fromTerminal["browser", default: 0] > fromTerminal["terminal", default: 0])
    #expect(fromBrowser["terminal", default: 0] > fromBrowser["browser", default: 0])
    #expect(fromTerminal["code"] == nil)
    #expect(abs(fromTerminal.values.reduce(0, +) - 1) < 0.000_001)
    #expect(model.count == 200)
}

@Test func adaptsAfterHabitChangesAndRejectsInvalidInput() {
    var model = Predictor()
    let now = Date().timeIntervalSince1970
    for _ in 0..<100 { model.observe(SwitchEvent(timestamp: now - 120 * 86_400, previous: nil, source: "code", target: "old")) }
    for _ in 0..<10 { model.observe(SwitchEvent(timestamp: now, previous: nil, source: "code", target: "new")) }
    model.observe(SwitchEvent(timestamp: .nan, previous: nil, source: "code", target: "new"))
    model.observe(SwitchEvent(timestamp: now, previous: nil, source: "code", target: "code"))
    #expect(model.count == 110)
    let prediction = model.probabilities(appIDs: ["code", "old", "new"], source: "code", previous: nil, recent: [], at: now)
    #expect(prediction["new", default: 0] > prediction["old", default: 0])
    #expect(model.probabilities(appIDs: [], source: "code", previous: nil, recent: []).isEmpty)
}

@MainActor @Test func importsReadOnlyWithoutDuplicatesAndPreservesOnFailure() throws {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let source = folder.appendingPathComponent("Applight.sqlite")
    var db: OpaquePointer?
    #expect(sqlite3_open(source.path, &db) == SQLITE_OK)
    #expect(sqlite3_exec(db, "CREATE TABLE ZRECORD(Z_PK INTEGER,ZDATE REAL,ZPREVIOUS TEXT,ZFROM TEXT,ZTO TEXT); INSERT INTO ZRECORD VALUES(1,800000000,'terminal','code','browser'),(2,800000001,'code','browser','notes'),(3,800000002,NULL,'same','same');", nil, nil, nil) == SQLITE_OK)
    sqlite3_close(db)
    let original = try Data(contentsOf: source)
    let store = try HistoryStore(url: folder.appendingPathComponent("Glint.sqlite"))
    #expect(try store.importApplight(from: source) == 2)
    #expect(try store.importApplight(from: source) == 0)
    #expect(try Data(contentsOf: source) == original)
    #expect(try store.events().count == 2)
    let wrong = folder.appendingPathComponent("Wrong.sqlite")
    sqlite3_open(wrong.path, &db); sqlite3_exec(db, "CREATE TABLE unrelated(x);", nil, nil, nil); sqlite3_close(db)
    #expect(throws: HistoryStore.StoreError.self) { try store.importApplight(from: wrong) }
    #expect(try store.events().count == 2)
    let reopened = try HistoryStore(url: folder.appendingPathComponent("Glint.sqlite"))
    #expect(try reopened.events() == store.events())
}

@Test func replayRealHistoryWhenProvided() throws {
    guard let path = ProcessInfo.processInfo.environment["GLINT_HISTORY_PATH"] else { return }
    let events = try JSONDecoder().decode([SwitchEvent].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    let candidates = Array(Set(events.flatMap { [$0.source, $0.target] + [$0.previous].compactMap { $0 } })).sorted()
    let apps = candidates.map { AppEntry(id: $0, name: $0, url: URL(fileURLWithPath: "/Applications/\($0).app")) }
    let cutoff = Int(Double(events.count) * 0.8)
    var model = Predictor()
    var recent: [String] = []
    var hits = [0, 0, 0]
    var reciprocal = 0.0
    var timings: [Double] = []
    for (i, event) in events.enumerated() {
        if i >= cutoff {
            let start = ContinuousClock.now
            let scores = model.probabilities(appIDs: candidates, source: event.source, previous: event.previous, recent: recent, at: event.timestamp)
            let elapsed = start.duration(to: .now)
            timings.append(Double(elapsed.components.seconds) * 1_000 + Double(elapsed.components.attoseconds) / 1e15)
            let ranked = Search.rank(apps, query: "", recent: recent, current: event.source, running: [], limit: candidates.count, predictions: scores).map(\.id)
            let rank = try #require(ranked.firstIndex(of: event.target)) + 1
            for (j, limit) in [1, 3, 5].enumerated() { hits[j] += rank <= limit ? 1 : 0 }
            reciprocal += 1 / Double(rank)
        }
        model.observe(event)
        recent = ([event.target, event.source] + [event.previous].compactMap { $0 } + recent).reduce(into: [String]()) { result, id in
            if !result.contains(id) { result.append(id) }
        }
        recent = Array(recent.prefix(80))
    }
    let n = events.count - cutoff
    timings.sort()
    print("Swift held-out replay: n=\(n), top1=\(hits[0])/\(n), top3=\(hits[1])/\(n), top5=\(hits[2])/\(n), MRR=\(reciprocal / Double(n)), p50=\(timings[timings.count/2])ms, p95=\(timings[Int(Double(timings.count)*0.95)])ms")
    #expect(hits[2] >= hits[1] && hits[1] >= hits[0])
    #expect(timings[Int(Double(timings.count) * 0.95)] < 10)
}
