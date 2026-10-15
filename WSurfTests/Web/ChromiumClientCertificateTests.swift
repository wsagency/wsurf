// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

@MainActor
struct ChromiumClientCertificateTests {
    private let first = Data([0x30, 0x01])
    private let second = Data([0x30, 0x02])

    @Test func exactDERMatchReturnsItsIndex() {
        var asked: URL?
        let index = ChromiumClient.chooseClientCertificate(
            host: "mirovinsko.example",
            candidates: [first, second],
            isActive: true,
            preferred: { asked = $0; return self.second }
        )
        #expect(index == 1)
        #expect(asked == URL(string: "https://mirovinsko.example"))
    }

    @Test func missReturnsNil() {
        let index = ChromiumClient.chooseClientCertificate(
            host: "example.com", candidates: [first], isActive: true, preferred: { _ in self.second }
        )
        #expect(index == nil)
    }

    @Test func noPreferenceReturnsNil() {
        let index = ChromiumClient.chooseClientCertificate(
            host: "example.com", candidates: [first], isActive: true, preferred: { _ in nil }
        )
        #expect(index == nil)
    }

    @Test func emptyCandidatesReturnNil() {
        let index = ChromiumClient.chooseClientCertificate(
            host: "example.com", candidates: [], isActive: true, preferred: { _ in self.first }
        )
        #expect(index == nil)
    }

    @Test func inactiveFeatureNeverChooses() {
        let index = ChromiumClient.chooseClientCertificate(
            host: "example.com", candidates: [first], isActive: false, preferred: { _ in self.first }
        )
        #expect(index == nil)
    }
}
