// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import os
import WebKit

extension BrowserModel {
    // MARK: - Memory pressure

    private static let warningKeepsRecent = 3

    @discardableResult
    func discardBackgroundTabs(keepingRecent keep: Int = 0) -> Int {
        let spared = Set([activeTabID].compactMap { $0 } + recentlyActive.prefix(keep))
        var discarded = 0
        for tab in tabs where !spared.contains(tab.id)
            && !tab.isFavorite
            && tab.canDiscardWebContent
            && protectionReason(for: tab) == nil {
            tab.discardWebContent()
            discarded += 1
        }
        return discarded
    }

    @discardableResult
    func unload(_ tab: BrowserTab) -> Bool {
        guard tabsByID[tab.id] === tab else { return false }
        guard tab.isMaterialised else { return true }
        guard !tab.isDeferred, !tab.urlString.isEmpty else { return true }

        let splitReplacement = activeTabID == tab.id
            ? activeSplit?.tabs.compactMap { tabsByID[$0] }.first { $0 !== tab }
            : nil
        guard tab.intrinsicProtectionReason == nil,
              !downloads.hasActiveDownload(for: tab.id),
              !keepsActive(tab)
        else { return false }
        if protectionReason(for: tab) == .visibleInSplit {
            removeFromSplit(tab)
        }
        guard tab.canDiscardWebContent else { return true }

        if activeTabID == tab.id {
            let replacement = splitReplacement
                ?? tabs.first { $0 !== tab && $0.isMaterialised && !$0.isDeferred }
            if let replacement {
                activeTabID = replacement.id
            } else {
                hasNoActiveTab = true
                activeTabID = nil
            }
        }
        tab.discardWebContent()
        scheduleSave()
        return !tab.isMaterialised
    }

    func unload(_ items: [SidebarItem]) {
        let selected = tabs(under: items)
        let selectedIDs = Set(selected.map(\.id))
        if let active = activeTab, selectedIDs.contains(active.id),
           active.intrinsicProtectionReason == nil,
           !downloads.hasActiveDownload(for: active.id),
           !keepsActive(active) {
            if let replacement = tabs.first(where: {
                !selectedIDs.contains($0.id) && $0.isMaterialised && !$0.isDeferred
            }) {
                activate(replacement)
            } else {
                hasNoActiveTab = true
                activeTabID = nil
            }
        }
        for tab in selected {
            _ = unload(tab)
        }
    }

    func protectionReason(for tab: BrowserTab) -> TabProtectionReason? {
        if let reason = tab.intrinsicProtectionReason {
            return reason
        }
        if downloads.hasActiveDownload(for: tab.id) {
            return .activeDownload
        }
        if keepsActive(tab) {
            return .alwaysKeepActive
        }
        if isVisibleInSplit(tab) {
            return .visibleInSplit
        }
        return nil
    }

    func siteOrigin(for tab: BrowserTab) -> String {
        guard let url = URL(string: tab.urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return "" }
        return SitePermissions.origin(for: url)
    }
    func setEngine(_ engine: BrowserEngine, for origin: String) async -> Bool {
        let permissions = sitePermissions
        let canonical = SitePermissions.origin(for: URL(string: origin))
        guard let scheme = URL(string: canonical)?.scheme?.lowercased(),
              scheme == "http" || scheme == "https"
        else { return false }
        guard sitePermissions.engine(for: canonical) != engine else { return true }

        let affected = tabs.filter { siteOrigin(for: $0) == canonical && $0.isMaterialised }
        let protected = affected.contains {
            $0.intrinsicProtectionReason != nil || downloads.hasActiveDownload(for: $0.id)
        }
        if protected {
            guard await ConfirmAlert.destructive(
                "Switch rendering engine?",
                detail: "This reloads the website and may end active work, media, or downloads.",
                verb: "Switch Engine"
            ) else { return false }
        }
        guard sitePermissions === permissions else { return false }

        sitePermissions.setEngine(engine, for: canonical)
        await applyStoredEngine(to: canonical)
        return true
    }

