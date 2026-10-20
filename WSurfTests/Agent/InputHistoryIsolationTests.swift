// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

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
