import AppKit
import CoreServices
import GlintCore

nonisolated struct AppScanner: Sendable {
    @concurrent static func scan(extra: [URL]) async -> [AppEntry] {
        let manager = FileManager.default
        let roots = ["/Applications", "/System/Applications", "/System/Cryptexes/App/System/Applications", "/System/Library/CoreServices/Applications",
                     manager.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        var urls = extra
        for root in roots {
            guard let walker = manager.enumerator(at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            while let url = walker.nextObject() as? URL {
                if url.pathExtension.lowercased() == "app" { urls.append(url) }
            }
        }
        var entries: [String: AppEntry] = [:]
        for originalURL in urls {
            let url = originalURL.resolvingSymlinksInPath()
            guard !Task.isCancelled, let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
                  id != Bundle.main.bundleIdentifier,
                  (bundle.object(forInfoDictionaryKey: "LSBackgroundOnly") as? Bool) != true else { continue }
            let name = (bundle.localizedInfoDictionary?["CFBundleDisplayName"] as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            if entries[id] == nil { entries[id] = AppEntry(id: id, name: name, url: url) }
        }
        return Array(entries.values)
    }
}

final class Catalog {
    private(set) var apps: [AppEntry] = []
    var changed: (() -> Void)?
    private var scanTask: Task<Void, Never>?
    private var stream: FSEventStreamRef?

    func start() {
        mergeRunning()
        refresh()
        let paths = ["/Applications", "/System/Applications",
                     FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
            .filter { FileManager.default.fileExists(atPath: $0) }
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                            retain: nil, release: nil, copyDescription: nil)
        stream = FSEventStreamCreate(nil, { _, info, _, _, _, _ in
            guard let info else { return }
            MainActor.assumeIsolated { Unmanaged<Catalog>.fromOpaque(info).takeUnretainedValue().refresh() }
        }, &context, paths as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2,
           FSEventStreamCreateFlags(kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagIgnoreSelf))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    func stop() {
        scanTask?.cancel()
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
        stream = nil
    }

    func refresh() {
        scanTask?.cancel()
        let extra = (UserDefaults.standard.stringArray(forKey: "extraApps") ?? []).map { URL(fileURLWithPath: $0) }
        scanTask = Task { [weak self] in
            let found = await AppScanner.scan(extra: extra)
            guard !Task.isCancelled, let self else { return }
            apps = found
            mergeRunning()
        }
    }

    func mergeRunning() {
        var indexed = Dictionary(apps.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier,
                  let url = app.bundleURL, let name = app.localizedName else { continue }
            indexed[id] = AppEntry(id: id, name: name, url: url)
        }
        apps = Array(indexed.values)
        changed?()
    }

    func add(_ urls: [URL]) {
        let paths = Set((UserDefaults.standard.stringArray(forKey: "extraApps") ?? []) + urls.map(\.path))
        UserDefaults.standard.set(paths.sorted(), forKey: "extraApps")
        refresh()
    }
}
