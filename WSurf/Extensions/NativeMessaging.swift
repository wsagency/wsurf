// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import os
import WebKit

// Chrome's exact runtime.lastError strings; extensions string-match them, never localize.
nonisolated enum NativeMessagingError: Error, Sendable, LocalizedError {
    case forbidden
    case communicationFailed
    case hostExited

    var errorDescription: String? {
        switch self {
        case .forbidden:
            "Access to the specified native messaging host is forbidden."
        case .communicationFailed:
            "Error when communicating with the native messaging host."
        case .hostExited:
            "Native host has exited."
        }
    }
}

nonisolated enum NativeMessageFraming {
    static let maxMessageBytes = 64 * 1024 * 1024

    static func encode(_ payload: Data) throws -> Data {
        guard payload.count <= maxMessageBytes else { throw NativeMessagingError.communicationFailed }
        var frame = Data(capacity: 4 + payload.count)
        withUnsafeBytes(of: UInt32(payload.count).littleEndian) { frame.append(contentsOf: $0) }
        frame.append(payload)
        return frame
    }
}

nonisolated struct NativeMessageDecoder {
    private var buffer = Data()

    mutating func append(_ data: Data) {
        buffer.append(data)
    }

    mutating func next() throws -> Data? {
        guard buffer.count >= 4 else { return nil }
        let base = buffer.startIndex
        let length = UInt32(buffer[base])
            | UInt32(buffer[base + 1]) << 8
            | UInt32(buffer[base + 2]) << 16
            | UInt32(buffer[base + 3]) << 24
        guard Int(length) <= NativeMessageFraming.maxMessageBytes else {
            throw NativeMessagingError.communicationFailed
        }
        let total = 4 + Int(length)
        guard buffer.count >= total else { return nil }
        let payload = Data(buffer[(base + 4)..<(base + total)])
        buffer.removeSubrange(base..<(base + total))
        return payload
    }
}

nonisolated struct NativeMessagingManifest: Equatable, Sendable {
    var name: String
    var path: String
    var allowedOrigins: [String] = []
    var allowedExtensions: [String] = []
    var fileURL: URL?

    static var defaultSearchDirectories: [URL] {
        let library = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return [
            library.appendingPathComponent("WSurf/NativeMessagingHosts", isDirectory: true),
            library.appendingPathComponent("Google/Chrome/NativeMessagingHosts", isDirectory: true),
            library.appendingPathComponent("Chromium/NativeMessagingHosts", isDirectory: true),
            URL(fileURLWithPath: "/Library/Google/Chrome/NativeMessagingHosts", isDirectory: true),
            URL(fileURLWithPath: "/Library/Application Support/Chromium/NativeMessagingHosts", isDirectory: true),
        ]
    }

    static var defaultMozillaDirectories: [URL] {
        let library = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        return [
            library.appendingPathComponent("Mozilla/NativeMessagingHosts", isDirectory: true),
            URL(fileURLWithPath: "/Library/Application Support/Mozilla/NativeMessagingHosts", isDirectory: true),
        ]
    }

    static func isValidHostName(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 255 else { return false }
        let segments = name.split(separator: ".", omittingEmptySubsequences: false)
        guard !segments.isEmpty else { return false }
        return segments.allSatisfy { segment in
            !segment.isEmpty && segment.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
        }
    }

    static func parse(_ data: Data, name: String) -> NativeMessagingManifest? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["name"] as? String == name,
              root["type"] as? String == "stdio",
              let path = root["path"] as? String
        else { return nil }
        let origins = root["allowed_origins"] as? [String] ?? []
        let extensions = root["allowed_extensions"] as? [String] ?? []
        guard !origins.isEmpty || !extensions.isEmpty else { return nil }
        return NativeMessagingManifest(
            name: name,
            path: path,
            allowedOrigins: origins,
            allowedExtensions: extensions
        )
    }

    static func locate(name: String, in directories: [URL]) -> NativeMessagingManifest? {
        guard isValidHostName(name) else { return nil }
        for directory in directories {
            let file = directory.appendingPathComponent("\(name).json")
            guard let data = try? Data(contentsOf: file),
                  var manifest = parse(data, name: name)
            else { continue }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: manifest.path, isDirectory: &isDirectory),
                  !isDirectory.boolValue,
                  FileManager.default.isExecutableFile(atPath: manifest.path)
            else { continue }
            manifest.fileURL = file
            return manifest
        }
        return nil
    }

    static func geckoID(inPackage package: URL) -> String? {
        let url = package.appendingPathComponent("manifest.json")
        guard let data = try? Data(contentsOf: url),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let settings = (root["browser_specific_settings"] ?? root["applications"]) as? [String: Any]
        return (settings?["gecko"] as? [String: Any])?["id"] as? String
    }

    func allows(origin: String) -> Bool {
        let target = trimmed(origin)
        return allowedOrigins.contains { trimmed($0).caseInsensitiveCompare(target) == .orderedSame }
    }

    private func trimmed(_ origin: String) -> String {
        origin.hasSuffix("/") ? String(origin.dropLast()) : origin
    }
}

