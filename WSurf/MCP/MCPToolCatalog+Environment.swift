// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import MCP

nonisolated extension MCPToolCatalog {
    /// Media and network emulation and scoped site-data clearing. Developer tier only: a paired app on a developer site in the
    /// Developer profile.
    static let environmentEntries: [Entry] = [
        Entry(
            name: "emulateMedia",
            description:
                """
                Emulate how the page sees its environment: colorScheme (dark, light or system), reducedMotion \
                (reduce, no-preference or system) and offline (true or false). Omitted settings stay as they are; system removes an \
                override. WebKit supports only colorScheme; reducedMotion and offline are rejected before anything changes. \
                The result reports what the page measured. Needs Developer access and a visible tab. Applies to this tab only; \
                resetDevelopment, disconnecting or losing access removes it.
                """,
            parameters: [
                tab,
                Parameter(name: "colorScheme", type: "string", description: "dark, light, or system.", required: false),
                Parameter(name: "reducedMotion", type: "string", description: "reduce, no-preference, or system. Chromium only.", required: false),
                Parameter(name: "offline", type: "boolean", description: "true makes every request fail. Chromium only.", required: false),
            ], scope: .developer, title: "Emulate Media"),
        Entry(
            name: "clearSiteData",
            description:
                """
                Delete the saved website data of the tab's own site so the next load starts signed out: localStorage, sessionStorage, \
                IndexedDB, Cache Storage and service workers of its origin, and the cookies of its host (cookies are shared by every \
                port of a host). Other sites and the HTTP cache are untouched. Nothing is read or returned except counts. \
                Needs Developer access, a visible tab, a developer site and the Developer profile; never available in your everyday profile.
                """,
            parameters: [tab], scope: .developer, title: "Clear Site Data"),
    ]
}
