// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AuthenticationServices
import CryptoKit
import Foundation

@testable import WSurf

/// Synthetic Passwords transfers of any size for the limit and scale tests. Synthetic only: `example.test` hosts and freshly
/// generated keys, never real data.
nonisolated enum ExchangeScale {
    static let accountID = Data([0xA0, 0x01])

    /// One exporter item id per index.
    static func itemID(_ index: Int) -> Data {
        var value = UInt32(index).bigEndian
        return Data([0xB0]) + withUnsafeBytes(of: &value) { Data($0) }
    }

    /// A login (`basicAuthentication`) with its own username and password.
    static func login(_ index: Int) -> ASImportableCredential {
        .basicAuthentication(.init(
            userName: .init(id: Data([0x11]), fieldType: .string, value: "user\(index)", label: "Login"),
            password: .init(id: Data([0x12]), fieldType: .concealedString, value: "password-\(index)", label: "Secret")
        ))
    }

    /// A plain note of exactly `bytes` bytes (at least the index marker), different for every index.
    static func note(_ index: Int, bytes: Int) -> ASImportableCredential {
        let marker = "note \(index) "
        let text = marker + String(repeating: "x", count: max(0, bytes - marker.utf8.count))
        return .note(.init(content: .init(id: nil, fieldType: .string, value: text, label: nil)))
    }

    /// A passkey for `site<index>.example.test` with a freshly generated ES256 key.
    static func passkey(_ index: Int) throws -> ASImportableCredential {
        .passkey(.init(
            credentialID: Data("credential-\(index)".utf8),
            relyingPartyIdentifier: "site\(index).example.test",
            userName: "user\(index)",
            userDisplayName: "User \(index)",
            userHandle: Data("handle-\(index)".utf8),
            key: try PasskeyKeyEncoding.exportPKCS8(P256.Signing.PrivateKey())
        ))
    }

    static func totp(_ index: Int) -> ASImportableCredential {
        .totp(.init(
            secret: Data("seed-\(index)".utf8), period: 30, digits: 6, userName: "user\(index)", algorithm: .sha1, issuer: "Example"
        ))
    }

    static func item(
        _ index: Int, credentials: [ASImportableCredential], websites: [URL]? = nil
    ) -> ASImportableItem {
        let urls = websites ?? [URL(string: "https://site\(index).example.test/login")!]
        var item = ASImportableItem(
            id: itemID(index),
            created: .distantPast,
            lastModified: .distantPast,
            title: "Item \(index)",
            scope: ASImportableCredentialScope(urls: urls, androidApps: []),
            credentials: credentials,
            tags: []
        )
        item.created = nil
        item.lastModified = nil
        return item
    }

    static func transfer(_ items: [ASImportableItem]) -> ASExportedCredentialData {
        ASExportedCredentialData(
            accounts: [ASImportableAccount(id: accountID, userName: "ada", email: "ada@example.test", collections: [], items: items)],
            formatVersion: .v1,
            exporterRelyingPartyIdentifier: "example.test",
            exporterDisplayName: "Fixture",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    /// `count` items, each a login and a note of `noteBytes` bytes. Every `passkeyEvery`-th item also holds a passkey and every
    /// `totpEvery`-th a verification code (`nil` for none).
    static func transfer(
        items count: Int, noteBytes: Int = 300, passkeyEvery: Int? = 10, totpEvery: Int? = 20
    ) throws -> ASExportedCredentialData {
        var items: [ASImportableItem] = []
        items.reserveCapacity(count)
        for index in 0..<count {
            var credentials = [login(index), note(index, bytes: noteBytes)]
            if let passkeyEvery, index % passkeyEvery == 0 {
                credentials.append(try passkey(index))
            }
            if let totpEvery, index % totpEvery == 0 {
                credentials.append(totp(index))
            }
            items.append(item(index, credentials: credentials))
        }
        return transfer(items)
    }
}
