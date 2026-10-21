// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation

extension BrowserSettings {
    var downloadFolder: URL {
        get { globalValue(\.downloadFolder, storage: storedDownloadFolder) }
        set { setGlobal(\BrowserSettings.downloadFolder, storage: \BrowserSettings.storedDownloadFolder, value: newValue, key: Key.downloadFolder, encode: { $0.path(percentEncoded: false) }) }
    }

    var asksWhereToSave: Bool {
        get { globalValue(\.asksWhereToSave, storage: storedAsksWhereToSave) }
        set { setGlobal(\BrowserSettings.asksWhereToSave, storage: \BrowserSettings.storedAsksWhereToSave, value: newValue, key: Key.askWhereToSave) }
    }

    var downloadRetention: DownloadRetention {
        get { globalValue(\.downloadRetention, storage: storedDownloadRetention) }
        set { setGlobal(\BrowserSettings.downloadRetention, storage: \BrowserSettings.storedDownloadRetention, value: newValue, key: Key.downloadRetention, encode: { $0.rawValue }) }
    }

    static var defaultDownloadFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }
}