nonisolated final class NativeMessagingConnection: @unchecked Sendable {
    enum Event: Sendable {
        case message(Data)
        case closed(NativeMessagingError?)
    }

    let events: AsyncStream<Event>

    private let process = Process()
    private let stdinHandle: FileHandle
    private let stdoutHandle: FileHandle
    private let stderrHandle: FileHandle
    private let continuation: AsyncStream<Event>.Continuation
    private let queue = DispatchQueue(label: "io.wsagency.wsurf.native-messaging")
    // Teardown can race a queued write; reject writes before draining the queue.
    private let stateLock = NSLock()
    private var decoder = NativeMessageDecoder()
    private var finished = false
    private var closed = false
    private var exitStatus: Int32?
    private var sawEOF = false

    init(manifest: NativeMessagingManifest, arguments: [String]) throws {
        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        stdinHandle = input.fileHandleForWriting
        stdoutHandle = output.fileHandleForReading
        stderrHandle = errors.fileHandleForReading

        let (stream, continuation) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .unbounded)
        events = stream
        self.continuation = continuation

        process.executableURL = URL(fileURLWithPath: manifest.path)
        process.arguments = arguments
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        // Writing to a dead host's stdin raises SIGPIPE and kills WSurf without this.
        _ = fcntl(stdinHandle.fileDescriptor, F_SETNOSIGPIPE, 1)

        stdoutHandle.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard let self else { return }
            self.queue.async { self.ingest(chunk) }
        }
        stderrHandle.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            Pipeline.log.notice("Native messaging stderr received (\(chunk.count) bytes)")
        }
        // EOF and termination race in both orders; whichever lands second closes.
        process.terminationHandler = { [weak self] process in
            let status = process.terminationStatus
            guard let self else { return }
            self.queue.async {
                self.exitStatus = status
                if status != 0 {
                    Pipeline.log.notice("Native messaging exited with status \(status)")
                }
                if self.sawEOF {
                    self.finishForExit(status)
                }
            }
            self.queue.asyncAfter(deadline: .now() + 2) {
                self.finishForExit(status)
            }
        }

        do {
            try process.run()
        } catch {
            continuation.finish()
            Pipeline.log.error("nativemsg operation failed")
            throw NativeMessagingError.communicationFailed
        }
    }

    func send(_ payload: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let canSend = !self.closed && !self.finished
            self.stateLock.unlock()
            guard canSend else { return }
            do {
                try self.stdinHandle.write(contentsOf: NativeMessageFraming.encode(payload))
            } catch {
                self.finish(.closed(.hostExited))
            }
        }
    }

    func close() {
        stateLock.lock()
        closed = true
        stateLock.unlock()
        queue.async { self.finish(.closed(nil)) }
        terminateIfNeeded()
    }

    private func ingest(_ chunk: Data) {
        guard !finished else { return }
        guard !chunk.isEmpty else {
            sawEOF = true
            if let exitStatus {
                finishForExit(exitStatus)
            }
            return
        }
        decoder.append(chunk)
        do {
            while let payload = try decoder.next() {
                continuation.yield(.message(payload))
            }
        } catch {
            finish(.closed(.communicationFailed))
        }
    }

    private func finishForExit(_ status: Int32) {
        finish(.closed(status != 0 ? .hostExited : nil))
    }

    private func finish(_ event: Event) {
        guard !finished else { return }
        stateLock.lock()
        closed = true
        stateLock.unlock()
        finished = true
        continuation.yield(event)
        continuation.finish()
        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil
        try? stdinHandle.close()
        terminateIfNeeded()
    }

    private func terminateIfNeeded() {
        let process = process
        guard process.isRunning else { return }
        // A blocked stdin write must not also block termination or the main actor.
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(500)) {
            if process.isRunning {
                process.terminate()
            }
        }
    }
}

