import AppKit
import Carbon
import GlintCore
import Testing
@testable import Glint

@Suite(.serialized) @MainActor struct AppLauncherTests {
    @Test func laterInputSuppressesFailureFromAnOldLaunchRequest() async throws {
        var pending: CheckedContinuation<NSRunningApplication, Error>?
        let launcher = AppLauncher(recoverApplication: { _ in nil }, openApplication: { _, _ in
            try await withCheckedThrowingContinuation { pending = $0 }
        })
        let entry = AppEntry(id: "local.glint.test.cancelled", name: "Cancelled", url: URL(fileURLWithPath: "/tmp/Cancelled.app"))
        let opening = Task { try await launcher.open(entry, retry: {}) }
        await Task.yield()
        let reply = try #require(pending)
        launcher.cancel()
        reply.resume(throwing: NSError(domain: NSOSStatusErrorDomain, code: -600))
        try await opening.value
    }

    @Test func errorReplyWithVerifiedWindowIsSuccessful() async throws {
        var recoveryCalls = 0
        var openCalls = 0
        let url = URL(fileURLWithPath: "/tmp/GlintReady.app")
        let launcher = AppLauncher(recoverApplication: { requestedURL in
            #expect(requestedURL == url)
            recoveryCalls += 1
            return NSRunningApplication.current
        }, openApplication: { _, _ in
            openCalls += 1
            throw NSError(domain: NSOSStatusErrorDomain, code: -600)
        })
        let result = try await launcher.launch(at: url, configuration: NSWorkspace.OpenConfiguration())
        #expect(result.processIdentifier == getpid() && openCalls == 1 && recoveryCalls == 1)
    }

    @Test func failedReopenAndFallbackCanRecoverTheReplacementWindow() async throws {
        var recoveryCalls = 0
        var openCalls = 0
        let launcher = AppLauncher(recoverApplication: { _ in
            recoveryCalls += 1
            return NSRunningApplication.current
        }, openApplication: { _, _ in
            openCalls += 1
            throw NSError(domain: NSOSStatusErrorDomain, code: -600)
        })
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.appleEvent = NSAppleEventDescriptor.null()
        _ = try await launcher.launch(at: URL(fileURLWithPath: "/tmp/GlintReady.app"), configuration: configuration)
        #expect(openCalls == 2 && recoveryCalls == 1)
    }

    @Test func successfulReplyDoesNotInspectWindowsOrWait() async throws {
        var recoveries = 0
        let launcher = AppLauncher(recoverApplication: { _ in
            recoveries += 1
            return nil
        }, openApplication: { _, _ in NSRunningApplication.current })
        _ = try await launcher.launch(at: URL(fileURLWithPath: "/tmp/Fixture.app"), configuration: NSWorkspace.OpenConfiguration())
        #expect(recoveries == 0)
    }

    @Test func rejectedReopenFallsBackOnceToNormalOpen() async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.appleEvent = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEReopenApplication), targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        let url = URL(fileURLWithPath: "/tmp/GlintFixture.app")
        var calls: [Bool] = []
        let launcher = AppLauncher(openApplication: { requestedURL, options in
            #expect(requestedURL == url && options === configuration)
            calls.append(options.appleEvent != nil)
            if calls.count == 1 { throw NSError(domain: NSOSStatusErrorDomain, code: -1708) }
            return NSRunningApplication.current
        })
        let result = try await launcher.launch(at: url, configuration: configuration)
        #expect(result.processIdentifier == getpid() && calls == [true, false])
    }

    @Test func normalOpenFailureIsNotHiddenOrRetried() async {
        var calls = 0
        let launcher = AppLauncher(openApplication: { _, options in
            calls += 1
            #expect(options.appleEvent == nil && !options.promptsUserIfNeeded)
            throw NSError(domain: NSOSStatusErrorDomain, code: -43)
        })
        let entry = AppEntry(id: "local.glint.test.missing", name: "Missing", url: URL(fileURLWithPath: "/tmp/Missing.app"))
        do {
            try await launcher.open(entry, retry: {})
            Issue.record("A missing app must report failure")
        } catch {
            #expect((error as NSError).domain == NSOSStatusErrorDomain && (error as NSError).code == -43)
        }
        #expect(calls == 1)
    }

    @Test func failedFallbackReportsItsError() async {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.appleEvent = NSAppleEventDescriptor.null()
        var calls = 0
        let launcher = AppLauncher(openApplication: { _, _ in
            calls += 1
            throw NSError(domain: NSOSStatusErrorDomain, code: calls == 1 ? -1708 : -10810)
        })
        do {
            _ = try await launcher.launch(at: URL(fileURLWithPath: "/tmp/Missing.app"), configuration: configuration)
            Issue.record("A failed normal open must report failure")
        } catch {
            #expect((error as NSError).domain == NSOSStatusErrorDomain && (error as NSError).code == -10810)
        }
        #expect(calls == 2)
    }

    @Test func successfulReopenHasNoFallbackOrExtraRequest() async throws {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.appleEvent = NSAppleEventDescriptor.null()
        var calls = 0
        let launcher = AppLauncher(openApplication: { _, options in
            calls += 1
            #expect(options.appleEvent != nil)
            return NSRunningApplication.current
        })
        _ = try await launcher.launch(at: URL(fileURLWithPath: "/tmp/Fixture.app"), configuration: configuration)
        #expect(calls == 1 && configuration.appleEvent != nil)
    }

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
