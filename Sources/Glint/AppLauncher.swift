import AppKit
import Carbon
import GlintCore

/// LaunchServices can return the old process while an earlier Quit is still finishing.
final class AppLauncher {
    private let center: NotificationCenter
    private var observer: NSObjectProtocol?
    private var expiry: Task<Void, Never>?
    private var request: UUID?
    private var terminated = false
    private var completed = false

    init(center: NotificationCenter = NSWorkspace.shared.notificationCenter) { self.center = center }

    func open(_ app: AppEntry, retry: @escaping @MainActor () -> Void) async throws {
        cancel()
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
        let url = running?.bundleURL ?? app.url
        if let running {
            watch(pid: running.processIdentifier, retry: retry)
        }
        let result: Result<NSRunningApplication, Error>
        do { result = .success(try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)) }
        catch { result = .failure(error) }
        let stillRequested = request != nil
        let exited = complete()
        if case .failure = result, !exited { cancel() }
        let launched: NSRunningApplication
        if exited || (stillRequested && (try? result.get().isTerminated) == true) {
            cancel()
            launched = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        } else { launched = try result.get() }
        if !launched.isActive { launched.activate() }
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
        if let observer { center.removeObserver(observer) }
        observer = nil
        expiry?.cancel()
        expiry = nil
        request = nil
        terminated = false
        completed = false
    }
}
