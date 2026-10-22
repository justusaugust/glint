import Foundation
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
