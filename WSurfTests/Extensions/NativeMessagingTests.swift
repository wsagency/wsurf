// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import Testing
import WebKit

@testable import WSurf

/// The native-messaging bridge speaks Chrome's stdio protocol: a little-endian
/// length header, then the JSON. The dead host leads - a launch-constrained
/// helper is AMFI-killed the instant an unlisted browser launches it.
struct NativeMessagingTests {

    @MainActor
    private final class Delegate: NSObject, WKWebExtensionControllerDelegate {
        let service: NativeMessagingService
        var ports: [ObjectIdentifier: WKWebExtension.MessagePort] = [:]

        init(service: NativeMessagingService) {
            self.service = service
        }

        func webExtensionController(
            _ controller: WKWebExtensionController,
            connectUsing port: WKWebExtension.MessagePort,
            for context: WKWebExtensionContext,
            completionHandler: @escaping ((any Error)?) -> Void
        ) {
            switch service.connect(port: port, for: context) {
            case .connected:
                ports[ObjectIdentifier(context)] = port
                completionHandler(nil)
            case .failed(let error):
                completionHandler(error)
            case .unavailable:
                completionHandler(NativeMessagingError.communicationFailed)
            }
        }
    }

    @MainActor
    private func controllerConfiguration() -> WKWebExtensionController.Configuration {
        let configuration = WKWebExtensionController.Configuration.nonPersistent()
        let dataStore = configuration.webViewConfiguration.websiteDataStore
        configuration.webViewConfiguration = WebViewPool.makeConfiguration()
        configuration.webViewConfiguration.websiteDataStore = dataStore
        return configuration
    }

    // MARK: - Hosts that die

    /// A regression here SIGPIPE-kills the test runner itself.
    @Test func aWriteToADeadHostIsHarmless() async throws {
        let manifest = NativeMessagingManifest(
            name: "com.example.exits",
            path: "/usr/bin/true",
            allowedOrigins: ["chrome-extension://abcdef/"]
        )
        let connection = try NativeMessagingConnection(manifest: manifest, arguments: ["chrome-extension://abcdef/"])

        var sawClose = false
        for await event in connection.events {
            if case .closed = event {
                sawClose = true
            }
        }
        #expect(sawClose, "a host that exits reports its close")

        connection.send(Data(#"{"late":true}"#.utf8))
    }

    @Test func aHostThatFailsReportsItsExit() async throws {
        let manifest = NativeMessagingManifest(
            name: "com.example.fails",
            path: "/usr/bin/false",
            allowedOrigins: ["chrome-extension://abcdef/"]
        )
        let connection = try NativeMessagingConnection(manifest: manifest, arguments: ["chrome-extension://abcdef/"])

        var closure: NativeMessagingError?
        for await event in connection.events {
            if case .closed(let error) = event {
                closure = error
            }
        }
        #expect(closure == .hostExited, "a nonzero exit is an error, not a clean close")
    }

    // MARK: - A host that answers

    @Test func aHostRepliesToWhatTheBridgeSends() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let host = directory.appendingPathComponent("echo-host")
        let script = """
        #!/usr/bin/env python3
        import sys, struct
        header = sys.stdin.buffer.read(4)
        length = struct.unpack('<I', header)[0]
        body = sys.stdin.buffer.read(length)
        out = b'{"echo":true}'
        sys.stdout.buffer.write(struct.pack('<I', len(out)) + out)
        sys.stdout.buffer.flush()
        """
        try script.write(to: host, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: host.path)

        let manifest = NativeMessagingManifest(
            name: "com.example.echo",
            path: host.path,
            allowedOrigins: ["chrome-extension://abcdef/"]
        )
        let connection = try NativeMessagingConnection(manifest: manifest, arguments: ["chrome-extension://abcdef/"])
        connection.send(Data(#"{"ping":1}"#.utf8))

        var received: Data?
        for await event in connection.events {
            if case .message(let data) = event {
                received = data
                connection.close()
            }
            if case .closed = event {
                break
            }
        }

        let object = received.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        #expect(object?["echo"] as? Bool == true)
    }

    // MARK: - Errors the extension sees

    @Test func theErrorStringsAreChromesVerbatim() {
        #expect(NativeMessagingError.forbidden.localizedDescription
            == "Access to the specified native messaging host is forbidden.")
        #expect(NativeMessagingError.communicationFailed.localizedDescription
            == "Error when communicating with the native messaging host.")
        #expect(NativeMessagingError.hostExited.localizedDescription
            == "Native host has exited.")
    }

