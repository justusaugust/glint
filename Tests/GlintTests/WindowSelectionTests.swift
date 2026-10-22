import AppKit
import ApplicationServices
import Testing
import GlintCore
@testable import Glint

@Suite(.serialized) @MainActor struct WindowSelectionTests {
    private let apps = (1...2).map { AppEntry(id: "fixture\($0)", name: "Fixture \($0)", url: URL(fileURLWithPath: "/tmp/Fixture\($0).app")) }
    private func windows(_ count: Int = 8) -> [WindowEntry] {
        (1...count).map { WindowEntry(title: $0 == 1 ? "Résumé" : "Window \($0)", minimized: $0 == 2,
                                     element: AXUIElementCreateApplication(getpid())) }
    }
    private func labels(_ view: NSView?) -> [String] {
        guard let view else { return [] }
        return [view.accessibilityLabel()].compactMap { $0 } + view.subviews.flatMap { labels($0) }
    }
    private func waitFor(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(predicate())
    }

    @Test func ordinaryReleaseNeverRequestsWindows() {
        let palette = Palette()
        defer { palette.orderOut(nil) }
        var loads = 0
        var opened: String?
        palette.loadWindows = { _ in loads += 1; return .success([]) }
        palette.onCommit = { opened = $0.id }
        palette.present(hold: true)
        palette.render(apps, running: [apps[0].id], count: 2)
        palette.receive(0, text: "Fixture")
        palette.commit()
        #expect(opened == apps[0].id && loads == 0 && !palette.isChoosingWindow)
        palette.receive(19, text: "2")
        palette.receive(124, text: "")
        #expect(loads == 0 && !palette.isChoosingWindow)
        palette.commit()
        #expect(opened == apps[1].id)
    }

    @Test func windowsAreOptionalSearchableAndReachableBeyondFiveRows() async throws {
        let palette = Palette()
        defer { palette.orderOut(nil) }
        let entries = windows()
        var focused: UUID?
        var opened: String?
        palette.loadWindows = { _ in .success(entries) }
        palette.onCommit = { opened = $0.id }
        palette.onWindowCommit = { _, window in focused = window.id }
        palette.present(hold: true)
        palette.render(apps, running: Set(apps.map(\.id)), count: 2)
        palette.receive(0, text: "fix")
        palette.receive(19, text: "2")
        let top = palette.frame.maxY
        palette.receive(124, text: "")
        try await waitFor { labels(palette.contentView).contains { $0.hasPrefix("Résumé,") } }
        #expect(palette.isChoosingWindow && palette.query.isEmpty)
        #expect(palette.frame.maxY == top && !palette.isKeyWindow)
        palette.move(6)
        palette.receive(18, text: "1")
        palette.commit()
        #expect(focused == entries[6].id && opened == nil)
        palette.receive(0, text: "resume")
        palette.commit()
        #expect(focused == entries[0].id && palette.query == "resume")
        #expect(palette.backFromWindows())
        #expect(palette.query == "fix" && palette.frame.maxY == top)
        palette.commit()
        #expect(opened == apps[1].id)
    }

    @Test func emptyUnavailableAndLoadingReleaseOpenTheApp() async throws {
        for result: Result<[WindowEntry], WindowAccess.Failure> in [.success([]), .failure(.permission), .failure(.unavailable)] {
            let palette = Palette()
            defer { palette.orderOut(nil) }
            var opened: String?
            palette.loadWindows = { _ in result }
            palette.onCommit = { opened = $0.id }
            palette.present(hold: true)
            palette.render(apps, running: Set(apps.map(\.id)), count: 2)
            palette.browseWindows()
            palette.commit()
            #expect(opened == apps[0].id)
            try await Task.sleep(for: .milliseconds(5))
            palette.commit()
            #expect(opened == apps[0].id)
        }
    }

