// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CCef
import Foundation
import Security

extension ChromiumClient {
    typealias PreferredCertificate = @MainActor (_ url: URL) -> Data?

    /// Index into `candidates` (DER) of the smart-card identity the keychain prefers for `host`.
    /// nil means "use CEF's default behavior".
    static func chooseClientCertificate(
        host: String,
        candidates: [Data],
        isActive: Bool = SmartCardFeature.shared.isActive,
        preferred: PreferredCertificate = keychainPreferredCertificate
    ) -> Int? {
        guard isActive, !candidates.isEmpty,
              let url = URL(string: "https://\(host)"),
              let der = preferred(url),
              !der.isEmpty
        else { return nil }
        return candidates.firstIndex(of: der)
    }

    static func keychainPreferredCertificate(for url: URL) -> Data? {
        guard let identity = SecIdentityCopyPreferred(url.absoluteString as CFString, nil, nil) else { return nil }
        var certificate: SecCertificate?
        guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess, let certificate else { return nil }
        return SecCertificateCopyData(certificate) as Data
    }

    /// DER bytes of a CEF certificate, borrowed (the caller keeps its own reference).
    nonisolated static func derData(of certificate: UnsafeMutablePointer<cef_x509_certificate_t>) -> Data? {
        guard let binary = certificate.pointee.get_derencoded?(certificate) else { return nil }
        defer { ChromiumInterop.release(UnsafeMutableRawPointer(binary)) }
        let size = binary.pointee.get_size?(binary) ?? 0
        guard size > 0 else { return nil }
        var data = Data(count: size)
        let copied = data.withUnsafeMutableBytes { buffer in
            binary.pointee.get_data?(binary, buffer.baseAddress, size, 0) ?? 0
        }
        return copied == size ? data : nil
    }

    /// CEF include/capi/cef_request_handler_capi.h:219 on_select_client_certificate(self, browser, isProxy,
    /// host, port, certificatesCount, certificates, callback); :77 cef_select_client_certificate_callback_t.select(self, cert).
    /// CEF hands over a reference to each certificate and the callback; every path releases them.
    nonisolated static func selectClientCertificate(
        _ handlerSelf: UnsafeMutablePointer<cef_request_handler_t>?,
        browser: UnsafeMutablePointer<cef_browser_t>?,
        isProxy: Int32,
        host: UnsafePointer<cef_string_t>?,
        count: Int,
        certificates: UnsafePointer<UnsafeMutablePointer<cef_x509_certificate_t>?>?,
        callback: UnsafeMutablePointer<cef_select_client_certificate_callback_t>?
    ) -> Int32 {
        ChromiumClient.releaseBrowser(browser)
        let certificateList = (0..<count).map { certificates?[$0] }
        defer { certificateList.forEach { ChromiumClient.release($0.map(UnsafeMutableRawPointer.init)) } }
        guard let callback else { return 0 }
        let raw = UnsafeMutableRawPointer(callback)
        guard isProxy == 0,
              let client = ChromiumClient.owner(handlerSelf.map(UnsafeMutableRawPointer.init))
        else {
            ChromiumClient.release(raw)
            return 0
        }
        let candidates = certificateList.map { $0.flatMap(ChromiumClient.derData(of:)) ?? Data() }
        let host = ChromiumClient.string(host)
        let match = MainActor.assumeIsolated {
            client.isClosed ? nil : ChromiumClient.chooseClientCertificate(host: host, candidates: candidates)
        }
        guard let match, let chosen = certificateList[match] else {
            ChromiumClient.release(raw)
            return 0
        }
        callback.pointee.select?(callback, chosen)
        ChromiumClient.release(raw)
        return 1
    }
}
