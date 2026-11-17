// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Darwin
import Foundation
import Testing

@testable import CefKit
@testable import WSurf

/// D4-20: the Chromium service holds the line itself. A hello that did not come from WSurf's own client (a raw XPC sender: these
/// tests) cannot loosen Chromium's switches, point its log anywhere, or start it on a root that leads through a link; the client
/// retries a hello that timed out in a relaunch, and tells a service it cannot reach from one that died.
///
/// The first group needs no service and runs in the default lane: the shared switch rules, the client's logic, the path helpers and
/// `Tools/check-service-strings.sh` on files made here. The second group (gated per test on `ChromiumServiceBundle.isPresent`,
/// `Tools/run-chromium-oop-tests.sh ChromiumServiceHardeningTests`) drives the real service over raw XPC, with a root of its own for
/// each test, and measures launchd's respawn throttle.
@Suite(.serialized)
struct ChromiumServiceHardeningTests {
    private static let helloTimeout: TimeInterval = 30

    // MARK: The shared switch rules (no service)

    @Test
    func onlyWSurfsOwnSwitchesWithTheirOwnValuesPassTheSharedRule() {
        // The wire form: a switch with no value travels as the empty string.
        #expect(CefRemoteSwitches.refused(wire: [:]).isEmpty)
        #expect(CefRemoteSwitches.refused(wire: ["disable-backgrounding-occluded-windows": "", "disable-chrome-login-prompt": ""]).isEmpty)
        let bad: [String: String] = [
            "no-sandbox": "",
            "remote-debugging-port": "9222",
            "disable-web-security": "",
            "allow-file-access-from-files": "",
            "user-data-dir": "/tmp/elsewhere",
            // An allowed name with a value WSurf does not give it is another switch.
            "disable-chrome-login-prompt": "1",
            // Names are exact: no case folding, no leading dashes.
            "Disable-Chrome-Login-Prompt": "",
            "--disable-chrome-login-prompt": "",
        ]
        #expect(CefRemoteSwitches.refused(wire: bad) == bad.keys.sorted())
        #expect(CefRemoteSwitches.refused(wire: ["no-sandbox": "", "disable-chrome-login-prompt": ""]) == ["no-sandbox"])
    }

    @Test
    func theClientsFilterAndTheServicesRefusalAgreeOnEveryRequest() {
        let requests: [[String: String?]] = [
            [:],
            ["disable-chrome-login-prompt": nil],
            ["disable-chrome-login-prompt": nil, "no-sandbox": nil],
            ["disable-chrome-login-prompt": "1"],
            ["remote-debugging-port": "9222"],
        ]
        for request in requests {
            let wire = request.mapValues { $0 ?? "" }
            let kept = CefRemoteSwitches.filter(request)
            let refusedNames = Set(CefRemoteSwitches.refused(wire: wire))
            // What the client drops is exactly what the service would refuse: a hello the client built is never refused.
            #expect(Set(request.keys).subtracting(kept.keys) == refusedNames, "\(request)")
            #expect(CefRemoteSwitches.refused(wire: kept.mapValues { $0 ?? "" }).isEmpty, "\(request)")
        }
        #expect(ChromiumRuntime.extraCommandLineSwitches == CefRemoteSwitches.allowed, "WSurf's in-process list is the shared one")
    }

