// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Foundation

/// The superseded password value and the Trash/restore credential value: never a whole `CredentialAccount`.
nonisolated struct PasswordValue: Codable, Equatable, Sendable {
    var username: String
    var password: String?
    var basicAuthenticationMetadata: CredentialBasicAuthenticationMetadata?
}

/// The metadata history projection: secrets-free. `exchange` is the stored `exchangeMetadata` decoded into the typed
/// `ExchangeMetadata` and re-encoded with sorted keys (known fields and dates kept, unknown keys dropped).
nonisolated struct MetadataProjection: Codable, Equatable, Sendable {
    var displayName: String?
    var origins: [String]
    var loginURLs: [URL]
    var exchange: Data?
    var exchangeAccountID: Data?
    var exchangeItemID: Data?
}

nonisolated extension MetadataProjection {
    /// Throws `CredentialStoreError.metadataUndecodable` when the stored exchange bytes are not typed `ExchangeMetadata`.
    init(_ account: CredentialAccount) throws {
        displayName = account.displayName
        origins = account.origins
        loginURLs = account.loginURLs
        exchange = try CredentialContent.exchangeMetadata(account).map { try CredentialContent.canonicalJSON($0) }
        exchangeAccountID = account.exchangeAccountID
        exchangeItemID = account.exchangeItemID
    }
}

nonisolated enum CredentialPart: Equatable, Sendable {
    case password(CredentialAccount)
    case totp(CredentialAccount)
    case passkey(WebsitePasskey)
    case metadata(CredentialAccount)
    case note(CredentialAccount)
}

/// §12.3 content hash: SHA-256 over `StoreWriter` bytes (u8 part tag, then the fields in a fixed order). No JSON is hashed.
nonisolated enum CredentialContent {
    /// The persisted-payload convention (same as `CredentialVaultCrypto.encodePayload`): sorted keys, default strategies.
    static func canonicalJSON<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            return try encoder.encode(value)
        } catch {
            throw CredentialVaultError.invalidData
        }
    }

    /// The typed exchange metadata, `nil` when the account has none. Throws `metadataUndecodable` for any other bytes.
    static func exchangeMetadata(_ account: CredentialAccount) throws -> CredentialExchangeCodec.ExchangeMetadata? {
        guard let raw = account.exchangeMetadata else { return nil }
        do {
            return try JSONDecoder().decode(CredentialExchangeCodec.ExchangeMetadata.self, from: raw)
        } catch {
            throw CredentialStoreError.metadataUndecodable
        }
    }

    static func hash(_ part: CredentialPart) throws -> Data {
        var writer = StoreWriter()
        switch part {
        case let .password(account):
            writer.u8(1)
            writePassword(&writer, account)
        case let .totp(account):
            writer.u8(2)
            writer.optional(account.totp) { writer, totp in
                writer.bytes(totp.secret)
                writer.text(totp.algorithm.rawValue)
                writer.u32(Int(totp.period))
                writer.u32(Int(totp.digits))
                writer.optional(totp.issuer) { $0.text($1) }
                writer.optional(totp.userName) { $0.text($1) }
            }
        case let .passkey(passkey):
            writer.u8(3)
            try writePasskey(&writer, passkey)
        case let .metadata(account):
            writer.u8(4)
            try writeMetadata(&writer, account)
        case let .note(account):
            // Tag 5. The exact UTF-8 of every note and its field description, in order; `nil` and "no notes" are the same bytes.
            writer.u8(5)
            writer.optional(account.notes) { writer, notes in
                writer.array(notes) { writer, note in
                    writer.text(note.text)
                    writer.optional(note.field, writeField)
                }
            }
        }
        return Data(SHA256.hash(data: writer.data))
    }

    private static func writePassword(_ writer: inout StoreWriter, _ account: CredentialAccount) {
        writer.text(account.username)
        writer.optional(account.password) { $0.text($1) }
        writer.optional(account.basicAuthenticationMetadata) { writer, metadata in
            writer.optional(metadata.username, writeField)
            writer.optional(metadata.password, writeField)
        }
    }

    private static func writeField(_ writer: inout StoreWriter, _ field: CredentialEditableFieldMetadata) {
        writer.optional(field.id) { $0.bytes($1) }
        writer.optional(field.label) { $0.text($1) }
        writer.text(field.fieldType.rawValue)
    }

    private static func writePasskey(_ writer: inout StoreWriter, _ passkey: WebsitePasskey) throws {
        guard passkey.algorithm == -7 else { throw CredentialVaultError.invalidData }
        let key = try PasskeyKeyEncoding.importPKCS8(passkey.privateKeyPKCS8)
        writer.text(passkey.rpID.lowercased())
        writer.bytes(passkey.credentialID)
        writer.bytes(passkey.userHandle)
        writer.bytes(key.publicKey.x963Representation)
    }

    private static func writeMetadata(_ writer: inout StoreWriter, _ account: CredentialAccount) throws {
        let exchange = try exchangeMetadata(account)
        writer.optional(account.displayName) { $0.text($1) }
        writer.array(account.origins) { $0.text($1) }
        writer.array(account.loginURLs) { $0.text($1.absoluteString) }
        writer.optional(exchange) { writer, exchange in
            writer.text(exchange.accountName)
            writer.text(exchange.email)
            writer.optional(exchange.fullName) { $0.text($1) }
            writer.optional(exchange.subtitle) { $0.text($1) }
            writer.bool(exchange.favorite)
            writer.array(exchange.tags) { $0.text($1) }
            writer.array(exchange.collections, writeCollection)
        }
    }

    private static func writeCollection(_ writer: inout StoreWriter, _ collection: CredentialExchangeCodec.ExchangeCollection) {
        writer.bytes(collection.id)
        writer.text(collection.title)
        writer.optional(collection.subtitle) { $0.text($1) }
        writer.array(collection.items) { writer, link in
            writer.bytes(link.item)
            writer.optional(link.account) { $0.bytes($1) }
        }
        writer.array(collection.subcollections, writeCollection)
    }
}
