import AppKit
import GlintCore

final class Palette: NSPanel, NSTextFieldDelegate, NSWindowDelegate {
    private static let initialSize = NSSize(width: 688, height: 498)
    private let queryField = NSTextField()
    private var queryTrailing: NSLayoutConstraint!
    private let searchIcon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!)
    private let backButton = NSButton(image: NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Back to apps")!, target: nil, action: nil)
    private struct WindowSession {
        enum Content { case loading, ready([WindowEntry]), unavailable(String) }
        let id = UUID()
        let app: AppEntry
        let appQuery: String
        let appSelection: Int
        var content: Content = .loading
    }
    private var windowSession: WindowSession?
    private var windowTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var previews: [UUID: NSImage] = [:]
    private struct CachedPreview {
        let window: WindowEntry
        let image: NSImage
        let captured: ContinuousClock.Instant
    }
    private var previewCache: [CachedPreview] = []
    private var attemptedPreviews: Set<UUID> = []
    private let previewButton = NSButton(title: "Enable previews", target: nil, action: nil)
    private let settingsButton = NSButton()
    var canPreview: () -> Bool = { CGPreflightScreenCaptureAccess() }
    var loadPreviews: ((AppEntry, [WindowEntry], @escaping @MainActor (UUID, CGImage) -> Void) async -> Void)?
    var onEnablePreviews: (() -> Bool)?
    var loadWindows: ((AppEntry) async -> Result<[WindowEntry], WindowAccess.Failure>)?
    var onWindowCommit: ((AppEntry, WindowEntry) -> Void)?
    var isChoosingWindow: Bool { windowSession != nil }
    private let footer = NSTextField(labelWithString: "")
    private let empty = NSTextField(labelWithString: "No matching apps")
    private let rows = NSStackView()
    private let container = NSView()
    private var items: [AppEntry] = []
    private var selected = 0
    private var explicitApp: AppEntry?
    private var running: Set<String> = []
    private var icons: [URL: NSImage] = [:]
    private var lastMousePosition = NSEvent.mouseLocation
    var onQuery: ((String) -> Void)?
    var onCommit: ((AppEntry) -> Void)?
    var onCancel: (() -> Void)?
    var onSettings: (() -> Void)?
    var isHold = false
    var holdLabel = "Right ⌘"
    var indexing = true
    private(set) var query = ""

    init() {
        super.init(contentRect: NSRect(origin: .zero, size: Self.initialSize),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        title = "Glint"
        setAccessibilityTitle("Glint app switcher")
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .floating
        hidesOnDeactivate = false
        isMovableByWindowBackground = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        animationBehavior = .none
        delegate = self

        // Glass refraction needs space outside the visible rounded surface.
        contentView = GlassBackdrop(content: container)

        searchIcon.contentTintColor = .secondaryLabelColor
        add(searchIcon)
        backButton.target = self
        backButton.action = #selector(backClicked)
        backButton.isBordered = false
        backButton.contentTintColor = .secondaryLabelColor
        backButton.isHidden = true
        backButton.toolTip = "Back to apps (← or esc)"
        add(backButton)
        queryField.isBordered = false
        queryField.drawsBackground = false
        queryField.focusRingType = .none
        queryField.font = .systemFont(ofSize: 28, weight: .regular)
        queryField.placeholderString = "Switch to an app"
        queryField.delegate = self
        queryField.setAccessibilityLabel("Search apps")
        queryField.setAccessibilityIdentifier("glint-search")
        queryField.cell?.isScrollable = true
        add(queryField)

        let settings = settingsButton
        settings.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")
        settings.target = self
        settings.action = #selector(settingsClicked)
        settings.isBordered = false
        settings.contentTintColor = .secondaryLabelColor
        settings.toolTip = "Settings"
        add(settings)
        previewButton.target = self
        previewButton.action = #selector(enablePreviews)
        previewButton.bezelStyle = .rounded
        previewButton.toolTip = "Allow Screen Recording for window thumbnails. Images stay in memory."
        previewButton.isHidden = true
        add(previewButton)

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 4
        add(rows)
        empty.font = .systemFont(ofSize: 15)
        empty.textColor = .secondaryLabelColor
        add(empty)
        footer.font = .systemFont(ofSize: 11, weight: .medium)
        footer.lineBreakMode = .byTruncatingTail
        footer.textColor = .secondaryLabelColor
        add(footer)

        queryTrailing = queryField.trailingAnchor.constraint(equalTo: settings.leadingAnchor, constant: -16)
        NSLayoutConstraint.activate([
            searchIcon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 26),
            searchIcon.topAnchor.constraint(equalTo: container.topAnchor, constant: 28),
            searchIcon.widthAnchor.constraint(equalToConstant: 25), searchIcon.heightAnchor.constraint(equalToConstant: 25),
            backButton.centerXAnchor.constraint(equalTo: searchIcon.centerXAnchor),
            backButton.centerYAnchor.constraint(equalTo: searchIcon.centerYAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 28), backButton.heightAnchor.constraint(equalToConstant: 28),
            queryField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 15),
            queryField.centerYAnchor.constraint(equalTo: searchIcon.centerYAnchor),
            queryTrailing!,
            previewButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -22),
            previewButton.centerYAnchor.constraint(equalTo: searchIcon.centerYAnchor),
            previewButton.widthAnchor.constraint(equalToConstant: 118), previewButton.heightAnchor.constraint(equalToConstant: 28),
            settings.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -22),
            settings.centerYAnchor.constraint(equalTo: searchIcon.centerYAnchor),
            settings.widthAnchor.constraint(equalToConstant: 26), settings.heightAnchor.constraint(equalToConstant: 28),
            rows.topAnchor.constraint(equalTo: container.topAnchor, constant: 86),
            rows.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            rows.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            empty.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            empty.topAnchor.constraint(equalTo: container.topAnchor, constant: 112),
            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 27),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -27),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -17)
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(displayParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func displayParametersChanged() {
        onCancel?()
        orderOut(nil)
    }

    static func placement(in visibleFrame: NSRect, height: CGFloat) -> NSRect {
        let width = min(initialSize.width, visibleFrame.width)
        let preferredTop = visibleFrame.minY + visibleFrame.height * 0.64 + initialSize.height / 2
        let top = min(visibleFrame.maxY, max(visibleFrame.minY + initialSize.height, preferredTop))
        return NSRect(x: visibleFrame.midX - width / 2, y: top-height, width: width, height: height)
    }

    override var canBecomeKey: Bool { !isHold }
    override var canBecomeMain: Bool { false }

    private func add(_ view: NSView) { view.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(view) }

    func present(hold: Bool) {
        clearWindows()
        isHold = hold
        makeFirstResponder(nil)
        if hold && isKeyWindow { resignKey() }
        // The event tap owns hold input; a native field editor would select programmatic updates.
        queryField.isEditable = !hold
        queryField.isSelectable = !hold
        lastMousePosition = NSEvent.mouseLocation
        query = ""
        queryField.stringValue = ""
        selected = 0
        explicitApp = nil
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let rect = screen?.visibleFrame {
            setFrame(Self.placement(in: rect, height: frame.height), display: isVisible)
        }
        if hold { orderFrontRegardless() }
        else { makeKeyAndOrderFront(nil); makeFirstResponder(queryField) }
        assert(!hold || (!isKeyWindow && queryField.currentEditor() == nil))
    }

    func render(_ results: [AppEntry], running: Set<String>, count: Int) {
        guard windowSession == nil else { return }
        var apps = results
        if let explicitApp, !apps.contains(where: { $0.id == explicitApp.id }) {
            apps = Array(apps.prefix(4)) + [explicitApp]
        }
        items = apps
        catalogCount = count
        self.running = running
        selected = explicitApp.flatMap { choice in apps.firstIndex { $0.id == choice.id } } ?? 0
        for view in rows.arrangedSubviews { rows.removeArrangedSubview(view); view.removeFromSuperview() }
        for (index, app) in apps.enumerated() {
            let icon = icons[app.url] ?? NSWorkspace.shared.icon(forFile: app.url.path)
            icons[app.url] = icon
            let row = PaletteRow(title: app.name, detail: running.contains(app.id) ? "Running" : "Open application",
                                 icon: icon, index: index, selected: selected == index, browsable: running.contains(app.id))
            row.browse = { [weak self] in self?.select(index); self?.browseWindows() }
            row.clicked = { [weak self] in self?.onCommit?(app) }
            row.hovered = { [weak self] in
                guard let self, NSEvent.mouseLocation != lastMousePosition else { return }
                lastMousePosition = NSEvent.mouseLocation
                select(index)
            }
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
        if icons.count > 80 { icons = icons.filter { key, _ in apps.contains { $0.url == key } } }
        empty.isHidden = !apps.isEmpty
        empty.stringValue = indexing && apps.isEmpty ? "Finding your apps…" : "No matching apps"
        footer.stringValue = isHold
            ? "Release \(holdLabel) to switch    ⇥ windows    1–5 choose    ⇧digit to type    esc cancel"
            : "↵ open    ⇥ windows    1–5 choose    esc close    \(count) apps"
        resize(height: CGFloat(max(1, apps.count)) * 62 + 182)
    }

    private func resize(height: CGFloat) {
        guard frame.height != height else { return }
        setFrame(NSRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height), display: false)
        contentView?.needsLayout = true
        contentView?.needsDisplay = true
    }

    private var matchingWindows: [WindowEntry] {
        guard case .ready(let windows) = windowSession?.content else { return [] }
        let text = AppEntry.normalize(query)
        return text.isEmpty ? windows : windows.filter { AppEntry.normalize($0.title).contains(text) }
    }

    func browseWindows() {
        guard windowSession == nil, items.indices.contains(selected), running.contains(items[selected].id), let loadWindows else { return }
        let app = items[selected]
        let session = WindowSession(app: app, appQuery: query, appSelection: selected)
        windowSession = session
        query = ""
        selected = 0
        syncQueryField()
        searchIcon.isHidden = true
        backButton.isHidden = false
        queryField.placeholderString = "Find a window"
        queryField.setAccessibilityLabel("Search windows in \(app.name)")
        renderWindows()
        windowTask = Task { [weak self] in
            let result = await loadWindows(app)
            guard !Task.isCancelled, let self, isVisible, windowSession?.id == session.id else { return }
            switch result {
            case .success(let windows): windowSession?.content = .ready(windows)
            case .failure(let error): windowSession?.content = .unavailable(error.message)
            }
            windowTask = nil
            renderWindows()
        }
    }

    @discardableResult func backFromWindows() -> Bool {
        guard let session = windowSession else { return false }
        clearWindows()
        query = session.appQuery
        selected = session.appSelection
        explicitApp = session.app
        syncQueryField()
        render(items, running: running, count: catalogCount)
        return true
    }

    private var catalogCount = 0
    private func clearWindows() {
        if windowSession != nil {
            for view in rows.arrangedSubviews { rows.removeArrangedSubview(view); view.removeFromSuperview() }
        }
        windowTask?.cancel()
        windowTask = nil
        previewTask?.cancel()
        previewTask = nil
        previews.removeAll()
        attemptedPreviews.removeAll()
        previewButton.isHidden = true
        settingsButton.isHidden = false
        windowSession = nil
        searchIcon.isHidden = false
        backButton.isHidden = true
        queryField.placeholderString = "Switch to an app"
        queryField.setAccessibilityLabel("Search apps")
        queryTrailing?.constant = -16
    }

    override func orderOut(_ sender: Any?) {
        clearWindows()
        super.orderOut(sender)
    }

    @objc private func backClicked() { backFromWindows() }

    private func renderWindows() {
        guard let session = windowSession else { return }
        let windows = matchingWindows
        selected = min(selected, max(0, windows.count - 1))
        let start = selected / 3 * 3
        let visible = Array(windows.dropFirst(start).prefix(3))
        let permissionNeeded = loadPreviews != nil && !canPreview()
        if permissionNeeded { discardPreviewCache(); previews.removeAll() }
        let now = ContinuousClock.now
        previewCache.removeAll { $0.captured.duration(to: now) > .seconds(10) }
        for window in visible where previews[window.id] == nil {
            if let cached = previewCache.first(where: { CFEqual($0.window.element, window.element)
                && $0.window.title == window.title && $0.window.frame == window.frame }) {
                previews[window.id] = cached.image
                if cached.captured.duration(to: now) < .seconds(1) { attemptedPreviews.insert(window.id) }
            }
        }
        previewButton.isHidden = !permissionNeeded
        settingsButton.isHidden = permissionNeeded
        queryTrailing.constant = permissionNeeded ? -108 : -16
        for view in rows.arrangedSubviews { rows.removeArrangedSubview(view); view.removeFromSuperview() }
        let icon = icons[session.app.url] ?? NSWorkspace.shared.icon(forFile: session.app.url.path)
        for (offset, window) in visible.enumerated() {
            let index = start + offset
            let row = PaletteRow(title: window.title, detail: window.minimized ? "Minimized" : session.app.name,
                                 icon: icon, index: offset, selected: selected == index, browsable: false,
                                 isWindow: true, preview: previews[window.id],
                                 previewPending: !permissionNeeded && loadPreviews != nil && !attemptedPreviews.contains(window.id))
            row.windowID = window.id
            row.clicked = { [weak self] in self?.onWindowCommit?(session.app, window) }
            row.hovered = { [weak self] in
                guard let self, NSEvent.mouseLocation != lastMousePosition else { return }
                lastMousePosition = NSEvent.mouseLocation
                select(index)
            }
            rows.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
        empty.isHidden = !visible.isEmpty
        switch session.content {
        case .loading: empty.stringValue = "Finding windows…"
        case .unavailable(let message): empty.stringValue = message
        case .ready(let all): empty.stringValue = all.isEmpty ? "No open windows" : "No matching windows"
        }
        updateWindowFooter()
        let rowCount: Int
        if case .loading = session.content { rowCount = 3 }
        else { rowCount = max(1, visible.count) }
        resize(height: CGFloat(rowCount) * 94 + 182)
        capturePreviews(visible, in: session)
    }

    private func updateWindowFooter() {
        guard let session = windowSession else { return }
        if isHold {
            footer.stringValue = "Release \(holdLabel) to browse windows    1–3 to focus    esc back"
            return
        }
        let windows = matchingWindows
        let start = selected / 3 * 3
        let visible = Array(windows.dropFirst(start).prefix(3))
        let action = "↵"
        if !windows.isEmpty {
            let count = windows.count == 1 ? "1 window" : "\(start + 1)–\(start + visible.count) of \(windows.count) windows"
            footer.stringValue = "\(count)    ↵ / 1–3 to focus    ← / esc back"
        } else if case .ready(let all) = session.content, !all.isEmpty {
            footer.stringValue = "← / esc to return to apps    \(action) to cancel"
        } else {
            footer.stringValue = "\(action) to open \(session.app.name)    ← / esc to return to apps"
        }
    }

    func releaseHold() {
        guard windowSession != nil else { commit(); return }
        isHold = false
        queryField.isEditable = true
        queryField.isSelectable = true
        makeKeyAndOrderFront(nil)
        makeFirstResponder(queryField)
        syncQueryField()
        updateWindowFooter()
    }

    private func capturePreviews(_ windows: [WindowEntry], in session: WindowSession) {
        previewTask?.cancel()
        previewTask = nil
        let pending = windows.filter { !attemptedPreviews.contains($0.id) }
        guard !pending.isEmpty, canPreview(), let loadPreviews else { return }
        previewTask = Task { [weak self] in
            await loadPreviews(session.app, pending) { [weak self] id, image in
                guard !Task.isCancelled, let self, isVisible, windowSession?.id == session.id else { return }
                let preview = NSImage(cgImage: image, size: .zero)
                previews[id] = preview
                if let window = pending.first(where: { $0.id == id }) {
                    previewCache.removeAll { CFEqual($0.window.element, window.element) }
                    previewCache.append(CachedPreview(window: window, image: preview, captured: .now))
                    if previewCache.count > 18 { previewCache.removeFirst(previewCache.count - 18) }
                }
                for case let row as PaletteRow in rows.arrangedSubviews where row.windowID == id { row.setPreview(preview) }
            }
            guard !Task.isCancelled, let self, windowSession?.id == session.id else { return }
            attemptedPreviews.formUnion(pending.map(\.id))
            for case let row as PaletteRow in rows.arrangedSubviews { row.finishPreviewLoading() }
            previewTask = nil
        }
    }

    func discardPreviewCache() { previewCache.removeAll() }

    @objc private func enablePreviews() {
        if onEnablePreviews?() == true { renderWindows() }
        else { previewButton.title = "Allow in Settings" }
    }

    private func syncQueryField() {
        queryField.stringValue = query
        if let editor = queryField.currentEditor() as? NSTextView {
            editor.string = query
            editor.setSelectedRange(NSRange(location: (query as NSString).length, length: 0))
        }
    }

    private func select(_ index: Int) {
        let count = windowSession == nil ? items.count : matchingWindows.count
        guard (0..<count).contains(index) else { return }
        if windowSession == nil { explicitApp = items[index] }
        guard selected != index else { return }
        let oldPage = selected / 3
        selected = index
        if windowSession != nil, selected / 3 != oldPage { renderWindows(); return }
        let start = windowSession == nil ? 0 : selected / 3 * 3
        for (i, view) in rows.arrangedSubviews.enumerated() { (view as? PaletteRow)?.setSelected(start + i == selected) }
    }

    func move(_ amount: Int) {
        let count = windowSession == nil ? items.count : matchingWindows.count
        guard count > 0 else { return }
        select((selected + amount + count) % count)
    }

    func commit() {
        if let session = windowSession {
            let windows = matchingWindows
            if windows.indices.contains(selected) { onWindowCommit?(session.app, windows[selected]) }
            else if case .ready(let all) = session.content, !all.isEmpty { onCancel?() }
            else { onCommit?(session.app) }
        } else if items.indices.contains(selected) { onCommit?(items[selected]) }
        else { onCancel?() }
    }

    private static let digits: [UInt16: String] = [18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9", 29: "0", 83: "1", 84: "2", 85: "3", 86: "4", 87: "5", 88: "6", 89: "7", 91: "8", 92: "9", 82: "0"]

    private func selectNumber(_ text: String) -> Bool {
        let count = windowSession == nil ? items.count : matchingWindows.count
        let start = windowSession == nil ? 0 : selected / 3 * 3
        let pageSize = windowSession == nil ? 5 : 3
        guard text.count == 1, let number = Int(text), number >= 1, number <= min(pageSize, count - start) else { return false }
        select(start + number - 1)
        if windowSession != nil { commit() }
        return true
    }

    override func sendEvent(_ event: NSEvent) {
        if !isHold, event.type == .keyDown,
           event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty {
            if event.keyCode == 124 || event.keyCode == 48 {
                if windowSession == nil { browseWindows() }
                else if event.keyCode == 48 { move(1) }
                return
            }
            if event.keyCode == 123, backFromWindows() { return }
        }
        if !isHold, event.type == .keyDown,
           event.modifierFlags.intersection([.command, .control, .option]).isEmpty,
           let digit = Self.digits[event.keyCode] {
            if event.modifierFlags.contains(.shift), let editor = queryField.currentEditor() as? NSTextView {
                editor.insertText(digit, replacementRange: NSRange(location: NSNotFound, length: 0))
                return
            }
            if selectNumber(digit) { return }
        }
        super.sendEvent(event)
    }

    func receive(_ code: UInt16, text: String, literalNumber: Bool = false) {
        switch code {
        case 125: move(1)
        case 48:
            if literalNumber { if !backFromWindows() { move(-1) } }
            else if windowSession != nil { move(1) }
            else { browseWindows() }
        case 126: move(-1)
        case 124: browseWindows()
        case 123: if !backFromWindows() { move(-1) }
        case 53: if !backFromWindows() { onCancel?() }
        case 36, 76: commit()
        case 51, 117:
            if !query.isEmpty { query.removeLast(); queryChanged() }
        default:
            if !literalNumber, selectNumber(text) { return }
            let text = literalNumber ? Self.digits[code] ?? text : text
            let printable = text.filter { !$0.isNewline && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }
            guard !printable.isEmpty, query.count < 128 else { return }
            query += String(printable.prefix(128 - query.count))
            queryChanged()
        }
    }

    private func queryChanged() {
        selected = 0
        explicitApp = nil
        if queryField.stringValue != query { queryField.stringValue = query }
        if windowSession != nil { renderWindows() }
        else { onQuery?(query) }
    }
    func controlTextDidChange(_ notification: Notification) { query = String(queryField.stringValue.prefix(128)); queryChanged() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.insertNewline(_:)): commit()
        case #selector(NSResponder.cancelOperation(_:)): if !backFromWindows() { onCancel?() }
        default: return false
        }
        return true
    }

    @objc private func settingsClicked() { onCancel?(); onSettings?() }
    func windowDidResignKey(_ notification: Notification) { if !isHold { onCancel?() } }
}

