import AppKit
import GlintCore

final class Palette: NSPanel, NSTextFieldDelegate, NSWindowDelegate {
    private let queryField = NSTextField()
    private let footer = NSTextField(labelWithString: "")
    private let empty = NSTextField(labelWithString: "No matching apps")
    private let rows = NSStackView()
    private let container = NSView()
    private var items: [AppEntry] = []
    private var selected = 0
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
        super.init(contentRect: NSRect(x: 0, y: 0, width: 688, height: 498),
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

        // Glass refraction and its shadow need space outside the visible rounded surface.
        contentView = GlassBackdrop(content: container)

        let searchIcon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)!)
        searchIcon.contentTintColor = .secondaryLabelColor
        add(searchIcon)
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

        let settings = NSButton(image: NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Settings")!,
                                target: self, action: #selector(settingsClicked))
        settings.isBordered = false
        settings.contentTintColor = .secondaryLabelColor
        settings.toolTip = "Settings"
        add(settings)

        rows.orientation = .vertical
        rows.alignment = .leading
        rows.spacing = 4
        add(rows)
        empty.font = .systemFont(ofSize: 15)
        empty.textColor = .secondaryLabelColor
        add(empty)
        footer.font = .systemFont(ofSize: 11, weight: .medium)
        footer.textColor = .secondaryLabelColor
        add(footer)

        NSLayoutConstraint.activate([
            searchIcon.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 26),
            searchIcon.topAnchor.constraint(equalTo: container.topAnchor, constant: 28),
            searchIcon.widthAnchor.constraint(equalToConstant: 25), searchIcon.heightAnchor.constraint(equalToConstant: 25),
            queryField.leadingAnchor.constraint(equalTo: searchIcon.trailingAnchor, constant: 15),
            queryField.centerYAnchor.constraint(equalTo: searchIcon.centerYAnchor),
            queryField.trailingAnchor.constraint(equalTo: settings.leadingAnchor, constant: -16),
            settings.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -22),
            settings.centerYAnchor.constraint(equalTo: searchIcon.centerYAnchor),
            settings.widthAnchor.constraint(equalToConstant: 26), settings.heightAnchor.constraint(equalToConstant: 28),
            rows.topAnchor.constraint(equalTo: container.topAnchor, constant: 86),
            rows.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            rows.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            empty.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            empty.topAnchor.constraint(equalTo: container.topAnchor, constant: 112),
            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 27),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -17)
        ])
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    private func add(_ view: NSView) { view.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(view) }

    func present(hold: Bool) {
        isHold = hold
        lastMousePosition = NSEvent.mouseLocation
        query = ""
        queryField.stringValue = ""
        selected = 0
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let rect = screen?.visibleFrame {
            setFrameOrigin(NSPoint(x: rect.midX - frame.width / 2, y: rect.minY + rect.height * 0.64 - frame.height / 2))
        }
        if hold { orderFrontRegardless() }
        else { makeKeyAndOrderFront(nil); makeFirstResponder(queryField) }
    }

    func render(_ apps: [AppEntry], running: Set<String>, count: Int) {
        items = apps
        self.running = running
        selected = min(selected, max(0, items.count - 1))
        for view in rows.arrangedSubviews { rows.removeArrangedSubview(view); view.removeFromSuperview() }
        for (index, app) in apps.enumerated() {
            let icon = icons[app.url] ?? NSWorkspace.shared.icon(forFile: app.url.path)
            icons[app.url] = icon
            let row = AppRow(app: app, icon: icon, index: index, selected: selected == index, running: running.contains(app.id))
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
            ? "Release \(holdLabel) to switch    ↑ ↓ to choose    esc to cancel"
            : "↵ to open    ↑ ↓ to choose    esc to close                                    \(count) apps"
        let height = CGFloat(max(1, apps.count)) * 62 + 134
        let top = frame.maxY
        setFrame(NSRect(x: frame.minX, y: top - height - 48, width: 688, height: height + 48), display: isVisible)
        queryField.setAccessibilityValue(query)
    }

    private func select(_ index: Int) {
        guard items.indices.contains(index), selected != index else { return }
        selected = index
        for (i, view) in rows.arrangedSubviews.enumerated() { (view as? AppRow)?.setSelected(i == selected) }
    }

    func move(_ amount: Int) {
        guard !items.isEmpty else { return }
        select((selected + amount + items.count) % items.count)
    }

    func commit() { if items.indices.contains(selected) { onCommit?(items[selected]) } else { onCancel?() } }

    func receive(_ code: UInt16, text: String) {
        switch code {
        case 125, 124, 48: move(1)
        case 126, 123: move(-1)
        case 36, 76: commit()
        case 51, 117:
            if !query.isEmpty { query.removeLast(); queryChanged() }
        default:
            if query.isEmpty, let number = Int(text), (1...items.count).contains(number) { select(number - 1); return }
            let printable = text.filter { !$0.isNewline && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) }
            guard !printable.isEmpty, query.count < 128 else { return }
            query += String(printable.prefix(128 - query.count))
            queryChanged()
        }
    }

    private func queryChanged() { selected = 0; queryField.stringValue = query; onQuery?(query) }
    func controlTextDidChange(_ notification: Notification) { query = String(queryField.stringValue.prefix(128)); queryChanged() }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): move(1)
        case #selector(NSResponder.moveUp(_:)): move(-1)
        case #selector(NSResponder.insertNewline(_:)): commit()
        case #selector(NSResponder.cancelOperation(_:)): onCancel?()
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
        glass.cornerRadius = 28
        glass.contentView = content
        glass.wantsLayer = true
        glass.layer?.shadowColor = NSColor.black.cgColor
        glass.layer?.shadowOpacity = 0.32
        glass.layer?.shadowRadius = 14
        glass.layer?.shadowOffset = CGSize(width: 0, height: -6)
        addSubview(glass)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override func layout() {
        super.layout()
        glass.frame = bounds.insetBy(dx: 24, dy: 24)
        glass.layer?.shadowPath = CGPath(roundedRect: glass.bounds, cornerWidth: 28, cornerHeight: 28, transform: nil)
    }
}