    @Test
    func theLogFileMayOnlyBeTheStagedOnesNameInTheRootOrBesideIt() {
        #expect(CefRemoteSwitches.logFileCandidates(root: "/tmp/home/Chromium") == [
            "/tmp/home/Chromium/chromium-service.log", "/tmp/home/chromium-service.log",
        ])
        // The client's own rule (`validatedLogPath`) yields a path of the second kind in a staged run: its home holds the root.
        let home = URL(filePath: "/tmp/home", directoryHint: .isDirectory)
        let sent = ChromiumRemote.validatedLogPath("/tmp/home/chromium-service.log", stageHome: home)
        #expect(CefRemoteSwitches.logFileCandidates(root: "/tmp/home/Chromium").contains(sent))
    }

    // MARK: The client (no service)

    @Test @MainActor
    func aHelloThatTimesOutDuringARelaunchIsAskedOnceMoreAndThenFailsForGood() {
        let remote = ChromiumRemoteClientTests().makeRemote()
        defer { remote.disconnect() }
        remote.connect()
        remote.receive(.interrupted, generation: remote.generation)
        #expect(remote.state == .relaunching)
        #expect(remote.helloCount == 2)
        remote.helloEnded(.timedOut, sentAt: 0, generation: remote.generation)
        #expect(remote.state == .relaunching, "the replacement may only be slow: one more hello")
        #expect(remote.helloCount == 3)
        remote.helloEnded(.timedOut, sentAt: 0, generation: remote.generation)
        #expect(remote.state == .failed(.noAnswer), "a second timeout is the hard failure")
        #expect(remote.helloCount == 3, "and no third hello")
    }

    @Test @MainActor
    func aHelloThatTimesOutAtTheFirstLaunchFailsAtOnce() {
        let remote = ChromiumRemoteClientTests().makeRemote()
        defer { remote.disconnect() }
        #expect(remote.connect() == .starting)
        remote.helloEnded(.timedOut, sentAt: 0, generation: remote.generation)
        #expect(remote.state == .failed(.noAnswer))
        #expect(remote.helloCount == 1, "a service that was never up is not retried: only a relaunch is waited for")
    }

    @Test @MainActor
    func eachRelaunchGetsItsOwnRetry() {
        let remote = ChromiumRemoteClientTests().makeRemote()
        defer { remote.disconnect() }
        remote.connect()
        remote.receive(.interrupted, generation: remote.generation)
        remote.helloEnded(.timedOut, sentAt: 0, generation: remote.generation)
        #expect(remote.helloCount == 3)
        // The replacement dies too (two deaths at one instant are below the cap of three): its successor is waited for like the first.
        remote.receive(.interrupted, generation: remote.generation)
        #expect(remote.state == .relaunching)
        #expect(remote.helloCount == 4)
        remote.helloEnded(.timedOut, sentAt: 0, generation: remote.generation)
        #expect(remote.state == .relaunching, "the retry was given back with the new instance")
        #expect(remote.helloCount == 5)
    }

    @Test @MainActor
    func anInvalidConnectionBeforeTheHelloIsAnsweredIsUnreachableNotADeath() {
        let remote = ChromiumRemoteClientTests().makeRemote(invalidMeansUnreachable: true)
        defer { remote.disconnect() }
        #expect(remote.connect() == .starting)
        remote.receive(.invalid, generation: remote.generation)
        #expect(remote.state == .failed(.noAnswer))
        #expect(remote.interruptions == 0, "no death was counted")
        #expect(remote.helloCount == 1, "and nothing was relaunched")
        #expect(remote.isGivenUp, "only a person's action asks again")
    }

    @Test @MainActor
    func anInvalidConnectionDuringARelaunchIsUnreachableToo() {
        let remote = ChromiumRemoteClientTests().makeRemote(invalidMeansUnreachable: true)
        defer { remote.disconnect() }
        remote.connect()
        remote.receive(.interrupted, generation: remote.generation)
        #expect(remote.state == .relaunching)
        remote.receive(.invalid, generation: remote.generation)
        #expect(remote.state == .failed(.noAnswer))
        #expect(remote.helloCount == 2)
    }

    @Test @MainActor
    func theSeamKeepsAnInvalidConnectionADeathForTheTestsThatScriptTheirEvents() {
        // D4-5's crash-loop tests feed a client the events a connection would deliver: with the seam off an INVALID is a death, as it
        // was, so the cap is reached by counting.
        let remote = ChromiumRemoteClientTests().makeRemote(invalidMeansUnreachable: false)
        defer { remote.disconnect() }
        remote.connect()
        remote.receive(.invalid, generation: remote.generation)
        #expect(remote.state == .relaunching)
        #expect(remote.interruptions == 1)
        #expect(remote.helloCount == 2)
    }

    // MARK: Paths (no service)

    @Test
    func aDanglingSymlinkIsNotAFolderThatDoesNotExistYet() throws {
        let base = try Self.canonicalTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: base) }
        let missing = base.appending(path: "no-such-target-\(UUID().uuidString)", directoryHint: .isDirectory)
        let dangling = base.appending(path: "dangling")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: missing)
        // `fileExists` follows the link and says no: the old code appended "dangling" to the folder above and called it canonical.
        #expect(ChromiumRemote.canonicalPath(of: dangling) == nil)
        #expect(ChromiumRemote.canonicalPath(of: dangling.appending(path: "child", directoryHint: .isDirectory)) == nil)
        #expect(!FileManager.default.fileExists(atPath: missing.path), "nothing was made through the link")
        // A folder that is not there yet, and a link that leads somewhere, still resolve.
        let fresh = try #require(ChromiumRemote.canonicalPath(of: base.appending(path: "fresh/one", directoryHint: .isDirectory)))
        #expect(fresh.path == base.appending(path: "fresh/one").path)
        let target = base.appending(path: "target", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let good = base.appending(path: "good")
        try FileManager.default.createSymbolicLink(at: good, withDestinationURL: target)
        let resolved = try #require(ChromiumRemote.canonicalPath(of: good.appending(path: "child", directoryHint: .isDirectory)))
        #expect(resolved.path == target.appending(path: "child").path)
    }

    // MARK: The strings check (no service)

    private struct ScriptRun {
        let status: Int32
        let output: String
    }

    private static var repositoryRoot: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    private static func runChecker(_ arguments: [String]) throws -> ScriptRun {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/bash")
        process.arguments = [repositoryRoot.appending(path: "Tools/check-service-strings.sh").path] + arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return ScriptRun(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    private static func canonicalTemporaryFolder() throws -> URL {
        let made = FileManager.default.temporaryDirectory.appending(path: "wsurf-d4-hardening-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
        let canonical = try #require(realpath(made.path, nil))
        defer { free(canonical) }
        return URL(filePath: String(cString: canonical), directoryHint: .isDirectory)
    }

    private static func write(_ lines: [String], to url: URL) throws {
        try Data((["a service that has this text in it"] + lines + ["and some more text, as a binary has"]).joined(separator: "\n").utf8).write(to: url)
    }

    @Test
    func theStringsCheckPassesAServiceWithoutDebugOpsAndFailsOneWithAnyOfThem() throws {
        let folder = try Self.canonicalTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clean = folder.appending(path: "clean")
        try Self.write(["debug and abort are plain words here", "browser create started", "history read"], to: clean)
        let clear = try Self.runChecker([clean.path])
        #expect(clear.status == 0, "\(clear.output)")

        // Every token the check names fails it on its own: the ones the task lists, and the ops of the protocol.
        let tokens = [
            "consumeExitOnHello", "hangExit", "create FAILED (debug)", "create held (debug)", "closeFirst", "cpuPaint",
            "smallSourceCache", "debug.holdHistory", "debug.abort", "debug.stats", "debug.exitOnHello", "debug.stubBrowser", "debug.askHost",
        ]
        for token in tokens {
            let file = folder.appending(path: "with-\(token.replacingOccurrences(of: " ", with: "_"))")
            try Self.write([token], to: file)
            let run = try Self.runChecker([file.path])
            #expect(run.status == 1, "\(token): \(run.output)")
            #expect(run.output.contains(token), "the failure names \(token): \(run.output)")
        }
        let missing = try Self.runChecker([folder.appending(path: "no-such-file").path])
        #expect(missing.status == 2)
    }

    @Test
    func theStringsCheckProvesItSeesTheDebugOpsOfAServiceThatHasThem() throws {
        let folder = try Self.canonicalTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let debug = folder.appending(path: "debug")
        try Self.write(["create FAILED (debug)", "create held (debug)", "debug.abort"], to: debug)
        #expect(try Self.runChecker(["--expect-debug", debug.path]).status == 0)
        // A file with nothing in it would pass the plain check for the wrong reason: the other mode refuses it.
        let empty = folder.appending(path: "empty")
        try Self.write([], to: empty)
        #expect(try Self.runChecker([empty.path]).status == 0)
        #expect(try Self.runChecker(["--expect-debug", empty.path]).status == 1)
    }

    // MARK: Raw XPC: the service refuses what is not WSurf's (gated)

    /// A hello for `client`'s root with the given switches and log file, as WSurf's client would build it but for what is asked.
    private static func hello(
        _ client: ChromiumServiceClient, root: String? = nil, switches: [String: String?]? = nil, logFile: String? = nil
    ) -> CefRemoteMessage {
        let hello = CefRemoteMessage.hello()
        hello.set(CefRemote.Key.rootPath, root ?? client.root.path)
        hello.set(CefRemote.Key.cachePath, (root.map { URL(filePath: $0) } ?? client.root).appending(path: "default").path)
        if let switches {
            hello.set(CefRemote.Key.switches, strings: switches)
        }
        if let logFile {
            hello.set(CefRemote.Key.logFile, logFile)
        }
        return hello
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aHelloWithASwitchThatIsNotWSurfsIsRefusedBeforeCEFStarts() throws {
        let client = try ChromiumServiceClient()
        defer { client.finish(expectExit: false) }
        // The first one is harmless on purpose: a service that wrongly took it would start Chromium with it, and the cases after it
        // (no sandbox, a debugging port) would then find CEF already up and start nothing.
        let refused: [(String, [String: String?])] = [
            ("a switch WSurf does not have", ["wsurf-d4-20-not-a-switch": nil]),
            ("no-sandbox", ["no-sandbox": nil]),
            ("a debugging port", ["remote-debugging-port": "9222"]),
            ("web security off", ["disable-web-security": nil]),
            ("file access", ["allow-file-access-from-files": nil]),
            ("a WSurf switch with another value", ["disable-chrome-login-prompt": "1"]),
            ("WSurf's switches and one more", ["disable-chrome-login-prompt": nil, "user-data-dir": "/tmp/elsewhere"]),
        ]
        for (name, switches) in refused {
            let reply = try client.call(Self.hello(client, switches: switches), timeout: Self.helloTimeout)
            #expect(!reply.bool(CefRemote.Key.success), "\(name) must be refused")
            #expect(reply.string(CefRemote.Key.error).contains("switch"), "\(name): \(reply.string(CefRemote.Key.error))")
            let stats = try client.stats()
            #expect(!stats.bool(CefRemote.Key.started), "\(name): a refused hello starts no CEF")
        }
        // Not a blanket refusal: WSurf's own two switches, which the client sends, start Chromium.
        let own = Self.hello(client, switches: ["disable-backgrounding-occluded-windows": nil, "disable-chrome-login-prompt": nil])
        let reply = try client.call(own, timeout: Self.helloTimeout)
        #expect(reply.bool(CefRemote.Key.success), "\(reply.string(CefRemote.Key.error))")
        #expect(try client.stats().bool(CefRemote.Key.started))
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aLogFileThatIsNotTheStagedRunsOwnIsRefusedBeforeCEFStarts() throws {
        let client = try ChromiumServiceClient()
        defer { client.finish(expectExit: false) }
        let outside = FileManager.default.temporaryDirectory.appending(path: "wsurf-d4-log-\(UUID().uuidString).log")
        let target = FileManager.default.temporaryDirectory.appending(path: "wsurf-d4-log-target-\(UUID().uuidString)")
        let unrelated = FileManager.default.temporaryDirectory.appending(path: "wsurf-d4-log-folder-\(UUID().uuidString)", directoryHint: .isDirectory)
        let link = client.root.appending(path: "chromium-service.log")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        defer {
            try? FileManager.default.removeItem(at: outside)
            try? FileManager.default.removeItem(at: target)
            try? FileManager.default.removeItem(at: unrelated)
        }
        let refused: [(String, String)] = [
            // First, and harmless if wrongly taken (the folder is not there, so CEF writes nothing): the right name in a folder that
            // is neither the root nor beside it, so that only the place refuses it.
            ("the right name in an unrelated folder", unrelated.appending(path: "chromium-service.log").path),
            ("a file somewhere else", outside.path),
            ("another name in the root", client.root.appending(path: "other.log").path),
            ("a relative path", "chromium-service.log"),
            // Built as text: `URL.appending` may fold the `..` away, which would leave the (allowed) file beside the root.
            ("a path with .. in it", client.root.path + "/../chromium-service.log"),
            ("a folder two levels up", client.root.deletingLastPathComponent().deletingLastPathComponent().appending(path: "chromium-service.log").path),
            ("the right name, as a link to somewhere else", link.path),
            ("a system file", "/etc/hosts"),
        ]
        for (name, path) in refused {
            let reply = try client.call(Self.hello(client, logFile: path), timeout: Self.helloTimeout)
            #expect(!reply.bool(CefRemote.Key.success), "\(name) (\(path)) must be refused")
            #expect(reply.string(CefRemote.Key.error).contains("log"), "\(name): \(reply.string(CefRemote.Key.error))")
            #expect(!(try client.stats()).bool(CefRemote.Key.started), "\(name): a refused hello starts no CEF")
        }
        #expect(!FileManager.default.fileExists(atPath: target.path), "nothing was written through the link")
        #expect(!FileManager.default.fileExists(atPath: outside.path))
        #expect(!FileManager.default.fileExists(atPath: unrelated.path), "no folder was made for a refused log file")
        // The staged run's own file, in the root, is taken (here it is a link, which the loop refused: a plain one is made now).
        try FileManager.default.removeItem(at: link)
        let reply = try client.call(Self.hello(client, logFile: link.path), timeout: Self.helloTimeout)
        #expect(reply.bool(CefRemote.Key.success), "\(reply.string(CefRemote.Key.error))")
        #expect(try client.stats().string(CefRemote.Key.logFile) == link.path)
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aRootThatLeadsThroughADanglingSymlinkIsRefusedAndStartsNothing() throws {
        let client = try ChromiumServiceClient()
        defer { client.finish(expectExit: false) }
        let missing = FileManager.default.temporaryDirectory.appending(path: "wsurf-d4-dangling-\(UUID().uuidString)", directoryHint: .isDirectory)
        let dangling = client.root.appending(path: "dangling")
        try FileManager.default.createSymbolicLink(at: dangling, withDestinationURL: missing)
        defer { try? FileManager.default.removeItem(at: missing) }
        // The old check took a link that leads nowhere for a folder that is not made yet, below a canonical parent, and let it pass.
        let reply = try client.call(Self.hello(client, root: dangling.path), timeout: Self.helloTimeout)
        #expect(!reply.bool(CefRemote.Key.success), "a root through a dangling symlink must be refused")
        #expect(reply.string(CefRemote.Key.error).contains("canonical"), "\(reply.string(CefRemote.Key.error))")
        #expect(!(try client.stats()).bool(CefRemote.Key.started))
        #expect(!FileManager.default.fileExists(atPath: missing.path), "nothing was made through the link")
        // And a cache folder through one, under a good root.
        let cache = client.root.appending(path: "default", directoryHint: .isDirectory)
        let cacheLink = client.root.appending(path: "cache-link")
        try FileManager.default.createSymbolicLink(at: cacheLink, withDestinationURL: cache.appending(path: "no-such"))
        let withLink = Self.hello(client)
        withLink.set(CefRemote.Key.cachePath, cacheLink.appending(path: "profile").path)
        let refusedCache = try client.call(withLink, timeout: Self.helloTimeout)
        #expect(!refusedCache.bool(CefRemote.Key.success), "a cache path through a dangling symlink must be refused")
        #expect(!(try client.stats()).bool(CefRemote.Key.started))
        // A context's folder through one is refused too, and nothing is made there.
        #expect(try client.call(Self.hello(client), timeout: Self.helloTimeout).bool(CefRemote.Key.success))
        let context = CefRemoteMessage(CefRemote.Op.createContext)
        context.set(CefRemote.Key.context, "through-a-link")
        context.set(CefRemote.Key.cachePath, cacheLink.appending(path: "profile").path)
        #expect(!(try client.call(context)).bool(CefRemote.Key.success))
        #expect(try client.stats().int(CefRemote.Key.contexts) == 0)
        #expect(!FileManager.default.fileExists(atPath: cache.appending(path: "no-such").path), "nothing was made through the link")
    }

    // MARK: Every kind of connection (gated)

    /// The hellos of the connections that are not the control one. They share one path in the service (`attachSideConnection`), so a
    /// rule held there holds for each; this list is what the tests below walk, so a kind added to it is held to every rule at once.
    /// The input connection is among them from protocol v3 (D4-12): its traffic is routed by the same attach.
    private static let sideHellos = [CefRemote.Op.inputHello, CefRemote.Op.framesHello, CefRemote.Op.axHello]

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func noKindOfSideConnectionIsAttachedBeforeAHostThatGotOkOrFromTheControlConnection() throws {
        let client = try ChromiumServiceClient()
        defer { client.finish(expectExit: false) }
        // `finish` can only end a service whose pid the client has seen, and a raw `call` of a hello does not record it.
        _ = try client.stats()
        func attempt(_ op: String) throws -> CefRemoteMessage {
            let side = try ChromiumServiceClient(root: client.root)
            defer { side.close() }
            return try side.call(CefRemoteMessage(op))
        }
        // 1. No hello yet.
        for op in Self.sideHellos {
            let reply = try attempt(op)
            #expect(!reply.bool(CefRemote.Key.success), "\(op) before any hello")
            #expect(reply.string(CefRemote.Key.error) == "no host has said hello", "\(op): \(reply.string(CefRemote.Key.error))")
        }
        // 2. A hello the service refused (a switch that is not WSurf's) leaves a control connection and no CEF: still no host.
        let refused = try client.call(Self.hello(client, switches: ["wsurf-d4-20-not-a-switch": nil]), timeout: Self.helloTimeout)
        #expect(!refused.bool(CefRemote.Key.success))
        for op in Self.sideHellos {
            #expect(!(try attempt(op)).bool(CefRemote.Key.success), "\(op) after a refused hello")
        }
        // 3. After a hello that got ok: the control connection itself may be none of them, and the host's other connections may be each.
        #expect(try client.call(Self.hello(client), timeout: Self.helloTimeout).bool(CefRemote.Key.success))
        for op in Self.sideHellos {
            let fromControl = try client.call(CefRemoteMessage(op))
            #expect(!fromControl.bool(CefRemote.Key.success), "\(op) from the control connection")
            #expect(fromControl.string(CefRemote.Key.error).contains("control connection"), "\(op): \(fromControl.string(CefRemote.Key.error))")
        }
        var attached: [ChromiumServiceClient] = []
        defer { attached.forEach { $0.close() } }
        for op in Self.sideHellos {
            let side = try ChromiumServiceClient(root: client.root)
            attached.append(side)
            let reply = try side.call(CefRemoteMessage(op))
            #expect(reply.bool(CefRemote.Key.success), "\(op) from the host's process after its hello: \(reply.string(CefRemote.Key.error))")
        }
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func noKindOfSideConnectionCanActOnChromiumAndTheOnesNotAttachedCannotEither() throws {
        let client = try ChromiumServiceClient()
        defer { client.finish(expectExit: false) }
        _ = try client.stats()
        #expect(try client.call(Self.hello(client), timeout: Self.helloTimeout).bool(CefRemote.Key.success))
        // Ops that act on CEF are the control connection's alone: from a connection attached as any kind, and from one that is
        // attached as none, they are refused and have no effect.
        let hostOnly = [
            CefRemote.Op.createContext, CefRemote.Op.createBrowser, CefRemote.Op.close, CefRemote.Op.load, CefRemote.Op.resize,
            CefRemote.Op.accessibility,
        ]
        var senders: [(String, ChromiumServiceClient)] = []
        defer { senders.forEach { $0.1.close() } }
        for op in Self.sideHellos {
            let side = try ChromiumServiceClient(root: client.root)
            senders.append((op, side))
            #expect(try side.call(CefRemoteMessage(op)).bool(CefRemote.Key.success))
        }
        let unattached = try ChromiumServiceClient(root: client.root)
        senders.append(("unattached", unattached))
        for (kind, sender) in senders {
            for op in hostOnly {
                let message = CefRemoteMessage(op, browser: 1)
                if op == CefRemote.Op.createBrowser {
                    message.set(CefRemote.Key.url, "about:blank")
                }
                let reply = try sender.call(message)
                #expect(reply.string(CefRemote.Key.error) == "not the host", "\(op) from \(kind): \(reply.string(CefRemote.Key.error))")
                #expect(!reply.bool(CefRemote.Key.success), "\(op) from \(kind)")
            }
        }
        let stats = try client.stats()
        #expect(stats.int(CefRemote.Key.contexts) == 0, "no context was made")
        #expect(stats.int(CefRemote.Key.count) == 0, "no browser was made")
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func theServiceTheLaneBuiltHasTheDebugOpsTheStringsCheckLooksFor() throws {
        // The other half of the strings check, on the real thing: this service is built with the ops (the tests above need them),
        // so the check must see them. The same check on the service built without them is the lane's second build.
        let executable = ChromiumServiceBundle.url.appending(path: "Contents/MacOS/WSurf Chromium")
        let run = try Self.runChecker(["--expect-debug", executable.path])
        #expect(run.status == 0, "\(run.output)")
        let plain = try Self.runChecker([executable.path])
        #expect(plain.status == 1, "the plain check must refuse a service with debug ops: \(plain.output)")
    }
}

/// D4-20, the D4-5 carry: how long launchd holds back the replacement of a service that ended young, and whether ending the XPC
/// transaction before `exit` changes it. Its own suite so that the focused run of `ChromiumServiceHardeningTests` and the mutation runs
/// do not pay for it (about two minutes of waiting); it reports, and asserts nothing about the numbers, which are launchd's.
@Suite(.serialized)
struct ChromiumServiceThrottleTests {
    private enum Ending: String {
        /// The control connection closes: the service closes its browsers, flushes, ends its transaction (`xpc_transaction_end`)
        /// and exits with status 0.
        case clean
        /// `debug.abort`: SIGKILL, so the transaction cannot end: the crash case.
        case killed
    }

    /// One service lives `age` seconds, ends as `ending`, and the next hello's wait is measured: from the end to the replacement's
    /// answer, less CEF's own start (`startMs`), which leaves what launchd held back.
    private func measureRespawn(afterAge age: TimeInterval, _ ending: Ending) throws -> (heldBack: TimeInterval, total: TimeInterval) {
        let first = try ChromiumServiceClient()
        // `finish()` only closes and waits: after a kill it must not send anything, which would launch (and throttle) another one.
        defer { first.finish() }
        // The hello of a service launchd holds back (the one before this was young) takes ten seconds: the age counts from its answer.
        _ = try first.hello(linger: 600)
        let spawned = Date()
        let pid = try #require(first.pid)
        let wait = age - Date().timeIntervalSince(spawned)
        if wait > 0 {
            Thread.sleep(forTimeInterval: wait)
        }
        let lived = Date().timeIntervalSince(spawned)
        switch ending {
        case .clean:
            first.close()
        case .killed:
            first.send(CefRemoteMessage(CefRemote.Op.debugAbort))
        }
        let gone = try #require(ChromiumServiceClient.secondsUntilGone(pid, within: 10), "the service did not end")
        let ended = Date()
        let second = try ChromiumServiceClient()
        defer { second.finish() }
        let reply = try second.hello()
        let total = Date().timeIntervalSince(ended)
        #expect(reply.bool(CefRemote.Key.success), "\(reply.string(CefRemote.Key.error))")
        let replacement = try #require(second.pid)
        #expect(replacement != pid, "a new instance answered")
        let start = reply.double(CefRemote.Key.startMs) / 1000
        let line = String(
            format: "%@ after %.1f s of life (gone %.2f s later): the next hello was answered %.2f s after the end, ",
            ending.rawValue, lived, gone, total
        ) + String(format: "CEF's start %.2f s of it, so launchd held it back about %.2f s", start, total - start)
        print("ChromiumServiceThrottleTests observed: " + line)
        return (total - start, total)
    }

    /// The D4-5 carry, answered by measurement: does ending the XPC transaction before `exit` avoid launchd's respawn throttle?
    /// The service already ends it on every deliberate exit (`ServiceHost.endTransaction`), so the clean arm IS that case, against
    /// the kill (which cannot) at the same age and a service older than the throttle's interval as the control. The numbers are
    /// reported, not asserted: the throttle is launchd's.
    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func theRespawnWaitAfterAYoungServiceEndsCleanlyAndAfterItIsKilledIsMeasured() throws {
        var young: [Ending: [TimeInterval]] = [:]
        for _ in 0..<2 {
            for ending in [Ending.clean, .killed] {
                young[ending, default: []].append(try measureRespawn(afterAge: 4, ending).heldBack)
            }
        }
        let old = try measureRespawn(afterAge: 12, .clean).heldBack
        let summary = young.keys.sorted { $0.rawValue < $1.rawValue }.map { ending in
            "\(ending.rawValue) at ~4 s: " + (young[ending] ?? []).map { String(format: "%.2f", $0) }.joined(separator: ", ") + " s"
        }.joined(separator: "; ")
        print("ChromiumServiceThrottleTests observed: held back by launchd (hello wait less CEF's start): \(summary); "
            + String(format: "clean at ~12 s: %.2f s", old))
        #expect(young.values.allSatisfy { $0.count == 2 })
    }
}
