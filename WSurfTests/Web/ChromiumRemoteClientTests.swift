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
/// The second group (gated per test on `ChromiumServiceBundle.isPresent`) runs against the real service of the OOP lane; it is in
/// `ChromiumRemoteClientTests+Service.swift` (`Tools/run-chromium-oop-tests.sh ChromiumRemoteClientTests`).
@MainActor
@Suite(.serialized)
struct ChromiumRemoteClientTests {
    // MARK: Helpers

    static let noSuchService = "io.wsagency.wsurf.test.no-such-chromium-service"

    final class FakeNow {
        var now: TimeInterval = 1000
    }

    @MainActor
    final class Handle: ChromiumRemoteBrowserHandle {
        var events: [String] = []
        var endedCount = 0
        var allowsNavigation = true
        /// What a page proxy might do when its browser is gone: the test's stand-in for it runs inside the callback.
        var onEnded: (() -> Void)?

        func remoteEvent(_ message: CefRemoteMessage) {
            events.append(message.op)
        }

        func remoteServiceEnded() {
            endedCount += 1
            onEnded?()
        }

        func remoteAllowsNavigation(to url: String) -> Bool {
            allowsNavigation
        }
    }

    /// A client with a latch of its own that is willing. `serviceName` is one that does not exist, unless a gated test passes the
    /// real one. The root is a fresh temporary folder, so nothing outside is read or written.
    func makeRemote(
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

    func waitUntil(_ seconds: TimeInterval, _ condition: () -> Bool) async -> Bool {
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
    func onlyTheServicesLeavingTextRefusesARequestAsLeaving() {
        #expect(ChromiumRemote.isServiceLeavingReply(Self.reply(success: false, error: CefRemote.leavingError)))
        // Other refusals have the same shape (no pid, no version) and are answers: they are not asked again.
        for text in ["not the host", "no such browser", "unknown op", "the cache path must be inside the root cache path", ""] {
            #expect(!ChromiumRemote.isServiceLeavingReply(Self.reply(success: false, error: text)), "\(text)")
        }
        #expect(!ChromiumRemote.isServiceLeavingReply(Self.reply(success: false)))
        #expect(!ChromiumRemote.isServiceLeavingReply(Self.reply(success: true, error: CefRemote.leavingError)))
    }

    private static func reply(success: Bool, error: String? = nil) -> CefRemoteMessage {
        let message = CefRemoteMessage("reply")
        message.set(CefRemote.Key.success, success)
        if let error {
            message.set(CefRemote.Key.error, error)
        }
        return message
    }

    /// Drives one request through a refusal as leaving, the old instance's end, and the retry, with no service: the table's ids are
    /// the order of the sends (the hello is 1, the request 2, the replacement's hello 3, the retry 4).
    private func requestRefusedAsLeaving(secondReply: CefRemoteMessage) async -> (outcome: CefRemoteReply<CefRemoteMessage>, instance: Int, remote: ChromiumRemote) {
        let remote = makeRemote()
        _ = remote.connect()
        let task = Task { await remote.requestTracked(CefRemoteMessage(CefRemote.Op.debugStats)) }
        #expect(await waitUntil(2) { remote.pendingRequestCount == 2 }, "the hello and the request are waiting")
        #expect(remote.requests.reply(2, Self.reply(success: false, error: CefRemote.leavingError)))
        #expect(await waitUntil(2) { remote.leavingRetries == 1 }, "the refusal is not the answer: the request waits for the old instance to end")
        #expect(remote.interruptions == 0, "nothing is asked again while the old instance is still there")
        remote.receive(.interrupted, generation: remote.generation)
        #expect(await waitUntil(2) { remote.helloCount == 2 && remote.pendingRequestCount == 2 }, "the replacement's hello and the retry")
        #expect(remote.requests.reply(4, secondReply))
        let answered = await task.value
        return (answered.reply, answered.instance, remote)
    }

    @Test
    func aRequestRefusedBecauseTheServiceIsLeavingIsAskedAgainOnceItHasEndedAndGetsTheSecondAnswer() async {
        let (outcome, instance, remote) = await requestRefusedAsLeaving(secondReply: Self.reply(success: true))
        defer { remote.disconnect() }
        guard case let .value(answer) = outcome else {
            Issue.record("the retry's reply was not delivered: \(outcome)")
            return
        }
        #expect(answer.bool(CefRemote.Key.success))
        #expect(instance == 1, "answered by the instance after the one that refused")
        #expect(remote.leavingRetries == 1)
        #expect(remote.state == .relaunching, "a leaving service that ends is relaunched, and the state says so")
        #expect(remote.helloCount == 2, "one replacement, not one per attempt")
    }

    @Test
    func aSecondRefusalAsLeavingIsTheAnswerAndIsNotAskedAgain() async {
        let (outcome, _, remote) = await requestRefusedAsLeaving(secondReply: Self.reply(success: false, error: CefRemote.leavingError))
        defer { remote.disconnect() }
        guard case let .value(answer) = outcome else {
            Issue.record("the retry's reply was not delivered: \(outcome)")
            return
        }
        #expect(ChromiumRemote.isServiceLeavingReply(answer))
        #expect(remote.leavingRetries == 1, "once only")
        #expect(remote.pendingRequestCount == 1, "only the replacement's hello is left: no third send")
    }

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

    @Test
    func aBrowserThatSendsFromItsEndedCallbackDuringTheThirdDeathDoesNotLaunchAFourthServiceAndTheStateStaysCrashLooping() {
        let clock = FakeNow()
        let remote = makeRemote(clock: clock)
        let handle = Handle()
        // A page proxy that makes its browser again and talks to the service as soon as it hears the old one is gone.
        handle.onEnded = { [unowned remote, unowned handle] in
            _ = remote.makeBrowser(handle)
            _ = remote.send(CefRemoteMessage(CefRemote.Op.debugStats))
        }
        defer {
            handle.onEnded = nil
            remote.disconnect()
        }
        _ = remote.makeBrowser(handle)
        remote.connect()
        for second in [0.0, 10.0, 20.0] {
            clock.now = 1000 + second
            remote.receive(.interrupted, generation: remote.generation)
        }
        #expect(handle.endedCount == 3)
        #expect(remote.helloCount == 3, "the third death is the cap: the callback's message launches nothing")
        #expect(remote.state == .crashLooping)
    }

    @Test
    func aBrowserThatSendsFromItsEndedCallbackDuringARelaunchIsFoldedIntoTheOneReplacementHello() {
        let remote = makeRemote()
        let handle = Handle()
        handle.onEnded = { [unowned remote] in
            _ = remote.send(CefRemoteMessage(CefRemote.Op.debugStats))
        }
        defer {
            handle.onEnded = nil
            remote.disconnect()
        }
        _ = remote.makeBrowser(handle)
        remote.connect()
        remote.receive(.interrupted, generation: remote.generation)
        #expect(remote.state == .relaunching)
        #expect(remote.helloCount == 2, "one replacement hello, not one for the callback and one for the relaunch")
        #expect(remote.pendingRequestCount == 1, "the replacement's hello, which the callback's request did not interrupt")
    }

    @Test
    func aBrowserThatSendsWhileDisconnectIsTellingItDoesNotBringTheConnectionBack() {
        let remote = makeRemote()
        let handle = Handle()
        handle.onEnded = { [unowned remote] in
            _ = remote.send(CefRemoteMessage(CefRemote.Op.debugStats))
        }
        defer { handle.onEnded = nil }
        _ = remote.makeBrowser(handle)
        remote.connect()
        remote.disconnect()
        #expect(handle.endedCount == 1)
        #expect(remote.state == .stopped)
        #expect(remote.helloCount == 1, "no new hello from the callback")
        #expect(remote.pendingRequestCount == 0)
    }

    @Test
    func aHelloAnswerThatArrivesInACrashLoopOrAfterARefusalIsIgnored() {
        let clock = FakeNow()
        let remote = makeRemote(clock: clock)
        defer { remote.disconnect() }
        remote.connect()
        for second in [0.0, 1.0, 2.0] {
            clock.now = 1000 + second
            remote.receive(.interrupted, generation: remote.generation)
        }
        #expect(remote.state == .crashLooping)
        let answer = CefRemoteMessage("reply")
        answer.set(CefRemote.Key.success, true)
        answer.set(CefRemote.Key.pid, 4242)
        remote.helloEnded(.value(answer), sentAt: clock.now, generation: remote.generation)
        #expect(remote.state == .crashLooping, "an instance launched too late is not run on")
        #expect(remote.servicePID == 0)
        #expect(!remote.hasFramesConnection)
    }

    @Test
    func aPidOutsideInt32IsClampedNotATrap() {
        let remote = makeRemote()
        defer { remote.disconnect() }
        remote.connect()
        let answer = CefRemoteMessage("reply")
        answer.set(CefRemote.Key.success, true)
        answer.set(CefRemote.Key.pid, Int64.max)
        remote.helloEnded(.value(answer), sentAt: 1000, generation: remote.generation)
        #expect(remote.servicePID == Int32.max)
    }

    @Test
    func aRequestWaitsForTheHelloTooUnlessTheServiceIsUp() {
        typealias Remote = ChromiumRemote
        #expect(Remote.effectiveTimeout(nil, defaultTimeout: 5, isRunning: true, helloTimeout: 15) == 5)
        #expect(Remote.effectiveTimeout(1, defaultTimeout: 5, isRunning: true, helloTimeout: 15) == 1)
        // Starting or relaunching: the request is served after the hello, which launchd may hold back for about 10 s.
        #expect(Remote.effectiveTimeout(nil, defaultTimeout: 5, isRunning: false, helloTimeout: 15) == 20)
        #expect(Remote.effectiveTimeout(1, defaultTimeout: 5, isRunning: false, helloTimeout: 15) == 16)
        // 5 s is not enough for a relaunch after a young death (about 10 s); the allowance covers it.
        #expect(Remote.effectiveTimeout(nil, defaultTimeout: 5, isRunning: false, helloTimeout: Remote.defaultHelloTimeout) > 10)
    }

    @Test
    func aCacheDirectoryOutsideTheRootIsRefusedBeforeAnythingIsMade() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "wsurf-d4-client-\(UUID().uuidString)", directoryHint: .isDirectory)
        let sibling = FileManager.default.temporaryDirectory.appending(path: "wsurf-d4-outside-\(UUID().uuidString)", directoryHint: .isDirectory)
        let remote = makeRemote(root: root)
        defer {
            remote.disconnect()
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sibling)
        }
        // A folder next to the root, one that leaves it by `..`, one whose name only starts like the root's, and one through a
        // link inside the root that points out.
        let canonicalRoot = try ChromiumRemote.prepareRoot(root)
        let twin = URL(filePath: canonicalRoot.path + "-twin", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: twin) }
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "link"), withDestinationURL: sibling)
        let escapes = [
            sibling.appending(path: "a", directoryHint: .isDirectory),
            root.appending(path: "../wsurf-d4-escape-\(UUID().uuidString)", directoryHint: .isDirectory),
            twin.appending(path: "a", directoryHint: .isDirectory),
            root.appending(path: "link/child", directoryHint: .isDirectory),
        ]
        for path in escapes {
            #expect(!(await remote.ensureContext(id: UUID(), cacheDirectory: path)), "\(path.path)")
        }
        #expect(!FileManager.default.fileExists(atPath: sibling.appending(path: "a").path))
        #expect(!FileManager.default.fileExists(atPath: sibling.appending(path: "child").path), "nothing was made through the link")
        #expect(!FileManager.default.fileExists(atPath: twin.path))
        #expect(remote.helloCount == 0, "refused on the client: no service was asked, none was launched")
    }

    @Test
    func theCanonicalPathOfAFolderThatDoesNotExistYetKeepsTheAliasOutAndMakesNothing() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "wsurf-d4-client-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: root) }
        let canonicalRoot = try ChromiumRemote.prepareRoot(root)
        let wanted = try #require(ChromiumRemote.canonicalPath(of: root.appending(path: "Profiles/one", directoryHint: .isDirectory)))
        #expect(wanted.path == canonicalRoot.path + "/Profiles/one")
        #expect(ChromiumRemote.isInside(wanted, root: canonicalRoot))
        #expect(ChromiumRemote.isInside(canonicalRoot, root: canonicalRoot))
        #expect(!FileManager.default.fileExists(atPath: canonicalRoot.appending(path: "Profiles").path), "made nothing")
    }
}
