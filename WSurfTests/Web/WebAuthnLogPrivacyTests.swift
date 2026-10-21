// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

/// Source-level rule for the passkey diagnostics: which sites a person has passkeys for never reaches the unified log in the
/// clear. Outside `#if DEBUG`, the RP ID is only ever logged as a hash and nothing but the fixed event and info text is public.
struct WebAuthnLogPrivacyTests {
    private static let root = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    /// The text of `path` with every `#if DEBUG` branch removed (its `#else` branch is kept).
    private func releaseSource(_ path: String) throws -> String {
        let text = try String(contentsOf: Self.root.appending(path: path), encoding: .utf8)
        var kept: [Substring] = []
        var inDebug = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "#if DEBUG" {
                inDebug = true
            } else if inDebug, trimmed == "#else" || trimmed == "#endif" {
                inDebug = false
            } else if !inDebug {
                kept.append(line)
            }
        }
        return kept.joined(separator: "\n")
    }

    @Test(arguments: ["WSurf/Web/Credentials/WebAuthnAdapter.swift", "WSurf/Web/Credentials/WebsiteAuthenticatorCeremony.swift"])
    func passkeyDiagnosticsKeepRPIDsAndCountsPrivateInRelease(path: String) throws {
        let source = try releaseSource(path)
        let publicValues = try Regex(#"\\\(\s*([^,()]+?)\s*,\s*privacy:\s*\.public\s*\)"#)
        for match in source.matches(of: publicValues) {
            let expression = String(match.output[1].substring ?? "")
            #expect(["event", "info"].contains(expression), "\(path): `\(expression)` is logged in the clear")
        }
        #expect(source.firstMatch(of: try Regex(#"rpI[dD]=\\\([^)]*privacy:\s*\.public"#)) == nil, "\(path): an RP ID is logged in the clear")
        #expect(!source.contains("Logger("), "\(path): passkey diagnostics go through WebAuthnRefusal.log")
    }

    @Test func theRPIDIsLoggedOnlyAsAHash() throws {
        let source = try releaseSource("WSurf/Web/Credentials/WebAuthnAdapter.swift")
        #expect(source.contains("rpId=\\(rpID, privacy: .private(mask: .hash))"))
        #expect(source.contains("\\(counts, privacy: .private)"))
    }
}