@MainActor
final class NativeMessagingService {
    enum ConnectOutcome {
        case unavailable
        case connected
        case failed(any Error)
    }

    private enum Resolution {
        case host(NativeMessagingManifest, arguments: [String])
        case unavailable
        case forbidden
    }

    private let searchDirectories: [URL]
    private let mozillaDirectories: [URL]
    var geckoID: ((String) -> String?)?

    @MainActor
    private final class ActiveConnection {
        let context: WKWebExtensionContext
        let port: WKWebExtension.MessagePort
        let connection: NativeMessagingConnection
        var task: Task<Void, Never>?
        var closed = false

        init(
            context: WKWebExtensionContext,
            port: WKWebExtension.MessagePort,
            connection: NativeMessagingConnection
        ) {
            self.context = context
            self.port = port
            self.connection = connection
        }
    }

    private var connections: [ObjectIdentifier: [ObjectIdentifier: ActiveConnection]] = [:]

    init(
        searchDirectories: [URL] = NativeMessagingManifest.defaultSearchDirectories,
        mozillaDirectories: [URL] = NativeMessagingManifest.defaultMozillaDirectories
    ) {
        self.searchDirectories = searchDirectories
        self.mozillaDirectories = mozillaDirectories
    }

    private func resolve(
        _ applicationIdentifier: String?,
        for context: WKWebExtensionContext
    ) -> Resolution {
        guard let name = applicationIdentifier,
              NativeMessagingManifest.isValidHostName(name),
              context.hasPermission(.nativeMessaging)
        else { return .unavailable }

        var refused = false
        if let manifest = NativeMessagingManifest.locate(name: name, in: searchDirectories) {
            let origin = "chrome-extension://\(context.uniqueIdentifier)/"
            if manifest.allows(origin: origin) {
                return .host(manifest, arguments: [origin])
            }
            refused = true
        }
        if let gecko = geckoID?(context.uniqueIdentifier),
           let manifest = NativeMessagingManifest.locate(name: name, in: mozillaDirectories) {
            if manifest.allowedExtensions.contains(gecko) {
                return .host(manifest, arguments: [manifest.fileURL?.path ?? name, gecko])
            }
            refused = true
        }
        guard refused else { return .unavailable }
        Pipeline.log.notice("Native messaging host refused connection")
        return .forbidden
    }

