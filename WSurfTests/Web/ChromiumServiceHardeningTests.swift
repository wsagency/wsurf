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

    /// A Mach-O file that has no debug ops in it and is on every Mac: the strings check runs `otool` on what it is given.
    private static func machOCopy(in folder: URL, named name: String, appending lines: [String] = []) throws -> URL {
        let copy = folder.appending(path: name)
        try FileManager.default.copyItem(at: URL(filePath: "/usr/bin/true"), to: copy)
        if !lines.isEmpty {
            let handle = try FileHandle(forWritingTo: copy)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(("\n" + lines.joined(separator: "\n") + "\n").utf8))
        }
        return copy
    }

    /// What the strings check looks for, as the script prints it (`--list`): the texts of `DebugOps.swift` and the short names.
    private static func listed() throws -> (texts: [String], names: [String]) {
        let run = try runChecker(["--list"])
        let lines = run.output.split(separator: "\n").map(String.init)
        return (
            lines.filter { $0.hasPrefix("text: ") }.map { String($0.dropFirst(6)) },
            lines.filter { $0.hasPrefix("name: ") }.map { String($0.dropFirst(6)) }
        )
    }

    /// The names of CefKit's `@_alwaysEmitIntoClient` debug names and their values, from the source: `[property name: wire value]`.
    private static func debugNamesInCefKit() throws -> [String: String] {
        let text = try String(contentsOf: repositoryRoot.appending(path: "Packages/CefSwift/Sources/CefKit/CefRemoteProtocol.swift"), encoding: .utf8)
        let pattern = try Regex(#"@_alwaysEmitIntoClient public static var (\w+): String \{ "([^"]*)" \}"#)
        return Dictionary(uniqueKeysWithValues: text.matches(of: pattern).map { match in
            (String(match.output[1].substring ?? ""), String(match.output[2].substring ?? ""))
        })
    }

    /// The entries of `DebugOps.swift`: `[property name: text]`.
    private static func debugTextsInService() throws -> [String: String] {
        let text = try String(
            contentsOf: repositoryRoot.appending(path: "Packages/CefSwift/Sources/wsurf-chromium-service/DebugOps.swift"), encoding: .utf8)
        let pattern = try Regex(#"static let (\w+) = "([^"]*)""#)
        return Dictionary(uniqueKeysWithValues: text.matches(of: pattern).map { match in
            (String(match.output[1].substring ?? ""), String(match.output[2].substring ?? ""))
        })
    }

    @Test
    func theDebugNamesTheirTextsAndTheScriptsListAgree() throws {
        // A debug op added later must be in all three places, or this fails: its name in CefKit (as `@_alwaysEmitIntoClient`), its
        // text in DebugOps.swift under the same name, 16 bytes or more and holding the wire name, and the script reads the texts
        // from that file, so it cannot miss one.
        let names = try Self.debugNamesInCefKit()
        let texts = try Self.debugTextsInService()
        #expect(names.count >= 13, "the debug names were found in CefRemoteProtocol.swift: \(names.count)")
        #expect(Set(names.keys) == Set(texts.keys), "names without a text, or texts without a name: \(Set(names.keys).symmetricDifference(texts.keys).sorted())")
        for (name, wire) in names {
            let text = try #require(texts[name], "\(name)")
            #expect(text.utf8.count >= 16, "\(name): \"\(text)\" is shorter than 16 bytes, which `strings` cannot see")
            #expect(text.contains(wire), "\(name): the text \"\(text)\" does not hold the wire name \"\(wire)\"")
        }
        #expect(Set(texts.values).count == texts.count, "the texts are unique")
        // The script's own list is those texts, and the names it looks for as code are the CefKit ones of 8 to 15 bytes.
        let listed = try Self.listed()
        #expect(Set(listed.texts) == Set(texts.values))
        #expect(Set(listed.names) == Set(names.values))
        // The debug ops a service without them must answer "unknown op" are every `Op.debug*` name of CefKit.
        let ops = Set(names.filter { $0.key.hasPrefix("debug") }.values)
        #expect(ops == Set(ChromiumServiceNoDebugOpsTests.debugOps), "the absence test covers every debug op: \(ops.symmetricDifference(ChromiumServiceNoDebugOpsTests.debugOps).sorted())")
        // The names are the ones the client and the tests use (the compiler resolves them), and nothing else is debug-named.
        #expect(CefRemote.Op.debugAbort == "debug.abort" && CefRemote.DebugCreate.cpuPaint == "cpuPaint")
    }

    @Test
    func theStringsCheckPassesAFileWithoutDebugOpsAndFailsOneWithAnyOfTheirTexts() throws {
        let folder = try Self.canonicalTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let clean = try Self.machOCopy(in: folder, named: "clean", appending: ["debug and abort are plain words here", "browser create started"])
        let clear = try Self.runChecker([clean.path])
        #expect(clear.status == 0, "\(clear.output)")
        // Every text it looks for fails it on its own, and is named.
        for text in try Self.listed().texts {
            let file = try Self.machOCopy(in: folder, named: "with-\(abs(text.hashValue))", appending: [text])
            let run = try Self.runChecker([file.path])
            #expect(run.status == 1, "\(text): \(run.output)")
            #expect(run.output.contains(text), "the failure names \(text): \(run.output)")
        }
        // The extra names count against a service without the ops too.
        let extra = try Self.machOCopy(in: folder, named: "extra", appending: ["consumeExitOnHello"])
        #expect(try Self.runChecker([extra.path]).status == 1)
        #expect(try Self.runChecker([folder.appending(path: "no-such-file").path]).status == 2)
        // A file that is not a program cannot be judged: the check fails instead of passing for the wrong reason.
        let text = folder.appending(path: "plain.txt")
        try Self.write([], to: text)
        #expect(try Self.runChecker([text.path]).status == 2)
    }

    @Test
    func theDebugBuildCheckRequiresEveryTextAndEveryShortNameAndNamesTheOnesItMisses() throws {
        let folder = try Self.canonicalTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let listed = try Self.listed()
        // Nothing of the ops: every text and every short name is named as missing.
        let bare = try Self.machOCopy(in: folder, named: "bare")
        let none = try Self.runChecker(["--expect-debug", bare.path])
        #expect(none.status == 1, "\(none.output)")
        for text in listed.texts {
            #expect(none.output.contains("text: \(text)"), "named: \(text)")
        }
        // Every text but one: that one is named, and nothing else is a text.
        let leftOut = try #require(listed.texts.first { $0.hasPrefix("debug.stats") })
        let nearly = try Self.machOCopy(in: folder, named: "nearly", appending: listed.texts.filter { $0 != leftOut })
        let almost = try Self.runChecker(["--expect-debug", nearly.path])
        #expect(almost.status == 1)
        #expect(almost.output.contains("text: \(leftOut)"))
        #expect(listed.texts.filter { $0 != leftOut }.allSatisfy { !almost.output.contains("text: \($0)") }, "only the missing text is named: \(almost.output)")
        // All the texts and no code: the short names are missing (a text alone is not the op).
        let texts = try Self.machOCopy(in: folder, named: "texts", appending: listed.texts)
        let named = try Self.runChecker(["--expect-debug", texts.path])
        #expect(named.status == 1)
        for name in listed.names where (8...15).contains(name.utf8.count) {
            #expect(named.output.contains("short name (as code immediates): \(name)"), "named: \(name)")
        }
    }

    @Test
    func theImmediatesScannerFindsANameBuiltFromImmediatesAndNothingElse() throws {
        let folder = try Self.canonicalTemporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        // What the compiler writes for `debug.stats` (8 bytes in one register, the rest in another), as `otool -tV` prints it.
        func moves(_ bytes: [UInt8], register: String) -> [String] {
            let pieces = stride(from: 0, to: bytes.count, by: 2).map { UInt16(bytes[$0]) | (($0 + 1 < bytes.count ? UInt16(bytes[$0 + 1]) : 0) << 8) }
            return pieces.enumerated().map { index, value in
                String(format: "0000000100001000\t%@\t%@, #0x%x%@", index == 0 ? "mov" : "movk", register, value, index == 0 ? "" : ", lsl #\(16 * index)")
            }
        }
        func disassembly(_ name: String, spread: Bool) -> String {
            let bytes = Array(name.utf8)
            let head = moves(Array(bytes.prefix(8)), register: "x0")
            let tail = moves(Array(bytes.dropFirst(8)), register: "x1")
            let filler = Array(repeating: "0000000100001000\tnop", count: spread ? 40 : 0)
            return (tail + head.prefix(2) + filler + head.dropFirst(2)).joined(separator: "\n")
        }
        let script = Self.repositoryRoot.appending(path: "Tools/check-service-immediates.py").path
        func run(_ text: String, _ names: [String]) throws -> [String] {
            let file = folder.appending(path: "d-\(UUID().uuidString)")
            try Data(text.utf8).write(to: file)
            let process = Process()
            process.executableURL = URL(filePath: "/usr/bin/python3")
            process.arguments = ["-I", script, file.path] + names
            let pipe = Pipe()
            process.standardOutput = pipe
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
        }
        #expect(try run(disassembly("debug.stats", spread: false), ["debug.stats", "closeFirst"]) == ["FOUND:debug.stats", "MISSING:closeFirst"])
        #expect(try run(disassembly("closeFirst", spread: false), ["closeFirst", "cpuPaint"]) == ["FOUND:closeFirst", "MISSING:cpuPaint"])
        // The pieces far apart in the code are not one name.
        #expect(try run(disassembly("debug.stats", spread: true), ["debug.stats"]) == ["MISSING:debug.stats"])
        #expect(try run("0000000100001000\tnop\n", ["debug.stats"]) == ["MISSING:debug.stats"])
    }

    @Test
    func aLingerHasAnUpperBoundAndANumberThatIsNotOneIsTheDefault() {
        #expect(CefRemoteLinger.clamped(86_400) == CefRemoteLinger.maximumSeconds)
        #expect(CefRemoteLinger.clamped(.infinity) == CefRemoteLinger.maximumSeconds)
        #expect(CefRemoteLinger.clamped(0.01) == CefRemoteLinger.minimumSeconds)
        #expect(CefRemoteLinger.clamped(-5) == CefRemoteLinger.minimumSeconds)
        #expect(CefRemoteLinger.clamped(.nan) == CefRemoteLinger.defaultSeconds)
        #expect(CefRemoteLinger.clamped(25) == 25)
        let linger = CefRemoteLinger(seconds: 1e9, schedule: { _, _ in {} }, onExit: { _ in })
        #expect(linger.seconds == CefRemoteLinger.maximumSeconds)
        linger.setSeconds(1e9)
        #expect(linger.seconds == CefRemoteLinger.maximumSeconds)
    }

    @Test
    func aRootMustBeStrictlyBelowOneOfWSurfsFolders() {
        let bases = ["/Users/someone/Library/Application Support/WSurf", "/private/var/folders/ab/cd/T"]
        #expect(CefRemoteRoot.isAllowed("/Users/someone/Library/Application Support/WSurf/Chromium", bases: bases))
        #expect(CefRemoteRoot.isAllowed("/private/var/folders/ab/cd/T/wsurf-stage/home/Chromium", bases: bases))
        #expect(!CefRemoteRoot.isAllowed("/Users/someone/Library/Application Support/WSurf", bases: bases), "the base itself is not a root")
        #expect(!CefRemoteRoot.isAllowed("/private/var/folders/ab/cd/T", bases: bases))
        #expect(!CefRemoteRoot.isAllowed("/private/var/folders/ab/cd/Tx/root", bases: bases), "component by component")
        #expect(!CefRemoteRoot.isAllowed("/Users/someone/Library/Application Support/WSurf-other/root", bases: bases))
        #expect(!CefRemoteRoot.isAllowed("/Users/someone", bases: bases))
        #expect(!CefRemoteRoot.isAllowed("/", bases: bases))
        #expect(!CefRemoteRoot.isAllowed("/private/tmp/root", bases: bases))
        #expect(!CefRemoteRoot.isAllowed("/private/var/folders/ab/cd/T/root", bases: []))
        // The real bases hold this process's temporary folder, resolved: the folder the tests make their roots in.
        let temporary = realpath(NSTemporaryDirectory(), nil).map { String(cString: $0) }
        #expect(temporary != nil && CefRemoteRoot.bases().contains(temporary ?? ""))
        // `resolve` refuses what could name somewhere else.
        #expect(CefRemoteRoot.resolve("relative/path") == nil)
        #expect(CefRemoteRoot.resolve("/a/../b") == nil)
        #expect(CefRemoteRoot.resolve("/a/./b") == nil)
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
        // The right name as a hard link to another file is refused too: CEF appends to a log, and that write would reach the other name.
        try FileManager.default.removeItem(at: link)
        try Data("not a log".utf8).write(to: target)
        #expect(Darwin.link(target.path, link.path) == 0, "the hard link was made")
        let hardLinked = try client.call(Self.hello(client, logFile: link.path), timeout: Self.helloTimeout)
        #expect(!hardLinked.bool(CefRemote.Key.success), "a log with a second hard link must be refused")
        #expect(hardLinked.string(CefRemote.Key.error).contains("log"), "\(hardLinked.string(CefRemote.Key.error))")
        #expect(!(try client.stats()).bool(CefRemote.Key.started))
        try FileManager.default.removeItem(at: link)
        #expect((try String(contentsOf: target, encoding: .utf8)) == "not a log", "nothing was written through the hard link")
        // The staged run's own file, in the root, is taken (none is there yet).
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

    // MARK: Every hello, the root's base, the staged log (gated)

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func everyHelloPassesTheSameChecksAndASecondOneThatAsksForSomethingElseIsRefused() throws {
        let client = try ChromiumServiceClient()
        defer { client.finish(expectExit: false) }
        _ = try client.stats()
        let good = Self.hello(client, switches: ["disable-chrome-login-prompt": nil])
        let first = try client.call(good, timeout: Self.helloTimeout)
        #expect(first.bool(CefRemote.Key.success), "\(first.string(CefRemote.Key.error))")
        // The client's own retry asks for the same: answered ok, and CEF stays as it was.
        let again = try client.call(Self.hello(client, switches: ["disable-chrome-login-prompt": nil]), timeout: Self.helloTimeout)
        #expect(again.bool(CefRemote.Key.success), "a repeat of the same hello is answered ok: \(again.string(CefRemote.Key.error))")
        // After CEF is up, a hello with a switch that is not WSurf's is refused as the first one would be (it was ok'd before).
        let bad = try client.call(Self.hello(client, switches: ["no-sandbox": nil]), timeout: Self.helloTimeout)
        #expect(!bad.bool(CefRemote.Key.success), "a second hello with a switch that is not WSurf's must be refused")
        #expect(bad.string(CefRemote.Key.error).contains("switch"), "\(bad.string(CefRemote.Key.error))")
        // So is one that is allowed by itself and is not what CEF was started with: other switches, another root, another log.
        let fewer = try client.call(Self.hello(client), timeout: Self.helloTimeout)
        #expect(!fewer.bool(CefRemote.Key.success), "other switches than CEF was started with")
        #expect(fewer.string(CefRemote.Key.error).contains("second hello"), "\(fewer.string(CefRemote.Key.error))")
        let otherRoot = FileManager.default.temporaryDirectory.appending(path: "wsurf-d4-other-root-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: otherRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: otherRoot) }
        let canonical = try #require(realpath(otherRoot.path, nil))
        defer { free(canonical) }
        let moved = try client.call(
            Self.hello(client, root: String(cString: canonical), switches: ["disable-chrome-login-prompt": nil]), timeout: Self.helloTimeout)
        #expect(!moved.bool(CefRemote.Key.success), "another root than CEF was started with")
        #expect(moved.string(CefRemote.Key.error).contains("second hello"), "\(moved.string(CefRemote.Key.error))")
        let logged = try client.call(
            Self.hello(client, switches: ["disable-chrome-login-prompt": nil], logFile: client.root.appending(path: "chromium-service.log").path),
            timeout: Self.helloTimeout)
        #expect(!logged.bool(CefRemote.Key.success), "a log file that CEF was not started with")
        // A refused repeat changes nothing: the service is as it was, and still takes a side connection from the host.
        let stats = try client.stats()
        #expect(stats.bool(CefRemote.Key.started))
        #expect(stats.string(CefRemote.Key.logFile) == "/dev/null")
        let side = try ChromiumServiceClient(root: client.root)
        defer { side.close() }
        #expect(try side.call(CefRemoteMessage(CefRemote.Op.framesHello)).bool(CefRemote.Key.success), "a refused repeat does not unready the host")
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aRootOutsideWSurfsFoldersIsRefusedAndStartsNothing() throws {
        let client = try ChromiumServiceClient()
        defer { client.finish(expectExit: false) }
        _ = try client.stats()
        // `/tmp` is not the user's temporary folder (`/private/var/folders/...`), and is the kind of place a root must not be.
        let outside = URL(filePath: "/private/tmp/wsurf-d4-outside-root-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        for (name, root) in [
            ("a canonical folder outside WSurf's own", outside.path),
            ("the temporary folder itself", try #require(realpath(NSTemporaryDirectory(), nil).map { String(cString: $0) })),
            ("the root of the disk", "/"),
            ("the home folder", NSHomeDirectory()),
        ] {
            let reply = try client.call(Self.hello(client, root: root), timeout: Self.helloTimeout)
            #expect(!reply.bool(CefRemote.Key.success), "\(name) (\(root)) must be refused")
            #expect(reply.string(CefRemote.Key.error).contains("below WSurf"), "\(name): \(reply.string(CefRemote.Key.error))")
            #expect(!(try client.stats()).bool(CefRemote.Key.started), "\(name): a refused hello starts no CEF")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty, "nothing was made in the folder that was refused")
        #expect(try client.call(Self.hello(client), timeout: Self.helloTimeout).bool(CefRemote.Key.success), "a root of the tests' own is taken")
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func aStagedRunsLogBesideItsRootIsTakenAndOneBesideAnyOtherIsNot() throws {
        // A staged run's root is `<home>/Chromium` and its log `<home>/chromium-service.log`: the folder beside the root, which holds
        // the root, and which is itself below a base. A root straight under the temporary folder has the temporary folder beside it.
        let home = FileManager.default.temporaryDirectory.appending(path: "wsurf-d4-stage-\(UUID().uuidString)", directoryHint: .isDirectory)
        let root = home.appending(path: "Chromium", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let canonicalRoot = URL(filePath: try #require(realpath(root.path, nil).map { String(cString: $0) }), directoryHint: .isDirectory)
        let staged = try ChromiumServiceClient(root: canonicalRoot)
        defer { staged.finish(expectExit: false) }
        _ = try staged.stats()
        let beside = canonicalRoot.deletingLastPathComponent().appending(path: "chromium-service.log")
        let reply = try staged.call(Self.hello(staged, logFile: beside.path), timeout: Self.helloTimeout)
        #expect(reply.bool(CefRemote.Key.success), "the log beside a staged root: \(reply.string(CefRemote.Key.error))")
        #expect(try staged.stats().string(CefRemote.Key.logFile) == beside.path)
        // The same name beside a root that is straight under the temporary folder would be in the temporary folder itself: refused.
        let direct = try ChromiumServiceClient()
        defer { direct.finish(expectExit: false) }
        _ = try direct.stats()
        let shared = URL(filePath: try #require(realpath(NSTemporaryDirectory(), nil).map { String(cString: $0) }), directoryHint: .isDirectory)
            .appending(path: "chromium-service.log")
        let refused = try direct.call(Self.hello(direct, logFile: shared.path), timeout: Self.helloTimeout)
        #expect(!refused.bool(CefRemote.Key.success), "a log in the temporary folder itself must be refused")
        #expect(!FileManager.default.fileExists(atPath: shared.path), "and was not made")
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func theExitOnHelloMarkerIsOnlyReadAndWrittenForARootThatPassesTheHellosRule() throws {
        let client = try ChromiumServiceClient()
        defer { client.finish(expectExit: false) }
        _ = try client.stats()
        let outside = URL(filePath: "/private/tmp/wsurf-d4-marker-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outside) }
        let refused = CefRemoteMessage(CefRemote.Op.debugExitOnHello)
        refused.set(CefRemote.Key.rootPath, outside.path)
        refused.set(CefRemote.Key.count, 1)
        #expect(!(try client.call(refused)).bool(CefRemote.Key.success), "a root outside WSurf's folders gets no marker")
        #expect(!FileManager.default.fileExists(atPath: outside.appending(path: ".debug-exit-on-hello").path))
        let relative = CefRemoteMessage(CefRemote.Op.debugExitOnHello)
        relative.set(CefRemote.Key.rootPath, "relative/folder")
        relative.set(CefRemote.Key.count, 1)
        #expect(!(try client.call(relative)).bool(CefRemote.Key.success))
        // A root of the tests' own is written, and taking it off again (count 0) removes the marker.
        let allowed = CefRemoteMessage(CefRemote.Op.debugExitOnHello)
        allowed.set(CefRemote.Key.rootPath, client.root.path)
        allowed.set(CefRemote.Key.count, 0)
        #expect(try client.call(allowed).bool(CefRemote.Key.success))
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent && ChromiumServiceNoDebugOpsTests.serviceHasDebugOps))
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
