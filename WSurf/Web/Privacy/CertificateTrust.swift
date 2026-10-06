// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import CCef
import CryptoKit
import Foundation
import os
import Security

@MainActor
enum CertificateTrust {
    private static var accepted: [String: String] = [:]
    private static var exceptionGeneration = 0

    enum Decision {
        case useDefaultHandling
        case proceed(URLCredential)
        case cancel
    }

    static func decide(
        for challenge: URLAuthenticationChallenge,
        allowsExceptions: Bool,
        in window: NSWindow?
    ) async -> Decision {
        guard allowsExceptions else { return .useDefaultHandling }
        let space = challenge.protectionSpace
        guard space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = space.serverTrust
        else { return .useDefaultHandling }

        let host = space.host.lowercased()
        switch await decideInvalid(host: host, trust: trust, allowsExceptions: allowsExceptions, in: window) {
        case .proceed:
            return .proceed(URLCredential(trust: trust))
        case .cancel:
            return .cancel
        case .useDefaultHandling:
            return .useDefaultHandling
        }
    }

    /// Shared decision path for WebKit challenges and native CEF certificate
    /// errors. The accepted map is deliberately keyed by host and leaf
    /// fingerprint, never by a host alone.
    static func decideInvalid(
        host: String,
        trust: SecTrust,
        allowsExceptions: Bool,
        in window: NSWindow?
    ) async -> Decision {
        guard allowsExceptions else { return .useDefaultHandling }
        let generation = exceptionGeneration
        guard let trusted = try? await evaluate(trust),
              generation == exceptionGeneration
        else { return .useDefaultHandling }
        if trusted {
            return .useDefaultHandling
        }
        guard let fingerprint = fingerprint(of: trust) else { return .useDefaultHandling }
        let key = host.lowercased()
        if accepted[key] == fingerprint {
            return .proceed(URLCredential(trust: trust))
        }
        let confirmed = await ask(host: key, trust: trust, fingerprint: fingerprint, in: window)
        guard confirmed, generation == exceptionGeneration else { return .cancel }
        Self.accepted[key] = fingerprint
        Pipeline.log.notice("certificate exception accepted for a host this session")
        return .proceed(URLCredential(trust: trust))
    }

    static func forgetAll() {
        accepted.removeAll()
        exceptionGeneration &+= 1
    }

    static func evaluate(
        _ trust: SecTrust,
        start: (SecTrust, DispatchQueue, @escaping SecTrustWithErrorCallback) -> OSStatus
            = SecTrustEvaluateAsyncWithError
    ) async throws -> Bool {
        try await withCheckedThrowingContinuation { continuation in
            let status = start(trust, .main) { _, trusted, _ in
                continuation.resume(returning: trusted)
            }
            if status != errSecSuccess {
                continuation.resume(throwing: NSError(domain: NSOSStatusErrorDomain, code: Int(status)))
            }
        }
    }

    static var acceptedHostCount: Int {
        accepted.count
    }

    nonisolated static func chainData(
        from certificate: UnsafeMutablePointer<cef_x509_certificate_t>
    ) -> [Data] {
        let count = certificate.pointee.get_issuer_chain_size?(certificate) ?? 0
        var values = [Data?](repeating: nil, count: count + 1)
        if let leaf = certificate.pointee.get_derencoded?(certificate) {
            values[0] = copy(binary: leaf)
            ChromiumInterop.release(UnsafeMutableRawPointer(leaf))
        }
        guard count > 0 else { return values.compactMap { $0 } }
        var chain = [UnsafeMutablePointer<cef_binary_value_t>?](repeating: nil, count: count)
        var returned = count
        chain.withUnsafeMutableBufferPointer { buffer in
            certificate.pointee.get_derencoded_issuer_chain?(certificate, &returned, buffer.baseAddress)
        }
        for index in 0..<count {
            if let value = chain[index] {
                values[index + 1] = copy(binary: value)
                ChromiumInterop.release(UnsafeMutableRawPointer(value))
            }
        }
        return values.compactMap { $0 }
    }

    static func makeTrust(from chain: [Data], host: String?) -> SecTrust? {
        let certificates = chain.compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
        guard !certificates.isEmpty else { return nil }
        let policy = SecPolicyCreateSSL(true, host as CFString?)
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(certificates as CFTypeRef, policy, &trust) == errSecSuccess else {
            return nil
        }
        return trust
    }

    private nonisolated static func copy(binary: UnsafeMutablePointer<cef_binary_value_t>) -> Data? {
        let size = binary.pointee.get_size?(binary) ?? 0
        guard size > 0 else { return Data() }
        var data = Data(count: size)
        let copied = data.withUnsafeMutableBytes { buffer in
            binary.pointee.get_data?(binary, buffer.baseAddress, size, 0) ?? 0
        }
        guard copied == size else { return nil }
        return data
    }

    // MARK: - Asking

    private static func ask(
        host: String,
        trust: SecTrust,
        fingerprint: String,
        in window: NSWindow?
    ) async -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = String(localized: "This website’s identity can’t be verified")
        alert.informativeText = detail(host: host, trust: trust, fingerprint: fingerprint)
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Continue")).hasDestructiveAction = true

        guard let window else {
            return alert.runModal() == .alertSecondButtonReturn
        }
        let response = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }
        return response == .alertSecondButtonReturn
    }

    private static func detail(host: String, trust: SecTrust, fingerprint: String) -> String {
        var lines = [
            String(localized: "WSurf can’t confirm that this certificate belongs to \(host). Somebody may be impersonating the website."),
            "",
        ]
        if let summary = leafSummary(of: trust) {
            lines.append(String(localized: "Issued to: \(summary)"))
        }
        lines.append(String(localized: "SHA-256: \(fingerprint)"))
        lines.append("")
        lines.append(String(localized: "Continue only if you expected this — a development server, or a proxy your organization runs. The exception lasts until you quit."))
        return lines.joined(separator: "\n")
    }

    private static func leafCertificate(of trust: SecTrust) -> SecCertificate? {
        (SecTrustCopyCertificateChain(trust) as? [SecCertificate])?.first
    }

    private static func leafSummary(of trust: SecTrust) -> String? {
        guard let certificate = leafCertificate(of: trust) else { return nil }
        return SecCertificateCopySubjectSummary(certificate) as String?
    }

    static func fingerprint(of trust: SecTrust) -> String? {
        guard let certificate = leafCertificate(of: trust) else { return nil }
        return SHA256.hash(data: SecCertificateCopyData(certificate) as Data)
            .map { String(format: "%02X", $0) }
            .joined(separator: " ")
    }
}
