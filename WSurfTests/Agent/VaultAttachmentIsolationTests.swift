// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

// Files kept in the credentials vault (scans, PDFs, documents of the family) are for the person at the keyboard, like the vault's cards
// and passwords. No tool of the assistant, no MCP tool and nothing they call may read one, so the code behind them must not even name
// the file API, its encrypted folder or the folder of decrypted copies; no tool offers them; and an MCP connection is refused a
// vault file's address. The same source scan as `SecureItemIsolationTests`.
struct VaultAttachmentIsolationTests {
    private static let guarded = ["WSurf/MCP", "WSurf/Agent", "WSurf/Web/Assistant"]
    private static let needles = [
        "credentialattachment", "vaultblob", "vaultfilepreview", "addattachment", "readattachment", "discardattachments",
        "sweepattachments", "hasattachment", "temporarycopy", "savefilecopy", "credentials.blobs", "vault file previews",
    ]

    private var repositoryRoot: URL {
        URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    @Test func agentAndMCPSourcesNeverNameTheVaultsFiles() throws {
        var scanned = 0
        for relative in Self.guarded {
            let directory = repositoryRoot.appending(path: relative)
            let enumerator = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
            var found: [String] = []
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                scanned += 1
                let text = try String(contentsOf: url, encoding: .utf8).lowercased()
                if Self.needles.contains(where: text.contains) {
                    found.append(url.lastPathComponent)
                }
            }
            #expect(found.isEmpty, "\(relative) names the vault's files in \(found)")
        }
        // A scan that found no files would pass for the wrong reason.
        #expect(scanned > 40)
    }

    /// The tools as a connected app or the assistant is offered them: none of them reads a file kept in the vault.
    @Test func noAssistantOrMCPToolOffersVaultFiles() {
        let mcp = MCPToolCatalog.listed.map { "\($0.name)\n\($0.description)" }
        let assistant = AgentToolCatalog.all.map { "\($0.id)\n\(String(localized: $0.title))\n\(String(localized: $0.summary))" }
        #expect(mcp.count > 10 && assistant.count > 10)
        for text in mcp + assistant {
            let lowered = text.lowercased()
            for phrase in ["vault file", "credential file", "attached file", "file in the vault", "credential attachment"] {
                #expect(!lowered.contains(phrase), "a tool offers \(phrase): \(text.prefix(80))")
            }
        }
    }

    /// The MCP refusal: a vault file's encrypted copy and its decrypted preview are local files, and no MCP access, even the Developer
    /// tier's "This Mac", covers a `file:` address; the store's file calls need the vault's own lease, which no MCP session holds.
    @Test func anMCPConnectionIsRefusedEveryVaultFileAddress() throws {
        let support = FileManager.default.temporaryDirectory.appending(path: "isolation-\(UUID().uuidString)", directoryHint: .isDirectory)
        let encrypted = VaultBlob.file(UUID(), in: VaultBlob.folder(in: support, vaultID: UUID()))
        let preview = VaultFilePreviewFolder.shared.runFolder.appending(path: "copy/scan.pdf")
        for url in [encrypted, preview] {
            #expect(url.isFileURL)
            #expect(!MCPDeveloperAccess.matches(url, sites: ["localhost", "127.0.0.1"], includesThisMac: true), "\(url.path)")
        }
    }
}
