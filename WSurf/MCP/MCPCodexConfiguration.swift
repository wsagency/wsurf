// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Darwin
import Foundation

nonisolated enum MCPCodexConfiguration {
    private static func withStagedConfiguration<T>(_ original: Data?, body: (URL) throws -> T) throws -> T {
        let directory = FileManager.default.temporaryDirectory.appending(path: "wsurf-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = directory.appending(path: "config.toml")
        if let original {
            try MCPConfigurationFile.writePrivate(original, to: configuration)
        }
        return try body(directory)
    }

    static func installation(
        in original: Data?, executable: URL, command: String, arguments: [String] = MCPClientConfiguration.arguments
    ) throws -> MCPClientInstallation {
        guard original != nil else { return .absent }
        return try withStagedConfiguration(original) { directory in
            let entries = try servers(executable: executable, directory: directory)
            guard let existing = entries.first(where: { $0["name"] as? String == "wsurf" }) else { return .absent }
            guard let transport = existing["transport"] as? [String: Any],
                  MCPClientConfiguration.matches(transport, command: command, arguments: arguments) else { throw MCPClientSetupError.conflictingServer }
            return .installed(token: MCPClientConfiguration.token(in: transport))
        }
    }

    /// Adds the `wsurf` server, or with a token sets only its `WSURF_MCP_TOKEN` variable. Returns nil when nothing
    /// needs to change.
    static func adding(
        to original: Data?, executable: URL, command: String,
        arguments: [String] = MCPClientConfiguration.arguments, token: String? = nil
    ) throws -> Data? {
        try withStagedConfiguration(original) { directory in
            try addInStagingDirectory(directory, executable: executable, command: command, arguments: arguments, token: token)
        }
    }

    private static func addInStagingDirectory(
        _ directory: URL, executable: URL, command: String, arguments: [String], token: String?
    ) throws -> Data? {
        let configuration = directory.appending(path: "config.toml")
        let before = try servers(executable: executable, directory: directory)
        let existing = before.first(where: { $0["name"] as? String == "wsurf" })
        if let existing {
            guard let transport = existing["transport"] as? [String: Any],
                  MCPClientConfiguration.matches(transport, command: command, arguments: arguments) else { throw MCPClientSetupError.conflictingServer }
            guard token != nil else { return nil }
        } else {
            _ = try run(executable, arguments: ["mcp", "add", "wsurf", "--", command] + arguments, directory: directory)
        }
        if let token {
            // The token goes into the staged file, not onto the codex command line where `ps` would show it.
            guard let text = try MCPConfigurationFile(url: configuration).original.flatMap({ String(data: $0, encoding: .utf8) }) else {
                throw MCPClientSetupError.commandFailed
            }
            try Data(settingToken(token, in: text).utf8).write(to: configuration, options: .atomic)
        }
        let after = try servers(executable: executable, directory: directory)
        guard let installed = after.first(where: { $0["name"] as? String == "wsurf" }),
              let transport = installed["transport"] as? [String: Any],
              MCPClientConfiguration.matches(transport, command: command, arguments: arguments),
              MCPClientConfiguration.token(in: transport) == token,
              NSDictionary(dictionary: indexed(before.filter { $0["name"] as? String != "wsurf" }))
                  .isEqual(to: indexed(after.filter { $0["name"] as? String != "wsurf" })),
              existing.map({ withoutToken($0) == withoutToken(installed) }) ?? true
        else {
            throw MCPClientSetupError.commandFailed
        }
        return try MCPConfigurationFile(url: configuration).original
    }

    /// `toml` with `WSURF_MCP_TOKEN` set in the `[mcp_servers.wsurf.env]` table. Only that one value changes: the codex
    /// CLI then parses the result, and the caller keeps it only if every other server and setting is unchanged.
    static func settingToken(_ token: String, in toml: String) -> String {
        let table = "[mcp_servers.wsurf.env]"
        let assignment = "\(MCPPairing.environmentName) = \"\(token)\""
        var lines = toml.components(separatedBy: "\n")
        guard let header = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == table }) else {
            if lines.last == "" { lines.removeLast() }
            lines += ["", table, assignment, ""]
            return lines.joined(separator: "\n")
        }
        let end = lines[(header + 1)...].firstIndex { $0.trimmingCharacters(in: .whitespaces).hasPrefix("[") } ?? lines.endIndex
        if let existing = lines[(header + 1)..<end].firstIndex(where: {
            let line = $0.trimmingCharacters(in: .whitespaces)
            return line.hasPrefix(MCPPairing.environmentName)
                && line.dropFirst(MCPPairing.environmentName.count).trimmingCharacters(in: .whitespaces).hasPrefix("=")
        }) {
            lines[existing] = assignment
        } else {
            lines.insert(assignment, at: header + 1)
        }
        return lines.joined(separator: "\n")
    }

    /// The server entry as `codex mcp list --json` reports it, minus the pairing variable.
    private static func withoutToken(_ entry: [String: Any]) -> NSDictionary {
        var entry = entry
        if var transport = entry["transport"] as? [String: Any] {
            // `env` is null or absent when empty; compare both as absent.
            var environment = transport["env"] as? [String: Any] ?? [:]
            environment.removeValue(forKey: MCPPairing.environmentName)
            transport["env"] = environment.isEmpty ? nil : environment
            entry["transport"] = transport
        }
        return NSDictionary(dictionary: entry)
    }

    private static func indexed(_ entries: [[String: Any]]) -> [String: Any] {
        var result: [String: Any] = [:]
        for entry in entries {
            if let name = entry["name"] as? String { result[name] = entry }
        }
        return result
    }

    private static func servers(executable: URL, directory: URL) throws -> [[String: Any]] {
        let data = try run(executable, arguments: ["mcp", "list", "--json"], directory: directory)
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw MCPClientSetupError.commandFailed
        }
        return entries
    }

    private static func run(_ executable: URL, arguments: [String], directory: URL) throws -> Data {
        let output = directory.appending(path: "output-\(UUID().uuidString)")
        try MCPConfigurationFile.writePrivate(Data(), to: output)
        let handle = try FileHandle(forWritingTo: output)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = directory
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = directory.path
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = handle
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while process.isRunning {
            if ContinuousClock.now >= deadline || Task.isCancelled {
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
                throw MCPClientSetupError.commandFailed
            }
            usleep(10_000)
        }
        guard process.terminationStatus == 0 else { throw MCPClientSetupError.commandFailed }
        return try MCPConfigurationFile(url: output).original ?? Data()
    }
}
