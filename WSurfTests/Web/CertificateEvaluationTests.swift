// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import Security
import Testing
import WebKit

@testable import WSurf

@MainActor
struct CertificateEvaluationTests {
    @Test func disabledExceptionsLeaveValidationToWebKit() async {
        let space = UnevaluatedProtectionSpace(
            host: "example.com", port: 443, protocol: "https", realm: nil,
            authenticationMethod: NSURLAuthenticationMethodServerTrust
        )
        let challenge = URLAuthenticationChallenge(
            protectionSpace: space, proposedCredential: nil, previousFailureCount: 0,
            failureResponse: nil, error: nil, sender: UnusedChallengeSender()
        )
        let decision = await CertificateTrust.decide(for: challenge, allowsExceptions: false, in: nil)
        guard case .useDefaultHandling = decision else {
            Issue.record("WebKit must validate certificates when exceptions are disabled")
            return
        }
    }

    @Test(arguments: [true, false])
    func evaluationPreservesTrustResult(anchored: Bool) async throws {
        let trust = try makeTrust(anchored: anchored)
        #expect(try await CertificateTrust.evaluate(trust) == anchored)
        #expect(try await CertificateTrust.evaluate(trust) == anchored)
    }

    @Test func mainQueueCanRunWhileEvaluationIsPending() async throws {
        let trust = try makeTrust()
        var didRunMainQueue = false
        let trusted = try await CertificateTrust.evaluate(trust) { trust, queue, completion in
            #expect(queue === DispatchQueue.main)
            DispatchQueue.main.async {
                didRunMainQueue = true
                completion(trust, true, nil)
            }
            return errSecSuccess
        }
        #expect(trusted)
        #expect(didRunMainQueue)
    }

    @Test func inlineCompletionResumesOnce() async throws {
        let trust = try makeTrust()
        let trusted = try await CertificateTrust.evaluate(trust) { trust, _, completion in
            completion(trust, false, nil)
            return errSecSuccess
        }
        #expect(!trusted)
    }

    @Test func startFailureDoesNotWaitForACallback() async throws {
        let trust = try makeTrust()
        do {
            _ = try await CertificateTrust.evaluate(trust) { _, _, _ in errSecParam }
            Issue.record("A failed start must throw")
        } catch {
            #expect((error as NSError).domain == NSOSStatusErrorDomain)
            #expect((error as NSError).code == Int(errSecParam))
        }
    }

    /// A WebKit page is secure for credentials only while its main frame's certificate passes evaluation and no certificate
    /// exception was accepted for its document; WebKit's own flag stays on past a warning. A self-signed certificate stands in
    /// for one accepted past a warning (nothing is trusted or stored outside this test).
    @Test(.boundedWebViews)
    func aWebKitPageIsSecureOnlyWithACertificateThatPassesAndNoException() async throws {
        let failing = try makeTrust(anchored: false), passing = try makeTrust(anchored: true)
        let configuration = interactiveWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let page = BrowserPage(webKit: WKWebView(frame: NSRect(x: 0, y: 0, width: 200, height: 200), configuration: configuration), context: context)
        page.certificateStanding.webKitSecure = true
        #expect(!page.hasOnlySecureContent, "no certificate, no secure page")

        page.serverTrustChanged(failing)
        try await Task.sleep(for: .milliseconds(300))
        #expect(!page.hasOnlySecureContent, "a certificate that fails evaluation, as one accepted past a warning does")

        page.serverTrustChanged(passing)
        #expect(!page.hasOnlySecureContent, "not before its evaluation")
        #expect(await waitUntil(timeout: .seconds(5)) { page.hasOnlySecureContent })

        page.certificateStanding.exceptionAccepted()
        #expect(!page.hasOnlySecureContent, "a subresource past a warning taints the document")
        page.certificateStanding.navigationStarted()
        page.certificateStanding.navigationCommitted()
        #expect(page.hasOnlySecureContent, "the next document is clean")

        page.certificateStanding.navigationStarted()
        page.certificateStanding.exceptionAccepted()
        #expect(!page.hasOnlySecureContent)
        page.certificateStanding.navigationCommitted()
        #expect(!page.hasOnlySecureContent, "an exception while the navigation was provisional belongs to the new document too")

        page.certificateStanding.navigationStarted()
        page.certificateStanding.navigationCommitted()
        #expect(page.hasOnlySecureContent)
        page.certificateStanding.webKitSecure = false
        #expect(!page.hasOnlySecureContent, "WebKit's own rule still holds")
        page.certificateStanding.webKitSecure = true
        page.serverTrustChanged(nil)
        #expect(!page.hasOnlySecureContent)
        await page.close()
        await context.endPrivateSession()
    }

    private func makeTrust(anchored: Bool = true) throws -> SecTrust {
        let data = try #require(Data(base64Encoded: Self.certificate))
        let certificate = try #require(SecCertificateCreateWithData(nil, data as CFData))
        var trust: SecTrust?
        #expect(SecTrustCreateWithCertificates(certificate, SecPolicyCreateBasicX509(), &trust) == errSecSuccess)
        let result = try #require(trust)
        #expect(SecTrustSetAnchorCertificates(result, (anchored ? [certificate] : []) as CFArray) == errSecSuccess)
        #expect(SecTrustSetAnchorCertificatesOnly(result, true) == errSecSuccess)
        #expect(SecTrustSetNetworkFetchAllowed(result, false) == errSecSuccess)
        #expect(SecTrustSetVerifyDate(result, Date(timeIntervalSince1970: 1_800_000_000) as CFDate) == errSecSuccess)
        return result
    }

    private static let certificate = """
        MIIBmzCCAUGgAwIBAgIUdeVwvca0ZsB/WOArBAp8Rd43EbAwCgYIKoZIzj0EAwIwIzEh
        MB8GA1UEAwwYbGluZW4tdHJ1c3QtdGVzdC5pbnZhbGlkMB4XDTI2MDkyMzA4MjUxM1oX
        DTM2MDkyMDA4MjUxM1owIzEhMB8GA1UEAwwYbGluZW4tdHJ1c3QtdGVzdC5pbnZhbGlk
        MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEAQ5kJDUiBcuROD3HNUBM+HesG2n/yLw+
        1lMRGwzXqvHcK5bPJ2HpngKhPVPpVNh14ajZxddF43B/l9n8+0qLh6NTMFEwHQYDVR0O
        BBYEFArGZPvXudxCdA105Q+6J+upaOooMB8GA1UdIwQYMBaAFArGZPvXudxCdA105Q+6
        J+upaOooMA8GA1UdEwEB/wQFMAMBAf8wCgYIKoZIzj0EAwIDSAAwRQIhAKpV/DtnSj4D
        FzBs8RaZI3ErneIJcFka2YsJvdAmw6hUAiBFdTXwJGvAe+N+nlHVAOrC9GEKxZ2exrRZ
        xpBn+P4otg==
        """.replacingOccurrences(of: "\n", with: "")
}

private nonisolated final class UnevaluatedProtectionSpace: URLProtectionSpace, @unchecked Sendable {
    override var serverTrust: SecTrust? {
        Issue.record("Disabled exceptions must not inspect or evaluate the server trust")
        return nil
    }
}

private nonisolated final class UnusedChallengeSender: NSObject, URLAuthenticationChallengeSender {
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
    func cancel(_ challenge: URLAuthenticationChallenge) {}
}
