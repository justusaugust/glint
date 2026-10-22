import AppKit
import Testing
@testable import Glint

@Suite(.serialized) @MainActor struct AppLauncherTests {
    @Test func exitBeforeLaunchReplyRequestsOneInlineRetry() {
        let center = NotificationCenter()
        let recovery = AppLauncher(center: center)
        defer { recovery.cancel() }
        var retries = 0
        recovery.watch(pid: getpid()) { retries += 1 }
        center.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil,
                    userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current])
        #expect(recovery.complete() && !recovery.complete() && retries == 0)
    }

    @Test func exitAfterLaunchReplyRetriesOnlyOnceAndIgnoresUnrelatedProcesses() {
        let center = NotificationCenter()
        let recovery = AppLauncher(center: center)
        defer { recovery.cancel() }
        var retries = 0
        recovery.watch(pid: -1) { retries += 1 }
        #expect(!recovery.complete())
        center.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil,
                    userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current])
        #expect(retries == 0)
        recovery.watch(pid: getpid()) { retries += 1 }
        #expect(!recovery.complete())
        for _ in 0..<2 {
            center.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil,
                        userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current])
        }
        #expect(retries == 1)
    }

    @Test func laterUserInputOrAReplacementRequestCancelsOldRecovery() {
        let center = NotificationCenter()
        let recovery = AppLauncher(center: center)
        defer { recovery.cancel() }
        var retries = 0
        recovery.watch(pid: getpid()) { retries += 1 }
        #expect(!recovery.complete())
        recovery.cancel()
        center.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil,
                    userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current])
        #expect(retries == 0 && !recovery.complete())
        recovery.watch(pid: getpid()) { retries += 1 }
        recovery.watch(pid: -1) { retries += 10 }
        #expect(!recovery.complete())
        center.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil,
                    userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication.current])
        #expect(retries == 0)
    }
}
