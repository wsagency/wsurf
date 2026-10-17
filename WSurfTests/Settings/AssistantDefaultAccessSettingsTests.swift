// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

/// The words and search entries for the default website access.
@MainActor
struct AssistantDefaultAccessSettingsTests {
    @Test func theCaptionDescribesEachLevel() {
        let ask = String(localized: AssistantAccessPolicy.ask.defaultCaption)
        let readOnly = String(localized: AssistantAccessPolicy.readOnly.defaultCaption)
        let control = String(localized: AssistantAccessPolicy.control.defaultCaption)

        #expect(ask == "The assistant asks before it reads or uses each website.")
        #expect(readOnly.contains("reads websites without asking"))
        #expect(readOnly.contains("clicks, types, or submits"))
        #expect(control.contains("without asking"))
        for consequence in ["purchases", "payments", "sending", "deleting", "signing in", "password or payment fields"] {
            #expect(control.contains(consequence))
        }
    }

    @Test func siteMenusOfferDefaultFirstAndNameIt() {
        #expect(AssistantAccessPolicy.followsDefaultLabel(.control) == "Default (Allow Control)")
        #expect(AssistantAccessPolicy.followsDefaultLabel(.readOnly) == "Default (Read Only)")
        #expect(AssistantAccessPolicy.followsDefaultLabel(.ask) == "Default (Ask)")
    }

    @Test func theDefaultRowIsSearchableOnTheAssistantPage() {
        let entry = SettingsIndex.all.first { $0.id == "assistant.defaultAccess" }
        #expect(entry?.category == .provider)
        #expect(SettingsIndex.search("website access").contains { $0.id == "assistant.defaultAccess" })
        #expect(SettingsIndex.search("allow control").contains { $0.id == "assistant.defaultAccess" })
    }

    @Test func approvedActionsKeepsItsOldName() {
        let entry = SettingsIndex.all.first { $0.id == "privacy.assistant" }
        #expect(entry?.searchableTitle == "Approved actions")
        #expect(SettingsIndex.search("approved actions").contains { $0.id == "privacy.assistant" })
        #expect(SettingsIndex.search("allowed without asking").contains { $0.id == "privacy.assistant" })
    }
}
