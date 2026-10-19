// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

/// A frame's autofill policy is sent once more when the first call is refused, so a document that was still starting is not left
/// with autofill off; a frame that keeps refusing is not asked forever.
@MainActor
struct AutofillPolicyDeliveryTests {
    private struct Refused: Error {}

    @Test func aDeliveredPolicyIsSentOnce() async {
        var calls = 0, failures = 0
        let delivered = await AutofillPolicyDelivery.deliver(retryAfter: .zero) {
            calls += 1
        } failed: { _ in
            failures += 1
        }
        #expect(delivered && calls == 1 && failures == 0)
    }

    @Test func aRefusedPolicyIsSentOnceMore() async {
        var calls = 0, failures = 0
        let delivered = await AutofillPolicyDelivery.deliver(retryAfter: .zero) {
            calls += 1
            if calls == 1 {
                throw Refused()
            }
        } failed: { _ in
            failures += 1
        }
        #expect(delivered && calls == 2 && failures == 1)
    }

    @Test func aFrameThatKeepsRefusingIsAskedTwiceOnly() async {
        var calls = 0, failures = 0
        let delivered = await AutofillPolicyDelivery.deliver(retryAfter: .zero) {
            calls += 1
            throw Refused()
        } failed: { _ in
            failures += 1
        }
        #expect(!delivered && calls == 2 && failures == 2)
    }
}
