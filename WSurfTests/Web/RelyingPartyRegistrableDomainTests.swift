// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

// The registrable domain (public suffix plus one label) that exact-duplicate detection compares sites by. Public-suffix names are
// rule names here, not user data.
struct RelyingPartyRegistrableDomainTests {
    @Test(arguments: [
        ("example.test", "example.test"),
        ("www.example.test", "example.test"),
        ("login.eu.example.test", "example.test"),
        ("WWW.Example.TEST.", "example.test"),
        ("www.example.co.uk", "example.co.uk"),
        ("a.github.io", "a.github.io"),
        ("deep.a.github.io", "a.github.io"),
    ])
    func aHostIsReducedToItsRegistrableDomain(host: String, expected: String) {
        #expect(RelyingPartyPolicy.registrableDomain(of: host) == expected)
    }

    @Test(arguments: ["com", "co.uk", "github.io", "localhost", "192.0.2.1", "[2001:db8::1]", "", "example.test/path"])
    func aNameWithNoRegistrableDomainHasNone(host: String) {
        #expect(RelyingPartyPolicy.registrableDomain(of: host) == nil)
    }
}
