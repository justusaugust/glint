import AppKit
import ApplicationServices

// AX references are immutable handles; all messaging stays in the concurrent operations below.
nonisolated struct WindowEntry: @unchecked Sendable, Identifiable {
    let id = UUID()
    let title: String
    let minimized: Bool
    let element: AXUIElement
    var frame: CGRect? = nil
}

nonisolated enum WindowAccess {
    enum Failure: Error, Sendable {
        case permission, unavailable
        var message: String {
            switch self {
            case .permission: "Allow Accessibility access to choose windows"
            case .unavailable: "Windows unavailable — open the app or try again"
            }
        }
    }

    static func windowTitle(_ text: String) -> String {
        let title = String(text.prefix(256)).components(separatedBy: .controlCharacters)
            .filter { !$0.isEmpty }.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Untitled window" : title
    }

    static func selectableSize(_ size: CGSize) -> Bool {
        // AppKit exposes transient titlebar tooltips as tiny AXDialog windows.
        size.width >= 80 && size.height >= 40
    }

    @concurrent static func list(pid: pid_t) async -> Result<[WindowEntry], Failure> {
        guard AXIsProcessTrusted() else { return .failure(.permission) }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.15)
        var value: CFArray?
        // shortcut: inspect up to 128 windows per request; add paging if real usage reaches this limit.
        let error = AXUIElementCopyAttributeValues(app, kAXWindowsAttribute as CFString, 0, 128, &value)
        if error == .noValue { return .success([]) }
        guard error == .success, let elements = value as? [AXUIElement] else { return .failure(.unavailable) }
        let deadline = ContinuousClock.now + .milliseconds(600)
        var windows: [WindowEntry] = []
        for element in elements {
            guard !Task.isCancelled, ContinuousClock.now < deadline else { return .failure(.unavailable) }
            AXUIElementSetMessagingTimeout(element, 0.15)
            var attributes: CFArray?
            let keys = [kAXTitleAttribute, kAXMinimizedAttribute, kAXSubroleAttribute, kAXRoleAttribute, kAXPositionAttribute, kAXSizeAttribute] as CFArray
            let status = AXUIElementCopyMultipleAttributeValues(element, keys, [], &attributes)
            if status == .invalidUIElement { continue }
            guard status == .success, let values = attributes as? [Any], values.count == 6 else { return .failure(.unavailable) }
            guard values[3] as? String == kAXWindowRole else { continue }
            var frame: CGRect?
            if CFGetTypeID(values[4] as CFTypeRef) == AXValueGetTypeID(), CFGetTypeID(values[5] as CFTypeRef) == AXValueGetTypeID() {
                var point = CGPoint.zero, size = CGSize.zero
                let positionValue = unsafeBitCast(values[4] as CFTypeRef, to: AXValue.self)
                let sizeValue = unsafeBitCast(values[5] as CFTypeRef, to: AXValue.self)
                if AXValueGetValue(positionValue, .cgPoint, &point), AXValueGetValue(sizeValue, .cgSize, &size) {
                    guard selectableSize(size) else { continue }
                    frame = CGRect(origin: point, size: size)
                }
            }
            let subrole = values[2] as? String
            guard subrole != kAXFloatingWindowSubrole, subrole != kAXSystemFloatingWindowSubrole else { continue }
            windows.append(WindowEntry(title: windowTitle(values[0] as? String ?? ""),
                                       minimized: values[1] as? Bool ?? false, element: element, frame: frame))
        }
        return .success(windows)
    }

    @concurrent static func focus(_ window: WindowEntry) async -> Bool {
        guard !Task.isCancelled, AXIsProcessTrusted() else { return false }
        AXUIElementSetMessagingTimeout(window.element, 0.15)
        if window.minimized,
           AXUIElementSetAttributeValue(window.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse) != .success { return false }
        let raised = AXUIElementPerformAction(window.element, kAXRaiseAction as CFString)
        guard raised == .success else { return false }
        AXUIElementSetAttributeValue(window.element, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        return true
    }
}
