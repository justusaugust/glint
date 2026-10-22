import AppKit
import Testing
import GlintCore
@testable import Glint

@MainActor @Test func holdInputDoesNotSelectTextAndNormalEditingStillWorks() throws {
    NSApplication.shared.setActivationPolicy(.accessory)
    let palette = Palette()
    defer { palette.orderOut(nil) }
    func searchField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.placeholderString == "Switch to an app" { return field }
        return view.subviews.lazy.compactMap { searchField(in: $0) }.first
    }
    let content = try #require(palette.contentView)
    let field = try #require(searchField(in: content))
    palette.present(hold: false)
    let editor = try #require(field.currentEditor() as? NSTextView)
    editor.insertText("ca", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(field.stringValue == "ca")
    #expect(editor.selectedRange().length == 0)
    editor.setSelectedRange(NSRange(location: 0, length: 1))
    editor.insertText("b", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(field.stringValue == "ba")
    #expect(editor.selectedRange() == NSRange(location: 1, length: 0))

    // Exercise a hold after a live editor, the state that left highlighted query text behind.
    palette.present(hold: true)
    palette.receive(0, text: "cal")
    #expect(field.stringValue == "cal")
    #expect(field.currentEditor() == nil)
    #expect(!palette.isKeyWindow)
    palette.receive(51, text: "")
    #expect(field.stringValue == "ca")

    palette.orderOut(nil)
    palette.present(hold: false)
    let resumed = try #require(field.currentEditor() as? NSTextView)
    resumed.insertText("n", replacementRange: NSRange(location: NSNotFound, length: 0))
    resumed.insertText("o", replacementRange: NSRange(location: NSNotFound, length: 0))
    #expect(field.stringValue == "no")
    #expect(resumed.selectedRange().length == 0)
}

@MainActor @Test func numbersChooseFilteredResultsAndShiftEntersDigits() throws {
    let palette = Palette()
    defer { palette.orderOut(nil) }
    let apps = (1...5).map { AppEntry(id: "app\($0)", name: "App \($0)", url: URL(fileURLWithPath: "/tmp/GlintTest\($0).app")) }
    var committed: String?
    palette.onCommit = { committed = $0.id }
    palette.present(hold: true)
    palette.receive(0, text: "app")
    palette.render(apps, running: [], count: 5)
    palette.receive(19, text: "2")
    #expect(palette.query == "app")
    palette.commit()
    #expect(committed == "app2")
    palette.receive(19, text: "@", literalNumber: true)
    #expect(palette.query == "app2")
    palette.receive(51, text: "")
    #expect(palette.query == "app")

    palette.present(hold: true)
    palette.receive(18, text: "!", literalNumber: true)
    palette.receive(0, text: "Password")
    #expect(palette.query == "1Password")
    palette.present(hold: false)
    palette.render(apps, running: [], count: 5)
    for (flags, characters, expectedQuery) in [(NSEvent.ModifierFlags.shift, "!", "1"), ([], "2", "1")] {
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
            timestamp: 0, windowNumber: palette.windowNumber, context: nil, characters: characters,
            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: flags.isEmpty ? 19 : 18))
        palette.sendEvent(event)
        #expect(palette.query == expectedQuery)
    }
    palette.commit()
    #expect(committed == "app2")
}

@MainActor @Test func shiftDuringAHoldTypesLiteralDigitsWithoutCancelling() throws {
    let shortcut = Shortcut()
    var began = 0, committed = 0, cancelled = 0
    var literal = false
    shortcut.begin = { began += 1 }
    shortcut.commit = { committed += 1 }
    shortcut.cancel = { cancelled += 1 }
    shortcut.input = { _, _, value in literal = value }
    let command = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | HoldKey.rightCommand.deviceMask)
    func deliver(_ type: CGEventType, code: UInt16, flags: CGEventFlags) throws {
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true))
        event.flags = flags
        _ = shortcut.receive(type, event)
    }
    try deliver(.flagsChanged, code: 54, flags: command)
    try deliver(.flagsChanged, code: 56, flags: command.union(.maskShift))
    try deliver(.keyDown, code: 18, flags: command.union(.maskShift))
    try deliver(.flagsChanged, code: 54, flags: .maskShift)
    #expect(began == 1 && committed == 1 && cancelled == 0 && literal)
    try deliver(.flagsChanged, code: 54, flags: command.union(.maskShift))
    #expect(began == 1)
}