private final class GlassBackdrop: NSView {
    private let glass = NSGlassEffectView()
    init(content: NSView) {
        super.init(frame: NSRect(x: 0, y: 0, width: 688, height: 498))
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        glass.style = .regular
        glass.cornerRadius = 36
        if #available(macOS 27.0, *) { glass.effectIsInteractive = true }
        glass.contentView = content
        glass.wantsLayer = true
        addSubview(glass)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func layout() {
        super.layout()
        glass.frame = bounds.insetBy(dx: 24, dy: 24)
    }
}

private final class PaletteRow: NSView {
    var clicked: (() -> Void)?
    var browse: (() -> Void)?
    var hovered: (() -> Void)?
    private var tracking: NSTrackingArea?
    private let name: NSTextField
    private let detail: NSTextField
    private let number: NSTextField
    private let disclosure = NSButton()
    private let windowPreview: WindowThumbnail?
    private let isWindow: Bool
    var windowID: UUID?
    private var selected: Bool

    init(title: String, detail: String, icon: NSImage, index: Int, selected: Bool, browsable: Bool,
         isWindow: Bool = false, preview: NSImage? = nil, previewPending: Bool = false) {
        self.selected = selected
        self.isWindow = isWindow
        windowPreview = isWindow ? WindowThumbnail(icon: icon) : nil
        name = NSTextField(labelWithString: title)
        self.detail = NSTextField(labelWithString: detail)
        number = NSTextField(labelWithString: "\(index + 1)")
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        let image: NSView
        if let windowPreview {
            windowPreview.image = preview
            windowPreview.isLoading = previewPending && preview == nil
            image = windowPreview
        } else { image = NSImageView(image: icon) }
        name.font = .systemFont(ofSize: 15, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        self.detail.font = .systemFont(ofSize: 11)
        number.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        number.alignment = .center
        disclosure.image = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: "Show windows for \(title)")
        disclosure.target = self
        disclosure.action = #selector(browseClicked)
        disclosure.isBordered = false
        disclosure.contentTintColor = .secondaryLabelColor
        disclosure.isHidden = !browsable
        disclosure.toolTip = "Show windows (Tab)"
        self.detail.lineBreakMode = .byTruncatingTail
        for child in [image, name, self.detail, number, disclosure] { child.translatesAutoresizingMaskIntoConstraints = false; addSubview(child) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: isWindow ? 90 : 58),
            image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16), image.centerYAnchor.constraint(equalTo: centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: isWindow ? 128 : 36), image.heightAnchor.constraint(equalToConstant: isWindow ? 72 : 36),
            name.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 14), name.topAnchor.constraint(equalTo: topAnchor, constant: isWindow ? 27 : 10),
            name.trailingAnchor.constraint(lessThanOrEqualTo: disclosure.leadingAnchor, constant: -8),
            self.detail.leadingAnchor.constraint(equalTo: name.leadingAnchor), self.detail.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 2),
            self.detail.trailingAnchor.constraint(lessThanOrEqualTo: disclosure.leadingAnchor, constant: -8),
            disclosure.trailingAnchor.constraint(equalTo: number.leadingAnchor, constant: -8),
            disclosure.centerYAnchor.constraint(equalTo: centerYAnchor),
            disclosure.widthAnchor.constraint(equalToConstant: 24), disclosure.heightAnchor.constraint(equalToConstant: 28),
            number.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -15), number.centerYAnchor.constraint(equalTo: centerYAnchor),
            number.widthAnchor.constraint(equalToConstant: 22)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(title), \(detail), shortcut \(index + 1)")
        setSelected(selected)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    @objc private func browseClicked() { browse?() }
    override var isFlipped: Bool { true }
    func setSelected(_ value: Bool) {
        selected = value
        layer?.backgroundColor = value ? NSColor.controlAccentColor.withAlphaComponent(isWindow ? 0.15 : 0.85).cgColor : NSColor.clear.cgColor
        layer?.borderWidth = isWindow && value ? 1 : 0
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.7).cgColor
        name.textColor = value && !isWindow ? .white : .labelColor
        detail.textColor = value && !isWindow ? .white.withAlphaComponent(0.85) : .secondaryLabelColor
        number.textColor = value ? (isWindow ? .controlAccentColor : .white.withAlphaComponent(0.85)) : .secondaryLabelColor
        disclosure.contentTintColor = value ? .white.withAlphaComponent(0.85) : .secondaryLabelColor
        setAccessibilityValue(value ? "Selected" : "")
    }
    func setPreview(_ image: NSImage?) {
        windowPreview?.image = image
        windowPreview?.isLoading = false
    }
    func finishPreviewLoading() { windowPreview?.isLoading = false }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self)
        if let tracking { addTrackingArea(tracking) }
    }
    override func mouseMoved(with event: NSEvent) { hovered?() }
    override func mouseUp(with event: NSEvent) { if bounds.contains(convert(event.locationInWindow, from: nil)) { clicked?() } }
    override func accessibilityPerformPress() -> Bool { clicked?(); return true }
}

