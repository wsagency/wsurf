// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Security
import Testing

@testable import WSurf

private nonisolated final class IssuerSpace: URLProtectionSpace, @unchecked Sendable {
    let issuers: [Data]?

    init(host: String, port: Int, protocol: String, realm: String?, authenticationMethod: String, issuers: [Data]?) {
        self.issuers = issuers
        super.init(host: host, port: port, protocol: `protocol`, realm: realm, authenticationMethod: authenticationMethod)
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override var distinguishedNames: [Data]? {
        issuers
    }
}

@MainActor
struct ClientCertificateTests {
    private func space(
        method: String = NSURLAuthenticationMethodClientCertificate,
        port: Int = 443,
        issuers: [Data]? = nil
    ) -> URLProtectionSpace {
        IssuerSpace(
            host: "example.com",
            port: port,
            protocol: "https",
            realm: nil,
            authenticationMethod: method,
            issuers: issuers
        )
    }

    // Self-signed test identities (CN "Ana Horvat" / "Ivo Kovac", password "t"); never keychain-imported.
    // swiftlint:disable:next line_length
    private static let anaP12 = "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"
    // swiftlint:disable:next line_length
    private static let ivoP12 = "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"

    private func identity(_ base64: String) throws -> SecIdentity {
        var items: CFArray?
        let status = SecPKCS12Import(
            Data(base64Encoded: base64)! as CFData,
            [kSecImportExportPassphrase as String: "t", kSecImportToMemoryOnly as String: true] as CFDictionary,
            &items
        )
        #expect(status == errSecSuccess)
        let entry = try #require((items as? [[String: Any]])?.first)
        // SecPKCS12Import guarantees a SecIdentity for kSecImportItemIdentity.
        // swiftlint:disable:next force_cast
        return entry[kSecImportItemIdentity as String] as! SecIdentity
    }

    private func candidate(_ base64: String) throws -> ClientCertificatePicker.Candidate {
        ClientCertificatePicker.Candidate(identity: try identity(base64))
    }

    // MARK: - Decision

    @Test func clientCertificatePromptsWhenSmartCardActive() {
        #expect(
            AuthChallenge.decision(for: space(), previousFailureCount: 0, smartCardActive: true)
                == .promptForClientCertificate
        )
    }

    @Test func clientCertificateKeepsDefaultHandlingWhenInactive() {
        #expect(
            AuthChallenge.decision(for: space(), previousFailureCount: 0, smartCardActive: false)
                == .useDefaultHandling
        )
    }

    @Test(arguments: [true, false])
    func serverTrustStillWins(active: Bool) {
        #expect(
            AuthChallenge.decision(
                for: space(method: NSURLAuthenticationMethodServerTrust),
                previousFailureCount: 0,
                smartCardActive: active
            ) == .evaluateServerTrust
        )
    }

    @Test(arguments: [true, false])
    func passwordMethodsAreUnaffected(active: Bool) {
        #expect(
            AuthChallenge.decision(
                for: space(method: NSURLAuthenticationMethodHTTPBasic),
                previousFailureCount: 0,
                smartCardActive: active
            ) == .promptForCredential
        )
        #expect(
            AuthChallenge.decision(
                for: space(method: NSURLAuthenticationMethodHTTPBasic),
                previousFailureCount: 3,
                smartCardActive: active
            ) == .rejectProtectionSpace
        )
        #expect(
            AuthChallenge.decision(
                for: space(method: NSURLAuthenticationMethodNegotiate),
                previousFailureCount: 0,
                smartCardActive: active
            ) == .useDefaultHandling
        )
    }

    // MARK: - Keychain query

    @Test func identityQueryRequiresSmartCardTokenAndSigning() {
        let query = ClientCertificatePicker.identityQuery(issuers: nil)
        #expect(query[kSecAttrTokenID as String] as? String == "io.wsagency.smartcard.ctk")
        #expect(query[kSecAttrCanSign as String] as? Bool == true)
        #expect(query[kSecClass as String] as? String == kSecClassIdentity as String)
        #expect(query[kSecMatchIssuers as String] == nil)
    }

    @Test func identityQueryFiltersByAcceptableIssuers() {
        let issuers = [Data([1, 2, 3])]
        #expect(
            ClientCertificatePicker.identityQuery(issuers: issuers)[kSecMatchIssuers as String] as? [Data] == issuers
        )
        #expect(ClientCertificatePicker.identityQuery(issuers: [])[kSecMatchIssuers as String] == nil)
    }

    // MARK: - Picker

    @Test func serverIssuersReachTheQuery() async {
        let issuers = [Data([9, 9])]
        var received: [Data]?
        _ = await ClientCertificatePicker.credential(
            for: space(issuers: issuers),
            in: nil,
            query: { received = $0; return [] },
            select: { _, _, _ in Issue.record("picker must not appear"); return nil },
            setPreferred: { _, _ in }
        )
        #expect(received == issuers)
    }

    @Test func noIdentitiesMeansNoUIAndNoCredential() async {
        var shown = false
        var preferred = false
        let credential = await ClientCertificatePicker.credential(
            for: space(),
            in: nil,
            query: { _ in [] },
            select: { _, _, _ in shown = true; return nil },
            setPreferred: { _, _ in preferred = true }
        )
        #expect(credential == nil)
        #expect(!shown)
        #expect(!preferred)
    }

    @Test func cancelReturnsNilWithoutSavingAPreference() async throws {
        let ana = try candidate(Self.anaP12)
        var preferred = false
        let credential = await ClientCertificatePicker.credential(
            for: space(),
            in: nil,
            query: { _ in [ana] },
            select: { _, _, _ in nil },
            setPreferred: { _, _ in preferred = true }
        )
        #expect(credential == nil)
        #expect(!preferred)
    }

    @Test func choiceBuildsSessionCredentialAndSavesPreferenceForOrigin() async throws {
        let ana = try candidate(Self.anaP12)
        let ivo = try candidate(Self.ivoP12)
        var shown: [String] = []
        var saved: [(SecIdentity, URL)] = []
        let credential = await ClientCertificatePicker.credential(
            for: space(),
            in: nil,
            query: { _ in [ana, ivo] },
            select: { candidates, host, _ in
                shown = candidates.map(\.subject) + [host]
                return candidates[1]
            },
            setPreferred: { saved.append(($0, $1)) }
        )
        #expect(shown == ["Ana Horvat", "Ivo Kovac", "example.com"])
        #expect(credential?.persistence == .forSession)
        #expect(credential?.identity.map { CFEqual($0, ivo.identity) } == true)
        #expect(saved.count == 1)
        #expect(saved.first.map { CFEqual($0.0, ivo.identity) } == true)
        #expect(saved.first?.1 == URL(string: "https://example.com"))
    }

    @Test func nonStandardPortIsPartOfTheOrigin() async throws {
        let ana = try candidate(Self.anaP12)
        var origin: URL?
        _ = await ClientCertificatePicker.credential(
            for: space(port: 8443),
            in: nil,
            query: { _ in [ana] },
            select: { candidates, _, _ in candidates.first },
            setPreferred: { origin = $1 }
        )
        #expect(origin == URL(string: "https://example.com:8443"))
    }

    @Test func candidateShowsSubjectAndIssuerNames() throws {
        let ana = try candidate(Self.anaP12)
        #expect(ana.subject == "Ana Horvat")
        #expect(ana.issuer == "Ana Horvat")
    }
}
