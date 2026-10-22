// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import WSurfCore
import WSurfVault

@testable import WSurf

// The line under the Review Sync Changes list that says what Dismiss leaves. Dismissing an information row keeps this Mac’s version, so
// the next change made here replaces the version on the other devices without asking: the person is told before they press it.

@MainActor
struct VaultSyncReviewSheetTests {
    private func row(_ kind: SyncConflictKind) -> VaultSyncConflict {
        VaultSyncConflict(id: UUID(), kind: kind, parts: [], local: nil, incoming: nil)
    }

    @Test func theLineAboutDismissShowsExactlyWhileARowHasNothingButDismiss() {
        for kind in SyncConflictKind.allCases {
            #expect(VaultSyncReviewSheet.explainsDismissal([row(kind)]) == !VaultSyncReviewSheet.asksForChoice(kind), "\(kind)")
        }
        #expect(!VaultSyncReviewSheet.explainsDismissal([]))
        #expect(!VaultSyncReviewSheet.explainsDismissal([row(.bothChanged), row(.previouslyRemoved)]), "rows that ask for a choice have their buttons")
        #expect(VaultSyncReviewSheet.explainsDismissal([row(.bothChanged), row(.ambiguous)]))
        #expect(VaultSyncReviewSheet.explainsDismissal([row(.refused)]))
    }

    @Test func theLineSaysWhatDismissLeaves() {
        let line = String(localized: VaultSyncReviewSheet.dismissalNote)
        #expect(line == "Dismiss keeps this Mac’s version. Your next change here replaces the version on your other devices; theirs stays in its History.")
        #expect(line.hasSuffix(".") && !line.contains("'"), "a sentence, with a typographic apostrophe")
    }
}
