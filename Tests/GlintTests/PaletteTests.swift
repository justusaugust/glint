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
