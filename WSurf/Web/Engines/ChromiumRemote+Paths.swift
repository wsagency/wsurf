// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CefKit
import Foundation

// The hello and the paths it carries, split out of `ChromiumRemote.swift` to keep it under the file-length limit (D4-20). All of it is
// pure: no state of the client is read or written here.

extension ChromiumRemote {
    // MARK: The hello

    /// The Chromium switches the service may be given: exactly the ones WSurf's own Chromium has (`ChromiumRuntime`), with the
    /// values it gives them. Anything else a caller asks for (`no-sandbox`, a remote-debugging port, a switch that turns off the
    /// same-origin policy, a profile directory) is dropped here, so no hello, whoever builds it, can loosen the service.
    /// The service refuses a hello that asks for any other (`CefRemoteSwitches`, the one list both sides use).
    nonisolated static func allowedSwitches(_ requested: [String: String?]) -> [String: String?] {
        CefRemoteSwitches.filter(requested)
    }

    /// The only log file the service may be told about: the staged run's own (`chromium-service.log` in its home). Any other path,
    /// or none, or any path outside a staged run, is `/dev/null`, so no URL a page visits ever lands in a file of the service's
    /// choosing.
    nonisolated static func validatedLogPath(_ candidate: String?, stageHome: URL?) -> String {
        guard let candidate, candidate.hasPrefix("/"), let stageHome else { return "/dev/null" }
        let staged = stageHome.appending(path: "chromium-service.log", directoryHint: .notDirectory).standardizedFileURL.path
        return URL(filePath: candidate).standardizedFileURL.path == staged ? staged : "/dev/null"
    }

    /// The staged run's home, in a staged DEBUG run.
    nonisolated static var stageHome: URL? {
        #if DEBUG
        return StageMode.isActive ? StageMode.home : nil
        #else
        return nil
        #endif
    }

    /// The staged run's service log, which `validatedLogPath` accepts.
    nonisolated static var stagedLogPath: String? {
        stageHome?.appending(path: "chromium-service.log", directoryHint: .notDirectory).path
    }

    /// The hello: version, root and cache (the root's `Global`, as the in-process path), the allowed switches, the validated log
    /// file, and the linger when one is chosen (else the service's 60 s).
    nonisolated static func makeHello(
        protocolVersion: Int64 = CefRemote.protocolVersion,
        root: URL,
        linger: Double? = nil,
        switches: [String: String?] = ChromiumRuntime.extraCommandLineSwitches,
        logFile: String? = nil,
        stageHome: URL? = ChromiumRemote.stageHome
    ) -> CefRemoteMessage {
        let message = CefRemoteMessage.hello(protocolVersion: protocolVersion, linger: linger)
        message.set(CefRemote.Key.rootPath, root.path)
        message.set(CefRemote.Key.cachePath, root.appending(path: "Global", directoryHint: .isDirectory).path)
        message.set(CefRemote.Key.logFile, validatedLogPath(logFile, stageHome: stageHome))
        message.set(CefRemote.Key.switches, strings: allowedSwitches(switches))
        return message
    }

    /// The canonical form of a path that may not exist yet, made without creating anything: `..` and `.` are resolved, then the
    /// nearest existing ancestor goes through `realpath` (so a symlink or a `/var` alias in it is resolved) and the components
    /// below it, which cannot be links, are appended. Nil when no ancestor resolves, and for a dangling symlink: it is tested with
    /// `lstat` (`fileExists` follows a link, so one that leads nowhere looked like a folder not made yet, review L2), and `realpath`
    /// then fails on it.
    nonisolated static func canonicalPath(of url: URL) -> URL? {
        var existing = url.standardizedFileURL.path
        var below: [String] = []
        while !isPresent(existing) {
            guard existing != "/" else { return nil }
            below.insert((existing as NSString).lastPathComponent, at: 0)
            existing = (existing as NSString).deletingLastPathComponent
        }
        guard let resolved = realpath(existing, nil) else { return nil }
        defer { free(resolved) }
        return URL(filePath: String(cString: resolved), directoryHint: .isDirectory).appending(path: below.joined(separator: "/"))
    }

    /// Whether something is at `path`, a link (even a dangling one) included.
    nonisolated private static func isPresent(_ path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0
    }

    /// Whether `path` is `root` or below it, component by component (`/a/bc` is not inside `/a/b`). Both are canonical.
    nonisolated static func isInside(_ path: URL, root: URL) -> Bool {
        let inner = path.pathComponents
        let outer = root.pathComponents
        return inner.count >= outer.count && Array(inner.prefix(outer.count)) == outer
    }

    /// The root as CEF needs it: it exists, and it is the canonical path (Foundation keeps `/tmp` aliases; CEF refuses them).
    nonisolated static func prepareRoot(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        guard let canonical = realpath(url.path, nil) else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        defer { free(canonical) }
        return URL(filePath: String(cString: canonical), directoryHint: .isDirectory)
    }
}
