import Foundation

public struct SwitchEvent: Codable, Hashable, Sendable {
    public let timestamp: Double
    public let previous: String?
    public let source: String
    public let target: String
    public init(timestamp: Double, previous: String?, source: String, target: String) {
        self.timestamp = timestamp; self.previous = previous; self.source = source; self.target = target
    }
    public var isValid: Bool {
        timestamp.isFinite && timestamp > 0 && source != target && !source.isEmpty && !target.isEmpty
        && source.utf8.count <= 512 && target.utf8.count <= 512 && (previous?.utf8.count ?? 0) <= 512
    }
}

public struct Predictor: Sendable {
    private struct Counts: Sendable {
        var values: [String: Double] = [:]
        var updated: Double = 0
        func values(at timestamp: Double) -> [String: Double] {
            let decay = pow(2, -max(0, timestamp - updated) / (14 * 86_400))
            return values.mapValues { $0 * decay }
        }
        mutating func add(_ target: String, at timestamp: Double) {
            values = values(at: timestamp).filter { $0.value >= 0.0001 }
            values[target, default: 0] += 1
            updated = max(updated, timestamp)
        }
    }
    private var tables: [String: Counts] = [:]
    public private(set) var count = 0
    public init() {}

    private func keys(source: String, previous: String?, at timestamp: Double) -> [String] {
        let date = Date(timeIntervalSince1970: timestamp)
        let calendar = Calendar(identifier: .gregorian)
        let hour = calendar.component(.hour, from: date) / 4
        let weekday = calendar.component(.weekday, from: date)
        return ["global", "from:\(source)", "seq:\(previous ?? "")|\(source)", "hour:\(hour)",
                "sourcehour:\(source)|\(hour)", "week:\(weekday == 1 || weekday == 7)"]
    }

    public mutating func observe(_ event: SwitchEvent) {
        guard event.isValid else { return }
        for key in keys(source: event.source, previous: event.previous, at: event.timestamp) {
            tables[key, default: Counts()].add(event.target, at: event.timestamp)
        }
        count += 1
    }

    public func probabilities(appIDs: [String], source: String, previous: String?, recent: [String],
                              at timestamp: Double = Date().timeIntervalSince1970) -> [String: Double] {
        let candidates = Array(Set(appIDs)).filter { $0 != source }
        guard !candidates.isEmpty else { return [:] }
        let keys = keys(source: source, previous: previous, at: timestamp)
        let global = tables["global"]?.values(at: timestamp) ?? [:]
        let total = global.values.reduce(0, +)
        let prior = Dictionary(uniqueKeysWithValues: candidates.map { ($0, (global[$0, default: 0] + 0.25) / (total + 0.25 * Double(appIDs.count))) })
        func smooth(_ key: String, _ base: [String: Double], _ alpha: Double) -> [String: Double] {
            let counts = tables[key]?.values(at: timestamp) ?? [:]
            let total = counts.values.reduce(0, +)
            return Dictionary(uniqueKeysWithValues: candidates.map { ($0, (counts[$0, default: 0] + alpha * base[$0, default: 0]) / (total + alpha)) })
        }
        let sourceScores = smooth(keys[1], prior, 16)
        let hour = smooth(keys[3], prior, 10)
        let sourceHour = smooth(keys[4], sourceScores, 10)
        let week = smooth(keys[5], prior, 10)
        let order = ([previous].compactMap { $0 } + recent).reduce(into: [String]()) { result, id in
            if !result.contains(id) { result.append(id) }
        }
        let recency = Dictionary(uniqueKeysWithValues: candidates.map { id in
            (id, order.firstIndex(of: id).map { exp(-Double($0) / 3) } ?? 0.001)
        })
        let recencyTotal = recency.values.reduce(0, +)
        let base = Dictionary(uniqueKeysWithValues: candidates.map { id in
            (id, 0.30 * sourceScores[id, default: 0] + 0.025 * hour[id, default: 0]
                + 0.025 * sourceHour[id, default: 0] + 0.025 * week[id, default: 0]
                + 0.625 * recency[id, default: 0] / recencyTotal)
        })
        let baseTotal = base.values.reduce(0, +)
        let sequence = tables[keys[2]]?.values(at: timestamp) ?? [:]
        let observations = candidates.reduce(0.0) { $0 + sequence[$1, default: 0] }
        // A Bayesian backoff lets repeated context evidence override recency as confidence grows.
        // Prior strength 64 and base weights were selected by chronological validation MRR.
        return Dictionary(uniqueKeysWithValues: candidates.map { id in
            (id, (sequence[id, default: 0] + 64 * base[id, default: 0] / baseTotal) / (observations + 64))
        })
    }
}
