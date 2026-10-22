import AppKit
import Carbon
import GlintCore
import ServiceManagement
import UniformTypeIdentifiers

@main struct GlintApp {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSToolbarDelegate {
    private let catalog = Catalog()
    private let shortcut = Shortcut()
    private let palette = Palette()
    private var status: NSStatusItem?
    private var settings: NSWindow?
    private var settingsTab = NSToolbarItem.Identifier("keyboard")
    private var permissionLabel: NSTextField?
    private var learningLabel: NSTextField?
    private var appCountLabel: NSTextField?
    private var enableButton: NSButton?
    private var recent: [String] = []
    private var appRules: [String: AppRule] = [:]
    private var applicationsSettings: ApplicationsSettings?
    private var predictor = Predictor()
    private var history: HistoryStore?
    private var learningError: String?
    private var current: String?
    private var context: String?
    private var restoringFocus = false
    private var fallbackAvailable = false
    private var localMouseMonitor: Any?
    private var globalMouseMonitor: Any?
    private let defaults = UserDefaults.standard

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "local.glint.switcher").count <= 1 else {
            NSApp.terminate(nil); return
        }
        recent = defaults.stringArray(forKey: "recent") ?? []
        if let data = defaults.data(forKey: "appRules") {
            appRules = (try? PropertyListDecoder().decode([String: AppRule].self, from: data)) ?? [:]
        }
        do {
            let url = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("Glint/switches.sqlite")
            history = try HistoryStore(url: url)
            try reloadLearning()
        } catch { learningError = error.localizedDescription }
        shortcut.key = HoldKey(rawValue: defaults.integer(forKey: "holdKey")) ?? .rightCommand
        palette.holdLabel = shortcut.key.glyph
        palette.onQuery = { [weak self] _ in self?.updateResults() }
        palette.onCommit = { [weak self] app in self?.open(app) }
        palette.onCancel = { [weak self] in self?.dismiss() }
        palette.onSettings = { [weak self] in self?.showSettings() }
        shortcut.begin = { [weak self] in self?.show(hold: true) }
        shortcut.commit = { [weak self] in self?.palette.commit() }
        shortcut.cancel = { [weak self] in self?.palette.orderOut(nil) }
        shortcut.input = { [weak self] code, text, literal in self?.palette.receive(code, text: text, literalNumber: literal) }
        fallbackAvailable = shortcut.installFallback { [weak self] in
            guard let self else { return }
            if palette.isVisible { dismiss() } else { show(hold: false) }
        }
        if defaults.bool(forKey: "holdEnabled") { shortcut.start() }
        makeMenu()
        catalog.changed = { [weak self] in
            guard let self else { return }
            palette.indexing = false
            appCountLabel?.stringValue = "\(catalog.apps.count) apps"
            updateResults()
        }
        catalog.start()
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(activated(_:)), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(appsChanged), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(appsChanged), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(sleeping), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(waking), name: NSWorkspace.didWakeNotification, object: nil)
        record(NSWorkspace.shared.frontmostApplication)
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            if let self, palette.isVisible, event.window !== palette { dismiss() }
            return event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.dismiss()
        }
        if CommandLine.arguments.contains("--diagnostics") {
            Task { await diagnostics(); NSApp.terminate(nil) }
        } else {
            show(hold: false)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        catalog.stop()
        shortcut.stop()
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        show(hold: false); return false
    }

    private func makeMenu() {
        let main = NSMenu()
        let appItem = main.addItem(withTitle: "Glint", action: nil, keyEquivalent: "")
        let appMenu = NSMenu(title: "Glint")
        appItem.submenu = appMenu
        let preferences = appMenu.addItem(withTitle: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        preferences.target = self
        appMenu.addItem(withTitle: "Quit Glint", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let editItem = main.addItem(withTitle: "Edit", action: nil, keyEquivalent: "")
        let edit = NSMenu(title: "Edit")
        editItem.submenu = edit
        for (title, action, key) in [("Undo", "undo:", "z"), ("Redo", "redo:", "Z"),
                                      ("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
                                      ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        NSApp.mainMenu = main
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let ribbon = NSImage(contentsOf: Bundle.main.url(forResource: "GlintRibbon", withExtension: "svg")!)!
        let mark = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { frame in
            ribbon.draw(in: frame, from: NSRect(x: 170, y: 180, width: 680, height: 680), operation: .sourceOver, fraction: 1)
            return true
        }
        mark.isTemplate = true
        mark.accessibilityDescription = "Glint"
        status?.button?.image = mark
        status?.button?.toolTip = "Glint — app switcher"
        let menu = NSMenu()
        for (title, action, key) in [("Switch apps", #selector(showFromMenu), ""), ("Settings…", #selector(showSettings), ","),
                                     ("Refresh apps", #selector(refresh), ""), ("Add apps…", #selector(addApps), ""),
                                     ("Import Applight history…", #selector(importHistory), "")] {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: key); item.target = self
        }
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit Glint", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        status?.menu = menu
    }

    @objc private func showFromMenu() { show(hold: false) }
    private func show(hold: Bool) {
        guard !restoringFocus else { return }
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        context = front == Bundle.main.bundleIdentifier ? current : front ?? current
        palette.present(hold: hold)
        catalog.mergeRunning()
    }

    private func dismiss() { shortcut.cancelHold(); palette.orderOut(nil) }

    private func updateResults() {
        guard palette.isVisible else { return }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let regular = Set(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.compactMap(\.bundleIdentifier))
        let source = context ?? current ?? ""
        let probabilities = predictor.probabilities(appIDs: catalog.apps.map(\.id), source: source,
            previous: recent.first { $0 != source }, recent: recent)
        let results = Search.rank(catalog.apps, query: palette.query, recent: recent, current: context ?? current,
                                  running: regular, predictions: predictor.count > 0 ? probabilities : [:], rules: appRules)
        palette.render(results, running: running, count: catalog.apps.count)
    }

    private func open(_ app: AppEntry) {
        guard !restoringFocus else { return }
        dismiss()
        restoringFocus = true
        Task {
            defer { restoringFocus = false }
            do {
                let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.id).first
                running?.unhide()
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                configuration.addsToRecentItems = false
                configuration.createsNewApplicationInstance = false
                // Reopen is essential: activation alone leaves apps with no windows invisible.
                configuration.appleEvent = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass),
                    eventID: AEEventID(kAEReopenApplication), targetDescriptor: nil,
                    returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
                let launched = try await NSWorkspace.shared.openApplication(at: running?.bundleURL ?? app.url, configuration: configuration)
                if !launched.isActive { launched.activate() }
            } catch {
                let alert = NSAlert()
                alert.messageText = "Couldn’t open \(app.name)"
                alert.informativeText = "\(error.localizedDescription)\n\nIf the app moved, refresh the app list."
                alert.addButton(withTitle: "Refresh apps")
                alert.addButton(withTitle: "Close")
                NSApp.activate()
                if alert.runModal() == .alertFirstButtonReturn { catalog.refresh() }
            }
        }
    }

    @objc private func activated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        record(app)
        if palette.isVisible && app.bundleIdentifier != context && app.bundleIdentifier != Bundle.main.bundleIdentifier { dismiss() }
    }

    private func record(_ app: NSRunningApplication?) {
        guard let app, app.activationPolicy == .regular, let id = app.bundleIdentifier,
              id != Bundle.main.bundleIdentifier, id != current else { return }
        if let current {
            let event = SwitchEvent(timestamp: Date().timeIntervalSince1970, previous: recent.first { $0 != current }, source: current, target: id)
            predictor.observe(event)
            learningLabel?.stringValue = predictor.count.formatted()
            do { try history?.append(event) } catch { learningError = error.localizedDescription }
        }
        current = id
        recent.removeAll { $0 == id }
        recent.insert(id, at: 0)
        recent = Array(recent.prefix(80))
        defaults.set(recent, forKey: "recent")
        if let url = app.bundleURL, !catalog.apps.contains(where: { $0.id == id }) { catalog.add([url]) }
    }

    @objc private func appsChanged() { catalog.mergeRunning() }
    @objc private func sleeping() { dismiss(); shortcut.reset() }
    @objc private func waking() {
        shortcut.reset()
        if defaults.bool(forKey: "holdEnabled") { shortcut.start() }
        catalog.refresh()
    }
    @objc private func refresh() { catalog.refresh() }
    @objc private func addApps() {
        dismiss()
        let picker = NSOpenPanel()
        picker.title = "Add applications"
        picker.allowedContentTypes = [.applicationBundle]
        picker.allowsMultipleSelection = true
        picker.canChooseDirectories = false
        if picker.runModal() == .OK { catalog.add(picker.urls) }
    }

    private func reloadLearning() throws {
        predictor = Predictor()
        let events = try history?.events() ?? []
        // Cocoa date helpers otherwise retain an import's temporary objects until the run loop returns.
        for start in stride(from: 0, to: events.count, by: 512) {
            autoreleasepool {
                for event in events[start..<min(start + 512, events.count)] { predictor.observe(event) }
            }
        }
        assert(predictor.count == events.count)
    }

    @objc private func importHistory() {
        dismiss()
        let picker = NSOpenPanel()
        picker.title = "Import Applight history"
        picker.message = "Choose the Applight folder so SQLite can read its journal too. Only timestamps and app identifiers are imported."
        picker.canChooseDirectories = true
        picker.canChooseFiles = false
        picker.prompt = "Import history"
        picker.directoryURL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/com.seungwoochoe.Applight/Data/Library/Application Support/Applight")
        guard picker.runModal() == .OK, let url = picker.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let alert = NSAlert()
        do {
            guard let history else { throw HistoryStore.StoreError(message: learningError ?? "The learning database is unavailable.") }
            let count = try history.importApplight(from: url.appendingPathComponent("Applight.sqlite"))
            try reloadLearning()
            learningLabel?.stringValue = predictor.count.formatted()
            alert.messageText = "Imported \(count) app switches"
            alert.informativeText = "Glint has learned from \(predictor.count) switches. Reimporting skips duplicates."
        } catch { alert.messageText = "Couldn’t import history"; alert.informativeText = error.localizedDescription }
        alert.runModal()
    }

    @objc private func showSettings() {
        dismiss()
        if settings == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 280),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Glint"
            window.isReleasedWhenClosed = false
            window.titlebarAppearsTransparent = true
            window.toolbarStyle = .preference
            let toolbar = NSToolbar(identifier: "GlintSettings")
            toolbar.delegate = self
            toolbar.displayMode = .iconAndLabel
            toolbar.selectedItemIdentifier = settingsTab
            window.toolbar = toolbar
            settings = window
            window.center()
        }
        renderSettings()
        NSApp.activate()
        settings?.makeKeyAndOrderFront(nil)
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        ["general", "keyboard", "applications", "learning"].map { NSToolbarItem.Identifier($0) }
    }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }
    func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        let names = ["general": ("General", "slider.horizontal.3"), "keyboard": ("Keyboard", "keyboard"),
                     "applications": ("Apps", "square.grid.2x2"), "learning": ("Learning", "sparkles")]
        guard let (label, symbol) = names[id.rawValue] else { return nil }
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.target = self
        item.action = #selector(selectSettingsTab(_:))
        return item
    }
    @objc private func selectSettingsTab(_ sender: NSToolbarItem) {
        settingsTab = sender.itemIdentifier
        settings?.toolbar?.selectedItemIdentifier = settingsTab
        renderSettings()
    }

    private func renderSettings() {
        guard let settings else { return }
        let height: CGFloat = settingsTab.rawValue == "applications" ? 420 : 280
        let top = settings.frame.maxY
        settings.setContentSize(NSSize(width: 560, height: height))
        settings.setFrameOrigin(NSPoint(x: settings.frame.minX, y: top - settings.frame.height))
        if settingsTab.rawValue == "applications" {
            let editor = ApplicationsSettings(apps: catalog.apps, rules: appRules) { [weak self] id, rule in
                guard let self else { return }
                appRules[id] = rule == AppRule() ? nil : rule
                if let data = try? PropertyListEncoder().encode(appRules) { defaults.set(data, forKey: "appRules") }
                updateResults()
            }
            applicationsSettings = editor
            settings.contentView = editor.view
            return
        }
        applicationsSettings = nil
        permissionLabel = nil
        learningLabel = nil
        appCountLabel = nil
        enableButton = nil
        let surface = NSVisualEffectView()
        surface.material = .windowBackground
        surface.blendingMode = .behindWindow
        surface.state = .active
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        surface.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: surface.topAnchor, constant: 22),
            stack.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -24)
        ])
        func note(_ text: String) -> NSTextField {
            let field = NSTextField(wrappingLabelWithString: text)
            field.font = .systemFont(ofSize: 12)
            field.textColor = .secondaryLabelColor
            field.widthAnchor.constraint(equalToConstant: 512).isActive = true
            stack.addArrangedSubview(field)
            return field
        }
        func button(_ title: String, _ action: Selector) -> NSButton {
            let button = NSButton(title: title, target: self, action: action)
            button.bezelStyle = .rounded
            button.controlSize = .regular
            return button
        }
        switch settingsTab.rawValue {
        case "general":
            let login = NSSwitch()
            login.state = SMAppService.mainApp.status == .enabled ? .on : .off
            login.target = self; login.action = #selector(changeLogin(_:))
            login.setAccessibilityLabel("Open at login")
            let count = NSTextField(labelWithString: "\(catalog.apps.count) apps")
            appCountLabel = count
            count.textColor = .secondaryLabelColor
            let apps = NSStackView(views: [count, button("Add…", #selector(addApps)), button("Refresh", #selector(refresh))])
            apps.spacing = 10
            stack.addArrangedSubview(settingsGroup([
                settingsRow("Open at login", login), settingsRow("Applications", apps)
            ]))
            _ = note("Applications are indexed locally and refreshed when they change.")
        case "learning":
            let count = NSTextField(labelWithString: "\(predictor.count.formatted())")
            count.font = .monospacedDigitSystemFont(ofSize: 13, weight: .medium)
            learningLabel = count
            stack.addArrangedSubview(settingsGroup([
                settingsRow("Learned switches", count),
                settingsRow("Applight history", button("Import…", #selector(importHistory)))
            ]))
            _ = note("Predictions use app-to-app patterns, recent context, and time of day. Older habits gradually fade.")
            _ = note(learningError ?? "Your switching history stays on this Mac.")
        default:
            let picker = NSPopUpButton()
            for key in HoldKey.allCases { picker.addItem(withTitle: key.title); picker.lastItem?.tag = key.rawValue }
            picker.selectItem(withTag: shortcut.key.rawValue)
            picker.target = self; picker.action = #selector(changeKey(_:))
            picker.setAccessibilityLabel("Hold shortcut key")
            let enable = button("Enable…", #selector(enableHold))
            enableButton = enable
            let keys = NSTextField(labelWithString: "⌃  ⌥  Space")
            keys.font = .monospacedSystemFont(ofSize: 13, weight: .medium)
            keys.textColor = .secondaryLabelColor
            stack.addArrangedSubview(settingsGroup([
                settingsRow("Activation key", picker), settingsRow("Hold to switch", enable),
                settingsRow("Fallback shortcut", keys)
            ]))
            permissionLabel = note("")
            updatePermissionStatus()
        }
        settings.contentView = surface
    }

    private func settingsRow(_ title: String, _ control: NSView) -> NSView {
        let row = NSView()
        let label = NSTextField(labelWithString: title)
        label.font = .systemFont(ofSize: 13, weight: .medium)
        for view in [label, control] { view.translatesAutoresizingMaskIntoConstraints = false; row.addSubview(view) }
        NSLayoutConstraint.activate([
            row.widthAnchor.constraint(equalToConstant: 480),
            row.heightAnchor.constraint(equalToConstant: 46),
            label.leadingAnchor.constraint(equalTo: row.leadingAnchor), label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            control.trailingAnchor.constraint(equalTo: row.trailingAnchor), control.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: control.leadingAnchor, constant: -16)
        ])
        return row
    }

    private func settingsGroup(_ rows: [NSView]) -> NSView {
        let box = NSBox()
        box.boxType = .custom
        box.borderWidth = 0
        box.cornerRadius = 12
        box.fillColor = .controlBackgroundColor.withAlphaComponent(0.55)
        box.contentViewMargins = NSSize(width: 16, height: 6)
        let content = NSStackView(views: rows)
        content.orientation = .vertical
        content.alignment = .width
        content.spacing = 0
        box.contentView = content
        box.widthAnchor.constraint(equalToConstant: 512).isActive = true
        box.heightAnchor.constraint(equalToConstant: CGFloat(rows.count) * 46 + 12).isActive = true
        return box
    }

    @objc private func changeKey(_ sender: NSPopUpButton) {
        guard let key = HoldKey(rawValue: sender.selectedTag()) else { return }
        shortcut.key = key
        defaults.set(key.rawValue, forKey: "holdKey")
        palette.holdLabel = key.glyph
        if shortcut.enabled { shortcut.start() }
        updatePermissionStatus()
    }

    @objc private func enableHold() {
        if shortcut.enabled {
            shortcut.stop(); defaults.set(false, forKey: "holdEnabled")
        } else if AXIsProcessTrusted() {
            defaults.set(shortcut.start(), forKey: "holdEnabled")
        } else {
            let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        updatePermissionStatus()
    }

    private func updatePermissionStatus() {
        enableButton?.title = shortcut.enabled ? "Disable" : "Enable…"
        permissionLabel?.stringValue = shortcut.enabled
            ? "Hold \(shortcut.key.title), type to narrow the list, then release to open the highlighted app."
            : (shortcut.failure ?? "Enable Accessibility access for the hold shortcut, then click Enable. Quit Applight first if it uses the same key.")
    }

    @objc private func changeLogin(_ sender: NSSwitch) {
        do {
            if sender.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            sender.state = SMAppService.mainApp.status == .enabled ? .on : .off
            let alert = NSAlert(); alert.messageText = "Couldn’t update login setting"; alert.informativeText = error.localizedDescription; alert.runModal()
        }
    }


    private func diagnostics() async {
        let apps = await AppScanner.scan(extra: [])
        let start = ContinuousClock.now
        for _ in 0..<1_000 { _ = Search.rank(apps, query: "cod", recent: recent, current: current, running: []) }
        print("Catalog: \(apps.count) installed applications")
        print("1,000 searches: \(start.duration(to: .now))")
        print("Accessibility: \(AXIsProcessTrusted()); hold hook: \(shortcut.enabled); fallback: \(fallbackAvailable)")
        for name in ["Safari", "Notes", "TextEdit", "Codex"] {
            print("\(name): \(apps.contains { $0.name == name } ? "indexed" : "not installed")")
        }
    }
}
