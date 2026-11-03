// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import Testing

@testable import WSurf

@MainActor
struct AuthChallengeTests {
    private func space(
        method: String,
        host: String = "example.com"
    ) -> URLProtectionSpace {
        URLProtectionSpace(
            host: host,
            port: 443,
            protocol: "https",
            realm: nil,
            authenticationMethod: method
        )
    }

    @Test func serverTrustGoesToCertificateEvaluation() {
        #expect(
            AuthChallenge.decision(
                for: space(method: NSURLAuthenticationMethodServerTrust),
                previousFailureCount: 0
            ) == .evaluateServerTrust
        )
    }

    @Test func serverTrustIsNeverRejectedForFailures() {
        #expect(
            AuthChallenge.decision(
                for: space(method: NSURLAuthenticationMethodServerTrust),
                previousFailureCount: 5
            ) == .evaluateServerTrust
        )
    }

    @Test(arguments: [
        NSURLAuthenticationMethodHTTPBasic,
        NSURLAuthenticationMethodHTTPDigest,
        NSURLAuthenticationMethodNTLM,
    ])
    func passwordMethodsPrompt(method: String) {
        #expect(
            AuthChallenge.decision(for: space(method: method), previousFailureCount: 0)
                == .promptForCredential
        )
    }

    @Test func secondFailureStillPrompts() {
        #expect(
            AuthChallenge.decision(
                for: space(method: NSURLAuthenticationMethodHTTPBasic),
                previousFailureCount: 2
            ) == .promptForCredential
        )
    }

    @Test func thirdFailureRejectsInsteadOfRepromptingForever() {
        #expect(
            AuthChallenge.decision(
                for: space(method: NSURLAuthenticationMethodHTTPBasic),
                previousFailureCount: 3
            ) == .rejectProtectionSpace
        )
    }

    @Test(arguments: [
        NSURLAuthenticationMethodClientCertificate,
        NSURLAuthenticationMethodNegotiate,
        NSURLAuthenticationMethodHTMLForm,
    ])
    func nonPasswordMethodsUseDefaultHandling(method: String) {
        #expect(
            AuthChallenge.decision(for: space(method: method), previousFailureCount: 0)
                == .useDefaultHandling
        )
    }

    @Test func passwordBasedMatchesTheThreeInteractiveMethods() {
        #expect(AuthChallenge.isPasswordBased(NSURLAuthenticationMethodHTTPBasic))
        #expect(AuthChallenge.isPasswordBased(NSURLAuthenticationMethodHTTPDigest))
        #expect(AuthChallenge.isPasswordBased(NSURLAuthenticationMethodNTLM))
        #expect(!AuthChallenge.isPasswordBased(NSURLAuthenticationMethodServerTrust))
        #expect(!AuthChallenge.isPasswordBased(NSURLAuthenticationMethodClientCertificate))
        #expect(!AuthChallenge.isPasswordBased(NSURLAuthenticationMethodHTMLForm))
    }

    // MARK: Whose sheet it is

    @Test func theOriginIsTheSchemeHostAndANonDefaultPort() throws {
        #expect(AuthChallenge.origin(of: URL(string: "https://Example.com/a?b=1")) == "https://example.com")
        #expect(AuthChallenge.origin(of: URL(string: "https://example.com:443/")) == "https://example.com")
        #expect(AuthChallenge.origin(of: URL(string: "http://example.com:8080/")) == "http://example.com:8080")
        #expect(AuthChallenge.origin(of: URL(string: "http://example.com:443/")) == "http://example.com:443")
        #expect(AuthChallenge.origin(of: URL(string: "about:blank")) == nil)
        #expect(AuthChallenge.origin(of: nil) == nil)
    }

    @Test func onlyThePagesOwnWebsiteOrAProxyMayAsk() throws {
        let page = URL(string: "https://example.com/account")
        let own = URLProtectionSpace(
            host: "example.com", port: 443, protocol: "https", realm: "Staff", authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        #expect(AuthChallenge.mayPrompt(for: own, topLevel: [page]))
        #expect(AuthChallenge.mayPrompt(for: own, topLevel: [nil, page]))
        #expect(!AuthChallenge.mayPrompt(for: own, topLevel: [nil]))
        for (host, port, scheme) in [("evil.test", 443, "https"), ("example.com", 8443, "https"), ("example.com", 80, "http"),
                                     ("example.com.evil.test", 443, "https"),
                                    ] {
            let other = URLProtectionSpace(
                host: host, port: port, protocol: scheme, realm: "example.com – session expired",
                authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
            #expect(!AuthChallenge.mayPrompt(for: other, topLevel: [page]), "\(scheme)://\(host):\(port)")
        }
        let proxy = URLProtectionSpace(
            proxyHost: "proxy.test", port: 3128, type: NSURLProtectionSpaceHTTPProxy, realm: "corp",
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic)
        #expect(AuthChallenge.mayPrompt(for: proxy, topLevel: [page]))
        #expect(AuthChallenge.askingOrigin(of: proxy) == "proxy.test:3128")
        #expect(AuthChallenge.askingOrigin(of: own) == "https://example.com")
    }
}