@MainActor @Test func reopeningAfterFilteringKeepsTheSearchAnchor() {
    let palette = Palette()
    defer { palette.orderOut(nil) }
    let apps = (1...5).map { AppEntry(id: "app\($0)", name: "App \($0)", url: URL(fileURLWithPath: "/tmp/GlintTest\($0).app")) }
    for hold in [true, false] {
        palette.present(hold: hold)
        palette.render(apps, running: [], count: 5)
        let top = palette.frame.maxY
        let expandedHeight = palette.frame.height
        palette.receive(0, text: "app")
        palette.render(Array(apps.prefix(1)), running: [], count: 5)
        #expect(palette.frame.height < expandedHeight)
        #expect(palette.frame.maxY == top)
        // Shortcut cancellation hides the panel without resizing it.
        palette.orderOut(nil)
        palette.present(hold: hold)
        palette.render(apps, running: [], count: 5)
        #expect(palette.frame.maxY == top)
        palette.orderOut(nil)
    }
}


@MainActor @Test(arguments: [
    NSRect(x: 0, y: 0, width: 2056, height: 1290),
    NSRect(x: 2056, y: 40, width: 1920, height: 1040),
    NSRect(x: -1080, y: -160, width: 1080, height: 1880),
    NSRect(x: -540, y: 0, width: 540, height: 960),
    NSRect(x: 0, y: 1329, width: 1920, height: 1040),
    NSRect(x: 0, y: -1080, width: 1920, height: 1040),
    NSRect(x: 0, y: 0, width: 800, height: 600)
]) func panelPlacementFitsAvailableDisplay(_ visibleFrame: NSRect) {
    let compact = Palette.placement(in: visibleFrame, height: 244)
    let expanded = Palette.placement(in: visibleFrame, height: 492)
    #expect(visibleFrame.contains(compact))
    #expect(visibleFrame.contains(expanded))
    #expect(compact.maxY == expanded.maxY)
}

@MainActor @Test func displayReconfigurationCancelsAnActiveHold() throws {
    let palette = Palette()
    let shortcut = Shortcut()
    defer { palette.orderOut(nil) }
    var commits = 0
    shortcut.begin = { [weak palette] in palette?.present(hold: true) }
    shortcut.cancel = { [weak palette] in palette?.orderOut(nil) }
    shortcut.commit = { commits += 1 }
    palette.onCancel = { [weak shortcut] in shortcut?.cancelHold() }
    let command = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | HoldKey.rightCommand.deviceMask)
    func modifier(_ flags: CGEventFlags) throws {
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 54, keyDown: true))
        event.flags = flags
        _ = shortcut.receive(.flagsChanged, event)
    }
    try modifier(command)
    #expect(palette.isVisible && shortcut.holding)
    NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: NSApplication.shared)
    #expect(!palette.isVisible && !shortcut.holding)
    try modifier([])
    #expect(commits == 0)
    try modifier(command)
    #expect(palette.isVisible && shortcut.holding)
    try modifier([])
    #expect(commits == 1)
}


@MainActor @Test func interruptedHoldResetsWithoutAStaleCommitOrSwallowedKey() throws {
    for interruption: CGEventType? in [nil, .tapDisabledByTimeout, .tapDisabledByUserInput] {
        let shortcut = Shortcut()
        var begins = 0, commits = 0
        shortcut.begin = { begins += 1 }
        shortcut.commit = { commits += 1 }
        let command = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | HoldKey.rightCommand.deviceMask)
        func event(code: UInt16, flags: CGEventFlags) throws -> CGEvent {
            let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true))
            event.flags = flags
            return event
        }
        let down = try event(code: 54, flags: command)
        let up = try event(code: 54, flags: [])
        let letter = try event(code: 0, flags: command)
        _ = shortcut.receive(.flagsChanged, down)
        #expect(shortcut.receive(.keyDown, letter))
        if let interruption { _ = shortcut.receive(interruption, letter) }
        else { shortcut.reset() }
        #expect(!shortcut.holding)
        #expect(!shortcut.receive(.keyUp, letter))
        _ = shortcut.receive(.flagsChanged, up)
        #expect(commits == 0)
        _ = shortcut.receive(.flagsChanged, down)
        #expect(shortcut.holding)
        _ = shortcut.receive(.flagsChanged, up)
        #expect(begins == 2 && commits == 1)
    }
}


@MainActor @Test func filteredResultsKeepTheDisplayConstrainedWidth() {
    let palette = Palette()
    defer { palette.orderOut(nil) }
    let app = AppEntry(id: "app", name: "App", url: URL(fileURLWithPath: "/tmp/GlintTest.app"))
    palette.setFrame(NSRect(x: -540, y: 0, width: 540, height: 498), display: false)
    palette.render([app], running: [], count: 1)
    #expect(palette.frame.width == 540)
    palette.receive(0, text: "app")
    palette.render([], running: [], count: 1)
    #expect(palette.frame.width == 540)
}
