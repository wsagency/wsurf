// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation

extension BrowserSettings {
    // MARK: - Media

    var showsMediaPlayer: Bool {
        get { globalValue(\.showsMediaPlayer, storage: storedShowsMediaPlayer) }
        set { setGlobal(\BrowserSettings.showsMediaPlayer, storage: \BrowserSettings.storedShowsMediaPlayer, value: newValue, key: Key.mediaPlayer, didChange: { $0.onMediaPlayerChanged?(newValue) }) }
    }

    var showsLyrics: Bool {
        get { globalValue(\.showsLyrics, storage: storedShowsLyrics) }
        set { setGlobal(\BrowserSettings.showsLyrics, storage: \BrowserSettings.storedShowsLyrics, value: newValue, key: Key.lyrics, didChange: { $0.onLyricsChanged?(newValue) }) }
    }

    var sleepsInactiveTabs: Bool {
        get { globalValue(\.sleepsInactiveTabs, storage: storedSleepsInactiveTabs) }
        set {
            setGlobal(\BrowserSettings.sleepsInactiveTabs, storage: \BrowserSettings.storedSleepsInactiveTabs, value: newValue, key: Key.sleepsInactiveTabs, didChange: {
                $0.onSleepPolicyChanged?()
            })
        }
    }

    var showsLinkPreview: Bool {
        get { globalValue(\.showsLinkPreview, storage: storedShowsLinkPreview) }
        set { setGlobal(\BrowserSettings.showsLinkPreview, storage: \BrowserSettings.storedShowsLinkPreview, value: newValue, key: Key.linkPreview) }
    }

    var peeksAtLinks: Bool {
        get { globalValue(\.peeksAtLinks, storage: storedPeeksAtLinks) }
        set { setGlobal(\BrowserSettings.peeksAtLinks, storage: \BrowserSettings.storedPeeksAtLinks, value: newValue, key: Key.linkPeek) }
    }

    var refractsTabColor: Bool {
        get { globalValue(\.refractsTabColor, storage: storedRefractsTabColor) }
        set { setGlobal(\BrowserSettings.refractsTabColor, storage: \BrowserSettings.storedRefractsTabColor, value: newValue, key: Key.tabColorRefraction) }
    }

    var automaticPictureInPicture: Bool {
        get { globalValue(\.automaticPictureInPicture, storage: storedAutomaticPictureInPicture) }
        set {
            setGlobal(\BrowserSettings.automaticPictureInPicture, storage: \BrowserSettings.storedAutomaticPictureInPicture, value: newValue, key: Key.automaticPiP, didChange: {
                $0.onAutomaticPictureInPictureChanged?(newValue)
            })
        }
    }

    var showsVideoInPlayer: Bool {
        get { globalValue(\.showsVideoInPlayer, storage: storedShowsVideoInPlayer) }
        set {
            setGlobal(\BrowserSettings.showsVideoInPlayer, storage: \BrowserSettings.storedShowsVideoInPlayer, value: newValue, key: Key.videoInPlayer, didChange: { settings in
                if settings.showsVideoInPlayer {
                    settings.automaticPictureInPicture = false
                }
                settings.onVideoInPlayerChanged?(settings.showsVideoInPlayer)
            })
        }
    }
}
