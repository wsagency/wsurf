// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing

@testable import CefKit
@testable import WSurf

/// D4-20 (review M1 of PR #153): a service built WITHOUT the debug ops, as a signed one is, answers every debug op as an op it does
/// not know, and `Tools/check-service-strings.sh` finds nothing of them in it. The tests run only against such a service
/// (`WSURF_SERVICE_DEBUG_OPS=NO Tools/run-chromium-oop-tests.sh ChromiumServiceNoDebugOpsTests`; embed-chromium.sh builds it and
/// checks it with the same script); against the lane's usual service, which has the ops, they are skipped, and so are they in the
/// default lane, which has no service. Which one it is, is read from the service's file, not from a variable.
@Suite(.serialized)
struct ChromiumServiceNoDebugOpsTests {
    /// Every `Op.debug*` name. `ChromiumServiceHardeningTests` fails when this list and CefKit's differ.
    static let debugOps = [
        CefRemote.Op.debugAbort, CefRemote.Op.debugStats, CefRemote.Op.debugExitOnHello, CefRemote.Op.debugAskHost,
        CefRemote.Op.debugMemoryPressure, CefRemote.Op.debugStubBrowser, CefRemote.Op.debugHangExit, CefRemote.Op.debugHoldHistory,
    ]

    private static var executable: URL {
        ChromiumServiceBundle.url.appending(path: "Contents/MacOS/WSurf Chromium")
    }

    /// Whether the service's file has the debug ops: one of their texts is in it (every text is 16 bytes or more, so it is stored
    /// in the file as it is).
    static var serviceHasDebugOps: Bool {
        guard ChromiumServiceBundle.isPresent, let data = try? Data(contentsOf: executable, options: .mappedIfSafe) else { return false }
        return data.range(of: Data("debug.stats: the service answers".utf8)) != nil
    }

    static var serviceHasNoDebugOps: Bool {
        ChromiumServiceBundle.isPresent && !serviceHasDebugOps
    }

    private static func runChecker() throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(filePath: "/bin/bash")
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        process.arguments = [root.appending(path: "Tools/check-service-strings.sh").path, executable.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    @Test(.enabled(if: ChromiumServiceNoDebugOpsTests.serviceHasNoDebugOps))
    func theStringsCheckFindsNothingOfTheDebugOpsInThisService() throws {
        let run = try Self.runChecker()
        #expect(run.status == 0, "\(run.output)")
    }

    @Test(.enabled(if: ChromiumServiceNoDebugOpsTests.serviceHasNoDebugOps))
    func everyDebugOpIsAnUnknownOpToThisServiceBeforeAndAfterAHello() throws {
        let client = try ChromiumServiceClient()
        defer { client.finish(expectExit: true) }
        func probe(_ phase: String) throws {
            for op in Self.debugOps {
                let message = CefRemoteMessage(op, browser: 1)
                // The parameters an op would take, so that one that is answered is not refused for the lack of them.
                message.set(CefRemote.Key.rootPath, client.root.path)
                message.set(CefRemote.Key.count, 1)
                message.set(CefRemote.Key.flag, true)
                let reply = try client.call(message, timeout: 10)
                #expect(reply.string(CefRemote.Key.error) == "unknown op", "\(op) \(phase): \(reply.string(CefRemote.Key.error))")
                #expect(!reply.bool(CefRemote.Key.success), "\(op) \(phase)")
                #expect(!reply.has(CefRemote.Key.pid), "\(op) \(phase): nothing of the service's state is in the answer")
            }
        }
        try probe("before a hello")
        let hello = try client.hello()
        #expect(hello.bool(CefRemote.Key.success), "\(hello.string(CefRemote.Key.error))")
        try probe("after a hello")
        // No marker was written for the exit-on-hello op, which would have killed the next hello of a service that had it.
        #expect(!FileManager.default.fileExists(atPath: client.root.appending(path: ".debug-exit-on-hello").path))
    }

    @Test(.enabled(if: ChromiumServiceNoDebugOpsTests.serviceHasNoDebugOps))
    func aStagedClientsLogFileIsNotRefusedAndNotWrittenByThisService() throws {
        // A staged DEBUG client always names its log file: against a service without the ops (a signed one) that must not fail
        // the hello (review L2), and the file must never be made.
        let home = FileManager.default.temporaryDirectory.appending(path: "wsurf-d4-nodebug-\(UUID().uuidString)", directoryHint: .isDirectory)
        let root = home.appending(path: "Chromium", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let canonical = URL(filePath: try #require(realpath(root.path, nil).map { String(cString: $0) }), directoryHint: .isDirectory)
        let client = try ChromiumServiceClient(root: canonical)
        defer { client.finish(expectExit: true) }
        let log = canonical.deletingLastPathComponent().appending(path: "chromium-service.log")
        let reply = try client.hello(logFile: log.path)
        #expect(reply.bool(CefRemote.Key.success), "\(reply.string(CefRemote.Key.error))")
        usleep(300_000)
        #expect(!FileManager.default.fileExists(atPath: log.path), "this service writes no log")
        // A name that is not the staged run's is still refused: the shape is judged by every service.
        let other = CefRemoteMessage.hello()
        other.set(CefRemote.Key.rootPath, canonical.path)
        other.set(CefRemote.Key.cachePath, canonical.appending(path: "default").path)
        other.set(CefRemote.Key.logFile, "/etc/hosts")
        #expect(!(try client.call(other, timeout: 30)).bool(CefRemote.Key.success))
    }
}
