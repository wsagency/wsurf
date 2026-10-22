// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Foundation

/// One extension as the Website Settings panel and the extension's toolbar menu show it for the page in front.
struct ExtensionSiteControl: Identifiable, Equatable {
    let id: String
    let name: String
    /// Whether the extension is blocked on the page's website, by a block on that website or on a parent of it.
    let isBlocked: Bool
    /// The website a click acts on: the page's own, or the parent whose block covers it. Allowing the page's own website
    /// would change nothing while a parent still blocks it.
    let host: String
    /// Whether `host` is the page's own website.
    let isPageWebsite: Bool
}

/// What the page in front offers for extensions.
enum ExtensionSiteControls: Equatable {
    /// An internal or non-HTTP page, or no enabled extension runs there.
    case none
    /// The page is in a Chromium tab. Extensions run only in WebKit tabs, so there is nothing to block or allow.
    case webKitOnly
    case extensions([ExtensionSiteControl])
}

/// The per-site controls over the blocking in `ExtensionManager+Websites`. Everything here reads or calls that store, so a
/// block made from the panel, the toolbar menu or Settings is the same block.
extension ExtensionManager {
    /// The enabled extensions that run on `url`, or are blocked there, whatever engine the page uses. HTTP(S) pages only.
    func siteControls(on url: URL?) -> [ExtensionSiteControl] {
        guard let url, let website = Self.website(of: url) else { return [] }
        return actionableExtensions.compactMap { record in
            let blocking = blockingHost(id: record.id, for: website)
            guard blocking != nil || requestsAccess(id: record.id, to: url) else { return nil }
            let host = blocking ?? website
            return ExtensionSiteControl(
                id: record.id, name: record.displayName, isBlocked: blocking != nil,
                host: host, isPageWebsite: host == website
            )
        }
    }

    func siteControls(for tab: BrowserTab?) -> ExtensionSiteControls {
        guard let tab, !tab.isShowingSystemPage else { return .none }
        let controls = siteControls(on: URL(string: tab.urlString))
        guard !controls.isEmpty else { return .none }
        return runsExtensions(in: tab) ? .extensions(controls) : .webKitOnly
    }

    /// Only a WebKit page hosts extensions. A tab that has not loaded yet uses the engine it will load with.
    func runsExtensions(in tab: BrowserTab) -> Bool {
        (tab.loadedEngine ?? tab.preferredEngine(for: URL(string: tab.urlString))) == .webKit
    }

    /// What the Allow and Block buttons do: block an allowed extension on `control.host`, allow a blocked one there again.
    func toggle(_ control: ExtensionSiteControl) {
        setAllowed(control.isBlocked, on: control.host, id: control.id)
    }

    // MARK: - Toolbar menu

    /// The item in the extension's toolbar menu for the page in front: Block on or Allow on the website, or on a Chromium
    /// tab a disabled note saying why there is nothing to choose. Nil when the page offers nothing for this extension.
    func siteMenuItem(for id: String, in window: ExtensionWindowAdapter) -> NSMenuItem? {
        guard let tab = window.browser?.activeTab, !tab.isShowingSystemPage,
              let control = siteControls(on: URL(string: tab.urlString)).first(where: { $0.id == id })
        else { return nil }
        guard runsExtensions(in: tab) else {
            let note = NSMenuItem(title: String(localized: "Extensions run only in WebKit tabs. This tab uses Chromium."), action: nil, keyEquivalent: "")
            note.isEnabled = false
            return note
        }
        return appMenuItem(
            title: control.isBlocked ? String(localized: "Allow on \(control.host)") : String(localized: "Block on \(control.host)"),
            action: control.isBlocked ? #selector(allowOnWebsiteFromMenu(_:)) : #selector(blockOnWebsiteFromMenu(_:)),
            id: id, window: window, host: control.host
        )
    }

    @objc private func blockOnWebsiteFromMenu(_ sender: NSMenuItem) {
        setWebsiteFromMenu(sender, allowed: false)
    }

    @objc private func allowOnWebsiteFromMenu(_ sender: NSMenuItem) {
        setWebsiteFromMenu(sender, allowed: true)
    }

    private func setWebsiteFromMenu(_ sender: NSMenuItem, allowed: Bool) {
        guard let command = sender.representedObject as? ExtensionMenuCommand,
              let window = command.window, owns(window), let host = command.host else { return }
        setAllowed(allowed, on: host, id: command.id)
    }
}
