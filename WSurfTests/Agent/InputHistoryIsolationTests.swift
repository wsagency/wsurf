// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf
@testable import WSurfVault

// Input History is for the person at the keyboard. No tool of the assistant, no MCP tool and nothing they call may read it, so the
// code behind them must not even name it. This is the same source scan `PasskeyVaultUnlockGuardTests` uses for the vault's
// unlock relying party.
struct InputHistoryIsolationTests {
    /// The directories whose code is reachable by an agent or a connected app.
    private static let guarded = ["WSurf/MCP", "WSurf/Agent", "WSurf/Web/Assistant"]
    private static let needles = ["inputhistory", "input-history", "input history", "input_history"]

    private var repositoryRoot: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// The Swift files under `directory` that name Input History, and how many files were looked at.
    private func references(in directory: URL) throws -> (files: [String], scanned: Int) {
        let enumerator = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
        var found: [String] = []
        var scanned = 0
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            scanned += 1
            let text = try String(contentsOf: url, encoding: .utf8).lowercased()
            if Self.needles.contains(where: text.contains) {
                found.append(url.lastPathComponent)
            }
        }
        return (found, scanned)
    }

    @Test func agentAndMCPSourcesNeverReferenceInputHistory() throws {
        var scanned = 0
        for relative in Self.guarded {
            let result = try references(in: repositoryRoot.appending(path: relative))
            #expect(result.files.isEmpty, "\(relative) mentions Input History in \(result.files)")
            scanned += result.scanned
        }
        // A scan that found no files would pass for the wrong reason.
        #expect(scanned > 40)
    }

    /// The tools as a connected app or the assistant is offered them: none of them is about Input History, so a request to read it
    /// has no tool to go to.
    @Test func noAssistantOrMCPToolOffersInputHistory() {
        let mcp = MCPToolCatalog.listed.map { "\($0.name)\n\($0.description)" }
        let assistant = AgentToolCatalog.all.map { "\($0.id)\n\(String(localized: $0.title))\n\(String(localized: $0.summary))" }
        // An empty catalog would pass for the wrong reason.
        #expect(mcp.count > 10 && assistant.count > 10)
        for text in mcp + assistant {
            let lowered = text.lowercased()
            #expect(!Self.needles.contains(where: lowered.contains), "a tool names Input History: \(text.prefix(80))")
        }
    }

    /// The vault's Input History key is reached only through these names, and the scan above refuses each of them in agent and MCP
    /// code, so neither can ask a vault for it. The calls stop compiling if one is renamed, which brings this test back into review.
    @Test func agentsAndMCPCannotNameTheVaultsInputHistoryKey() {
        let viaManager: (CredentialManager) async throws -> InputHistoryVaultKey = { try await $0.inputHistoryKey() }
        let viaStore: (ProfileVaultStore, UUID, VaultAccess) async throws -> InputHistoryVaultKey = {
            try await $0.inputHistoryKey(vaultID: $1, using: $2)
        }
        // Moving Input History to another vault is reached only through `InputHistory` and `InputHistoryStore`, which the scan refuses too.
        let viaMove: (InputHistory, UUID, Profile) async throws -> Void = { try await $0.keep(in: $1, profile: $2) }
        let viaRebind: (InputHistoryStore, InputHistoryVaultKey, InputHistoryVaultKey?) async throws -> Void = {
            try await $0.keep(with: $1, from: $2)
        }
        _ = (viaManager, viaStore, viaMove, viaRebind)
        let names = [
            String(describing: InputHistoryVaultKey.self), String(describing: InputHistory.self), String(describing: InputHistoryStore.self),
            "inputHistoryKey", "wsurf.input-history.v2",
        ]
        for name in names {
            #expect(Self.needles.contains { name.lowercased().contains($0) }, "the scan would not see \(name)")
        }
    }

    @Test func theScanSeesAMentionInAnyCaseSpelling() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("InputHistoryScan-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("Nested"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try "let history = InputHistory.shared".write(to: directory.appendingPathComponent("Nested/A.swift"), atomically: true, encoding: .utf8)
        try "// reads the input history".write(to: directory.appendingPathComponent("B.swift"), atomically: true, encoding: .utf8)
        try "let history = 1".write(to: directory.appendingPathComponent("C.swift"), atomically: true, encoding: .utf8)

        let result = try references(in: directory)
        #expect(result.scanned == 3)
        #expect(Set(result.files) == ["A.swift", "B.swift"])
    }
}
