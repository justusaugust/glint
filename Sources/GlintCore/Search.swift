import Foundation

public struct AppEntry: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let url: URL
    public let searchName: String
    public let initials: String

    public init(id: String, name: String, url: URL) {
        self.id = id
        self.name = name
        self.url = url
        self.searchName = Self.normalize(name)
        self.initials = Self.normalize(name.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .compactMap(\.first).map(String.init).joined())
    }

    public static func normalize(_ text: String) -> String {
        text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines.union(.controlCharacters))
    }
}

public struct AppRule: Codable, Equatable, Sendable {
    public let aliases: [String]
    public let pinned: Bool
    public let excluded: Bool

    public init(aliases: [String] = [], pinned: Bool = false, excluded: Bool = false) {
        self.aliases = Array(Set(aliases.map(AppEntry.normalize).filter { !$0.isEmpty })).sorted()
        self.pinned = pinned
        self.excluded = excluded
    }
}

public enum Search {
    public static func score(_ query: String, in app: AppEntry) -> Int? {
        let name = app.searchName
        if name == query { return 10_000 }
        if name.hasPrefix(query) { return 8_000 }
        if app.initials.hasPrefix(query) { return 7_000 }
        if name.split(separator: " ").contains(where: { $0.hasPrefix(query) }) { return 6_000 }
        if name.contains(query) { return 5_000 }
        var cursor = name.startIndex
        var gaps = 0
        for character in query {
            guard cursor < name.endIndex, let match = name[cursor...].firstIndex(of: character) else { return nil }
            gaps += name.distance(from: cursor, to: match)
            cursor = name.index(after: match)
        }
        return 2_000 - gaps * 10 - name.count
    }

    public static func rank(_ apps: [AppEntry], query: String, recent: [String],
                            current: String?, running: Set<String>,
                            limit: Int = 5, predictions: [String: Double] = [:], rules: [String: AppRule] = [:]) -> [AppEntry] {
        let query = AppEntry.normalize(String(query.prefix(128)).trimmingCharacters(in: .whitespacesAndNewlines))
        let recency = Dictionary(recent.enumerated().map { ($1, max(0, 100 - $0)) }, uniquingKeysWith: max)
        return apps.compactMap { app -> (AppEntry, Int)? in
            let rule = rules[app.id]
            guard rule?.excluded != true else { return nil }
            let learned = predictions.isEmpty
                ? recency[app.id, default: 0] * 100 + (running.contains(app.id) ? 10 : 0)
                : Int(predictions[app.id, default: 0] * 1_000_000)
            let priority = learned + (rule?.pinned == true ? 2_000_000 : 0)
            if query.isEmpty {
                guard app.id != current else { return nil }
                return (app, priority)
            }
            let aliasMatch = rule?.aliases.compactMap { alias -> Int? in
                if alias == query { return 9_000 }
                return alias.hasPrefix(query) ? 7_500 : nil
            }.max()
            let match = max(score(query, in: app) ?? Int.min, aliasMatch ?? Int.min)
            guard match != Int.min else { return nil }
            return (app, match * 1_000_000 + priority)
        }.sorted {
            $0.1 == $1.1 ? $0.0.name.localizedStandardCompare($1.0.name) == .orderedAscending : $0.1 > $1.1
        }.prefix(max(0, limit)).map(\.0)
    }
}

public struct HoldGesture: Sendable {
    public enum State: Sendable { case idle, holding, cancelled }
    public enum Effect: Equatable, Sendable { case none, begin, commit, cancel }
    public private(set) var state: State = .idle
    public init() {}

    public mutating func modifier(down: Bool, otherModifier: Bool = false) -> Effect {
        switch (state, down, otherModifier) {
        case (.idle, true, false): state = .holding; return .begin
        case (.holding, false, _): state = .idle; return .commit
        case (.holding, true, true): state = .cancelled; return .cancel
        case (.cancelled, false, _): state = .idle; return .none
        default: return .none
        }
    }

    public mutating func cancel() -> Effect {
        guard state == .holding else { return .none }
        state = .cancelled
        return .cancel
    }

    public mutating func reset() { state = .idle }
}
