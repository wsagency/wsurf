// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Testing

@testable import WSurf

struct BuildIdentityTests {
    @Test func showsTheCandidateAndCommit() {
        let info = ["WSurfCandidate": "0.1.1-b3", "WSurfCommit": "4b1870a3"]
        #expect(BuildIdentity.candidateLine(info: info) == "Candidate 0.1.1-b3 · 4b1870a3")
    }

    @Test func leavesOutAMissingCommit() {
        #expect(BuildIdentity.candidateLine(info: ["WSurfCandidate": "0.1.1-b3", "WSurfCommit": ""]) == "Candidate 0.1.1-b3")
        #expect(BuildIdentity.candidateLine(info: ["WSurfCandidate": "0.1.1-b3"]) == "Candidate 0.1.1-b3")
    }

    @Test func omitsTheLineForDevEmptyOrMissing() {
        #expect(BuildIdentity.candidateLine(info: ["WSurfCandidate": "dev", "WSurfCommit": "4b1870a3"]) == nil)
        #expect(BuildIdentity.candidateLine(info: ["WSurfCandidate": " ", "WSurfCommit": "4b1870a3"]) == nil)
        #expect(BuildIdentity.candidateLine(info: ["WSurfCommit": "4b1870a3"]) == nil)
        #expect(BuildIdentity.candidateLine(info: nil) == nil)
    }
}
