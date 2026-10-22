import AppKit
import ScreenCaptureKit

nonisolated enum WindowPreviews {
    // SCWindow exposes immutable metadata but the SDK does not mark it Sendable.
    private struct Target: @unchecked Sendable { let window: SCWindow }

    static func match(_ window: WindowEntry, candidates: [(title: String, frame: CGRect)]) -> Int? {
        let titles = candidates.indices.filter { WindowAccess.windowTitle(candidates[$0].title) == window.title }
        guard let frame = window.frame else { return titles.count == 1 ? titles[0] : nil }
        let positions = titles.filter {
            let other = candidates[$0].frame
            return abs(other.minX - frame.minX) < 2 && abs(other.minY - frame.minY) < 2
                && abs(other.width - frame.width) < 2 && abs(other.height - frame.height) < 2
        }
        return positions.count == 1 ? positions[0] : nil
    }

    static func captureSize(for size: CGSize) -> CGSize {
        guard size.width > 0, size.height > 0 else { return CGSize(width: 256, height: 160) }
        let scale = min(256 / size.width, 160 / size.height)
        return CGSize(width: max(1, (size.width * scale).rounded()), height: max(1, (size.height * scale).rounded()))
    }

    @concurrent static func capture(_ windows: [WindowEntry], pid: pid_t,
                                    receive: @escaping @MainActor @Sendable (UUID, CGImage) -> Void) async {
        let visibleOnly = !windows.contains(where: \.minimized)
        guard !Task.isCancelled, CGPreflightScreenCaptureAccess(),
              let content = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: visibleOnly) else { return }
        var candidates = content.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 }
        var metadata = candidates.map { (title: $0.title ?? "", frame: $0.frame) }
        // Off-Space and hidden windows may be absent from the faster on-screen query.
        if visibleOnly, windows.contains(where: { match($0, candidates: metadata) == nil }) {
            guard !Task.isCancelled,
                  let all = try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: false) else { return }
            candidates = all.windows.filter { $0.owningApplication?.processID == pid && $0.windowLayer == 0 }
            metadata = candidates.map { (title: $0.title ?? "", frame: $0.frame) }
        }
        await withTaskGroup(of: (UUID, CGImage?).self) { group in
            for window in windows.prefix(3) {
                guard !Task.isCancelled else { break }
                guard let index = match(window, candidates: metadata) else { continue }
                let target = Target(window: candidates[index])
                group.addTask {
                    guard !Task.isCancelled else { return (window.id, nil) }
                    let configuration = SCScreenshotConfiguration()
                    let size = captureSize(for: target.window.frame.size)
                    configuration.width = Int(size.width)
                    configuration.height = Int(size.height)
                    configuration.showsCursor = false
                    configuration.ignoreShadows = true
                    configuration.includeChildWindows = false
                    configuration.dynamicRange = .sdr
                    configuration.displayIntent = .local
                    let filter = SCContentFilter(desktopIndependentWindow: target.window)
                    let output = try? await SCScreenshotManager.captureScreenshot(contentFilter: filter, configuration: configuration)
                    return (window.id, output?.sdrImage)
                }
            }
            for await (id, image) in group {
                if !Task.isCancelled, let image { await receive(id, image) }
            }
        }
    }
}
