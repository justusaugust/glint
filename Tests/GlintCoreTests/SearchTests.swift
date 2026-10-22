import Foundation
import Testing
@testable import GlintCore

private func app(_ id: String, _ name: String) -> AppEntry {
    AppEntry(id: id, name: name, url: URL(fileURLWithPath: "/Applications/\(name).app"))
}

@Test func searchesInstalledAndWindowlessApps() {
    let apps = [app("code", "Visual Studio Code"), app("safari", "Safari"), app("notes", "Notes"), app("cafe", "Café")]
    func find(_ query: String) -> [String] {
        Search.rank(apps, query: query, recent: [], current: nil, running: ["safari"]).map(\.id)
    }
    #expect(find("notes") == ["notes"])
    #expect(find("vsc") == ["code"])
    #expect(find("cafe") == ["cafe"])
    #expect(find("sfri") == ["safari"])
    #expect(find("nonexistent").isEmpty)
    #expect(find(String(repeating: "x", count: 10_000)).isEmpty)
    #expect(Search.score("whats", in: app("whatsapp", "\u{200e}WhatsApp")) == 8_000)
}

@Test func coldStartUsesRecencyAndPredictionsRespectExactMatches() {
    let apps = [app("code", "Code"), app("codex", "Codex"), app("safari", "Safari")]
    let previous = Search.rank(apps, query: "", recent: ["code", "safari", "codex"], current: "code",
                               running: ["code", "codex"])
    #expect(previous.first?.id == "safari")
    let learned = Search.rank(apps, query: "", recent: ["code", "safari", "codex"], current: "code",
                              running: ["code", "safari"], predictions: ["codex": 0.9, "safari": 0.1])
    #expect(learned.first?.id == "codex")
    let exact = Search.rank(apps, query: "Code", recent: ["codex"], current: nil, running: [],
                            predictions: ["codex": 0.99, "code": 0.01])
    #expect(exact.first?.id == "code")
    #expect(Search.rank(apps, query: "", recent: [], current: nil, running: [], limit: 0).isEmpty)
}

@Test func holdTypeReleaseAndCancellation() {
    var gesture = HoldGesture()
    #expect(gesture.modifier(down: true) == .begin)
    #expect(gesture.modifier(down: true) == .none)
    #expect(gesture.modifier(down: false) == .commit)
    #expect(gesture.modifier(down: false) == .none)
    #expect(gesture.modifier(down: true) == .begin)
    #expect(gesture.cancel() == .cancel)
    #expect(gesture.modifier(down: true) == .none)
    #expect(gesture.modifier(down: false) == .none)
    #expect(gesture.modifier(down: true, otherModifier: true) == .none)
    #expect(gesture.modifier(down: false) == .none)
    #expect(gesture.modifier(down: true) == .begin)
    #expect(gesture.modifier(down: true, otherModifier: true) == .cancel)
    gesture.reset()
    #expect(gesture.modifier(down: false) == .none)
}

@Test func searchBenchmark() {
    let apps = (0..<1_000).map { app("app\($0)", "Application \($0)") } + [app("codex", "Codex")]
    let start = ContinuousClock.now
    for _ in 0..<100 {
        #expect(Search.rank(apps, query: "cod", recent: [], current: nil, running: []).first?.id == "codex")
    }
    let elapsed = start.duration(to: .now)
    print("Search benchmark: 100 queries across 1,001 apps: \(elapsed)")
    #expect(elapsed < .seconds(5))
}
