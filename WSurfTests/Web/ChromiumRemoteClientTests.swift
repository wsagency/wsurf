// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Darwin
import Foundation
import IOSurface
import os
import QuartzCore
import Testing
import XPC

@testable import CefKit
@testable import WSurf

/// D4-5: WSurf's client of the Chromium service (`ChromiumRemote`) and the process's choice between the service and in-process
/// Chromium (`ChromiumOOP`).
///
/// The first group needs no service: the guard's truth table, the latch (with latches of its own, so no CEF and no global state
/// is touched), the hello's switch allowlist and log path, the frames connection's decoding, and the death accounting, driven by
/// feeding the client the events a connection would deliver (its connection goes to a service name that does not exist, so
/// nothing launches; a test never yields to the main queue while it holds such a client, except where it says so).
///
/// The second group (gated per test on `ChromiumServiceBundle.isPresent`) runs against the real service of the OOP lane
/// (`Tools/run-chromium-oop-tests.sh ChromiumRemoteClientTests`). launchd starts a service no sooner than 10 s after the spawn of
/// the one before it, so each of these tests may wait that long for its first hello. They run in an invocation that contains no
/// in-process Chromium suite: the last of them latches the process out of process.
@MainActor
@Suite(.serialized)
struct ChromiumRemoteClientTests {
    // MARK: Helpers

    private static let noSuchService = "io.wsagency.wsurf.test.no-such-chromium-service"

    private final class FakeNow {
        var now: TimeInterval = 1000
    }

    @MainActor
    private final class Handle: ChromiumRemoteBrowserHandle {
        var events: [String] = []
        var endedCount = 0
        var allowsNavigation = true

        func remoteEvent(_ message: CefRemoteMessage) {
            events.append(message.op)
        }

        func remoteServiceEnded() {
            endedCount += 1
        }

        func remoteAllowsNavigation(to url: String) -> Bool {
            allowsNavigation
        }
    }

    /// A client with a latch of its own that is willing. `serviceName` is one that does not exist, unless a gated test passes the
    /// real one. The root is a fresh temporary folder, so nothing outside is read or written.
    private func makeRemote(
        serviceName: String = noSuchService,
        clock: FakeNow = FakeNow(),
        helloTimeout: TimeInterval = ChromiumRemote.defaultHelloTimeout,
        latch: ChromiumOOP.Latch = ChromiumOOP.Latch(),
        isEnabled: Bool = true,
        root: URL? = nil
    ) -> ChromiumRemote {
        let directory = root ?? FileManager.default.temporaryDirectory.appending(path: "wsurf-d4-client-\(UUID().uuidString)", directoryHint: .isDirectory)
        return ChromiumRemote(
            serviceName: serviceName, sink: ChromiumFrameSink(), root: { directory }, helloTimeout: helloTimeout,
            clock: { clock.now }, latch: latch, isEnabled: { isEnabled }
        )
    }

    private func waitUntil(_ seconds: TimeInterval, _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return true
    }

