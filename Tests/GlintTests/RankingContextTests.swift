import AppKit
import Testing
import GlintCore
@testable import Glint

@MainActor @Test(arguments: [false, true]) func searchedSourceKeepsItsLearnedWeightAfterQuitting(learned: Bool) {
    let apps = ["Calculator", "Calendar", "Editor"].map {
        AppEntry(id: $0, name: $0, url: URL(fileURLWithPath: "/tmp/\($0).app"))
    }
    let now = 1_800_000_000.0
    var model = Predictor()
    for _ in 0..<(learned ? 5 : 0) {
        model.observe(SwitchEvent(timestamp: now, previous: nil, source: "Editor", target: "Calculator"))
    }
    let context = RankingContext(predictor: model, recent: ["Calculator", "Editor", "Calendar"],
                                 source: "Calculator", timestamp: now)
    for running: Set<String> in [["Calculator", "Editor"], ["Editor"]] {
        #expect(context.rank(apps, query: "ca", running: running).first?.id == "Calculator")
        #expect(context.rank(apps, query: " Calendar ", running: running).first?.id == "Calendar")
        #expect(context.rank(apps, query: "ca", running: running,
                             rules: ["Calculator": AppRule(excluded: true)]).first?.id == "Calendar")
    }
    #expect(!context.rank(apps, query: "", running: ["Calculator", "Editor"]).contains { $0.id == "Calculator" })
    #expect(context.rank(apps, query: "", running: ["Editor"]).first?.id == "Calculator")
    #expect(context.rank(apps, query: " ", running: ["Editor"],
                         rules: ["Calculator": AppRule(excluded: true)]).first?.id != "Calculator")
}

@MainActor @Test func focusHandoffOnlyChangesTheNextPresentation() {
    let apps = ["Calculator", "Calendar", "Editor"].map {
        AppEntry(id: $0, name: $0, url: URL(fileURLWithPath: "/tmp/\($0).app"))
    }
    let now = 1_800_000_000.0
    var model = Predictor()
    var recent = ["Calculator", "Calendar", "Editor"]
    let context = RankingContext(predictor: model, recent: recent, source: "Editor", timestamp: now)
    let before = context.rank(apps, query: "ca", running: ["Editor"])
    for _ in 0..<100 {
        model.observe(SwitchEvent(timestamp: now, previous: "Calendar", source: "Editor", target: "Calendar"))
    }
    recent = ["Calendar", "Editor", "Calculator"]
    #expect(context.rank(apps, query: "ca", running: ["Editor"]) == before)
    #expect(before.first?.id == "Calculator")
    let next = RankingContext(predictor: model, recent: recent, source: "Editor", timestamp: now)
    #expect(next.rank(apps, query: "ca", running: ["Editor"]).first?.id == "Calendar")
}