    func engine(for tab: BrowserTab) -> BrowserEngine {
        sitePermissions.engine(for: siteOrigin(for: tab))
    }

    func applyStoredEngine(to origin: String) async {
        let engine = sitePermissions.engine(for: origin)
        for tab in tabs where siteOrigin(for: tab) == origin && tab.isMaterialised {
            guard tab.page.engine != engine else { continue }
            _ = await tab.switchEngine(to: engine)
        }
    }

    func keepsActive(_ tab: BrowserTab) -> Bool {
        let origin = siteOrigin(for: tab)
        return !origin.isEmpty && sitePermissions.keepsActive(origin)
    }

    func setKeepsActive(_ keepsActive: Bool, for tab: BrowserTab) {
        let origin = siteOrigin(for: tab)
        guard !origin.isEmpty else { return }
        sitePermissions.setKeepsActive(keepsActive, for: origin)
    }

    func allowsAutomaticPicture(_ tab: BrowserTab) -> Bool {
        let origin = siteOrigin(for: tab)
        return origin.isEmpty || sitePermissions.allowsAutomaticPicture(origin)
    }

    func setAllowsAutomaticPicture(_ allows: Bool, for tab: BrowserTab) {
        let origin = siteOrigin(for: tab)
        guard !origin.isEmpty else { return }
        sitePermissions.setAllowsAutomaticPicture(allows, for: origin)
    }

    func relieveMemoryPressure(_ level: MemoryPressureMonitor.Level) {
        WebViewPool.shared.discardIdleForMemoryPressure()
        guard BrowserSettings.shared.sleepsInactiveTabs else { return }
        let keep = level == .critical ? 0 : Self.warningKeepsRecent
        let discarded = discardBackgroundTabs(keepingRecent: keep)
        guard discarded > 0 else { return }
        Pipeline.log.notice("memory pressure: discarded \(discarded, privacy: .public) background tabs")
    }

    func applyWebSettings() {
        let settings = BrowserSettings.shared
        for tab in tabs where tab.isMaterialised {
            settings.apply(to: tab.page)
            tab.refreshPopupPolicy()
        }
        WebViewPool.shared.discardIdle()
    }

    func autoplay(for tab: BrowserTab) -> AutoplayPolicy {
        let origin = siteOrigin(for: tab)
        guard !origin.isEmpty else { return BrowserSettings.shared.autoplay }
        return sitePermissions.autoplay(for: origin) ?? BrowserSettings.shared.autoplay
    }

    func setAutoplay(_ policy: AutoplayPolicy, for tab: BrowserTab) {
        let origin = siteOrigin(for: tab)
        guard !origin.isEmpty else { return }
        sitePermissions.setAutoplay(policy == BrowserSettings.shared.autoplay ? nil : policy, for: origin)
    }

    func popups(for tab: BrowserTab) -> PopupPolicy {
        tab.popups.effective
    }

    func setPopups(_ policy: PopupPolicy, for tab: BrowserTab) {
        let origin = siteOrigin(for: tab)
        guard !origin.isEmpty else { return }
        let fallback: PopupPolicy = BrowserSettings.shared.blocksPopups ? .blockAndNotify : .allow
        sitePermissions.setPopups(policy == fallback ? nil : policy, for: origin)
        tab.refreshPopupPolicy()
    }

    // MARK: - The browser's own pages

    @discardableResult
    func showSettings() -> BrowserTab {
        show(.settings)
    }

    @discardableResult
    func showHistory() -> BrowserTab {
        show(.history)
    }

    @discardableResult
    func showDownloads() -> BrowserTab {
        show(.downloads)
    }

    @discardableResult
    func showReleaseNotes() -> BrowserTab {
        show(.releaseNotes)
    }