private final class AppRow: NSView {
    var clicked: (() -> Void)?
    var hovered: (() -> Void)?
    private var tracking: NSTrackingArea?
    private let name: NSTextField
    private let detail: NSTextField
    private let number: NSTextField
    private var selected: Bool

    init(app: AppEntry, icon: NSImage, index: Int, selected: Bool, running: Bool) {
        self.selected = selected
        name = NSTextField(labelWithString: app.name)
        detail = NSTextField(labelWithString: running ? "Running" : "Open application")
        number = NSTextField(labelWithString: "\(index + 1)")
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 12
        let image = NSImageView(image: icon)
        name.font = .systemFont(ofSize: 15, weight: .medium)
        name.lineBreakMode = .byTruncatingTail
        detail.font = .systemFont(ofSize: 11)
        number.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        number.alignment = .center
        for child in [image, name, detail, number] { child.translatesAutoresizingMaskIntoConstraints = false; addSubview(child) }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 58),
            image.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16), image.centerYAnchor.constraint(equalTo: centerYAnchor),
            image.widthAnchor.constraint(equalToConstant: 36), image.heightAnchor.constraint(equalToConstant: 36),
            name.leadingAnchor.constraint(equalTo: image.trailingAnchor, constant: 14), name.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            name.trailingAnchor.constraint(lessThanOrEqualTo: number.leadingAnchor, constant: -12),
            detail.leadingAnchor.constraint(equalTo: name.leadingAnchor), detail.topAnchor.constraint(equalTo: name.bottomAnchor, constant: 2),
            number.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -15), number.centerYAnchor.constraint(equalTo: centerYAnchor),
            number.widthAnchor.constraint(equalToConstant: 22)
        ])
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("\(app.name), \(detail.stringValue), shortcut \(index + 1)")
        setSelected(selected)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    override var isFlipped: Bool { true }
    func setSelected(_ value: Bool) {
        selected = value
        layer?.backgroundColor = value ? NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor : NSColor.clear.cgColor
        name.textColor = value ? .white : .labelColor
        detail.textColor = value ? .white.withAlphaComponent(0.85) : .secondaryLabelColor
        number.textColor = value ? .white.withAlphaComponent(0.85) : .tertiaryLabelColor
        setAccessibilityValue(value ? "Selected" : "")
    }
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
