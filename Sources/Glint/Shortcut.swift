import AppKit
import Carbon
import GlintCore

enum HoldKey: Int, CaseIterable {
    case rightCommand = 54, rightOption = 61, rightControl = 62, leftControl = 59
    var title: String {
        switch self {
        case .rightCommand: "Right Command"
        case .rightOption: "Right Option"
        case .rightControl: "Right Control"
        case .leftControl: "Left Control"
        }
    }
    var glyph: String {
        switch self { case .rightCommand: "Right ⌘"; case .rightOption: "Right ⌥"; default: title.replacingOccurrences(of: "Control", with: "⌃") }
    }
    var deviceMask: UInt64 {
        switch self { case .rightCommand: 0x10; case .rightOption: 0x40; case .rightControl: 0x2000; case .leftControl: 0x1 }
    }
    var flag: CGEventFlags {
        switch self { case .rightCommand: .maskCommand; case .rightOption: .maskAlternate; default: .maskControl }
    }
}

final class Shortcut {
    var key: HoldKey = .rightCommand
    var begin: (() -> Void)?
    var commit: (() -> Void)?
    var cancel: (() -> Void)?
    var input: ((CGKeyCode, String) -> Void)?
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var gesture = HoldGesture()
    private var swallowed: Set<CGKeyCode> = []
    private var hotKey: EventHotKeyRef?
    private var hotKeyHandler: EventHandlerRef?
    private(set) var failure: String?
    var enabled: Bool { port != nil }
    var holding: Bool { gesture.state == .holding }

    func installFallback(_ action: @escaping () -> Void) -> Bool {
        fallback = action
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let handlerStatus = InstallEventHandler(GetApplicationEventTarget(), { _, _, context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated { Unmanaged<Shortcut>.fromOpaque(context).takeUnretainedValue().fallback?() }
            return noErr
        }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &hotKeyHandler)
        guard handlerStatus == noErr else { return false }
        return RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey),
            EventHotKeyID(signature: 0x474C4E54, id: 1), GetApplicationEventTarget(), 0, &hotKey) == noErr
    }
    private var fallback: (() -> Void)?

    @discardableResult func start() -> Bool {
        stop()
        guard AXIsProcessTrusted() else {
            failure = "Allow Glint in System Settings → Privacy & Security → Accessibility."
            return false
        }
        let mask = [CGEventType.flagsChanged, .keyDown, .keyUp, .leftMouseDown, .rightMouseDown]
            .reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                 eventsOfInterest: mask, callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let consumed = MainActor.assumeIsolated {
                Unmanaged<Shortcut>.fromOpaque(context).takeUnretainedValue().receive(type, event)
            }
            return consumed ? nil : Unmanaged.passUnretained(event)
        }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let port else { failure = "The keyboard hook could not start. Check Accessibility access, then retry."; return false }
        source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        failure = nil
        return true
    }

    func stop() {
        reset()
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let port { CFMachPortInvalidate(port) }
        source = nil
        port = nil
    }

    func reset() { gesture.reset(); swallowed.removeAll(); cancel?() }
    func cancelHold() { if gesture.cancel() == .cancel { cancel?() } }

    private func receive(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            reset()
            if let port { CGEvent.tapEnable(tap: port, enable: true) }
            return false
        }
        let code = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyUp, swallowed.remove(code) != nil { return true }
        if !holding && type != .flagsChanged { return false }
        // Secure text entry must never become launcher input, even after an interrupted gesture.
        if IsSecureEventInputEnabled() { reset(); return false }
        if type == .flagsChanged {
            let down = event.flags.rawValue & key.deviceMask != 0
            let others = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift]).subtracting(key.flag)
            // Only the configured physical key starts a gesture; unrelated flag changes cannot start one.
            if code != key.rawValue && gesture.state == .idle { return false }
            let effect = gesture.modifier(down: down, otherModifier: !others.isEmpty)
            switch effect { case .begin: begin?(); case .commit: commit?(); case .cancel: cancel?(); case .none: break }
            return false
        }
        if type == .leftMouseDown || type == .rightMouseDown { return false }
        guard holding, type == .keyDown else { return false }
        swallowed.insert(code)
        if code == kVK_Escape { cancelHold(); return true }
        var characters = [UniChar](repeating: 0, count: 64)
        var count = 0
        event.keyboardGetUnicodeString(maxStringLength: characters.count, actualStringLength: &count, unicodeString: &characters)
        let string = NSEvent(cgEvent: event)?.charactersIgnoringModifiers ?? String(utf16CodeUnits: characters, count: count)
        input?(code, string)
        return true
    }
}
