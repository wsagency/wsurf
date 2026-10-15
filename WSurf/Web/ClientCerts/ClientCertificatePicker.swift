// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import OSLog
import Security

/// Lets the user pick a smart-card identity for a TLS client-certificate challenge.
@MainActor
enum ClientCertificatePicker {
    static let tokenID = "io.wsagency.smartcard.ctk"

    @MainActor struct Candidate {
        let identity: SecIdentity
        /// Token certificates other than identity leaves, so the server can build the chain.
        let intermediates: [SecCertificate]
        let subject: String
        let issuer: String

        init(identity: SecIdentity, intermediates: [SecCertificate] = []) {
            self.identity = identity
            self.intermediates = intermediates
            var leaf: SecCertificate?
            SecIdentityCopyCertificate(identity, &leaf)
            subject = leaf.map { ClientCertificatePicker.subject(of: $0) }
                ?? String(localized: "Unnamed certificate")
            issuer = leaf.map { ClientCertificatePicker.issuer(of: $0) } ?? ""
        }
    }

    typealias Query = @MainActor (_ issuers: [Data]?) -> [Candidate]
    typealias Select = @MainActor (_ candidates: [Candidate], _ host: String, _ window: NSWindow?) async -> Candidate?
    typealias SetPreferred = @MainActor (_ identity: SecIdentity, _ url: URL) -> Void

    /// Returns nil when no card identity matches or the user cancels; the caller cancels the challenge.
    static func credential(
        for space: URLProtectionSpace,
        in window: NSWindow?,
        query: Query = keychainCandidates,
        select: Select = present,
        setPreferred: SetPreferred = setKeychainPreferred
    ) async -> URLCredential? {
        let candidates = query(space.distinguishedNames)
        guard !candidates.isEmpty,
              let chosen = await select(candidates, space.host, window) else {
            return nil
        }
        if let origin = origin(of: space) {
            setPreferred(chosen.identity, origin)
        }
        return URLCredential(
            identity: chosen.identity,
            certificates: chosen.intermediates.isEmpty ? nil : chosen.intermediates,
            persistence: .forSession
        )
    }

    static func origin(of space: URLProtectionSpace) -> URL? {
        var parts = URLComponents()
        parts.scheme = space.protocol ?? "https"
        parts.host = space.host
        let standard = parts.scheme == "https" ? 443 : 80
        if space.port != standard, space.port != 0 {
            parts.port = space.port
        }
        return parts.url
    }

    // MARK: - Keychain

    static func identityQuery(issuers: [Data]?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrTokenID as String: tokenID,
            kSecAttrCanSign as String: true,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        if let issuers, !issuers.isEmpty {
            query[kSecMatchIssuers as String] = issuers
        }
        return query
    }

    static func keychainCandidates(issuers: [Data]?) -> [Candidate] {
        let identities = copyMatching(identityQuery(issuers: issuers)) as? [SecIdentity] ?? []
        guard !identities.isEmpty else { return [] }
        let certificates = copyMatching([
            kSecClass as String: kSecClassCertificate,
            kSecAttrTokenID as String: tokenID,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]) as? [SecCertificate] ?? []
        let leaves = Set(identities.compactMap { identity -> Data? in
            var leaf: SecCertificate?
            SecIdentityCopyCertificate(identity, &leaf)
            return leaf.map { SecCertificateCopyData($0) as Data }
        })
        let intermediates = certificates.filter { !leaves.contains(SecCertificateCopyData($0) as Data) }
        return identities.map { Candidate(identity: $0, intermediates: intermediates) }
    }

    private static func copyMatching(_ query: [String: Any]) -> CFTypeRef? {
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status != errSecSuccess, status != errSecItemNotFound {
            Pipeline.log.error("Smart card keychain query failed: \(status)")
        }
        return status == errSecSuccess ? result : nil
    }

    private static func setKeychainPreferred(_ identity: SecIdentity, _ url: URL) {
        let status = SecIdentitySetPreferred(identity, url.absoluteString as CFString, nil)
        if status != errSecSuccess {
            Pipeline.log.error("Saving the certificate preference failed: \(status)")
        }
    }

    // MARK: - Display

    private static func subject(of certificate: SecCertificate) -> String {
        var name: CFString?
        if SecCertificateCopyCommonName(certificate, &name) == errSecSuccess, let name {
            return name as String
        }
        return SecCertificateCopySubjectSummary(certificate) as String?
            ?? String(localized: "Unnamed certificate")
    }

    private static func issuer(of certificate: SecCertificate) -> String {
        let oid = kSecOIDX509V1IssuerName
        guard let values = SecCertificateCopyValues(certificate, [oid] as CFArray, nil) as? [String: Any],
              let section = values[oid as String] as? [String: Any],
              let items = section[kSecPropertyKeyValue as String] as? [[String: Any]] else { return "" }
        func value(_ label: CFString) -> String? {
            items.first { $0[kSecPropertyKeyLabel as String] as? String == label as String }?[kSecPropertyKeyValue as String] as? String
        }
        return value(kSecOIDCommonName) ?? value(kSecOIDOrganizationName) ?? ""
    }

    private static func title(for candidate: Candidate) -> String {
        candidate.issuer.isEmpty
            ? candidate.subject
            : String(localized: "\(candidate.subject), issued by \(candidate.issuer)")
    }

    private static func present(
        _ candidates: [Candidate],
        host: String,
        in window: NSWindow?
    ) async -> Candidate? {
        let alert = NSAlert()
        alert.messageText = String(localized: "Choose a certificate for \(host)")
        alert.informativeText = String(localized: "This website asks for a certificate from your smart card.")
        alert.addButton(withTitle: String(localized: "Choose"))
        alert.addButton(withTitle: String(localized: "Cancel"))

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 360, height: 26), pullsDown: false)
        for candidate in candidates {
            // addItem(withTitle:) would collapse identical titles into one entry.
            popup.menu?.addItem(NSMenuItem(title: title(for: candidate), action: nil, keyEquivalent: ""))
        }
        alert.accessoryView = popup

        let response = await AuthChallenge.present(alert, in: window)
        guard response == .alertFirstButtonReturn,
              candidates.indices.contains(popup.indexOfSelectedItem) else { return nil }
        return candidates[popup.indexOfSelectedItem]
    }
}
