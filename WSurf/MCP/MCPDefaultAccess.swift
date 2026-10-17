// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Whether a paired app follows the owner's Website access default when it opens a new website.
///
/// The default lives in the profile's SitePermissions.json, which a process with a shell can edit. So an app never reads that
/// file to raise its own access. Whether apps follow the default, and the level the owner approved for them, are in the
/// keychain (`MCPTrustStore`), and Settings alone writes them. The file can only lower the result: the app gets the lower of
/// the two levels, and nothing at all while the keychain cannot be read.
@MainActor
enum MCPDefaultAccess {
    /// The default level paired apps get in `browser`'s window now. Ask unless the owner turned this on, the keychain is
    /// readable and the window is not private.
    static func level(in browser: BrowserModel, trust: MCPTrustStore) -> AssistantAccessPolicy {
        guard trust.isAvailable, trust.appsFollowDefault, !browser.opensPrivately, !browser.context.profile.isPrivate else { return .ask }
        let approved = trust.appsDefaultLevel
        let current = browser.sitePermissions.assistantDefault
        return rank(approved) <= rank(current) ? approved : current
    }

    /// Whether `client` may open and use `url` in `browser`'s window without the Open and Share sheet: it is paired and not
    /// paused, the default it follows is Allow Control, and the website has no choice of its own or chose Allow Control. A
    /// website set to Ask, Read Only or No Access keeps its own rule.
    static func opens(_ url: URL, client: PairedClient?, in browser: BrowserModel, trust: MCPTrustStore) -> Bool {
        guard let id = client?.id, let live = trust.client(id: id), !live.paused,
              level(in: browser, trust: trust) == .control
        else { return false }
        let record = browser.sitePermissions.assistantRecord(for: SitePermissions.origin(for: url))
        return record == nil || record == .control
    }

    /// Ask < Read Only < Allow Control. No Access is not a default, and counts as Ask.
    private static func rank(_ policy: AssistantAccessPolicy) -> Int {
        switch policy {
        case .ask, .deny:
            0
        case .readOnly:
            1
        case .control:
            2
        }
    }
}
