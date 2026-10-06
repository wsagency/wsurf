// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

#if DEBUG
import AppKit
import Foundation

@MainActor
enum StageRun {
    private static var tabs: [String: BrowserTab] = [:]

    static func startIfRequested(coordinator: AppCoordinator) {
        guard StageMode.isActive else { return }
        if CredentialIntegrationProbe.isEnabled {
            // Bootstrap installs the main menu asynchronously. Add only an explicit foreground entry.
            Task {
                while coordinator.mainMenu == nil {
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                }
                guard CredentialIntegrationProbe.isEnabled else { return }
                NSApp.mainMenu?.items.first?.submenu?.addItem(title: "Credential Probe…") {
                    CredentialIntegrationProbe.present(coordinator: coordinator)
                }
            }
            return
        }
        Task {
            try? await Task.sleep(for: .seconds(1.2))
            seed(into: coordinator)
        }
    }

    private static func seed(into coordinator: AppCoordinator) {
        let browser = coordinator.browser

        tabs.removeAll()
        browser.closeAllTabs()
        browser.history.clear()

        browser.history.merge(
            StageSet.history.map { visit in
                HistoryStore.Entry(
                    url: visit.site.address,
                    title: visit.site.title,
                    visitCount: visit.visitCount,
                    lastVisit: Date(timeIntervalSinceNow: -visit.hoursAgo * 3_600)
                )
            }
        )
        browser.downloads.stage(StageSet.downloads)

        let reading = StageSet.reading.sites.reversed().map { open($0, in: browser) }
        let folder = browser.createFolder(
            named: StageSet.reading.name,
            containing: reading.reversed()
        )
        browser.setFolderColor(StageSet.reading.color, for: folder)
        folder.isExpanded = true

        for site in StageSet.shipping.sites.reversed() {
            open(site, in: browser)
        }
        for site in StageSet.loose {
            open(site, in: browser)
        }
        for site in StageSet.pinned.reversed() {
            let tab = open(site, in: browser)
            tab.pinnedURL = site.url
            tab.pinnedTitle = site.title
        }

        if let opening = tabs[StageSet.opening.address] {
            browser.activate(opening)
        }
    }

    @discardableResult
    private static func open(_ site: StageSet.Site, in browser: BrowserModel) -> BrowserTab {
        let tab = browser.newTab(url: site.url, activate: false)
        tab.title = site.title
        tabs[site.address] = tab
        return tab
    }
}
#endif