    @Test func cancelledLookupCannotReplaceANewSession() async throws {
        let palette = Palette()
        defer { palette.orderOut(nil) }
        var requests: [CheckedContinuation<Result<[WindowEntry], WindowAccess.Failure>, Never>] = []
        palette.loadWindows = { _ in await withCheckedContinuation { requests.append($0) } }
        palette.present(hold: true)
        palette.render(apps, running: Set(apps.map(\.id)), count: 2)
        palette.browseWindows()
        try await waitFor { requests.count == 1 }
        palette.orderOut(nil)
        palette.present(hold: true)
        palette.render(apps, running: Set(apps.map(\.id)), count: 2)
        palette.receive(19, text: "2")
        palette.browseWindows()
        try await waitFor { requests.count == 2 }
        requests[1].resume(returning: .success(windows(1)))
        try await waitFor { labels(palette.contentView).contains { $0.hasPrefix("Résumé,") } }
        requests[0].resume(returning: .success(windows(8)))
        try await Task.sleep(for: .milliseconds(5))
        #expect(!labels(palette.contentView).contains { $0.hasPrefix("Window 2,") })
        #expect(palette.backFromWindows())
        var opened: String?
        palette.onCommit = { opened = $0.id }
        palette.commit()
        #expect(opened == apps[1].id)
    }

