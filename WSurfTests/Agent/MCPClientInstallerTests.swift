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

    // MARK: Pairing

    @Test(arguments: [MCPClientKind.claudeDesktop, .claudeCode, .cursor, .omp])
    func installerWritesTheTokenIntoEachJSONClientFormat(kind: MCPClientKind) throws {
        let merged = try #require(try MCPClientConfiguration.addingJSON(
            to: Data(#"{"mcpServers":{"other":{"command":"/bin/test"}}}"#.utf8), kind: kind, command: command, token: SyntheticToken.first
        ))
        let servers = try #require(try object(merged)["mcpServers"] as? [String: Any])
        let entry = try #require(servers["wsurf"] as? [String: Any])
        #expect(entry["env"] as? [String: String] == [MCPPairing.environmentName: SyntheticToken.first])
        #expect(entry["args"] as? [String] == ["--mcp"])
        #expect(entry["type"] as? String == (kind == .claudeCode ? "stdio" : nil))
        #expect(servers["other"] != nil)
        #expect(try MCPClientConfiguration.installation(in: merged, command: command) == .installed(token: SyntheticToken.first))
    }

    @Test func anEntryWithoutATokenIsInstalledButUnpaired() throws {
        let unpaired = try #require(try MCPClientConfiguration.addingJSON(to: nil, kind: .cursor, command: command))
        #expect(try MCPClientConfiguration.installation(in: unpaired, command: command) == .installed(token: nil))
        #expect(try MCPClientConfiguration.installation(in: nil, command: command) == .absent)
        #expect(try MCPClientConfiguration.installation(in: Data("{}".utf8), command: command) == .absent)
    }

    @Test func existingUnpairedEntriesAreRecognizedAndNotOverwrittenWithoutPair() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory.path) }
        let url = directory.appending(path: "config.json")
        let source = Data(#"{"mcpServers":{"wsurf":{"command":"\#(command)","args":["--mcp"],"disabled":true}}}"#.utf8)
        try source.write(to: url)
        let installer = MCPClientInstaller()
        #expect(try await installer.installation(target(url), command: command) == .installed(token: nil))
        let result = try await installer.install(target(url), command: command)
        #expect(result.alreadyPresent)
        #expect(try Data(contentsOf: url) == source)
    }

    @Test func pairingAnExistingEntryAddsOnlyTheTokenAndKeepsABackup() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory.path) }
        let url = directory.appending(path: "config.json")
        let source = Data(#"""
            {"theme":"dark","mcpServers":{"other":{"command":"/bin/test"},
             "wsurf":{"command":"\#(command)","args":["--mcp"],"disabled":true,"autoApprove":[],"env":{"A":"B"}}}}
            """#.utf8)
        try source.write(to: url)
        let trust = MCPTrustStore(storage: MemoryTrustStorage())
        let installer = MCPClientInstaller()

        let paired = try await installer.pair(target(url), command: command, trustStore: trust)

        #expect(try Data(contentsOf: #require(paired.backupURL)) == source)
        guard case .installed(let token?) = try await installer.installation(target(url), command: command) else {
            Issue.record("The entry should carry a token.")
            return
        }
        #expect(trust.client(forToken: token)?.id == paired.client.id)
        var expected = try object(source)
        var servers = try #require(expected["mcpServers"] as? [String: Any])
        var entry = try #require(servers["wsurf"] as? [String: Any])
        entry["env"] = ["A": "B", MCPPairing.environmentName: token]
        servers["wsurf"] = entry
        expected["mcpServers"] = servers
        #expect(NSDictionary(dictionary: try object(Data(contentsOf: url))).isEqual(to: expected))
        #expect(paired.client.name == "Claude Desktop")
    }

    @Test func rePairRotatesTheTokenInTheConfigurationAndTheStore() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory.path) }
        let url = directory.appending(path: "config.json")
        let trust = MCPTrustStore(storage: MemoryTrustStorage())
        let installer = MCPClientInstaller()
        let first = try await installer.pair(target(url), command: command, trustStore: trust)
        guard case .installed(let oldToken?) = try await installer.installation(target(url), command: command) else {
            Issue.record("The first pairing should write a token.")
            return
        }
        #expect(first.backupURL == nil)

        let second = try await installer.pair(target(url), command: command, trustStore: trust)

        guard case .installed(let newToken?) = try await installer.installation(target(url), command: command) else {
            Issue.record("The second pairing should write a token.")
            return
        }
        #expect(newToken != oldToken)
        #expect(second.client.id == first.client.id)
        #expect(trust.clients.count == 1)
        #expect(trust.client(forToken: oldToken) == nil)
        #expect(trust.client(forToken: newToken)?.id == first.client.id)
        #expect(try Data(contentsOf: url).range(of: Data(oldToken.utf8)) == nil)
    }

    @Test func aRevokedOrUnknownTokenInAnEntryPairsAsANewClient() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory.path) }
        let url = directory.appending(path: "config.json")
        let trust = MCPTrustStore(storage: MemoryTrustStorage())
        let installer = MCPClientInstaller()
        let first = try await installer.pair(target(url), command: command, trustStore: trust)
        try trust.revoke(first.client.id)
        let second = try await installer.pair(target(url), command: command, trustStore: trust)
        #expect(second.client.id != first.client.id)
        #expect(trust.clients.map(\.id) == [second.client.id])
    }

    @Test func trustStoreUnavailableDisablesPairingAndSaysSo() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory.path) }
        let url = directory.appending(path: "config.json")
        let source = Data("{ \"theme\": \"dark\" }\n".utf8)
        try source.write(to: url)
        let trust = MCPTrustStore(storage: nil)
        await #expect(throws: MCPClientSetupError.pairingUnavailable) {
            try await MCPClientInstaller().pair(target(url), command: command, trustStore: trust)
        }
        #expect(try Data(contentsOf: url) == source)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["config.json"])
        let message = try #require(MCPClientSetupError.pairingUnavailable.errorDescription)
        #expect(message.contains("Pairing isn’t available"))
        // Setup without pairing still works, as it did before.
        let result = try await MCPClientInstaller().install(target(url), command: command)
        #expect(!result.alreadyPresent)
        #expect(try MCPClientConfiguration.installation(in: Data(contentsOf: url), command: command) == .installed(token: nil))
    }

    @Test func aFailedPairingSaveIsReportedAfterTheConfigurationWasWritten() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory.path) }
        let url = directory.appending(path: "config.json")
        let storage = MemoryTrustStorage()
        let trust = MCPTrustStore(storage: storage)
        trust.loadIfNeeded()
        storage.refuseWrites()
        await #expect(throws: MCPClientSetupError.pairingFailed) {
            try await MCPClientInstaller().pair(target(url), command: command, trustStore: trust)
        }
        #expect(trust.clients.isEmpty)
        // The entry exists with a token no record knows, which is the same as unpaired.
        guard case .installed(let token?) = try await MCPClientInstaller().installation(target(url), command: command) else {
            Issue.record("The entry should exist.")
            return
        }
        #expect(trust.client(forToken: token) == nil)
    }

    @Test(arguments: [#"{"mcpServers":{"wsurf":{"command":"/other","args":["--mcp"]}}}"#,
                      #"{"mcpServers":{"wsurf":{"url":"https://example.test"}}}"#,
                      #"{"mcpServers":{"wsurf":null}}"#, ])
    func pairingNeverReplacesAConflictingEntry(source: String) {
        #expect(throws: MCPClientSetupError.conflictingServer) {
            try MCPClientConfiguration.addingJSON(to: Data(source.utf8), kind: .claudeDesktop, command: command, token: SyntheticToken.first)
        }
    }

    @Test func pairingNeverReplacesAnEnvironmentThatIsNotAnObject() throws {
        let source = Data(#"{"mcpServers":{"wsurf":{"command":"\#(command)","args":["--mcp"],"env":["A"]}}}"#.utf8)
        #expect(throws: MCPClientSetupError.conflictingServer) {
            try MCPClientConfiguration.addingJSON(to: source, kind: .cursor, command: command, token: SyntheticToken.first)
        }
    }

    @Test func settingTheCodexTokenChangesOnlyThatLine() {
        let token = MCPPairing.environmentName
        let assignment = "\(token) = \"\(SyntheticToken.first)\""
        let bare = "# keep\nmodel = \"x\"\n[mcp_servers.wsurf]\ncommand = \"c\"\n"
        #expect(MCPCodexConfiguration.settingToken(SyntheticToken.first, in: bare)
            == bare + "\n[mcp_servers.wsurf.env]\n\(assignment)\n")
        #expect(MCPCodexConfiguration.settingToken(SyntheticToken.first, in: "model = \"x\"")
            == "model = \"x\"\n\n[mcp_servers.wsurf.env]\n\(assignment)\n")
        let existing = "[mcp_servers.wsurf.env]\nOTHER = \"1\"\n\(token) = \"old\"\n[mcp_servers.next]\ncommand = \"n\"\n"
        #expect(MCPCodexConfiguration.settingToken(SyntheticToken.first, in: existing)
            == "[mcp_servers.wsurf.env]\nOTHER = \"1\"\n\(assignment)\n[mcp_servers.next]\ncommand = \"n\"\n")
        let withoutKey = "[mcp_servers.wsurf.env]\nOTHER = \"1\"\n"
        #expect(MCPCodexConfiguration.settingToken(SyntheticToken.first, in: withoutKey)
            == "[mcp_servers.wsurf.env]\n\(assignment)\nOTHER = \"1\"\n")
        let lookalike = "[mcp_servers.wsurf.env]\n\(token)_OTHER = \"1\"\n"
        #expect(MCPCodexConfiguration.settingToken(SyntheticToken.first, in: lookalike)
            == "[mcp_servers.wsurf.env]\n\(assignment)\n\(token)_OTHER = \"1\"\n")
    }

    @Test(.enabled(if: installedCodex != nil))
    func installerWritesTheTokenIntoTheCodexConfiguration() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory.path) }
        let url = directory.appending(path: "config.toml")
        let original = Data("# Keep this comment\nmodel = \"test\"\n[mcp_servers.\"other.server\"]\ncommand = \"/bin/true\"\nenabled = false\n".utf8)
        try original.write(to: url)
        let destination = MCPClientTarget(kind: .codex, configurationURL: url, codexExecutable: Self.installedCodex, isDetected: true)
        let installer = MCPClientInstaller()

        let result = try await installer.install(destination, command: command, token: SyntheticToken.first)

        let installed = try String(contentsOf: url, encoding: .utf8)
        #expect(installed.contains("# Keep this comment"))
        #expect(installed.contains("[mcp_servers.wsurf.env]"))
        #expect(installed.contains(#"WSURF_MCP_TOKEN = "\#(SyntheticToken.first)""#))
        #expect(try await installer.installation(destination, command: command) == .installed(token: SyntheticToken.first))
        #expect(try Data(contentsOf: #require(result.backupURL)) == original)
    }

    @Test(.enabled(if: installedCodex != nil))
    func pairingAnExistingCodexEntryKeepsItsOtherSettingsAndRotatesOnRePair() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(atPath: directory.path) }
        let url = directory.appending(path: "config.toml")
        let original = Data("""
            # Keep this comment
            model = "test"

            [mcp_servers.wsurf]
            command = "\(command)"
            args = ["--mcp"]
            enabled = false
            tool_timeout_sec = 77

            [mcp_servers.wsurf.env]
            OTHER = "1"
            """.utf8)
        try original.write(to: url)
        let destination = MCPClientTarget(kind: .codex, configurationURL: url, codexExecutable: Self.installedCodex, isDetected: true)
        let installer = MCPClientInstaller()
        let trust = MCPTrustStore(storage: MemoryTrustStorage())
        #expect(try await installer.installation(destination, command: command) == .installed(token: nil))
        #expect(try await installer.install(destination, command: command).alreadyPresent)
        #expect(try Data(contentsOf: url) == original)

        let first = try await installer.pair(destination, command: command, trustStore: trust)

        var text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("# Keep this comment"))
        #expect(text.contains("enabled = false"))
        #expect(text.contains("tool_timeout_sec = 77"))
        #expect(text.contains(#"OTHER = "1""#))
        #expect(try Data(contentsOf: #require(first.backupURL)) == original)
        guard case .installed(let oldToken?) = try await installer.installation(destination, command: command) else {
            Issue.record("The entry should carry a token.")
            return
        }
        #expect(trust.client(forToken: oldToken)?.id == first.client.id)

        let second = try await installer.pair(destination, command: command, trustStore: trust)

        text = try String(contentsOf: url, encoding: .utf8)
        #expect(!text.contains(oldToken))
        #expect(text.contains("enabled = false"))
        #expect(text.contains(#"OTHER = "1""#))
        #expect(second.client.id == first.client.id)
        #expect(trust.client(forToken: oldToken) == nil)
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
