// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Darwin
import Foundation
import Testing

@testable import WSurf

@MainActor
struct MCPClientInstallerTests {
    private let command = "/Applications/WSurf Browser.app/Contents/MacOS/WSurf"

    @Test func savedInstallationStatusIsReadWithoutChangingTheConfiguration() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "config.json")
        let installer = MCPClientInstaller()
        #expect(try await !installer.isInstalled(target(url), command: command))
        #expect(!FileManager.default.fileExists(atPath: url.path))
        let original = Data("{}".utf8)
        try original.write(to: url)
        #expect(try await !installer.isInstalled(target(url), command: command))
        #expect(try Data(contentsOf: url) == original)
        _ = try await installer.install(target(url), command: command)
        let installed = try Data(contentsOf: url)
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(try await MCPClientInstaller().isInstalled(target(url), command: command))
        #expect(try Data(contentsOf: url) == installed)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == files)
        try original.write(to: url)
        #expect(try await !installer.isInstalled(target(url), command: command))
    }

    @Test func standardLocationsAndCodexHomeOverride() {
        let home = URL(fileURLWithPath: "/Users/test")
        #expect(MCPClientKind.codex.configurationURL(home: home, environment: [:]).path == "/Users/test/.codex/config.toml")
        #expect(MCPClientKind.codex.configurationURL(home: home, environment: ["CODEX_HOME": "/work/profile"]).path == "/work/profile/config.toml")
        #expect(MCPClientKind.codex.configurationURL(home: home, environment: ["CODEX_HOME": "relative"]).path == "/Users/test/.codex/config.toml")
        #expect(MCPClientKind.claudeDesktop.configurationURL(home: home, environment: [:]).path == "/Users/test/Library/Application Support/Claude/claude_desktop_config.json")
        #expect(MCPClientKind.claudeCode.configurationURL(home: home, environment: [:]).path == "/Users/test/.claude.json")
        #expect(MCPClientKind.cursor.configurationURL(home: home, environment: [:]).path == "/Users/test/.cursor/mcp.json")
        #expect(MCPClientKind.omp.configurationURL(home: home, environment: [:]).path == "/Users/test/.omp/agent/mcp.json")
    }

    @Test(arguments: ["Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex", "Contents/Resources/codex"])
    func bundledCodexCLIIsDetectedWithoutShellPath(relativePath: String) throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let application = directory.appending(path: "ChatGPT.app")
        let executable = application.appending(path: relativePath)
        try FileManager.default.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: executable.path)
        #expect(MCPClientDiscovery.bundledCodexExecutable(in: [application]) == nil)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        #expect(MCPClientDiscovery.bundledCodexExecutable(in: [application]) == executable)
    }

    @Test(arguments: [MCPClientKind.claudeDesktop, .claudeCode, .cursor, .omp])
    func JSONMergePreservesOtherServersAndPrivateClientState(kind: MCPClientKind) throws {
        let source = Data(#"""
            {"theme":"dark","oauth":{"token":"fixture-secret"},
             "projects":{"/repo":{"mcpServers":{"wsurf":{"command":"project-specific"}}}},
             "mcpServers":{"other":{"command":"/bin/test","env":{"TOKEN":"fixture"}}}}
            """#.utf8)
        let merged = try MCPClientConfiguration.addingJSON(to: source, kind: kind, command: command)
        let result = try #require(merged)
        var root = try object(result)
        var servers = try #require(root["mcpServers"] as? [String: Any])
        let wsurf = try #require(servers.removeValue(forKey: "wsurf") as? [String: Any])
        #expect(wsurf["command"] as? String == command)
        #expect(wsurf["args"] as? [String] == ["--mcp"])
        #expect(wsurf["type"] as? String == (kind == .claudeCode ? "stdio" : nil))
        root["mcpServers"] = servers
        #expect(NSDictionary(dictionary: root).isEqual(to: try object(source)))
    }

    @Test(arguments: [MCPClientKind.cursor, .omp])
    func duplicateEntryPreservesDisabledStateAndCustomPermissionsByteForByte(kind: MCPClientKind) throws {
        let root: [String: Any] = [
            "disabledServers": ["wsurf"],
            "mcpServers": ["wsurf": [
                "command": command, "args": ["--mcp"], "disabled": true, "enabled": false, "autoApprove": [], "env": ["A": "B"],
            ], ],
        ]
        let data = try JSONSerialization.data(withJSONObject: root)
        #expect(try MCPClientConfiguration.addingJSON(to: data, kind: kind, command: command) == nil)
    }

    @Test func stageInstallationUsesItsSocketAndRejectsAnEntryPointingAtAnotherStage() throws {
        let stageSocket = "/tmp/wsurf-mcp-501-0123456789abcdef0123456789abcdef/browser.sock"
        let otherStageSocket = "/tmp/wsurf-mcp-501-fedcba9876543210fedcba9876543210/browser.sock"
        let stageArguments = ["--mcp", "--mcp-socket", stageSocket]
        let installedData = try MCPClientConfiguration.addingJSON(
            to: nil,
            kind: .claudeDesktop,
            command: command,
            arguments: stageArguments
        )
        let installed = try #require(installedData)
        let installedRoot = try object(installed)
        let installedEntry = try #require((installedRoot["mcpServers"] as? [String: Any])?["wsurf"] as? [String: Any])
        #expect(installedEntry["args"] as? [String] == stageArguments)
        #expect(MCPClientConfiguration.matches(installedEntry, command: command, arguments: stageArguments))

        let otherStageEntry = MCPClientConfiguration.entry(
            command: command,
            kind: .claudeDesktop,
            arguments: ["--mcp", "--mcp-socket", otherStageSocket]
        )
        #expect(!MCPClientConfiguration.matches(otherStageEntry, command: command, arguments: stageArguments))

        let source = try JSONSerialization.data(withJSONObject: ["mcpServers": ["wsurf": otherStageEntry]])
        #expect(throws: MCPClientSetupError.conflictingServer) {
            try MCPClientConfiguration.addingJSON(
                to: source,
                kind: .claudeDesktop,
                command: command,
                arguments: stageArguments
            )
        }
    }

    @Test(arguments: [#"{"mcpServers":{"wsurf":{"command":"/other","args":["--mcp"]}}}"#,
                      #"{"mcpServers":{"wsurf":{"url":"https://example.test"}}}"#,
                      #"{"mcpServers":{"wsurf":null}}"#, ])
    func conflictingEntryIsNeverReplaced(source: String) {
        #expect(throws: MCPClientSetupError.conflictingServer) {
            try MCPClientConfiguration.addingJSON(to: Data(source.utf8), kind: .claudeDesktop, command: command)
        }
    }

    @Test(arguments: ["", "{ broken", "[]", #"{"mcpServers":[]}"#, #"{"mcpServers":null}"#, "{ // comment\n}"])
    func malformedOrUnsupportedJSONIsNeverRewritten(source: String) {
        #expect(throws: MCPClientSetupError.invalidConfiguration) {
            try MCPClientConfiguration.addingJSON(to: Data(source.utf8), kind: .cursor, command: command)
        }
    }

    @Test func newConfigurationCreatesPrivateDirectoriesAndFile() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "new-profile/config.json")
        let result = try await MCPClientInstaller().install(target(url), command: command)
        #expect(!result.alreadyPresent)
        #expect(result.backupURL == nil)
        #expect(try permissions(url) == 0o600)
        #expect(try permissions(url.deletingLastPathComponent()) == 0o700)
        let installed = try object(Data(contentsOf: url))
        let servers = try #require(installed["mcpServers"] as? [String: Any])
        #expect(servers.count == 1)
    }

    @Test func existingConfigurationHasPrivateExactBackupAndIdempotentReinstall() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "config.json")
        let source = Data("{  \"theme\": \"dark\" }\n".utf8)
        try source.write(to: url)
        let installer = MCPClientInstaller()
        let result = try await installer.install(target(url), command: command)
        let backup = try #require(result.backupURL)
        #expect(try Data(contentsOf: backup) == source)
        #expect(try permissions(backup) == 0o600)
        let installed = try Data(contentsOf: url)
        let repeated = try await installer.install(target(url), command: command)
        #expect(repeated.alreadyPresent)
        #expect(repeated.backupURL == nil)
        #expect(try Data(contentsOf: url) == installed)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 2)
    }

    @Test func concurrentClientSaveIsDetectedBeforeCommit() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "config.json")
        try Data("{}".utf8).write(to: url)
        let snapshot = try MCPConfigurationFile(url: url)
        let external = Data(#"{"clientSaved":true}"#.utf8)
        try external.write(to: url, options: .atomic)
        #expect(throws: MCPClientSetupError.changedFile) { try snapshot.commit(Data("{}".utf8)) }
        #expect(try Data(contentsOf: url) == external)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["config.json"])
    }

    @Test func newlyCreatedConfigCannotBeOverwrittenByAnEarlierMissingSnapshot() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "config.json")
        let snapshot = try MCPConfigurationFile(url: url)
        let external = Data(#"{"clientSaved":true}"#.utf8)
        try external.write(to: url)
        #expect(throws: MCPClientSetupError.changedFile) { try snapshot.commit(Data("{}".utf8)) }
        #expect(try Data(contentsOf: url) == external)
    }

    @Test func symlinksDirectoriesAndHardLinksAreRejected() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appending(path: "real.json")
        let linked = directory.appending(path: "linked.json")
        try Data("{}".utf8).write(to: source)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: source)
        #expect(throws: MCPClientSetupError.unsafeFile) { try MCPConfigurationFile(url: linked) }
        #expect(throws: MCPClientSetupError.unsafeFile) { try MCPConfigurationFile(url: directory) }
        try FileManager.default.removeItem(at: linked)
        try FileManager.default.linkItem(at: source, to: linked)
        #expect(throws: MCPClientSetupError.unsafeFile) { try MCPConfigurationFile(url: linked) }
    }

    @Test func replacingTheConfigWithALinkDuringPreparationIsRejected() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "config.json")
        let other = directory.appending(path: "other.json")
        try Data("{}".utf8).write(to: url)
        try Data("{}".utf8).write(to: other)
        let snapshot = try MCPConfigurationFile(url: url)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: other)
        #expect(throws: MCPClientSetupError.unsafeFile) { try snapshot.commit(Data("updated".utf8)) }
        #expect(try Data(contentsOf: other) == Data("{}".utf8))
    }

    @Test func failedCodexCommandLeavesLiveConfigUntouched() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "config.toml")
        let original = Data("# private\nmodel = \"test\"\n".utf8)
        try original.write(to: url)
        let destination = MCPClientTarget(kind: .codex, configurationURL: url, codexExecutable: URL(fileURLWithPath: "/usr/bin/false"), isDetected: true)
        await #expect(throws: MCPClientSetupError.commandFailed) {
            try await MCPClientInstaller().install(destination, command: command)
        }
        #expect(try Data(contentsOf: url) == original)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["config.toml"])
    }

    private nonisolated static var installedCodex: URL? {
        MCPClientDiscovery.codexExecutable(
            home: FileManager.default.homeDirectoryForCurrentUser,
            environment: ProcessInfo.processInfo.environment,
            applications: [URL(fileURLWithPath: "/Applications/ChatGPT.app"), URL(fileURLWithPath: "/Applications/Codex.app")]
        )
    }

    @Test(.enabled(if: installedCodex != nil))
    func installedCodexCLIPreservesTOMLCommentsOtherServersAndPermissions() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "config.toml")
        let original = Data("# Keep this comment\nmodel = \"test\"\n[mcp_servers.\"other.server\"]\ncommand = \"/bin/true\"\nenabled = false\n".utf8)
        try original.write(to: url)
        let destination = MCPClientTarget(kind: .codex, configurationURL: url,
                                          codexExecutable: try #require(Self.installedCodex), isDetected: true)
        let installer = MCPClientInstaller()
        #expect(try await !installer.isInstalled(destination, command: command))
        let result = try await installer.install(destination, command: command)
        let installed = try String(contentsOf: url, encoding: .utf8)
        #expect(installed.contains("# Keep this comment"))
        #expect(installed.contains("[mcp_servers.\"other.server\"]"))
        #expect(installed.contains("enabled = false"))
        #expect(installed.contains("[mcp_servers.wsurf]"))
        #expect(installed.contains(command))
        #expect(try await MCPClientInstaller().isInstalled(destination, command: command))
        let backup = try #require(result.backupURL)
        #expect(try Data(contentsOf: backup) == original)
        #expect(try await installer.install(destination, command: command).alreadyPresent)
        #expect(try String(contentsOf: url, encoding: .utf8) == installed)
    }

    private func object(_ data: Data) throws -> [String: Any] {
        let decoded = try JSONSerialization.jsonObject(with: data)
        return try #require(decoded as? [String: Any])
    }

    private func target(_ url: URL) -> MCPClientTarget {
        MCPClientTarget(kind: .claudeDesktop, configurationURL: url, codexExecutable: nil, isDetected: true)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "wsurf-installer-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return url
    }

    private func permissions(_ url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.posixPermissions] as? NSNumber).intValue & 0o777
    }
}