    private static func makeSurface() throws -> IOSurface {
        try #require(IOSurface(properties: [
            .width: 16, .height: 16, .bytesPerElement: 4, .pixelFormat: 0x4247_5241,  // 'BGRA'
        ]))
    }

    // MARK: The guard

    #if DEBUG
    @Test
    func theGuardIsOffUnlessAskedForInATestHostOrAStagedRunWithTheServicePresent() {
        typealias Guard = ChromiumOOP
        // Asked for by the environment, but this is neither a test host nor a staged run: a real profile would lose every
        // session to the service's mock keychain.
        #expect(!Guard.isAllowed(request: "1", override: nil, isTestHost: false, isStaged: false, servicePresent: true))
        #expect(!Guard.isAllowed(request: "1", override: true, isTestHost: false, isStaged: false, servicePresent: true))
        // A test host or a staged run may, with the service in the app.
        #expect(Guard.isAllowed(request: "1", override: nil, isTestHost: true, isStaged: false, servicePresent: true))
        #expect(Guard.isAllowed(request: "1", override: nil, isTestHost: false, isStaged: true, servicePresent: true))
        #expect(!Guard.isAllowed(request: "1", override: nil, isTestHost: true, isStaged: true, servicePresent: false))
        // Not asked for.
        #expect(!Guard.isAllowed(request: nil, override: nil, isTestHost: true, isStaged: true, servicePresent: true))
        #expect(!Guard.isAllowed(request: "", override: nil, isTestHost: true, isStaged: true, servicePresent: true))
        #expect(!Guard.isAllowed(request: "0", override: nil, isTestHost: true, isStaged: true, servicePresent: true))
        // A test's override wins over the environment, both ways, and never gets around the rest of the guard.
        #expect(Guard.isAllowed(request: nil, override: true, isTestHost: true, isStaged: false, servicePresent: true))
        #expect(!Guard.isAllowed(request: "1", override: false, isTestHost: true, isStaged: false, servicePresent: true))
        #expect(!Guard.isAllowed(request: nil, override: true, isTestHost: false, isStaged: false, servicePresent: true))
    }
    #endif

    @Test
    func theEnvironmentValueIsOffWhenEmptyOrZero() {
        #expect(!ChromiumOOP.isOn(nil))
        #expect(!ChromiumOOP.isOn(""))
        #expect(!ChromiumOOP.isOn("0"))
        #expect(ChromiumOOP.isOn("1"))
        #expect(ChromiumOOP.isOn("yes"))
    }

    // MARK: The latch

    @Test
    func theLatchKeepsTheFirstDecisionWhateverTheNextCallerWants() {
        let latch = ChromiumOOP.Latch()
        #expect(latch.mode == nil)
        #expect(latch.resolve(wantsOutOfProcess: { true }) == .outOfProcess)
        #expect(latch.resolve(wantsOutOfProcess: { false }) == .outOfProcess)
        #expect(latch.mode == .outOfProcess)

        let other = ChromiumOOP.Latch()
        #expect(other.resolve(wantsOutOfProcess: { false }) == .inProcess)
        #expect(other.resolve(wantsOutOfProcess: { true }) == .inProcess)
    }

    @Test
    func theLatchAsksOnlyOnce() {
        let latch = ChromiumOOP.Latch()
        var asked = 0
        for _ in 0..<5 {
            _ = latch.resolve {
                asked += 1
                return true
            }
        }
        #expect(asked == 1)
    }

    @Test
    func aProcessThatLatchedInProcessRefusesTheService() {
        let latch = ChromiumOOP.Latch()
        _ = latch.resolve { false }
        let remote = makeRemote(latch: latch, isEnabled: true)
        #expect(remote.connect() == .failed(.notEnabled))
        #expect(remote.helloCount == 0, "no connection, no hello")
        #expect(!remote.send(CefRemoteMessage(CefRemote.Op.debugStats)))
        #expect(latch.mode == .inProcess)
    }

    @Test
    func aProcessTheGuardRefusesStaysInProcessAndNeverConnects() {
        let latch = ChromiumOOP.Latch()
        let remote = makeRemote(latch: latch, isEnabled: false)
        #expect(remote.connect() == .failed(.notEnabled))
        #expect(latch.mode == .inProcess, "the first start decided")
        #expect(remote.helloCount == 0)
    }

    @Test
    func anInProcessStartIsRefusedOnceTheProcessLatchedOutOfProcess() {
        #expect(ChromiumRuntime.inProcessStartRefusal(mode: .inProcess) == nil)
        #expect(ChromiumRuntime.inProcessStartRefusal(mode: .outOfProcess) != nil)
    }

    // MARK: The hello

    @Test
    func theHelloCarriesOnlyTheAllowedSwitches() {
        let hello = ChromiumRemote.makeHello(
            root: URL(filePath: "/tmp/wsurf-r", directoryHint: .isDirectory), linger: 5,
            switches: [
                "no-sandbox": nil,
                "remote-debugging-port": "9222",
                "remote-allow-origins": "*",
                "disable-web-security": nil,
                "user-data-dir": "/tmp/x",
                "disable-backgrounding-occluded-windows": nil,
                // An allowed name with a value WSurf does not give it is not the allowed switch.
                "disable-chrome-login-prompt": "1",
            ],
            logFile: nil, stageHome: nil
        )
        #expect(hello.op == CefRemote.Op.hello)
        #expect(hello.checkProtocolVersion() == .compatible)
        #expect(hello.string(CefRemote.Key.rootPath) == "/tmp/wsurf-r")
        #expect(hello.string(CefRemote.Key.cachePath) == "/tmp/wsurf-r/Global")
        #expect(hello.double(CefRemote.Key.linger) == 5)
        #expect(hello.strings(CefRemote.Key.switches) == ["disable-backgrounding-occluded-windows": ""])
    }

    @Test
    func theHelloOfWSurfsOwnSwitchesKeepsBoth() {
        let hello = ChromiumRemote.makeHello(root: URL(filePath: "/tmp/wsurf-r", directoryHint: .isDirectory))
        #expect(Set(hello.strings(CefRemote.Key.switches).keys) == Set(ChromiumRuntime.extraCommandLineSwitches.keys))
        #expect(!hello.has(CefRemote.Key.linger), "no linger named: the service's 60 s")
    }

    @Test
    func theServicesLogGoesToDevNullUnlessItIsTheStagedRunsOwnFile() {
        let home = URL(filePath: "/tmp/wsurf-stage-home", directoryHint: .isDirectory)
        let staged = "/tmp/wsurf-stage-home/chromium-service.log"
        #expect(ChromiumRemote.validatedLogPath(staged, stageHome: home) == staged)
        // Any other file, a path that leaves the home, a relative path, none, or no staged run at all.
        #expect(ChromiumRemote.validatedLogPath("/tmp/wsurf-stage-home/other.log", stageHome: home) == "/dev/null")
        #expect(ChromiumRemote.validatedLogPath("/tmp/wsurf-stage-home/../elsewhere/chromium-service.log", stageHome: home) == "/dev/null")
        #expect(ChromiumRemote.validatedLogPath("/Users/someone/chromium-service.log", stageHome: home) == "/dev/null")
        #expect(ChromiumRemote.validatedLogPath("chromium-service.log", stageHome: home) == "/dev/null")
        #expect(ChromiumRemote.validatedLogPath(nil, stageHome: home) == "/dev/null")
        #expect(ChromiumRemote.validatedLogPath(staged, stageHome: nil) == "/dev/null")
        let hello = ChromiumRemote.makeHello(root: home, logFile: "/etc/hosts", stageHome: home)
        #expect(hello.string(CefRemote.Key.logFile) == "/dev/null")
        let accepted = ChromiumRemote.makeHello(root: home, logFile: staged, stageHome: home)
        #expect(accepted.string(CefRemote.Key.logFile) == staged)
    }

    @Test
    func aRefusalWithNeitherAPidNorAVersionIsALeavingServicesAndStaysUnanswered() {
        let leaving = CefRemoteMessage("reply")
        leaving.set(CefRemote.Key.success, false)
        leaving.set(CefRemote.Key.error, "The Chromium service is leaving.")
        #expect(ChromiumRemote.isLeavingRefusal(leaving))

        let mismatch = CefRemoteMessage("reply")
        mismatch.setRefusal(.mismatch(theirs: 7))
        #expect(!ChromiumRemote.isLeavingRefusal(mismatch))
        #expect(ChromiumRemote.failure(forRefusedHello: mismatch, ourVersion: 7) == .protocolMismatch(service: CefRemote.protocolVersion))

        let cefFailed = CefRemoteMessage("reply")
        cefFailed.set(CefRemote.Key.success, false)
        cefFailed.set(CefRemote.Key.pid, 99)
        cefFailed.set(CefRemote.Key.protocolVersion, CefRemote.protocolVersion)
        #expect(!ChromiumRemote.isLeavingRefusal(cefFailed))
        #expect(ChromiumRemote.failure(forRefusedHello: cefFailed, ourVersion: CefRemote.protocolVersion) == .cefStartFailed)

        let ok = CefRemoteMessage("reply")
        ok.set(CefRemote.Key.success, true)
        #expect(!ChromiumRemote.isLeavingRefusal(ok))
    }

    // MARK: Frames

    @Test
    func aFrameEventOnTheFramesConnectionReachesTheSinkAndAPopupEventMovesThePopup() throws {
        let sink = ChromiumFrameSink()
        let page = CALayer()
        page.frame = CGRect(x: 0, y: 0, width: 400, height: 300)
        sink.register(browser: 5, pageLayer: page)
        let surface = try Self.makeSurface()

        let frame = CefRemoteMessage(CefRemote.Event.frame, browser: 5)
        xpc_dictionary_set_value(frame.object, CefRemote.Key.surface, IOSurfaceCreateXPCObject(surface))
        let popupFrame = CefRemoteMessage(CefRemote.Event.frame, browser: 5)
        popupFrame.set(CefRemote.Key.flag, true)
        xpc_dictionary_set_value(popupFrame.object, CefRemote.Key.surface, IOSurfaceCreateXPCObject(surface))
        let popup = CefRemoteMessage(CefRemote.Event.popup, browser: 5)
        popup.set(CefRemote.Key.flag, true)
        popup.set(CefRemote.Key.originX, 10.0)
        popup.set(CefRemote.Key.originY, 20.0)
        popup.set(CefRemote.Key.width, 100.0)
        popup.set(CefRemote.Key.height, 50.0)
        let unknown = CefRemoteMessage("nothing.we.know", browser: 5)
        let strayFrame = CefRemoteMessage(CefRemote.Event.frame, browser: 99)
        xpc_dictionary_set_value(strayFrame.object, CefRemote.Key.surface, IOSurfaceCreateXPCObject(surface))
        let noSurface = CefRemoteMessage(CefRemote.Event.frame, browser: 5)

        sink.framesQueue.sync {
            for message in [frame, popupFrame, popup, unknown, strayFrame, noSurface] {
                ChromiumRemote.deliverFrame(message.object, to: sink)
            }
        }
        #expect(sink.framesShown == 1)
        #expect(sink.popupFramesShown == 1)
        #expect(sink.framesDropped == 1, "a frame for a browser nobody registered")
        #expect((page.contents as? IOSurface)?.surfaceID == surface.surfaceID)
        let layer = try #require(sink.popupLayer(for: 5))
        #expect(!layer.isHidden)
        // CEF's rectangle has a top-left origin and this page layer is not flipped: 300 - (20 + 50) = 230.
        #expect(layer.frame == CGRect(x: 10, y: 230, width: 100, height: 50))
        sink.unregister(browser: 5)
    }

    // MARK: Deaths, relaunch and the crash loop (no service)

    @Test
    func aServiceThatDiesWithAHelloPendingIsRelaunchedAtOnceAndTheStateSaysSo() {
        let remote = makeRemote()
        defer { remote.disconnect() }
        #expect(remote.connect() == .starting)
        #expect(remote.helloCount == 1)
        remote.receive(.interrupted, generation: remote.generation)
        #expect(remote.state == .relaunching, "the replacement is being waited for, which is not an error")
        #expect(remote.helloCount == 2, "the hello went out at once, not at the next message")
        #expect(remote.interruptions == 1)
    }

    @Test
    func theHelloOfAReplacementWaitsLongEnoughForLaunchdsTenSecondThrottle() {
        // launchd starts a service no sooner than 10 s after the spawn of the one that died, so after a young death the hello
        // of the replacement is answered about 10 s later, not at once.
        #expect(ChromiumRemote.defaultHelloTimeout >= 12)
        let remote = makeRemote()
        defer { remote.disconnect() }
        #expect(remote.connect() == .starting)
    }

    @Test
    func threeYoungDeathsInThirtySecondsEndInACrashLoopAndNoFourthLaunch() {
        let clock = FakeNow()
        let remote = makeRemote(clock: clock)
        defer { remote.disconnect() }
        var seen: [ChromiumRemote.ServiceState] = []
        remote.onStateChange = { seen.append($0) }
        remote.connect()
        for second in [0.0, 10.0, 20.0] {
            clock.now = 1000 + second
            remote.receive(.interrupted, generation: remote.generation)
        }
        #expect(remote.state == .crashLooping)
        #expect(remote.helloCount == 3, "the third death is the cap: no fourth launch")
        #expect(seen.contains(.relaunching))
        #expect(seen.last == .crashLooping)
        // Nothing relaunches it by itself, not even a message.
        #expect(!remote.send(CefRemoteMessage(CefRemote.Op.debugStats)))
        #expect(remote.helloCount == 3)
        // A late end after the cap does not undo the crash state.
        remote.receive(.interrupted, generation: remote.generation)
        #expect(remote.state == .crashLooping)
    }

    @Test
    func deathsFartherApartThanTheWindowKeepRelaunching() {
        let clock = FakeNow()
        let remote = makeRemote(clock: clock)
        defer { remote.disconnect() }
        remote.connect()
        for round in 0..<5 {
            clock.now = 1000 + Double(round) * 31
            remote.receive(.interrupted, generation: remote.generation)
            #expect(remote.state == .relaunching, "death \(round + 1)")
        }
        #expect(remote.helloCount == 6)
    }

    @Test
    func aReloadAfterACrashLoopAsksForTheServiceAgainAndCountsFromZero() {
        let clock = FakeNow()
        let remote = makeRemote(clock: clock)
        defer { remote.disconnect() }
        remote.connect()
        for second in [0.0, 1.0, 2.0] {
            clock.now = 1000 + second
            remote.receive(.interrupted, generation: remote.generation)
        }
        #expect(remote.state == .crashLooping)
        remote.userReload()
        #expect(remote.state == .starting)
        #expect(remote.helloCount == 4)
        // The count started over: two more deaths still relaunch.
        clock.now = 1003
        remote.receive(.interrupted, generation: remote.generation)
        clock.now = 1004
        remote.receive(.interrupted, generation: remote.generation)
        #expect(remote.state == .relaunching)
    }

    @Test
    func aServiceThatEndsWithNothingInItIsAnIdleExitNotADeath() {
        let remote = makeRemote()
        defer { remote.disconnect() }
        for _ in 0..<10 {
            remote.receive(.interrupted, generation: remote.generation)
        }
        #expect(remote.state == .stopped)
        #expect(remote.helloCount == 0, "an idle service is not relaunched")
        // Idle exits are not counted toward the cap.
        remote.connect()
        remote.receive(.interrupted, generation: remote.generation)
        #expect(remote.state == .relaunching)
    }

    @Test
    func aBrowserInTheServiceMakesItsEndADeathAndEveryBrowserIsToldItEnded() {
        let remote = makeRemote()
        defer { remote.disconnect() }
        let first = Handle()
        let second = Handle()
        let firstID = remote.makeBrowser(first)
        let secondID = remote.makeBrowser(second)
        #expect(firstID == 1 && secondID == 2, "ids start at 1 (0 is what a message with no id reads as) and are never reused")
        remote.receive(.interrupted, generation: remote.generation)
        #expect(first.endedCount == 1)
        #expect(second.endedCount == 1)
        #expect(remote.browserCount == 0)
        #expect(remote.state == .relaunching)
        #expect(remote.helloCount == 1)
        #expect(remote.makeBrowser(Handle()) == 3)
    }

    @Test
    func anEventOfAConnectionThatWasGivenUpIsIgnored() {
        let remote = makeRemote()
        defer { remote.disconnect() }
        remote.connect()
        let stale = remote.generation
        remote.disconnect()
        #expect(remote.state == .stopped)
        remote.receive(.interrupted, generation: stale)
        remote.receive(.invalid, generation: stale)
        #expect(remote.state == .stopped)
        #expect(remote.helloCount == 1)
        #expect(remote.interruptions == 0)
    }

    @Test
    func aBrowserEventIsHandedToItsBrowserAndABrowserClosedForgetsIt() {
        let remote = makeRemote()
        defer { remote.disconnect() }
        let handle = Handle()
        let id = remote.makeBrowser(handle)
        let loadEnd = CefRemoteMessage(CefRemote.Event.loadEnd, browser: id)
        remote.receive(.message(loadEnd), generation: remote.generation)
        let stray = CefRemoteMessage(CefRemote.Event.loadEnd, browser: 77)
        remote.receive(.message(stray), generation: remote.generation)
        #expect(handle.events == [CefRemote.Event.loadEnd])
        let closed = CefRemoteMessage(CefRemote.Event.browserClosed, browser: id)
        remote.receive(.message(closed), generation: remote.generation)
        #expect(handle.events == [CefRemote.Event.loadEnd, CefRemote.Event.browserClosed])
        #expect(remote.browserCount == 0)
    }

    private final class Flag {
        var raised = false
    }

    @Test
    func aCloseSentToAServiceThatIsExitingIsAnsweredByTheConnectionDroppingNotByTheTimeout() {
        let remote = makeRemote()
        defer { remote.disconnect() }
        let handle = Handle()
        let id = remote.makeBrowser(handle)
        remote.connect()
        let generation = remote.generation
        let closed = Flag()
        // Everything here happens in one turn: nothing is delivered to the client in between, so the order is the test's own.
        remote.beginClose(id) { closed.raised = true }
        #expect(!closed.raised, "a close waits for its browser.closed, the connection ending, or the timeout")
        #expect(remote.pendingRequestCount == 2, "the hello and the close")
        // The service is leaving: it has no `browser.closed` to send. The dropped connection is the answer.
        remote.receive(.interrupted, generation: generation)
        #expect(closed.raised, "the connection dropping ended the close, not its 5 s timeout")
        #expect(handle.endedCount == 1, "the browser is told its service ended")
        #expect(remote.browserCount == 0)
        #expect(remote.pendingRequestCount == 1, "only the replacement's hello is left; the close ended once")
    }

    @Test
    func aCloseOfABrowserThatNoLongerExistsEndsAtOnce() {
        let remote = makeRemote()
        let closed = Flag()
        remote.beginClose(99) { closed.raised = true }
        #expect(closed.raised)
        #expect(remote.pendingRequestCount == 0)
    }

    @Test
    func aHelloRefusedBecauseTheServiceIsLeavingIsRelaunchedWithoutCountingTowardTheCrashLoop() {
        let remote = makeRemote()
        defer { remote.disconnect() }
        remote.connect()
        for round in 1...6 {
            remote.noteLeavingRefusal()
            remote.receive(.interrupted, generation: remote.generation)
            #expect(remote.state == .relaunching, "round \(round)")
        }
        #expect(remote.helloCount == 7, "every end got its replacement, and none counted as a death")
        // A real death after them is the first one: it relaunches too (the cap is three).
        remote.receive(.interrupted, generation: remote.generation)
        #expect(remote.state == .relaunching)
        remote.receive(.interrupted, generation: remote.generation)
        remote.receive(.interrupted, generation: remote.generation)
        #expect(remote.state == .crashLooping, "three real deaths still trip the cap")
    }

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
        // A cache directory outside the root is refused by the service, and the client does not remember it as made.
        let outside = FileManager.default.temporaryDirectory.appending(path: "wsurf-d4-outside-\(UUID().uuidString)", directoryHint: .isDirectory)
        #expect(!(await remote.ensureContext(id: UUID(), cacheDirectory: outside)))
        try? FileManager.default.removeItem(at: outside)
        await finish(remote, pid: pid)
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
