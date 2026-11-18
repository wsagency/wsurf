// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Darwin
import Foundation
import os
import Testing
import XPC

@testable import CefKit
@testable import WSurf

/// The second group of `ChromiumRemoteClientTests` (a file of its own to keep the suite under the length limits): the tests that
/// run against the real service of the OOP lane (`Tools/run-chromium-oop-tests.sh ChromiumRemoteClientTests`), each gated on
/// `ChromiumServiceBundle.isPresent`. launchd starts a service no sooner than 10 s after the spawn of the one before it, so each
/// of them may wait that long for its first hello. They run in an invocation that contains no in-process Chromium suite: the last
/// of them latches the process out of process.
extension ChromiumRemoteClientTests {
    // MARK: The real service

    /// Asks the service to count down `count` hellos that kill it (`debug.exitOnHello`) on a connection of its own, before the
    /// client says hello: the instance that answers is then the armed one, and so are the next `count - 1`.
    private func arm(count: Int, root: URL) async -> Bool {
        let message = CefRemoteMessage(CefRemote.Op.debugExitOnHello)
        message.set(CefRemote.Key.rootPath, root.path)
        message.set(CefRemote.Key.count, count)
        let connection = Self.makeArmConnection()
        let armed: Bool = await withCheckedContinuation { continuation in
            xpc_connection_send_message_with_reply(connection, message.object, DispatchQueue.main) { answer in
                continuation.resume(returning: CefRemoteMessage(wrapping: answer)?.bool(CefRemote.Key.success) ?? false)
            }
        }
        xpc_connection_cancel(connection)
        return armed
    }

    nonisolated private static func makeArmConnection() -> xpc_connection_t {
        let connection = xpc_connection_create((Bundle.main.bundleIdentifier ?? "") + CefRemote.serviceSuffix, DispatchQueue.global())
        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_activate(connection)
        return connection
    }

    /// A first hello may wait out launchd's 10 s throttle, then the launch and a cold CEF start, on a loaded machine: the timeout
    /// of these tests is the host tests' 30 s (the production default, tested above, is shorter and stays).
    private static let realHelloTimeout: TimeInterval = 30

    private func realRemote() -> (remote: ChromiumRemote, root: URL)? {
        let root = FileManager.default.temporaryDirectory.appending(path: "wsurf-d4-client-\(UUID().uuidString)", directoryHint: .isDirectory)
        guard let canonical = try? ChromiumRemote.prepareRoot(root) else { return nil }
        let remote = ChromiumRemote(
            sink: ChromiumFrameSink(), root: { canonical }, helloTimeout: Self.realHelloTimeout,
            clock: { ProcessInfo.processInfo.systemUptime }, latch: ChromiumOOP.Latch(), isEnabled: { true }
        )
        return (remote, canonical)
    }

