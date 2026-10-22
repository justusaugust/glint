import AppKit
import Testing
import GlintCore
@testable import Glint

@MainActor @Test func applicationsSettingsKeepsLabelsInsideRowsAndShowsSelection() throws {
    let apps = [AppEntry(id: "about", name: "About This Mac", url: URL(fileURLWithPath: "/System/Applications/Utilities/System Information.app")),
                AppEntry(id: "hint", name: "", url: URL(fileURLWithPath: "/Applications/TeX/hintview.app"))]
    #expect(apps[1].name == "hintview")
    let settings = ApplicationsSettings(apps: apps, rules: [:]) { _, _ in }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420), styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = settings.view
    defer { window.orderOut(nil) }
    window.contentView?.layoutSubtreeIfNeeded()
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let table = try #require(descendants(settings.view).compactMap { $0 as? NSTableView }.first)
    #expect(table.selectedRow == 0)
    for row in 0..<apps.count {
        let cell = try #require(table.view(atColumn: 0, row: row, makeIfNecessary: true))
        cell.layoutSubtreeIfNeeded()
        let field = try #require(descendants(cell).compactMap { $0 as? NSTextField }.first)
        let rowRect = table.rect(ofRow: row)
        let textRect = field.convert(field.bounds, to: table)
        #expect(textRect.height >= 14)
        #expect(rowRect.contains(textRect))
        #expect(field.stringValue == apps[row].name)
    }
    let titles = descendants(settings.view).compactMap { $0 as? NSTextField }.filter { $0.font?.pointSize == 17 }
    let title = try #require(titles.first)
    #expect(title.stringValue == apps[0].name)
    #expect(title.frame.height >= 18)
    table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
    settings.view.layoutSubtreeIfNeeded()
    #expect(title.stringValue == apps[1].name)
}