    // MARK: - Framing

    @Test func aFrameCarriesItsLengthLittleEndianFirst() throws {
        let payload = Data("hi".utf8)
        let frame = try NativeMessageFraming.encode(payload)
        #expect(Array(frame.prefix(4)) == [2, 0, 0, 0])
        #expect(frame.dropFirst(4) == payload)
    }

    @Test func aTooLargeMessageIsRefused() {
        var big = Data(count: NativeMessageFraming.maxMessageBytes + 1)
        #expect(throws: NativeMessagingError.self) {
            _ = try NativeMessageFraming.encode(big)
        }
        big.removeAll()
    }

    @Test func theDecoderYieldsWholeMessagesOnly() throws {
        var decoder = NativeMessageDecoder()
        let frame = try NativeMessageFraming.encode(Data("abc".utf8))

        decoder.append(frame.prefix(3))
        #expect(try decoder.next() == nil, "a partial header is not a message")

        decoder.append(frame.dropFirst(3))
        #expect(try decoder.next() == Data("abc".utf8))
        #expect(try decoder.next() == nil)
    }

    @Test func theDecoderSplitsBackToBackMessages() throws {
        var decoder = NativeMessageDecoder()
        var stream = Data()
        stream.append(try NativeMessageFraming.encode(Data("one".utf8)))
        stream.append(try NativeMessageFraming.encode(Data("two".utf8)))
        decoder.append(stream)

        #expect(try decoder.next() == Data("one".utf8))
        #expect(try decoder.next() == Data("two".utf8))
        #expect(try decoder.next() == nil)
    }

    @Test func theDecoderRejectsAnAbsurdLength() {
        var decoder = NativeMessageDecoder()
        decoder.append(Data([0xFF, 0xFF, 0xFF, 0xFF]))
        #expect(throws: NativeMessagingError.self) {
            _ = try decoder.next()
        }
    }

    // MARK: - Manifest

    @Test func aHostNameStaysWithinItsOwnFile() {
        #expect(NativeMessagingManifest.isValidHostName("com.apple.passwordmanager"))
        #expect(NativeMessagingManifest.isValidHostName("com_1password"))
        #expect(!NativeMessagingManifest.isValidHostName("../etc/passwd"))
        #expect(!NativeMessagingManifest.isValidHostName("a/b"))
        #expect(!NativeMessagingManifest.isValidHostName(""))
        #expect(!NativeMessagingManifest.isValidHostName("com..apple"))
    }

    @Test func onlyAStdioManifestWhoseNameMatchesParses() {
        let good = Data("""
        { "name": "com.example.host", "type": "stdio", "path": "/bin/cat",
          "allowed_origins": ["chrome-extension://abcdef/"] }
        """.utf8)
        #expect(NativeMessagingManifest.parse(good, name: "com.example.host") != nil)
        #expect(NativeMessagingManifest.parse(good, name: "com.other.host") == nil)

        let wrongType = Data("""
        { "name": "com.example.host", "type": "native", "path": "/bin/cat",
          "allowed_origins": ["chrome-extension://abcdef/"] }
        """.utf8)
        #expect(NativeMessagingManifest.parse(wrongType, name: "com.example.host") == nil)
    }

    @Test func theOriginMustBeOnTheHostsAllowlist() {
        let manifest = NativeMessagingManifest(
            name: "com.example.host",
            path: "/bin/cat",
            allowedOrigins: ["chrome-extension://pejdijmoenmkgeppbflobdenhhabjlaj/"]
        )
        #expect(manifest.allows(origin: "chrome-extension://pejdijmoenmkgeppbflobdenhhabjlaj/"))
        #expect(manifest.allows(origin: "chrome-extension://pejdijmoenmkgeppbflobdenhhabjlaj"))
        #expect(!manifest.allows(origin: "chrome-extension://someotherextensionid/"))
    }

    @Test func locateSkipsAManifestWhoseBinaryIsMissing() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let manifest = Data("""
        { "name": "com.example.missing", "type": "stdio", "path": "/does/not/exist",
          "allowed_origins": ["chrome-extension://abcdef/"] }
        """.utf8)
        try manifest.write(to: directory.appendingPathComponent("com.example.missing.json"))

        #expect(NativeMessagingManifest.locate(name: "com.example.missing", in: [directory]) == nil)
    }

    @Test func aFirefoxManifestNamesExtensionsInsteadOfOrigins() {
        let mozilla = Data("""
        { "name": "com.apple.passwordmanager", "type": "stdio", "path": "/bin/cat",
          "allowed_extensions": ["apple-passwords-firefox-extension@apple.com"] }
        """.utf8)
        let manifest = NativeMessagingManifest.parse(mozilla, name: "com.apple.passwordmanager")
        #expect(manifest?.allowedExtensions == ["apple-passwords-firefox-extension@apple.com"])
        #expect(manifest?.allowedOrigins == [])

        let empty = Data(#"{ "name": "x", "type": "stdio", "path": "/bin/cat" }"#.utf8)
        #expect(NativeMessagingManifest.parse(empty, name: "x") == nil, "a manifest allowing nobody is refused")
    }

    @Test func aPackageManifestNamesItsGeckoID() throws {
        let package = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: package) }

        let manifest = Data("""
        { "manifest_version": 2,
          "browser_specific_settings": { "gecko": { "id": "{aecec67f-0d10}" } } }
        """.utf8)
        try manifest.write(to: package.appendingPathComponent("manifest.json"))
        #expect(NativeMessagingManifest.geckoID(inPackage: package) == "{aecec67f-0d10}")

        let legacy = Data(#"{ "applications": { "gecko": { "id": "old@style" } } }"#.utf8)
        try legacy.write(to: package.appendingPathComponent("manifest.json"))
        #expect(NativeMessagingManifest.geckoID(inPackage: package) == "old@style")
    }

    @Test func locateFindsAManifestPointingAtARealBinary() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let manifest = Data("""
        { "name": "com.example.cat", "type": "stdio", "path": "/bin/cat",
          "allowed_origins": ["chrome-extension://abcdef/"] }
        """.utf8)
        try manifest.write(to: directory.appendingPathComponent("com.example.cat.json"))

        let found = NativeMessagingManifest.locate(name: "com.example.cat", in: [directory])
        #expect(found?.path == "/bin/cat")
        #expect(found?.allowedOrigins == ["chrome-extension://abcdef/"])
    }

    @Test(.boundedWebViews, .exclusiveExternalApp) @MainActor
    func tearingDownOneContextLeavesAnotherNativePortAlive() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wsurf-native-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let log = directory.appendingPathComponent("messages.log")
        let pythonPath = log.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        let host = directory.appendingPathComponent("host.py")
        try """
        #!/usr/bin/python3
        import json
        import struct
        import sys

        log = '\(pythonPath)'
        while True:
            header = sys.stdin.buffer.read(4)
            if len(header) != 4:
                break
            length = struct.unpack('<I', header)[0]
            payload = sys.stdin.buffer.read(length)
            if len(payload) != length:
                break
            message = json.loads(payload)
            with open(log, 'a', encoding='utf-8') as output:
                output.write(sys.argv[1] + ':' + message['marker'] + ':' + message['phase'] + '\\n')
            response = json.dumps(message).encode()
            sys.stdout.buffer.write(struct.pack('<I', len(response)) + response)
            sys.stdout.buffer.flush()
        """.write(to: host, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: host.path)

        let contextID = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
        let origin = "chrome-extension://\(contextID)/"
        let manifest: [String: Any] = [
            "name": "com.example.native_teardown",
            "type": "stdio",
            "path": host.path,
            "allowed_origins": [origin],
        ]
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: directory.appendingPathComponent("com.example.native_teardown.json"))

        let extensionManifest: [String: Any] = [
            "manifest_version": 3,
            "name": "Native teardown probe",
            "version": "1.0",
            "description": "Context isolation regression",
            "permissions": ["nativeMessaging"],
            "background": ["service_worker": "background.js"],
        ]
        let firstPackage = directory.appendingPathComponent("first-extension", isDirectory: true)
        let secondPackage = directory.appendingPathComponent("second-extension", isDirectory: true)
        for (package, marker) in [(firstPackage, "first"), (secondPackage, "second")] {
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: extensionManifest)
                .write(to: package.appendingPathComponent("manifest.json"))
            try """
            const port = chrome.runtime.connectNative("com.example.native_teardown");
            port.onMessage.addListener((message) => {
              if (message.phase === "trigger") {
                port.postMessage({phase: "late", marker: "\(marker)"});
              }
            });
            port.postMessage({phase: "initial", marker: "\(marker)"});
            """.write(to: package.appendingPathComponent("background.js"), atomically: true, encoding: .utf8)
        }

        let service = NativeMessagingService(
            searchDirectories: [directory],
            mozillaDirectories: []
        )
        let delegate = Delegate(service: service)
        let firstController = WKWebExtensionController(configuration: controllerConfiguration())
        firstController.delegate = delegate
        let secondController = WKWebExtensionController(configuration: controllerConfiguration())
        secondController.delegate = delegate
        let firstExtension = try await WKWebExtension(resourceBaseURL: firstPackage)
        let secondExtension = try await WKWebExtension(resourceBaseURL: secondPackage)
        let first = WKWebExtensionContext(for: firstExtension)
        let second = WKWebExtensionContext(for: secondExtension)
        first.uniqueIdentifier = contextID
        second.uniqueIdentifier = contextID
        for (controller, context) in [(firstController, first), (secondController, second)] {
            context.setPermissionStatus(.grantedExplicitly, for: .nativeMessaging)
            try controller.load(context)
        }
        defer {
            service.disconnect(for: first)
            service.disconnect(for: second)
            try? firstController.unload(first)
            try? secondController.unload(second)
        }

        try await first.loadBackgroundContent()
        try await second.loadBackgroundContent()

        func messages() -> [String] {
            (try? String(contentsOf: log, encoding: .utf8))?
                .split(whereSeparator: \.isNewline)
                .map(String.init) ?? []
        }

        let bothInitial = await waitUntil(timeout: .seconds(30)) {
            messages().filter { $0.hasSuffix(":initial") }.count == 2
        }
        try #require(bothInitial, "both contexts reached the native host")
        service.disconnect(for: first)
        let firstPort = try #require(delegate.ports[ObjectIdentifier(first)])
        let secondPort = try #require(delegate.ports[ObjectIdentifier(second)])
        await #expect(throws: (any Error).self) {
            try await firstPort.sendMessage(["phase": "trigger"])
        }
        try await secondPort.sendMessage(["phase": "trigger"])

        let secondStayedAlive = await waitUntil(timeout: .seconds(30)) {
            messages().contains("\(origin):second:late")
        }
        #expect(secondStayedAlive, "tearing down one context must not close another context's port")
        #expect(!messages().contains("\(origin):first:late"))
    }
}
