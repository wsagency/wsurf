// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

// Cards, addresses and the other items of the credentials vault are for the person at the keyboard. No tool of the assistant, no MCP
// tool and nothing they call may read them, so the code behind them must not even name the vault or its items. The same source scan
// as `InputHistoryIsolationTests`.
struct SecureItemIsolationTests {
    private static let guarded = ["WSurf/MCP", "WSurf/Agent", "WSurf/Web/Assistant"]
    private static let needles = [
        "secureitem", "vaultitemautofill", "credentialmanager", "storesnapshot", "profilevaultstore", "paymentcardvault",
        "autofillvaults", "credentialaccount",
    ]

    private var repositoryRoot: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

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

    @Test func agentAndMCPSourcesNeverReachTheVaultOrItsItems() throws {
        var scanned = 0
        for relative in Self.guarded {
            let result = try references(in: repositoryRoot.appending(path: relative))
            #expect(result.files.isEmpty, "\(relative) names the credentials vault in \(result.files)")
            scanned += result.scanned
        }
        // A scan that found no files would pass for the wrong reason.
        #expect(scanned > 40)
    }

    /// The tools as a connected app or the assistant is offered them: none of them reads a card, an address or another item.
    @Test func noAssistantOrMCPToolOffersCardsOrAddresses() {
        let mcp = MCPToolCatalog.entries.map { "\($0.name)\n\($0.description)" }
        let assistant = AgentToolCatalog.all.map { "\($0.id)\n\(String(localized: $0.title))\n\(String(localized: $0.summary))" }
        #expect(mcp.count > 10 && assistant.count > 10)
        for text in mcp + assistant {
            let lowered = text.lowercased()
            for word in ["payment card", "credit card", "card number", "credential vault", "saved address"] {
                #expect(!lowered.contains(word), "a tool offers \(word): \(text.prefix(80))")
            }
        }
    }
}