    /// Ends the test so that no service instance outlives it (the next test needs a fresh one).
    private func finish(_ remote: ChromiumRemote, pid: pid_t?) async {
        remote.disconnect()
        guard let pid else { return }
        let gone = await waitUntil(8) { kill(pid, 0) == -1 && errno == ESRCH }
        if !gone {
            Issue.record("the service \(pid) did not leave after its connection closed")
        }
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aReplacedInputConnectionIsForgottenWithoutCountingAServiceDeath() async throws {
        let (remote, root) = try #require(realRemote())
        remote.connect()
        guard await waitUntil(40, { remote.isRunning }), case let .running(pid) = remote.state else {
            Issue.record("no hello: \(remote.state): \(remote.lastRefusalText)")
            await finish(remote, pid: nil)
            return
        }
        do {
            let message = CefRemoteMessage(CefRemote.Op.focus)
            remote.sendInput(message)
            let old = try #require(remote.input)
            let generation = remote.generation
            let attached: Bool = await withCheckedContinuation { continuation in
                xpc_connection_send_message_with_reply(old, CefRemoteMessage(CefRemote.Op.debugStats).object, DispatchQueue.main) { answer in
                    continuation.resume(returning: CefRemoteMessage(wrapping: answer)?.int(CefRemote.Key.pid) == Int64(pid))
                }
            }
            try #require(attached, "a reply on the input connection follows its accepted hello")
            let replacement = try ChromiumServiceClient(root: root)
            defer { replacement.close() }
            let accepted = try replacement.call(CefRemoteMessage(CefRemote.Op.inputHello))
            try #require(accepted.bool(CefRemote.Key.success))
            #expect(await waitUntil(3) { !remote.hasInputConnection }, "the service cancelled the old input connection")
            #expect(remote.isRunning && remote.servicePID == pid)
            #expect(remote.generation == generation && remote.interruptions == 0, "the control connection stayed healthy")

            remote.sendInput(message)
            let reopened = try #require(remote.input)
            #expect(ObjectIdentifier(reopened) != ObjectIdentifier(old), "the next send opens a new input connection")
            #expect(await remote.statistics()?.int(CefRemote.Key.pid) == Int64(pid))
        } catch {
            await finish(remote, pid: pid)
            throw error
        }
        await finish(remote, pid: pid)
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aHelloIsAnsweredAndTheClientIsRunningWithItsFramesConnection() async throws {
        let (remote, _) = try #require(realRemote())
        _ = remote.connect()
        let up = await waitUntil(40) { remote.isRunning }
        #expect(up, "state \(remote.state): \(remote.lastRefusalText)")
        guard case let .running(pid) = remote.state else {
            await finish(remote, pid: nil)
            return
        }
        #expect(pid > 1 && pid != getpid())
        #expect(remote.servicePID == pid)
        #expect(remote.helloCount == 1)
        #expect(remote.cefStartMs > 0)
        #expect(remote.hasFramesConnection)
        let stats = await remote.statistics()
        #expect(stats?.int(CefRemote.Key.pid) == Int64(pid))
        #expect(stats?.bool(CefRemote.Key.started) == true)
        #expect(stats?.bool(CefRemote.Key.mockKeychain) == true)
        #expect(stats?.string(CefRemote.Key.logFile) == "/dev/null")
        #expect(remote.pendingRequestCount == 0)
        print("ChromiumRemoteClientTests observed: hello round trip \(remote.helloRoundTripMs) ms, CEF start \(remote.cefStartMs) ms")
        await finish(remote, pid: pid)
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func theFramesConnectionTheServiceAcceptedStaysAttachedAndNoSideHelloWasRefused() async throws {
        let (remote, _) = try #require(realRemote())
        _ = remote.connect()
        guard await waitUntil(40, { remote.isRunning }), case let .running(pid) = remote.state else {
            Issue.record("no hello: \(remote.state): \(remote.lastRefusalText)")
            await finish(remote, pid: nil)
            return
        }
        // The frames hello has a reply now: a refusal (not the host's process, no hello yet) would drop the connection.
        let stats = await remote.statistics()
        #expect(stats?.int(CefRemote.Key.pid) == Int64(pid), "a round trip after the frames hello")
        try await Task.sleep(for: .milliseconds(500))
        #expect(remote.hasFramesConnection)
        #expect(remote.sideRefusals == 0)
        await finish(remote, pid: pid)
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aKilledServiceThatRanElevenSecondsIsRelaunchedWithinTwoSecondsOfTheKill() async throws {
        let (remote, _) = try #require(realRemote())
        let handle = Handle()
        let id = remote.makeBrowser(handle)
        var seen: [ChromiumRemote.ServiceState] = []
        remote.onStateChange = { seen.append($0) }
        _ = remote.connect()
        guard await waitUntil(40, { remote.isRunning }), case let .running(first) = remote.state else {
            Issue.record("no first hello: \(remote.state): \(remote.lastRefusalText)")
            await finish(remote, pid: nil)
            return
        }
        // launchd starts a replacement no sooner than 10 s after the spawn of the instance that died. The hello was answered some
        // time after the spawn, so 11 s after it the instance has been up for at least 11 s and nothing delays the relaunch.
        try await Task.sleep(for: .seconds(11))
        let killed = ProcessInfo.processInfo.systemUptime
        remote.abortService()
        let relaunched = await waitUntil(15) { remote.isRunning && remote.servicePID != first }
        let took = ProcessInfo.processInfo.systemUptime - killed
        #expect(relaunched, "state \(remote.state)")
        #expect(took <= 2, "the new hello came \(took) s after the kill")
        print("ChromiumRemoteClientTests observed: kill after 11 s, new hello answered after \(took) s")
        #expect(remote.interruptions == 1)
        #expect(handle.endedCount == 1, "the browser that was in the dead service is told")
        #expect(remote.browserCount == 0)
        #expect(remote.helloCount == 2)
        #expect(seen.contains(.relaunching), "the state says relaunching meanwhile: \(seen)")
        _ = id
        if case let .running(second) = remote.state {
            #expect(second != first)
            #expect(remote.hasFramesConnection, "the frames connection is made again for the new instance")
            await finish(remote, pid: second)
        } else {
            await finish(remote, pid: nil)
        }
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aKilledServiceWithNothingInItIsAnIdleExitAndIsNotRelaunched() async throws {
        let (remote, _) = try #require(realRemote())
        _ = remote.connect()
        guard await waitUntil(40, { remote.isRunning }), case let .running(pid) = remote.state else {
            Issue.record("no first hello: \(remote.state): \(remote.lastRefusalText)")
            await finish(remote, pid: nil)
            return
        }
        remote.abortService()
        #expect(await waitUntil(5) { remote.state == .stopped }, "state \(remote.state)")
        try await Task.sleep(for: .seconds(1))
        #expect(remote.state == .stopped)
        #expect(remote.helloCount == 1, "no browser and no request: not a death, no relaunch")
        #expect(remote.interruptions == 1)
        await finish(remote, pid: pid)
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func threeServicesThatDieAtTheirHelloEndInACrashLoopAndNoFourthLaunchThenAReloadWorks() async throws {
        let (remote, root) = try #require(realRemote())
        var seen: [ChromiumRemote.ServiceState] = []
        remote.onStateChange = { seen.append($0) }
        #expect(await arm(count: 3, root: root))
        let started = ProcessInfo.processInfo.systemUptime
        _ = remote.connect()
        // launchd spawns each replacement 10 s after the spawn before it, so three young deaths take about 20 s and trip the cap
        // (3 deaths inside 30 s) about 20 s after the first, as the review of the service predicted.
        let looping = await waitUntil(45) { remote.state == .crashLooping }
        let took = ProcessInfo.processInfo.systemUptime - started
        #expect(looping, "state \(remote.state) after \(took) s")
        print("ChromiumRemoteClientTests observed: crash loop reached after \(took) s, hellos \(remote.helloCount)")
        #expect(remote.helloCount == 3)
        #expect(remote.interruptions == 3)
        #expect(seen.contains(.relaunching))
        #expect(!seen.contains { if case .running = $0 { true } else { false } }, "no instance ever answered: \(seen)")
        // No fourth launch, though a throttle's worth of time passes.
        try await Task.sleep(for: .seconds(12))
        #expect(remote.helloCount == 3)
        #expect(remote.state == .crashLooping)
        // The person reloads: the marker is used up, so this one answers.
        remote.userReload()
        let answered = await waitUntil(40) { remote.isRunning }
        #expect(answered, "state \(remote.state): \(remote.lastRefusalText)")
        if case let .running(pid) = remote.state {
            await finish(remote, pid: pid)
        } else {
            await finish(remote, pid: nil)
        }
    }

    /// The path of production: D4-8 asks for `ChromiumRuntime.shared.cacheDirectory(profileID:)`, which is built from the root as
    /// the runtime holds it, with the temporary folder's `/var` alias in it, while the hello carries the canonical root.
    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aContextForACacheDirectoryBuiltFromANonCanonicalRootIsCreated() async throws {
        let raw = FileManager.default.temporaryDirectory.appending(path: "wsurf-d4-client-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        let remote = ChromiumRemote(
            sink: ChromiumFrameSink(), root: { raw }, helloTimeout: Self.realHelloTimeout,
            clock: { ProcessInfo.processInfo.systemUptime }, latch: ChromiumOOP.Latch(), isEnabled: { true }
        )
        _ = remote.connect()
        guard await waitUntil(40, { remote.isRunning }), case let .running(pid) = remote.state else {
            Issue.record("no first hello: \(remote.state): \(remote.lastRefusalText)")
            await finish(remote, pid: nil)
            return
        }
        let profile = UUID()
        let created = await remote.ensureContext(id: profile, cacheDirectory: raw.appending(path: profile.uuidString, directoryHint: .isDirectory))
        #expect(created, "a profile's cache directory, built from the root the runtime holds, is inside the service's root")
        let memory = await remote.ensureContext(id: UUID(), cacheDirectory: nil)
        #expect(memory, "an in-memory (private) context")
        #expect(await remote.ensureContext(id: profile, cacheDirectory: raw.appending(path: profile.uuidString, directoryHint: .isDirectory)))
        let stats = await remote.statistics()
        #expect(stats?.int(CefRemote.Key.contexts) == 2)
        // A cache directory outside the root is refused (by the client, before the service is asked), and nothing is made there.
        let outside = FileManager.default.temporaryDirectory.appending(path: "wsurf-d4-outside-\(UUID().uuidString)", directoryHint: .isDirectory)
        #expect(!(await remote.ensureContext(id: UUID(), cacheDirectory: outside)))
        #expect(!FileManager.default.fileExists(atPath: outside.path), "a refused folder is not created")
        await finish(remote, pid: pid)
    }

    /// The request of a page that is being created while the service relaunches: it queues behind the replacement's hello, which
    /// launchd holds back about 10 s after the spawn of the instance that died, so the 5 s a request gets by default would end it
    /// before the service could answer.
    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aContextAskedForWhileTheServiceRelaunchesAfterAYoungDeathIsCreatedNotTimedOut() async throws {
        let (remote, root) = try #require(realRemote())
        #expect(await arm(count: 1, root: root))
        let started = ProcessInfo.processInfo.systemUptime
        _ = remote.connect()
        // The armed instance dies at its hello: a young death, so the replacement is about 10 s away.
        guard await waitUntil(30, { remote.state == .relaunching }) else {
            Issue.record("the armed service did not die at its hello: \(remote.state): \(remote.lastRefusalText)")
            await finish(remote, pid: nil)
            return
        }
        let asked = ProcessInfo.processInfo.systemUptime
        let created = await remote.ensureContext(id: UUID(), cacheDirectory: nil)
        let took = ProcessInfo.processInfo.systemUptime - asked
        #expect(created, "state \(remote.state) after \(took) s")
        print("ChromiumRemoteClientTests observed: a context asked for while relaunching was created after \(took) s (\(ProcessInfo.processInfo.systemUptime - started) s after the start)")
        if case let .running(pid) = remote.state {
            await finish(remote, pid: pid)
        } else {
            await finish(remote, pid: nil)
        }
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aRequestToAServiceThatNeverRepliesEndsOnceWithTimedOut() async throws {
        let (remote, _) = try #require(realRemote())
        _ = remote.connect()
        guard await waitUntil(40, { remote.isRunning }), case let .running(pid) = remote.state else {
            Issue.record("no first hello: \(remote.state): \(remote.lastRefusalText)")
            await finish(remote, pid: nil)
            return
        }
        // The service answers `debug.hangExit` and then blocks its main thread for 15 s (its exit backstop ends it at 5.5 s).
        guard case let .value(answer) = await remote.request(CefRemoteMessage(CefRemote.Op.debugHangExit)) else {
            Issue.record("no answer to debug.hangExit")
            await finish(remote, pid: pid)
            return
        }
        #expect(answer.bool(CefRemote.Key.success))
        let started = ProcessInfo.processInfo.systemUptime
        let reply = await remote.request(CefRemoteMessage(CefRemote.Op.debugStats), timeout: 1)
        let took = ProcessInfo.processInfo.systemUptime - started
        var timedOut = false
        if case .timedOut = reply {
            timedOut = true
        }
        #expect(timedOut, "the reply was not .timedOut")
        #expect(took >= 0.9 && took < 4, "the timeout is the request's own, 1 s (took \(took) s)")
        #expect(remote.pendingRequestCount == 0, "ended exactly once, and nothing is left waiting")
        await finish(remote, pid: pid)
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aCloseSentWhileTheServiceIsExitingReturnsAndTheBrowserIsGone() async throws {
        let (remote, _) = try #require(realRemote())
        let handle = Handle()
        let id = remote.makeBrowser(handle)
        _ = remote.connect()
        guard await waitUntil(40, { remote.isRunning }), case let .running(pid) = remote.state else {
            Issue.record("no first hello: \(remote.state): \(remote.lastRefusalText)")
            await finish(remote, pid: nil)
            return
        }
        _ = await remote.request(CefRemoteMessage(CefRemote.Op.debugHangExit))
        // The service is exiting and its main thread is blocked: it will never send `browser.closed`.
        let started = ProcessInfo.processInfo.systemUptime
        await remote.closeBrowser(id)
        let took = ProcessInfo.processInfo.systemUptime - started
        #expect(took < 9, "the close must end by the timeout or the connection dropping, not wait for an event that never comes (\(took) s)")
        #expect(remote.browserCount == 0)
        let told = handle.endedCount + handle.events.count(where: { $0 == CefRemote.Event.browserClosed })
        #expect(told >= 1, "the page hears that its browser is gone")
        await finish(remote, pid: pid)
    }

    /// A request the service refuses because it has begun to leave (#122's `isHost`) is asked again on the replacement, once. The
    /// window in which a leaving service still answers is about half a second wide (a context makes the exit wait for the cookie
    /// flush), so the probe asks every 50 ms until one is refused: the refusal is then not the answer the caller gets.
    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aRequestRefusedBecauseTheServiceIsLeavingIsAskedAgainOnTheReplacementAndIsServedThere() async throws {
        let (_, root) = try #require(realRemote())
        let remote = ChromiumRemote(
            sink: ChromiumFrameSink(), root: { root }, linger: 1, helloTimeout: Self.realHelloTimeout,
            clock: { ProcessInfo.processInfo.systemUptime }, latch: ChromiumOOP.Latch(), isEnabled: { true }
        )
        _ = remote.connect()
        guard await waitUntil(40, { remote.isRunning }), case let .running(first) = remote.state else {
            Issue.record("no first hello: \(remote.state): \(remote.lastRefusalText)")
            await finish(remote, pid: nil)
            return
        }
        // Every probe is a new context, which is also what makes the exit wait half a second for the cookie stores. A window that
        // is missed (the service left between two probes) starts the next instance, and the probe goes on there.
        var served = false
        let deadline = ContinuousClock.now + .seconds(45)
        while remote.leavingRetries == 0, ContinuousClock.now < deadline {
            served = await remote.ensureContext(id: UUID(), cacheDirectory: root.appending(path: "profiles/\(UUID().uuidString)", directoryHint: .isDirectory))
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(remote.leavingRetries == 1, "the probe was refused as leaving once and asked again once")
        #expect(served, "the request that was refused is served by the replacement (state \(remote.state))")
        #expect(remote.helloCount >= 2, "a replacement was asked for")
        guard case let .running(second) = remote.state else {
            Issue.record("the replacement is not running: \(remote.state)")
            await finish(remote, pid: nil)
            return
        }
        #expect(second != first)
        await finish(remote, pid: second)
    }

    /// The only test that touches the process's own latch (the others use latches of their own): it decides out of process for
    /// the rest of the host, which is why this suite runs in invocations with no in-process Chromium suite. No service is
    /// launched: the latch and the refusal are what is tested.
    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func theProcessLatchesOutOfProcessAndThenRefusesAnInProcessStart() {
        #if DEBUG
        ChromiumOOP.testOverride = true
        #expect(ChromiumOOP.isEnabled, "a test host with the service in the app and the override on")
        // The first Chromium start decides. It refuses here, before it makes a folder or loads CEF.
        #expect(throws: ChromiumError.self) { try ChromiumRuntime.shared.ensureInitialized() }
        #expect(ChromiumOOP.latch.mode == .outOfProcess)
        #expect(!ChromiumRuntime.shared.isInitialized, "CEF was never started in this process")
        // Whatever is asked afterwards, the decision stays (and no in-process start is attempted from here on).
        ChromiumOOP.testOverride = false
        #expect(ChromiumOOP.resolveMode() == .outOfProcess)
        ChromiumOOP.testOverride = nil
        #endif
    }
}
