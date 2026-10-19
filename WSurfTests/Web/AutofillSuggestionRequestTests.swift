// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

/// When a `select` from the page is the dropdown request already open for that page, and when it starts a new one. The page script
/// sends a `select` with the same field token for every focus and click on a field it still tracks.
struct AutofillSuggestionRequestTests {
    private let token = UUID().uuidString
    private let document = UUID().uuidString

    @Test func theFocusAndClickOfOneInteractionShareTheOpenRequest() {
        #expect(AutofillSuggestions.continues(token: token, documentID: document, open: (token: token, documentID: document), isSettled: false))
    }

    @Test func selectingTheSameFieldAfterAnyDismissalOpensTheDropdownAgain() {
        // Escape, a click elsewhere or another window closed the panel, or the lookup found nothing: the field token is unchanged.
        #expect(!AutofillSuggestions.continues(token: token, documentID: document, open: (token: token, documentID: document), isSettled: true))
    }

    @Test func anotherFieldOrDocumentIsNeverTheOpenRequest() {
        let open = (token: token, documentID: document)
        #expect(!AutofillSuggestions.continues(token: UUID().uuidString, documentID: document, open: open, isSettled: false))
        #expect(!AutofillSuggestions.continues(token: token, documentID: UUID().uuidString, open: open, isSettled: false))
    }
}