@MainActor @Test func cachedWeightsMatchUncachedAcrossCatalogAndModeChanges() {
    let now = 1_800_000_000.0
    let apps = (0..<9).map {
        AppEntry(id: "app\($0)", name: "Application \($0)", url: URL(fileURLWithPath: "/tmp/Fixture\($0).app"))
    }
    var model = Predictor()
    for i in 0..<200 {
        model.observe(SwitchEvent(timestamp: now + Double(i), previous: "app\((i+2)%9)",
                                  source: "app\(i%9)", target: "app\((i+1)%9)"))
    }
    let recent = apps.map(\.id)
    let context = RankingContext(predictor: model, recent: recent, source: "app0", timestamp: now+300)
    let catalogs = [Array(apps.prefix(8)), apps, Array(apps.dropFirst()), Array(apps.reversed()), [],
                    apps + [apps[0]], apps]
    let rules = ["app1": AppRule(aliases: ["work"], pinned: true), "app2": AppRule(excluded: true)]
    for catalog in catalogs {
        for includeSource in [false, true, false, true] {
            let expected = model.probabilities(appIDs: catalog.map(\.id), source: "app0", previous: "app1",
                                               recent: recent, includeSource: includeSource, at: now+300)
            let actual = context.probabilities(for: catalog, includeSource: includeSource)
            #expect(Set(actual.keys) == Set(expected.keys))
            for (id, value) in expected { #expect(abs(actual[id, default: -1] - value) < 1e-12) }
            #expect(context.probabilities(for: catalog, includeSource: includeSource) == actual)
        }
        for running: Set<String> in [["app0"], []] {
            for query in ["", " ", "app", "application 0", "work", "missing"] {
                let scores = model.probabilities(appIDs: catalog.map(\.id), source: "app0", previous: "app1",
                    recent: recent, includeSource: !AppEntry.normalize(query).isEmpty || !running.contains("app0"), at: now+300)
                let expected = Search.rank(catalog, query: query, recent: recent, current: "app0",
                                           running: running, predictions: scores, rules: rules)
                #expect(context.rank(catalog, query: query, running: running, rules: rules) == expected)
            }
        }
    }
    let renamed = [AppEntry(id: "app0", name: "Renamed", url: apps[0].url)] + apps.dropFirst()
    #expect(context.rank(renamed, query: "renamed", running: ["app0"]).first?.name == "Renamed")
    let cold = RankingContext(predictor: Predictor(), recent: recent, source: "app0", timestamp: now)
    #expect(cold.probabilities(for: apps, includeSource: true).isEmpty)
}

@MainActor @Test func holdTypeNumberReleaseWorksThroughCachedRanking() throws {
    let apps = ["Calculator", "Calendar", "Editor"].map {
        AppEntry(id: $0, name: $0, url: URL(fileURLWithPath: "/tmp/\($0).app"))
    }
    let now = 1_800_000_000.0
    var model = Predictor()
    model.observe(SwitchEvent(timestamp: now, previous: nil, source: "Editor", target: "Calculator"))
    let palette = Palette()
    let shortcut = Shortcut()
    defer { palette.orderOut(nil) }
    var context: RankingContext?
    var committed: [String] = []
    palette.onQuery = { [weak palette] query in
        guard let palette, let context else { return }
        palette.render(context.rank(apps, query: query, running: ["Editor"]), running: ["Editor"], count: apps.count)
    }
    palette.onCommit = { [weak palette] app in committed.append(app.id); context = nil; palette?.orderOut(nil) }
    shortcut.begin = { [weak palette] in
        context = RankingContext(predictor: model, recent: ["Calculator", "Editor", "Calendar"], source: "Editor", timestamp: now)
        palette?.present(hold: true)
        palette?.onQuery?("")
    }
    shortcut.input = { [weak palette] code, text, literal in palette?.receive(code, text: text, literalNumber: literal) }
    shortcut.commit = { [weak palette] in palette?.releaseHold() }
    shortcut.cancel = { [weak palette] in context = nil; palette?.orderOut(nil) }
    let command = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | HoldKey.rightCommand.deviceMask)
    @discardableResult func deliver(_ type: CGEventType, code: UInt16, text: String = "", flags: CGEventFlags) throws -> Bool {
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: type != .keyUp))
        event.flags = flags
        let units = Array(text.utf16)
        event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        return shortcut.receive(type, event)
    }
    for _ in 0..<2 {
        try deliver(.flagsChanged, code: 54, flags: command)
        let top = palette.frame.maxY
        for (code, text): (UInt16, String) in [(8, "c"), (0, "a"), (37, "l")] {
            #expect(try deliver(.keyDown, code: code, text: text, flags: command))
            #expect(try deliver(.keyUp, code: code, text: text, flags: command))
        }
        #expect(palette.query == "cal" && palette.isHold && !palette.isKeyWindow)
        #expect(palette.frame.maxY == top)
        try deliver(.keyDown, code: 19, text: "2", flags: command)
        #expect(palette.query == "cal")
        try deliver(.keyUp, code: 19, text: "2", flags: command)
        try deliver(.flagsChanged, code: 54, flags: [])
        #expect(committed.last == "Calendar" && context == nil && !palette.isVisible)
    }
    try deliver(.flagsChanged, code: 54, flags: command)
    try deliver(.keyDown, code: 8, text: "c", flags: command)
    try deliver(.keyDown, code: 53, flags: command)
    try deliver(.flagsChanged, code: 54, flags: [])
    #expect(committed == ["Calendar", "Calendar"] && context == nil && !palette.isVisible)
}