    func connect(port: WKWebExtension.MessagePort, for context: WKWebExtensionContext) -> ConnectOutcome {
        let manifest: NativeMessagingManifest
        let arguments: [String]
        switch resolve(port.applicationIdentifier, for: context) {
        case .unavailable:
            return .unavailable
        case .forbidden:
            return .failed(NativeMessagingError.forbidden)
        case .host(let found, let foundArguments):
            (manifest, arguments) = (found, foundArguments)
        }

        let connection: NativeMessagingConnection
        do {
            connection = try NativeMessagingConnection(manifest: manifest, arguments: arguments)
        } catch {
            return .failed(error)
        }

        let active = ActiveConnection(context: context, port: port, connection: connection)
        port.messageHandler = { [weak connection] message, error in
            guard let connection else { return }
            guard error == nil else {
                connection.close()
                return
            }
            guard let message,
                  let data = try? JSONSerialization.data(withJSONObject: message, options: .fragmentsAllowed)
            else {
                Pipeline.log.error("nativemsg: dropped a message that would not encode")
                return
            }
            connection.send(data)
        }
        port.disconnectHandler = { [weak self, weak active] _ in
            Task { @MainActor [weak self, weak active] in
                guard let self, let active else { return }
                self.disconnect(active)
            }
        }

        let contextKey = ObjectIdentifier(context)
        let portKey = ObjectIdentifier(port)
        connections[contextKey, default: [:]][portKey] = active
        active.task = Task { @MainActor [weak self, weak active] in
            guard let active else { return }
            for await event in active.connection.events {
                guard !Task.isCancelled else { return }
                switch event {
                case .message(let data):
                    guard !active.closed,
                          let object = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed),
                          !Task.isCancelled
                    else { continue }
                    try? await active.port.sendMessage(object)
                case .closed(let error):
                    self?.disconnect(active, error: error.map { $0 as NSError })
                    return
                }
            }
            self?.disconnect(active)
        }
        Pipeline.log.notice("Native messaging connected")
        return .connected
    }

    func disconnect(for context: WKWebExtensionContext) {
        let contextKey = ObjectIdentifier(context)
        guard let activeConnections = connections.removeValue(forKey: contextKey) else { return }
        for active in activeConnections.values {
            disconnect(active)
        }
    }

    private func disconnect(_ active: ActiveConnection, error: NSError? = nil) {
        guard !active.closed else { return }
        active.closed = true
        let contextKey = ObjectIdentifier(active.context)
        let portKey = ObjectIdentifier(active.port)
        if connections[contextKey]?[portKey] === active {
            connections[contextKey]?.removeValue(forKey: portKey)
            if connections[contextKey]?.isEmpty == true {
                connections.removeValue(forKey: contextKey)
            }
        }
        active.task?.cancel()
        active.task = nil
        active.port.messageHandler = nil
        active.port.disconnectHandler = nil
        active.connection.close()
        active.port.disconnect(throwing: error)
    }

    func sendOnce(
        message: Any,
        applicationIdentifier: String?,
        for context: WKWebExtensionContext,
        reply: @escaping (Any?, (any Error)?) -> Void
    ) -> Bool {
        let manifest: NativeMessagingManifest
        let arguments: [String]
        switch resolve(applicationIdentifier, for: context) {
        case .unavailable:
            return false
        case .forbidden:
            reply(nil, NativeMessagingError.forbidden)
            return true
        case .host(let found, let foundArguments):
            (manifest, arguments) = (found, foundArguments)
        }

        guard let data = try? JSONSerialization.data(withJSONObject: message, options: .fragmentsAllowed) else {
            reply(nil, NativeMessagingError.communicationFailed)
            return true
        }
        let connection: NativeMessagingConnection
        do {
            connection = try NativeMessagingConnection(manifest: manifest, arguments: arguments)
        } catch {
            reply(nil, error)
            return true
        }
        connection.send(data)
        Task { @MainActor in
            for await event in connection.events {
                switch event {
                case .message(let payload):
                    let object = try? JSONSerialization.jsonObject(with: payload, options: .fragmentsAllowed)
                    reply(object, nil)
                    connection.close()
                    return
                case .closed(let error):
                    reply(nil, error ?? NativeMessagingError.hostExited)
                    return
                }
            }
        }
        return true
    }
}
