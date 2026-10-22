import AppKit
import Testing
import GlintCore
@testable import Glint

private final class BackgroundActivation: NSRunningApplication, @unchecked Sendable {
    override var bundleIdentifier: String? { "fixture.automatic-activation" }
    override var activationPolicy: NSApplication.ActivationPolicy { .accessory }
}

@MainActor @Test func backgroundActivationDuringQuitDoesNotCancelTheHeldSelection() {
    let delegate = AppDelegate()
    let palette = delegate.palette
    defer { palette.orderOut(nil) }
    let apps = (1...2).map { AppEntry(id: "fixture\($0)", name: "Calculator \($0)", url: URL(fileURLWithPath: "/tmp/Fixture\($0).app")) }
    var committed: String?
    palette.onCommit = { committed = $0.id }
    palette.onCancel = { [weak palette] in palette?.orderOut(nil) }
    palette.present(hold: true)
    palette.render(apps, running: [], count: 2)
    palette.receive(0, text: "calc")
    palette.receive(19, text: "2")
    let top = palette.frame.maxY
    let activation = Notification(name: NSWorkspace.didActivateApplicationNotification,
        userInfo: [NSWorkspace.applicationUserInfoKey: BackgroundActivation()])
    delegate.activated(activation)
    palette.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: palette))
    #expect(palette.isVisible && palette.isHold && palette.query == "calc")
    #expect(palette.frame.maxY == top)
    palette.releaseHold()
    #expect(committed == apps[1].id)
    palette.present(hold: false)
    palette.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification, object: palette))
    #expect(!palette.isVisible)
}
