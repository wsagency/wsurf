// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Testing

@testable import WSurf

/// Runs a suite's tests with the 450 ms pause after an announced page action skipped. The pause is a UX delay after the
/// highlight ring shows (PageDriver.announce); a test that asserts it overrides `PageDriver.$pauseSleeper` itself, and
/// that inner value wins. Apply it only to suites that read no elapsed time.
struct NoAnnouncePause: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool {
        true
    }

    func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        try await PageDriver.$pauseSleeper.withValue({ _ in }) {
            try await function()
        }
    }
}

extension Trait where Self == NoAnnouncePause {
    static var noAnnouncePause: Self {
        Self()
    }
}
