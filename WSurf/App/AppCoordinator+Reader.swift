// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import Foundation

extension AppCoordinator {
    /// The tab Reader acts on: the one in front. A Peek over it or a split of several pages shows no Reader, so those have none.
    var readerTab: BrowserTab? {
        guard shownPeek == nil, browser.activeSplit == nil else { return nil }
        return browser.activeTab
    }

    func toggleReader() {
        readerTab?.reader.toggle()
    }

    /// Read Aloud, Pause Reading and Resume Reading are one command, as the button in Reader's bar is one button.
    func toggleReadAloud() {
        readerTab?.reader.toggleListening()
    }

    func stopReadAloud() {
        readerTab?.reader.stopListening()
    }
}
