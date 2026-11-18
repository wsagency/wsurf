// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

// D4-20: what a hello may ask of the service, and how CEF is started from one. Split out of `ServiceHost.swift` (which keeps the
// connections and the lifecycle). Nothing in this file is reached before the hello's protocol version was checked.

import AppKit
import CCef
import CCefAppKit
import CefKit
import Foundation

/// What an accepted hello asked for, resolved: the values CEF was (or would be) started with.
struct HelloParameters: Equatable {
    /// The root cache path: canonical and below one of WSurf's own folders (`CefRemoteRoot`).
    let root: String
    /// The cache path, resolved, the root or below it; nil when the hello named none.
    let cache: String?
    let switches: [String: String]
    /// `/dev/null`, or the staged run's `chromium-service.log` (a service with the debug ops only).
    let logFile: String
}

extension ServiceHost {
    /// The hello's parameters when every rule holds, else the error that refuses it. Pure with respect to CEF and the connections:
    /// nothing is made and nothing is started here, so every hello, the first or a repeat, can pass through it. After CEF is up, a
    /// hello that asks for something else than the one that started it is refused (CEF keeps what it was started with, so an
    /// "ok" would be a lie); one that asks for the same, which WSurf's client does when it asks again after a timeout, is answered ok.
    func validatedHello(_ message: CefRemoteMessage) throws -> HelloParameters {
        let root = message.string(CefRemote.Key.rootPath)
        guard root.hasPrefix("/") else { throw ServiceError(text: "the root cache path must be absolute") }
        // CEF refuses a root with an alias in it (`/var` for `/private/var`, a symlink), so the host sends the canonical one, and
        // anything else is refused here, before CEF starts, with a reason that names the cause.
        guard CefRemoteRoot.resolve(root) == root else {
            throw ServiceError(text: "the root cache path must exist and be canonical (no symlink or alias in it)")
        }
        // The root is below a folder WSurf itself uses (the application support folder, the temporary folder): see CefRemoteRoot.
        guard CefRemoteRoot.isAllowed(root, bases: CefRemoteRoot.bases()) else {
            throw ServiceError(text: "the root cache path must be below WSurf's own application support or temporary folder")
        }
        // The service holds the same line as WSurf's client, for a hello that did not come from it. A switch is WSurf's own
        // (name and value, `CefRemoteSwitches`) or it is not there.
        let switches = message.strings(CefRemote.Key.switches)
        let refusedSwitches = CefRemoteSwitches.refused(wire: switches)
        guard refusedSwitches.isEmpty else {
            throw ServiceError(text: "switches that are not WSurf's own are refused: \(refusedSwitches.joined(separator: ", "))")
        }
        guard let log = Self.checkedLogFile(message.string(CefRemote.Key.logFile), root: root) else {
            throw ServiceError(text: "the log file must be /dev/null, or the staged run's chromium-service.log (in the root or beside it)")
        }
        let cache = message.string(CefRemote.Key.cachePath)
        // The resolved path is the one CEF gets (review L1): what was checked is what is used.
        let resolvedCache = cache.isEmpty ? nil : Self.resolvedInside(cache, root: root)
        guard cache.isEmpty || resolvedCache != nil else {
            throw ServiceError(text: "the cache path must be the root cache path or inside it")
        }
        let parameters = HelloParameters(root: root, cache: resolvedCache, switches: switches, logFile: log)
        if let accepted = acceptedHello, accepted != parameters {
            throw ServiceError(text: "a second hello must ask for what the first one did: the service is already started with another root, cache, switches or log file")
        }
        return parameters
    }