    @Test func escapeBackKeepsTheHoldAndSecondEscapeCancelsRelease() throws {
        let palette = Palette()
        let shortcut = Shortcut()
        defer { palette.orderOut(nil) }
        var commits = 0
        shortcut.begin = {
            palette.present(hold: true)
            palette.render(apps, running: Set(apps.map(\.id)), count: 2)
        }
        shortcut.escape = { palette.backFromWindows() }
        shortcut.cancel = { palette.orderOut(nil) }
        shortcut.commit = { commits += 1 }
        palette.loadWindows = { _ in .success([]) }
        let command = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | HoldKey.rightCommand.deviceMask)
        func deliver(_ type: CGEventType, code: UInt16, flags: CGEventFlags) throws {
            let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true))
            event.flags = flags
            _ = shortcut.receive(type, event)
        }
        try deliver(.flagsChanged, code: 54, flags: command)
        palette.browseWindows()
        try deliver(.keyDown, code: 53, flags: command)
        #expect(shortcut.holding && !palette.isChoosingWindow && palette.isVisible)
        try deliver(.keyDown, code: 53, flags: command)
        #expect(!shortcut.holding && !palette.isVisible)
        try deliver(.flagsChanged, code: 54, flags: [])
        #expect(commits == 0)
    }

    @Test func normalEditingRestoresQueryWithoutSelectionAndLiteralDigitsStillWork() async throws {
        let palette = Palette()
        defer { palette.orderOut(nil) }
        palette.loadWindows = { _ in .success(windows()) }
        palette.present(hold: false)
        palette.render(apps, running: Set(apps.map(\.id)), count: 2)
        palette.receive(0, text: "fix")
        palette.browseWindows()
        try await waitFor { labels(palette.contentView).contains { $0.hasPrefix("Résumé,") } }
        palette.receive(19, text: "@", literalNumber: true)
        #expect(palette.query == "2")
        #expect(palette.backFromWindows())
        #expect(palette.query == "fix")
        let editor = try #require(palette.firstResponder as? NSTextView)
        #expect(editor.string == "fix" && editor.selectedRange() == NSRange(location: 3, length: 0))
    }

    @Test func unmatchedWindowSearchCancelsInsteadOfOpeningAnotherWindow() async throws {
        let palette = Palette()
        defer { palette.orderOut(nil) }
        palette.loadWindows = { _ in .success(windows()) }
        var opened = false, cancelled = false
        palette.onCommit = { _ in opened = true }
        palette.onWindowCommit = { _, _ in opened = true }
        palette.onCancel = { cancelled = true }
        palette.present(hold: true)
        palette.render(apps, running: Set(apps.map(\.id)), count: 2)
        palette.browseWindows()
        try await waitFor { labels(palette.contentView).contains { $0.hasPrefix("Résumé,") } }
        palette.receive(0, text: "no such window")
        palette.commit()
        #expect(cancelled && !opened)
    }
    @Test func previewsOnlyCaptureTheVisiblePageAfterExplicitDrillDown() async throws {
        let palette = Palette()
        defer { palette.orderOut(nil) }
        let entries = windows()
        var requests: [[UUID]] = []
        palette.canPreview = { true }
        palette.loadWindows = { _ in .success(entries) }
        palette.loadPreviews = { _, windows, _ in requests.append(windows.map(\.id)) }
        palette.present(hold: true)
        palette.render(apps, running: Set(apps.map(\.id)), count: 2)
        palette.receive(0, text: "fix")
        #expect(requests.isEmpty)
        palette.browseWindows()
        try await waitFor { requests.count == 1 }
        #expect(requests[0] == Array(entries.prefix(3)).map(\.id))
        palette.move(3)
        try await waitFor { requests.count == 2 }
        #expect(requests[1] == Array(entries.dropFirst(3).prefix(3)).map(\.id))
        palette.backFromWindows()
        let count = requests.count
        try await Task.sleep(for: .milliseconds(100))
        #expect(requests.count == count && palette.query == "fix")
    }

    @Test func missingPreviewPermissionNeverCallsTheCaptureAPI() async throws {
        let palette = Palette()
        defer { palette.orderOut(nil) }
        var requests = 0
        palette.canPreview = { false }
        palette.loadWindows = { _ in .success(windows()) }
        palette.loadPreviews = { _, _, _ in requests += 1 }
        palette.present(hold: true)
        palette.render(apps, running: Set(apps.map(\.id)), count: 2)
        palette.browseWindows()
        try await waitFor { labels(palette.contentView).contains { $0.hasPrefix("Résumé,") } }
        try await Task.sleep(for: .milliseconds(100))
        #expect(requests == 0)
        #expect(palette.contentView?.subviews.isEmpty == false)
        #expect(palette.frame.height <= 492)
    }

    @Test func duplicateTitlesRequireAnUnambiguousPreviewMatch() {
        var entry = windows(1)[0]
        let first = CGRect(x: 100, y: 200, width: 500, height: 300)
        let second = CGRect(x: 700, y: 200, width: 500, height: 300)
        let candidates = [(title: entry.title, frame: first), (title: entry.title, frame: second)]
        #expect(WindowPreviews.match(entry, candidates: candidates) == nil)
        entry.frame = second
        #expect(WindowPreviews.match(entry, candidates: candidates) == 1)
        #expect(WindowPreviews.match(entry, candidates: [candidates[0]]) == nil)
        #expect(WindowPreviews.match(entry, candidates: [candidates[1], candidates[1]]) == nil)
        #expect(WindowPreviews.match(entry, candidates: [(title: "Unrelated", frame: second)]) == nil)
    }

    @Test func thumbnailGeometryPreservesAspectRatioAndCentresTheImage() {
        let bounds = CGRect(x: 0, y: 0, width: 128, height: 72)
        for size in [CGSize(width: 520, height: 344), CGSize(width: 1600, height: 900), CGSize(width: 500, height: 900)] {
            let rect = WindowThumbnail.imageRect(size: size, in: bounds)
            #expect(bounds.contains(rect))
            #expect(abs(rect.midX - bounds.midX) < 0.01 && abs(rect.midY - bounds.midY) < 0.01)
            #expect(abs(rect.width / rect.height - size.width / size.height) < 0.01)
            let captured = WindowPreviews.captureSize(for: size)
            #expect(captured.width <= 256 && captured.height <= 160)
            #expect(abs(captured.width / captured.height - size.width / size.height) < 0.02)
        }
    }

    @Test func transientTitlebarTooltipIsNotAWindowChoice() {
        #expect(!WindowAccess.selectableSize(CGSize(width: 66, height: 20)))
        #expect(WindowAccess.selectableSize(CGSize(width: 520, height: 352)))
        #expect(WindowAccess.selectableSize(CGSize(width: 280, height: 140)))
    }

    @Test func thumbnailArrivalPreservesRowsAndSelection() async throws {
        let palette = Palette()
        defer { palette.orderOut(nil) }
        let entries = windows(3)
        var completion: CheckedContinuation<Void, Never>?
        var received: (@MainActor (UUID, CGImage) -> Void)?
        palette.canPreview = { true }
        palette.loadWindows = { _ in .success(entries) }
        palette.loadPreviews = { _, _, receive in
            received = receive
            await withCheckedContinuation { completion = $0 }
        }
        palette.present(hold: true)
        palette.render(apps, running: Set(apps.map(\.id)), count: 2)
        palette.browseWindows()
        try await waitFor { completion != nil }
        func row(in view: NSView?) -> NSView? {
            guard let view else { return nil }
            if view.accessibilityLabel()?.hasPrefix("Résumé,") == true { return view }
            return view.subviews.lazy.compactMap { row(in: $0) }.first
        }
        let before = try #require(row(in: palette.contentView))
        palette.move(1)
        let context = try #require(CGContext(data: nil, width: 128, height: 72, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        received?(entries[0].id, image)
        completion?.resume()
        try await Task.sleep(for: .milliseconds(10))
        #expect(row(in: palette.contentView) === before)
        var chosen: UUID?
        palette.onWindowCommit = { _, window in chosen = window.id }
        palette.commit()
        #expect(chosen == entries[1].id)
    }

    @Test func tabLetsCommandGoBeforeChoosingAWindow() async throws {
        let palette = Palette()
        defer { palette.orderOut(nil) }
        let entries = windows(3)
        var opened = false
        var focused: UUID?
        palette.loadWindows = { _ in .success(entries) }
        palette.onCommit = { _ in opened = true }
        palette.onWindowCommit = { _, window in focused = window.id }
        palette.present(hold: true)
        palette.render(apps, running: Set(apps.map(\.id)), count: 2)
        palette.receive(0, text: "fix")
        palette.receive(48, text: "")
        palette.releaseHold()
        #expect(!opened && focused == nil && palette.isChoosingWindow && !palette.isHold)
        #expect(palette.isKeyWindow)
        let editor = try #require(palette.firstResponder as? NSTextView)
        #expect(editor.selectedRange().length == 0)
        try await waitFor { labels(palette.contentView).contains { $0.hasPrefix("Résumé,") } }
        palette.receive(19, text: "2")
        #expect(focused == entries[1].id && !opened)
        #expect(palette.backFromWindows() && palette.query == "fix")
    }

    @Test func plainHoldReleaseStillCommitsImmediatelyWithoutLoadingWindows() {
        let palette = Palette()
        defer { palette.orderOut(nil) }
        var opened = false, loaded = false
        palette.loadWindows = { _ in loaded = true; return .success([]) }
        palette.onCommit = { _ in opened = true }
        palette.present(hold: true)
        palette.render(apps, running: Set(apps.map(\.id)), count: 2)
        palette.releaseHold()
        #expect(opened && !loaded)
    }

    @Test func repeatVisitUsesTheSameWindowSnapshotAndSleepInvalidationRemovesIt() async throws {
        let palette = Palette()
        defer { palette.orderOut(nil) }
        let handle = AXUIElementCreateApplication(getpid())
        let entry = WindowEntry(title: "Cached fixture", minimized: false, element: handle)
        let context = try #require(CGContext(data: nil, width: 128, height: 72, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        var captures = 0
        palette.canPreview = { true }
        palette.loadWindows = { _ in .success([WindowEntry(title: entry.title, minimized: false, element: handle)]) }
        palette.loadPreviews = { _, windows, receive in
            captures += 1
            receive(windows[0].id, image)
        }
        func thumbnail(in view: NSView?) -> WindowThumbnail? {
            guard let view else { return nil }
            if let thumbnail = view as? WindowThumbnail { return thumbnail }
            return view.subviews.lazy.compactMap { thumbnail(in: $0) }.first
        }
        func show() {
            palette.present(hold: true)
            palette.render(apps, running: Set(apps.map(\.id)), count: 2)
            palette.browseWindows()
        }
        show()
        try await waitFor { thumbnail(in: palette.contentView)?.image != nil }
        let first = try #require(thumbnail(in: palette.contentView)?.image)
        palette.orderOut(nil)
        show()
        try await waitFor { thumbnail(in: palette.contentView)?.image != nil }
        #expect(thumbnail(in: palette.contentView)?.image === first)
        #expect(thumbnail(in: palette.contentView)?.isLoading == false && thumbnail(in: palette.contentView)?.layer?.filters == nil)
        #expect(captures == 1)
        palette.orderOut(nil)
        palette.discardPreviewCache()
        show()
        try await waitFor { captures == 2 }
    }

    @Test func untitledAndMultilineWindowsMatchTheirNativePreviews() {
        let element = AXUIElementCreateApplication(getpid())
        let entry = WindowEntry(title: "Untitled window", minimized: false, element: element)
        #expect(WindowPreviews.match(entry, candidates: [(title: "", frame: .zero)]) == 0)
        let multiline = WindowEntry(title: WindowAccess.windowTitle("First\nSecond"), minimized: false, element: element)
        #expect(WindowPreviews.match(multiline, candidates: [(title: "First\nSecond", frame: .zero)]) == 0)
    }

    @Test func loadingThreeWindowPreviewsDoesNotCollapseAndExpandThePanel() async throws {
        let palette = Palette()
        defer { palette.orderOut(nil) }
        var completion: CheckedContinuation<Result<[WindowEntry], WindowAccess.Failure>, Never>?
        palette.loadWindows = { _ in await withCheckedContinuation { completion = $0 } }
        palette.present(hold: true)
        palette.render(apps, running: Set(apps.map(\.id)), count: 2)
        let top = palette.frame.maxY
        palette.browseWindows()
        let loadingHeight = palette.frame.height
        try await waitFor { completion != nil }
        completion?.resume(returning: .success(windows(3)))
        try await waitFor { labels(palette.contentView).contains { $0.hasPrefix("Résumé,") } }
        #expect(palette.frame.height == loadingHeight && palette.frame.maxY == top)
    }

    @Test func softFocusNeverBlocksSelectionAndClearsAsSoonAsAnImageArrives() async throws {
        let palette = Palette()
        defer { palette.orderOut(nil) }
        let entries = windows(1)
        var receive: ((UUID, CGImage) -> Void)?
        var completion: CheckedContinuation<Void, Never>?
        var focused: UUID?
        palette.canPreview = { true }
        palette.loadWindows = { _ in .success(entries) }
        palette.loadPreviews = { _, _, callback in
            receive = callback
            await withCheckedContinuation { completion = $0 }
        }
        palette.onWindowCommit = { _, window in focused = window.id }
        palette.present(hold: true)
        palette.render(apps, running: [apps[0].id], count: 2)
        palette.browseWindows()
        try await waitFor { completion != nil }
        func thumbnail(in view: NSView?) -> WindowThumbnail? {
            guard let view else { return nil }
            if let thumbnail = view as? WindowThumbnail { return thumbnail }
            return view.subviews.lazy.compactMap { thumbnail(in: $0) }.first
        }
        let thumbnail = try #require(thumbnail(in: palette.contentView))
        #expect(thumbnail.isLoading && thumbnail.image == nil && thumbnail.layer?.filters?.count == 1)
        palette.releaseHold()
        palette.receive(18, text: "1")
        #expect(focused == entries[0].id)
        let context = try #require(CGContext(data: nil, width: 128, height: 72, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let image = try #require(context.makeImage())
        receive?(entries[0].id, image)
        #expect(thumbnail.image != nil && !thumbnail.isLoading && thumbnail.layer?.filters == nil)
        completion?.resume()
    }

    @Test func failedCaptureDoesNotLeaveTheAppIconPermanentlyDefocused() async throws {
        let palette = Palette()
        defer { palette.orderOut(nil) }
        palette.canPreview = { true }
        palette.loadWindows = { _ in .success(windows(1)) }
        palette.loadPreviews = { _, _, _ in }
        palette.present(hold: true)
        palette.render(apps, running: [apps[0].id], count: 2)
        palette.browseWindows()
        try await waitFor { labels(palette.contentView).contains { $0.hasPrefix("Résumé,") } }
        func thumbnail(in view: NSView?) -> WindowThumbnail? {
            guard let view else { return nil }
            if let thumbnail = view as? WindowThumbnail { return thumbnail }
            return view.subviews.lazy.compactMap { thumbnail(in: $0) }.first
        }
        try await waitFor { thumbnail(in: palette.contentView)?.isLoading == false }
        #expect(thumbnail(in: palette.contentView)?.image == nil)
        #expect(thumbnail(in: palette.contentView)?.layer?.filters == nil)
    }

}
