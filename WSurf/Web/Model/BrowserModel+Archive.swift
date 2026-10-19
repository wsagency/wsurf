// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import os

extension BrowserModel {
    // MARK: - Archiving

    /// Marks the tabs as used at `date`, and the other panes of a split with each of them.
    func noteUse(of ids: [UUID?], at date: Date = Date()) {
        for id in ids.compactMap({ $0 }) {
            tabsByID[id]?.lastActiveAt = date
            for other in splits.others(of: id) {
                tabsByID[other]?.lastActiveAt = date
            }
        }
    }

    /// The tabs the archive may close. Pins, Favorites, folders and splits are the person's arrangement; a tab the
    /// process protections keep alive (a working assistant or MCP client, a download, media, an edited form) is in use.
    func staleTabs(unusedFor interval: TimeInterval, now: Date = Date()) -> [BrowserTab] {
        let cutoff = now.addingTimeInterval(-interval)
        let paired = splits.pairedTabs
        let active = activeTab?.id
        return tabs.filter { tab in
            tab.id != active
                && tab.lastActiveAt < cutoff
                && tab.pinID == nil
                && tab.pinnedURL == nil
                && !tab.isFavorite
                && !tab.isPrivate
                && !paired.contains(tab.id)
                && folder(containing: tab) == nil
                && protectionReason(for: tab) == nil
        }
    }

    @discardableResult
    func archiveStaleTabs(now: Date = Date()) -> Int {
        archiveTabs(unusedFor: context.settings.archiveTabsAfter, now: now)
    }

    /// Closes the stale tabs without putting them on the reopen stack (⇧⌘T) and records them in the archive,
    /// the most recently used last, so that a full archive drops the least recently used first.
    @discardableResult
    func archiveTabs(unusedFor delay: TabArchiveDelay, now: Date = Date()) -> Int {
        guard !opensPrivately, sessionClosedAt == nil, let interval = delay.interval else { return 0 }
        let stale = staleTabs(unusedFor: interval, now: now)
        guard !stale.isEmpty else { return 0 }
        tabArchive.add(
            stale.sorted { $0.lastActiveAt < $1.lastActiveAt }.map { ($0.title, $0.urlString) },
            at: now
        )
        for tab in stale {
            close(tab, recordForReopening: false)
        }
        Pipeline.log.notice("archive: archived \(stale.count, privacy: .public) unused tabs")
        return stale.count
    }

    /// Follows the archive delay for this window. `running` is false once the window is closing.
    func applyArchiveSweeper(running: Bool = true) {
        guard running else {
            archiveSweeper.stop()
            return
        }
        archiveSweeper.apply(context.settings.archiveTabsAfter) { [weak self] in
            self?.archiveStaleTabs()
        }
    }

    @discardableResult
    func restore(_ entry: TabArchive.Entry) -> BrowserTab? {
        guard let url = URL(string: entry.url) else { return nil }
        tabArchive.remove(entry)
        let tab = newTab(url: url, after: activeTab)
        tab.title = entry.title
        return tab
    }
}
