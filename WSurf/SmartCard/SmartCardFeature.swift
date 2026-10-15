// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Observation

/// Whether the CryptoTokenKit extension is registered with the OS.
/// Registration is not the same as the user having allowed it in System Settings.
enum CTKStatus: Equatable {
    case registered
    case notInstalled
    case unknown
}

/// Runs `pluginkit -m -p com.apple.ctk-tokens`; nil when the tool failed.
typealias PluginKitRunner = @Sendable () async -> String?

@MainActor
@Observable
final class SmartCardFeature {
#if DEBUG
    static let shared = SmartCardFeature(defaults: StageMode.defaults)
#else
    static let shared = SmartCardFeature()
#endif

    nonisolated static let tokenIdentifier = "io.wsagency.smartcard.ctk"
    nonisolated static let systemSettingsURL = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension")!

    // Machine-wide on purpose: one card reader and one CTK extension serve every
    // profile, so a per-profile switch could not honestly enable or disable them.
    private static let enabledKey = "smartcard.enabled"

    private(set) var enabled: Bool
    private(set) var loaded = false
    // Runtime-only: set by an explicit Unload so nothing reloads until the user says so.
    private(set) var manuallyUnloaded = false
    private(set) var ctkStatus: CTKStatus = .unknown
    private(set) var isCheckingCTK = false

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let runPluginKit: PluginKitRunner

    var isActive: Bool {
        enabled && loaded && !manuallyUnloaded
    }

    init(
        defaults: UserDefaults = .standard,
        runPluginKit: @escaping PluginKitRunner = { await SmartCardFeature.runSystemPluginKit() }
    ) {
        self.defaults = defaults
        self.runPluginKit = runPluginKit
        enabled = defaults.bool(forKey: Self.enabledKey)
    }

    func enable() {
        enabled = true
        defaults.set(true, forKey: Self.enabledKey)
        load()
    }

    func disable() {
        enabled = false
        defaults.set(false, forKey: Self.enabledKey)
        loaded = false
        manuallyUnloaded = false
    }

    /// Explicit user action; the only way out of the manually-unloaded state.
    func load() {
        guard enabled else { return }
        loaded = true
        manuallyUnloaded = false
    }

    func unload() {
        loaded = false
        manuallyUnloaded = true
    }

    /// The only automatic load path. Runtime state starts cleared on every launch.
    func appDidStart() {
        guard enabled, !manuallyUnloaded else { return }
        loaded = true
    }

    // MARK: - CryptoTokenKit extension (OS-managed, read-only)

    func refreshCTKStatus() async {
        isCheckingCTK = true
        let output = await runPluginKit()
        ctkStatus = output.map(Self.ctkStatus(fromPluginKit:)) ?? .unknown
        isCheckingCTK = false
    }

    func openSystemSettings() {
        NSWorkspace.shared.open(Self.systemSettingsURL)
    }

    /// Lines look like `+    io.example.token(1.0)<TAB>UUID<TAB>date<TAB>/path`.
    /// A listing that names other plugins, or says "(no matches)", proves ours is absent;
    /// anything else is not pluginkit output, so the answer is unknown.
    nonisolated static func ctkStatus(fromPluginKit output: String) -> CTKStatus {
        var sawEntry = false
        for line in output.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "(no matches)" {
                sawEntry = true
                continue
            }
            let token = trimmed.drop { "+-!?=~".contains($0) }
                .trimmingCharacters(in: .whitespaces)
                .split(whereSeparator: \.isWhitespace).first
            guard let token, token.hasSuffix(")"), let open = token.firstIndex(of: "(") else { continue }
            sawEntry = true
            if token[..<open] == tokenIdentifier {
                return .registered
            }
        }
        return sawEntry ? .notInstalled : .unknown
    }

    nonisolated static func runSystemPluginKit() async -> String? {
        await Task.detached {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(filePath: "/usr/bin/pluginkit")
            process.arguments = ["-m", "-p", "com.apple.ctk-tokens"]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        }.value
    }
}
