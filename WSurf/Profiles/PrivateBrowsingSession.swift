// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import WebKit

@MainActor
final class PrivateBrowsingSession {
    let database: AppDatabase
    let dataStore: WKWebsiteDataStore

    init(
        database: AppDatabase = .temporary(),
        dataStore: WKWebsiteDataStore = .nonPersistent()
    ) {
        self.database = database.isEphemeral ? database : .temporary()
        self.dataStore = dataStore.isPersistent ? .nonPersistent() : dataStore
    }
}
