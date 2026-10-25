import AppKit
import Carbon
import GlintCore
import OSLog

/// LaunchServices can return the old process while an earlier Quit is still finishing.
final class AppLauncher {
    private static let log = Logger(subsystem: "local.glint.switcher", category: "launch")
    private let recoverApplication: @MainActor (URL) async -> NSRunningApplication?
    private let center: NotificationCenter
    private let openApplication: @MainActor (URL, NSWorkspace.OpenConfiguration) async throws -> NSRunningApplication
    private var observer: NSObjectProtocol?
    private var expiry: Task<Void, Never>?
    private var request: UUID?
    private var terminated = false
    private var completed = false
    private var generation = 0

    init(center: NotificationCenter = NSWorkspace.shared.notificationCenter,
         recoverApplication: @escaping @MainActor (URL) async -> NSRunningApplication? = { await AppLauncher.applicationWithWindow(at: $0) },
         openApplication: @escaping @MainActor (URL, NSWorkspace.OpenConfiguration) async throws -> NSRunningApplication = {
             try await NSWorkspace.shared.openApplication(at: $0, configuration: $1)
         }) {
        self.recoverApplication = recoverApplication
        self.center = center
        self.openApplication = openApplication
    }

    func open(_ app: AppEntry, retry: @escaping @MainActor () -> Void) async throws {
        cancel()
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.id)
            .first { !$0.isTerminated && $0.processIdentifier > 0 }
        running?.unhide()
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = false
        // Reopen is essential: activation alone leaves apps with no windows invisible.
        if running != nil {
            configuration.appleEvent = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass),
                eventID: AEEventID(kAEReopenApplication), targetDescriptor: nil,
                returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        }
        let url = running?.bundleURL ?? app.url
        if let running {
            watch(pid: running.processIdentifier, retry: retry)
        }
        var generation = self.generation
        var result: Result<NSRunningApplication, Error>
        do { result = .success(try await launch(at: url, configuration: configuration)) }
        catch { result = .failure(error) }
        guard generation == self.generation else { return }
        let stillRequested = request != nil
        let exited = complete()
        if case .failure = result, !exited { cancel() }
        if exited || (stillRequested && (try? result.get().isTerminated) == true) {
            cancel()
            configuration.appleEvent = nil
            generation = self.generation
            do { result = .success(try await launch(at: url, configuration: configuration)) }
            catch { result = .failure(error) }
            guard generation == self.generation else { return }
        }
        let launched = try result.get()
        if !launched.isActive { launched.activate() }
    }

    func launch(at url: URL, configuration: NSWorkspace.OpenConfiguration) async throws -> NSRunningApplication {
        // Glint reports the final error after checking whether the app actually opened.
        configuration.promptsUserIfNeeded = false
        do { return try await openApplication(url, configuration) }
        catch {
            let failure = error as NSError
            Self.log.notice("Launch reply failed: \(failure.domain, privacy: .public) \(failure.code, privacy: .public)")
            if configuration.appleEvent != nil {
                configuration.appleEvent = nil
                return try await launch(at: url, configuration: configuration)
            }
            if let running = await recoverApplication(url) { return running }
            throw error
        }
    }

    static func applicationWithWindow(at url: URL) async -> NSRunningApplication? {
        let url = url.resolvingSymlinksInPath()
        guard let id = Bundle(url: url)?.bundleIdentifier else { return nil }
        // A failed launch reply can precede the replacement process's first window.
        for attempt in 0...6 {
            guard !Task.isCancelled else { return nil }
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: id).filter {
                !$0.isTerminated && $0.processIdentifier > 0 && $0.activationPolicy == .regular
                    && $0.bundleURL?.resolvingSymlinksInPath() == url
            }
            if !apps.isEmpty,
               let windows = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] {
                let owners = Set(windows.compactMap { window -> pid_t? in
                    guard window[kCGWindowLayer as String] as? Int == 0,
                          let bounds = window[kCGWindowBounds as String] as? NSDictionary,
                          let frame = CGRect(dictionaryRepresentation: bounds), WindowAccess.selectableSize(frame.size),
                          let pid = window[kCGWindowOwnerPID as String] as? pid_t else { return nil }
                    return pid
                })
                if let running = apps.first(where: { $0.isActive && owners.contains($0.processIdentifier) })
                    ?? apps.first(where: { owners.contains($0.processIdentifier) }) { return running }
            }
            if attempt < 6 { try? await Task.sleep(for: .milliseconds(100)) }
        }
        return nil
    }

    func watch(pid: pid_t, retry: @escaping @MainActor () -> Void) {
        cancel()
        let id = UUID()
        request = id
        observer = center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let terminatedPID = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            MainActor.assumeIsolated {
                guard let self, self.request == id, terminatedPID == pid else { return }
                self.terminated = true
                if self.completed { self.cancel(); retry() }
            }
        }
        // shortcut: cover a Quit already in flight for three seconds; later user input cancels immediately.
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled, let self, request == id else { return }
            cancel()
        }
    }

    /// If exit arrived before the open call returned, its caller retries without a second request.
    func complete() -> Bool {
        guard request != nil else { return false }
        if terminated { cancel(); return true }
        completed = true
        return false
    }

    func cancel() {
        generation &+= 1
        if let observer { center.removeObserver(observer) }
        observer = nil
        expiry?.cancel()
        expiry = nil
        request = nil
        terminated = false
        completed = false
    }
}
