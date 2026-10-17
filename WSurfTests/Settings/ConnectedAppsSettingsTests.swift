// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

struct ConnectedAppsSettingsTests {
    @Test func connectedAppsAreFoundInSettingsSearchOnTheAssistantPage() {
        let entry = SettingsIndex.all.first { $0.id == "assistant.connectedApps" }
        #expect(entry?.category == .provider)
        for query in ["connected apps", "paired", "revoke"] {
            #expect(SettingsIndex.search(query).contains { $0.id == "assistant.connectedApps" })
        }
        #expect(SettingsIndex.link(to: "assistant.connectedApps") != nil)
    }

    @Test func theExternalConnectionsLinkReachesAnIndexedPage() {
        let caption = SettingsIndex.caption(
            "Review paired apps in Connected apps.", naming: "Connected apps", at: "assistant.connectedApps"
        )
        #expect(caption.runs.contains { $0.link == SettingsIndex.link(to: "assistant.connectedApps") })
    }
}