final class WindowThumbnail: NSView {
    var image: NSImage? { didSet { needsDisplay = true } }
    private let icon: NSImage
    var isLoading = false {
        didSet {
            guard isLoading != oldValue else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer?.filters = isLoading ? CIFilter(name: "CIGaussianBlur", parameters: [kCIInputRadiusKey: 2]).map { [$0] } : nil
            CATransaction.commit()
        }
    }

    init(icon: NSImage) {
        self.icon = icon
        super.init(frame: .zero)
        layerUsesCoreImageFilters = true
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override var isFlipped: Bool { true }

    static func imageRect(size: CGSize, in bounds: CGRect) -> CGRect {
        guard size.width > 0, size.height > 0 else { return .zero }
        let scale = min(bounds.width / size.width, bounds.height / size.height)
        let fitted = CGSize(width: size.width * scale, height: size.height * scale)
        return CGRect(x: bounds.midX - fitted.width / 2, y: bounds.midY - fitted.height / 2,
                      width: fitted.width, height: fitted.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        if let image {
            let rect = Self.imageRect(size: image.size, in: bounds)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).addClip()
            image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                       hints: [.interpolation: NSImageInterpolation.high])
            NSGraphicsContext.restoreGraphicsState()
        } else {
            let rect = CGRect(x: bounds.midX - 24, y: bounds.midY - 24, width: 48, height: 48)
            icon.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true,
                      hints: [.interpolation: NSImageInterpolation.high])
        }
    }
}