    @discardableResult
    private func show(_ page: BrowserTab.InternalPage) -> BrowserTab {
        sidebarSelection.dropMarks()

        if let existing = tabs.first(where: { $0.internalPage == page }) {
            activeTabID = existing.id
            return existing
        }

        let tab: BrowserTab
        if let active = activeTab, SystemPages.showsStartFace(active) {
            tab = active
            activeTabID = tab.id
            tab.load(page.url)
        } else {
            tab = newTab(url: page.url, after: activeTab)
        }
        tab.title = page.title
        tab.urlString = page.url.absoluteString
        scheduleSave()
        return tab
    }

    func dismissInternalPage(_ page: BrowserTab.InternalPage) {
        guard let tab = tabs.first(where: { $0.internalPage == page }) else { return }
        if tab.canGoBack {
            tab.goBack()
            return
        }
        if tabs.count > 1 {
            if activeTabID == tab.id,
               let previous = recentlyActive.first(where: { $0 != tab.id && tabsByID[$0] != nil }) {
                activeTabID = previous
            }
            close(tab)
            return
        }
        tab.load(SystemPages.start)
    }

    func contextSummary(mentionedTabIDs: [UUID] = []) -> String? {
        let split = activeSplit
        let onScreen = splitPanes ?? [activeTab].compactMap { $0 }
        var seen = Set(onScreen.map(\.id))
        let mentioned = mentionedTabIDs.compactMap { id -> BrowserTab? in
            guard let tab = tabsByID[id], seen.insert(id).inserted else { return nil }
            return tab
        }
        let pages = onScreen + mentioned
        guard !pages.isEmpty else { return nil }
        let lines = pages.enumerated().map { index, tab -> String in
            let host = URL(string: tab.urlString)?.displayHost ?? "blank"
            var marks: [String] = []
            if let place = split.flatMap({ Self.paneName(of: tab.id, in: $0) }) {
                marks.append("ON SCREEN, \(place)")
            }
            if tab.id == activeTab?.id {
                marks.append("ACTIVE")
            }
            if mentionedTabIDs.contains(tab.id) {
                marks.append("MENTIONED")
            }
            let marker = marks.isEmpty ? "" : " ← " + marks.joined(separator: ", ")
            return "\(index + 1). \(tab.title) (\(host))\(marker)"
        }
        var summary = "[Pages in context:\n" + lines.joined(separator: "\n")
        if let split {
            summary += """

                Split view: the \(split.count) pages marked ON SCREEN share the window, so the user is \
                looking at all of them at once. "these pages", "both of them" and "compare them" mean \
                exactly those, in that order - never ask which. Read one of them with readPage's page \
                argument; switchTab moves the active pane without hiding any of them.
                """
        }
        if !mentionedTabIDs.isEmpty {
            summary += """

                The user attached the tabs marked MENTIONED to this request. Read one with readPage's \
                page argument (its title or host) without switching to it; the request is about them.
                """
        }
        return summary + "]"
    }

    private nonisolated static func paneName(of tabID: UUID, in split: TabSplit) -> String? {
        guard let index = split.tabs.firstIndex(of: tabID) else { return nil }
        let place = "pane \(index + 1) of \(split.count)"
        if split.count == 2 {
            switch split.axis {
            case .sideBySide:
                return index == 0 ? "left" : "right"
            case .stacked:
                return index == 0 ? "top" : "bottom"
            case nil:
                return place
            }
        }
        switch split.lineAxis {
        case .sideBySide:
            return "\(place) from the left"
        case .stacked:
            return "\(place) from the top"
        case nil:
            return place
        }
    }

    // MARK: - Address input

    static func looksLikeLocation(_ text: String) -> Bool {
        if text.contains("://") {
            return true
        }
        return text.contains(".") && !text.contains(" ")
    }

    func handleAddressInput(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let tab = ensureActiveTab()

        if text.contains("://"), let url = URL(string: text) {
            tab.load(url)
        } else if Self.looksLikeLocation(text), let url = URL(string: "https://\(text)") {
            tab.load(url)
        } else {
            tab.load(SearchURLBuilder.searchURL(for: text))
        }
    }
}
