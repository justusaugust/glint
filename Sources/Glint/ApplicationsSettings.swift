import AppKit
import GlintCore

final class ApplicationsSettings: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate {
    private let apps: [AppEntry]
    private var filtered: [AppEntry]
    private var rules: [String: AppRule]
    private let changed: (String, AppRule) -> Void
    private let search = NSSearchField()
    private let table = NSTableView()
    private let name = NSTextField(labelWithString: "")
    private let aliases = NSTextField()
    private let pin = NSButton(checkboxWithTitle: "Pin above other suggestions", target: nil, action: nil)
    private let show = NSButton(checkboxWithTitle: "Show in launcher", target: nil, action: nil)
    private let detail = NSStackView()
    private var selectedID: String?

    init(apps: [AppEntry], rules: [String: AppRule], changed: @escaping (String, AppRule) -> Void) {
        self.apps = apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        self.filtered = self.apps
        self.rules = rules
        self.changed = changed
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func loadView() {
        let surface = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 560, height: 420))
        surface.material = .windowBackground
        surface.blendingMode = .behindWindow
        surface.state = .active
        view = surface
        search.placeholderString = "Find an app"
        search.setAccessibilityLabel("Find an app to customize")
        search.delegate = self
        table.addTableColumn(NSTableColumn(identifier: .init("app")))
        table.headerView = nil
        table.rowHeight = 30
        table.style = .sourceList
        table.dataSource = self
        table.delegate = self
        table.setAccessibilityLabel("Applications")
        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let list = NSStackView(views: [search, scroll])
        list.orientation = .vertical
        list.alignment = .width
        list.spacing = 10
        name.font = .systemFont(ofSize: 17, weight: .semibold)
        name.lineBreakMode = .byTruncatingTail
        aliases.placeholderString = "work, editor"
        aliases.setAccessibilityLabel("Aliases, separated by commas")
        aliases.delegate = self
        let label = NSTextField(labelWithString: "Aliases")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        let note = NSTextField(wrappingLabelWithString: "Separate aliases with commas. Exact app names take priority. Pins lead suggestions; excluded apps stay hidden.")
        note.font = .systemFont(ofSize: 12)
        note.textColor = .secondaryLabelColor
        for button in [pin, show] { button.target = self; button.action = #selector(save) }
        detail.orientation = .vertical
        detail.alignment = .leading
        detail.spacing = 14
        for child in [name, label, aliases, pin, show, note] { detail.addArrangedSubview(child) }
        for child in [list, detail] { child.translatesAutoresizingMaskIntoConstraints = false; surface.addSubview(child) }
        NSLayoutConstraint.activate([
            list.leadingAnchor.constraint(equalTo: surface.leadingAnchor, constant: 20),
            list.topAnchor.constraint(equalTo: surface.topAnchor, constant: 20),
            list.bottomAnchor.constraint(equalTo: surface.bottomAnchor, constant: -20),
            list.widthAnchor.constraint(equalToConstant: 208),
            detail.leadingAnchor.constraint(equalTo: list.trailingAnchor, constant: 24),
            detail.trailingAnchor.constraint(equalTo: surface.trailingAnchor, constant: -24),
            detail.topAnchor.constraint(equalTo: list.topAnchor, constant: 4),
            name.widthAnchor.constraint(equalTo: detail.widthAnchor),
            aliases.widthAnchor.constraint(equalTo: detail.widthAnchor),
            note.widthAnchor.constraint(equalTo: detail.widthAnchor)
        ])
        selectFirst()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { filtered.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("app")
        let cell = tableView.makeView(withIdentifier: id, owner: self) as? NSTextField ?? NSTextField(labelWithString: "")
        cell.identifier = id
        cell.lineBreakMode = .byTruncatingTail
        cell.stringValue = filtered[row].name
        cell.textColor = rules[filtered[row].id]?.excluded == true ? .secondaryLabelColor : .labelColor
        return cell
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard filtered.indices.contains(table.selectedRow) else { selectedID = nil; detail.isHidden = true; return }
        let app = filtered[table.selectedRow]
        selectedID = app.id
        detail.isHidden = false
        let rule = rules[app.id] ?? AppRule()
        name.stringValue = app.name
        aliases.stringValue = rule.aliases.joined(separator: ", ")
        pin.state = rule.pinned ? .on : .off
        show.state = rule.excluded ? .off : .on
        pin.isEnabled = !rule.excluded
    }
    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSSearchField === search {
            let query = AppEntry.normalize(search.stringValue)
            filtered = apps.filter { query.isEmpty || $0.searchName.contains(query) || rules[$0.id]?.aliases.contains(where: { $0.contains(query) }) == true }
            table.reloadData()
            selectFirst()
        } else { save() }
    }
    private func selectFirst() {
        table.deselectAll(nil)
        if !filtered.isEmpty { table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false) }
        else { detail.isHidden = true }
    }
    @objc private func save() {
        guard let id = selectedID else { return }
        let rule = AppRule(aliases: aliases.stringValue.components(separatedBy: ","), pinned: pin.state == .on, excluded: show.state == .off)
        rules[id] = rule
        pin.isEnabled = !rule.excluded
        changed(id, rule)
        let row = table.selectedRow
        if row >= 0 { table.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: IndexSet(integer: 0)) }
    }
}
