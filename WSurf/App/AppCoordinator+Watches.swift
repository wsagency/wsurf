// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation

extension AppCoordinator {
    /// View › Watch This Page…: hidden in a private window, available for a website on screen.
    static func watchMenuState(isPrivate: Bool, url: URL?) -> (isShown: Bool, isEnabled: Bool) {
        (!isPrivate, !isPrivate && url.map(PageWatchReader.canWatch) == true)
    }

    /// Disabled too in a copy of WSurf that does not own the session: its watches would never be read or kept.
    var watchMenuState: (isShown: Bool, isEnabled: Bool) {
        let state = Self.watchMenuState(isPrivate: profiles.isPrivate, url: pageCommandTab.flatMap { URL(string: $0.urlString) })
        return (state.isShown, state.isEnabled && context.pageWatches?.isScheduling == true)
    }

    /// The person's own request from the menu, so the sheet they answer is the consent. Never in a private window.
    func watchCurrentPage() {
        guard watchMenuState.isEnabled, let center = context.pageWatches, let window = nativeWindow,
              let tab = pageCommandTab, let url = URL(string: tab.urlString) else { return }
        let request = PageWatchRequest(
            url: url,
            title: tab.title,
            condition: "",
            minutes: 60,
            readsWithWebKitInstead: PageWatchReader.readsWithWebKitInstead(url, permissions: context.sitePermissions)
        )
        Task { [weak self] in
            guard let answer = await PageWatchPrompt.ask(request, in: window, fromAssistant: false) else { return }
            let started = await PageWatchCreation.start(answer, in: center)
            guard let self, context.pageWatches === center else { return }
            show(notice: PageWatchCreation.notice(for: started))
            if case .watching = started {
                sidePanel.show(.watches)
            }
        }
    }
}
