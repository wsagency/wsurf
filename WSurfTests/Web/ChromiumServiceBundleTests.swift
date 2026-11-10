// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Darwin
import Foundation
import Security
import Testing
import XPC

@testable import WSurf

/// The layout of the out-of-process Chromium service (D4-2): `WSurf Chromium.xpc` exists only in a build with
/// `WSURF_CHROMIUM_OOP_BUILD=YES` (`Tools/run-chromium-oop-tests.sh`), so every test that needs it is gated per test on
/// `ChromiumServiceBundle.isPresent` and is skipped in the default build.
struct ChromiumServiceBundleTests {
    private var app: URL {
        Bundle.main.bundleURL
    }
    private var service: URL {
        ChromiumServiceBundle.url(in: app)
    }
    private var appIdentifier: String {
        Bundle.main.bundleIdentifier ?? ""
    }

    private func infoPlist() throws -> [String: Any] {
        let data = try Data(contentsOf: service.appending(path: "Contents/Info.plist"))
        return try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
    }

    /// The signing information of a bundle on disk, as `codesign -d` reads it.
    private func signature(of url: URL) throws -> [String: Any] {
        var code: SecStaticCode?
        try #require(SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess)
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation)
        try #require(SecCodeCopySigningInformation(try #require(code), flags, &information) == errSecSuccess)
        return try #require(information as? [String: Any])
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func theServiceHasThePlanInfoPlistAndNoPrivacyKeys() throws {
        let plist = try infoPlist()
        #expect(plist["CFBundlePackageType"] as? String == "XPC!")
        #expect(plist["CFBundleIdentifier"] as? String == appIdentifier + ".chromium")
        #expect(plist["LSMinimumSystemVersion"] as? String == "26.0")
        // Exactly these three keys: an XPC! bundle may launch with defaults when a key is missing, so a ping alone would not
        // notice one lost.
        let xpc = try #require(plist["XPCService"] as? [String: Any])
        #expect(Set(xpc.keys) == ["ServiceType", "JoinExistingSession", "RunLoopType"], "\(xpc)")
        #expect(xpc["ServiceType"] as? String == "Application")
        #expect(xpc["JoinExistingSession"] as? Bool == true)
        #expect(xpc["RunLoopType"] as? String == "NSRunLoop")
        // A privacy string is the owner's to add with the signing PR (D4-S), never before.
        #expect(plist.keys.filter { $0.hasSuffix("UsageDescription") }.isEmpty)
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func theServiceIsSignedAdHocWithNoEntitlementsAndNoHardenedRuntime() throws {
        let information = try signature(of: service)
        #expect(information[kSecCodeInfoIdentifier as String] as? String == appIdentifier + ".chromium")
        #expect(information[kSecCodeInfoEntitlementsDict as String] == nil)
        let flags = try #require(information[kSecCodeInfoFlags as String] as? NSNumber).uint32Value
        #expect(flags & SecCodeSignatureFlags.adhoc.rawValue != 0, "ad hoc")
        #expect(flags & SecCodeSignatureFlags.runtime.rawValue == 0, "no hardened runtime")
        #expect(information[kSecCodeInfoTeamIdentifier as String] == nil)
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func theFrameworkAndTheFiveHelpersExistOnlyInsideTheService() throws {
        let manager = FileManager.default
        let own = try #require(ChromiumServiceBundle.frameworks)
        let apps = app.appending(path: "Contents/Frameworks")
        #expect(manager.fileExists(atPath: own.appending(path: ChromiumServiceBundle.frameworkName).path))
        #expect(!manager.fileExists(atPath: apps.appending(path: ChromiumServiceBundle.frameworkName).path), "one copy")
        for helper in ChromiumServiceBundle.helperNames {
            let executable = "\(helper).app/Contents/MacOS/\(helper)"
            #expect(manager.isExecutableFile(atPath: own.appending(path: executable).path), "\(helper) in the service")
            #expect(!manager.fileExists(atPath: apps.appending(path: "\(helper).app").path), "\(helper) is not in the app")
        }
        // The in-process path is what the Chromium suites run, and it loads from the service's copy.
        #expect(ChromiumServiceBundle.frameworkDirectory == own.appending(path: ChromiumServiceBundle.frameworkName, directoryHint: .isDirectory))
        #expect(ChromiumServiceBundle.helperExecutable?.path.hasSuffix("WSurf Chromium.xpc/Contents/Frameworks/WSurf Helper.app/Contents/MacOS/WSurf Helper") == true)
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func pingAnswersWithAPidWhoseResponsibleProcessIsThisHost() throws {
        let reply = try Self.ping(appIdentifier + ".chromium")
        let pid = try #require(reply.pid)
        #expect(pid > 1 && pid != getpid(), "the service is a process of its own")
        // The prompt-free check of TCC attribution: macOS attributes an app's XPC service to the app, so a camera prompt would
        // name WSurf. The service's responsible process must be the one this host is responsible for itself (the host, when it
        // was launched as an app; the process that launched it otherwise), and never the service itself. The call is private;
        // without it the test cannot say, and fails rather than pass without checking.
        typealias Responsible = @convention(c) (pid_t) -> pid_t
        let symbol = try #require(dlsym(UnsafeMutableRawPointer(bitPattern: -2), "responsibility_get_pid_responsible_for_pid"))
        let responsibleFor = unsafeBitCast(symbol, to: Responsible.self)
        let service = responsibleFor(pid)
        let host = responsibleFor(getpid())
        #expect(service == host && service != pid, "service \(pid) is attributed to \(service); this host \(getpid()) to \(host)")
        print("ChromiumServiceBundleTests observed: service \(pid), responsible for it \(service); host \(getpid()), responsible for it \(host)")
    }

    @Test(.enabled(if: ChromiumServiceBundle.isPresent))
    func anUnknownOperationGetsAnErrorNotASilence() throws {
        let reply = try Self.ping(appIdentifier + ".chromium", op: "nonsense")
        #expect(reply.error == "unknown op")
        #expect(reply.pid == nil)
    }

    // MARK: Raw XPC

    private nonisolated struct Reply {
        var pid: pid_t?
        var error: String?
    }

    /// One message to the service and its reply, with a timeout. The connection is plain XPC, as the stub's `main.swift` speaks
    /// it; the wait is on this thread and the reply comes on a queue of its own, so nothing waits on the main queue.
    /// `nonisolated`, so that the reply closure, which XPC runs on that queue, is not inferred to be main-actor isolated.
    private nonisolated static func ping(_ serviceIdentifier: String, op: String = "ping") throws -> Reply {
        let queue = DispatchQueue(label: "ChromiumServiceBundleTests.xpc")
        let connection = xpc_connection_create(serviceIdentifier, queue)
        xpc_connection_set_event_handler(connection) { _ in }
        xpc_connection_activate(connection)
        defer { xpc_connection_cancel(connection) }
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(message, "op", op)
        let done = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var reply = Reply()
        nonisolated(unsafe) var failure: String?
        xpc_connection_send_message_with_reply(connection, message, queue) { answer in
            if xpc_get_type(answer) == XPC_TYPE_DICTIONARY {
                if xpc_dictionary_get_value(answer, "pid") != nil {
                    reply.pid = pid_t(xpc_dictionary_get_int64(answer, "pid"))
                }
                reply.error = xpc_dictionary_get_string(answer, "error").map { String(cString: $0) }
            } else {
                let text = xpc_copy_description(answer)
                defer { free(text) }
                failure = String(cString: text)
            }
            done.signal()
        }
        // The service starts on this first message: a cold launch of the signed bundle takes well under a second.
        #expect(done.wait(timeout: .now() + 10) == .success, "the service did not answer within 10 s")
        if let failure { Issue.record("the service connection failed: \(failure)") }
        return reply
    }
}