    /// Starts CEF from an accepted hello's parameters; a no-op when it is up (the parameters then equal the ones it started with).
    func startCEF(_ parameters: HelloParameters) throws {
        guard !CefRuntime.shared.isInitialized else { return }
        let started = Clock.nowNanoseconds
        // The framework and the helpers are the service's own copies (`Tools/embed-chromium.sh`): Chromium's sandbox lets a
        // child read only inside the browser process's main bundle, which here is the .xpc.
        let bundle = Bundle.main.bundleURL
        let frameworks = bundle.appendingPathComponent("Contents/Frameworks", isDirectory: true)
        var configuration = CefConfiguration()
        configuration.noSandbox = false
        // Until the owner picks a "Chromium Safe Storage" option (D4-S), the service never reads the keychain: a profile with
        // cookies encrypted under the real key would lose them, and a new code identity would raise a keychain prompt.
        configuration.safeStorage = .mockKeychain
        configuration.rootCachePath = URL(filePath: parameters.root, directoryHint: .isDirectory)
        configuration.cachePath = parameters.cache.map { URL(filePath: $0, directoryHint: .isDirectory) }
        configuration.persistSessionCookies = true
        configuration.defaultRuntimeStyle = .alloy
        // CEF's log goes to /dev/null unless WSurf names a file (a staged run), and `checkedLogFile` allowed it.
        logFile = parameters.logFile
        configuration.logFile = URL(filePath: logFile)
        configuration.logSeverity = logFile == "/dev/null" ? .error : .warning
        configuration.extraCommandLineSwitches = parameters.switches.mapValues { $0.isEmpty ? nil : $0 }
        configuration.windowlessRenderingEnabled = true
        configuration.frameworkDirectory = frameworks.appendingPathComponent("Chromium Embedded Framework.framework", isDirectory: true)
        configuration.browserSubprocessPath = frameworks.appendingPathComponent("WSurf Helper.app/Contents/MacOS/WSurf Helper")
        configuration.mainBundlePath = bundle
        try CefRuntime.shared.initialize(configuration: configuration)
        CEFApplication.setTerminateHandler(nil)
        acceptedHello = parameters
        cefStartMs = Double(Clock.nowNanoseconds &- started) / 1e6
        note(String(format: "CEF started in %.1f ms", cefStartMs))
    }

    /// `path` resolved (folders that do not exist yet included) when it is `root` (canonical) or below it, as CEF requires of a cache
    /// path; nil otherwise. Nothing is created here: the caller makes the folder, by the path this returns, only after it says yes.
    static func resolvedInside(_ path: String, root: String) -> String? {
        guard let resolved = CefRemoteRoot.resolve(path) else { return nil }
        return resolved == root || resolved.hasPrefix(root.hasSuffix("/") ? root : root + "/") ? resolved : nil
    }

    /// The log file CEF may write, for the hello's `named` one.
    ///
    /// - None named, or `/dev/null`: `/dev/null`.
    /// - Otherwise the name must have the staged run's shape, in a service with the DEBUG ops as in one without: `chromium-service.log`
    ///   in the root, or beside it when that folder is also below a base (a staged run's log is in its home, which holds the root).
    ///   The folder is resolved, and the file, when it exists, must be a regular file with one link only: CEF appends to it, and a
    ///   symlink or a hard link would let that write reach a file the name does not suggest. Anything else is nil, which refuses
    ///   the hello.
    /// - A shape that passes is written only by a service with the DEBUG ops (the OOP lane, a staged DEBUG ad hoc build). A service
    ///   without them (a signed one) writes no log at all, and the hello is not refused for it: a staged DEBUG client always names
    ///   its own file, and the service answers by keeping `/dev/null` (the file is never made, so no URL lands in it).
    ///
    /// The checks are made at the moment of the call (see `CefRemoteRoot.resolve` for what that does and does not guarantee).
    static func checkedLogFile(_ named: String, root: String) -> String? {
        guard !named.isEmpty, named != "/dev/null" else { return "/dev/null" }
        let directory = (named as NSString).deletingLastPathComponent
        guard named.hasPrefix("/"), (named as NSString).lastPathComponent == CefRemoteSwitches.logFileName,
              let resolvedDirectory = CefRemoteRoot.resolve(directory)
        else { return nil }
        var info = stat()
        if lstat(named, &info) == 0, (info.st_mode & S_IFMT) != S_IFREG || info.st_nlink > 1 {
            return nil
        }
        let resolved = (resolvedDirectory as NSString).appendingPathComponent(CefRemoteSwitches.logFileName)
        let bases = CefRemoteRoot.bases()
        let candidates = CefRemoteSwitches.logFileCandidates(root: root).filter { candidate in
            CefRemoteRoot.isAllowed((candidate as NSString).deletingLastPathComponent, bases: bases)
        }
        guard candidates.contains(resolved) else { return nil }
        #if WSURF_SERVICE_DEBUG_OPS
        return resolved
        #else
        note("a log file was named and is not written: this service has no debug ops")
        return "/dev/null"
        #endif
    }
}
