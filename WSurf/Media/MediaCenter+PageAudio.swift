// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation

extension MediaCenter {
    // MARK: - Which parts of a page make sound

    final class PageAudio {
        var audio = FrameAudio()
        var refresh: Task<Void, Never>?
    }

    /// How long the frames of a page are given to say again that they play.
    static let refreshWindow: Duration = .milliseconds(400)

    /// Per page, not per window: a tab moved to another window keeps what its page has said. Weak, so a closed page takes its
    /// entry with it.
    static let pageAudio = NSMapTable<BrowserPage, PageAudio>(keyOptions: .weakMemory, valueOptions: .strongMemory)

    /// Applies `change` to what the page's parts have said, and passes on whether the page, taken as a whole, now plays.
    func updateAudio(of page: BrowserPage, _ change: (inout FrameAudio) -> Void) {
        let entry = Self.pageAudio.object(forKey: page) ?? {
            let made = PageAudio()
            Self.pageAudio.setObject(made, forKey: page)
            return made
        }()
        let before = entry.audio.isPlaying
        change(&entry.audio)
        let after = entry.audio.isPlaying
        if before != after {
            onTabAudioChanged?(page, after)
        }
    }

    /// The engine says these frames are gone or show something else, so what they said about their sound is over.
    func forgetFrames(_ ids: Set<String>, of page: BrowserPage) {
        guard Self.pageAudio.object(forKey: page) != nil else { return }
        updateAudio(of: page) { $0.forget(engineFrames: ids) }
    }

    /// A document of the page saw one of its frames go or load another page. Frames that play are asked again and keep their
    /// place by answering; one that has gone cannot, and is dropped when the time is up. Nothing is done for a page with no
    /// playing frame, which is nearly every page.
    func refreshFrames(of page: BrowserPage) {
        guard let entry = Self.pageAudio.object(forKey: page), !entry.audio.frames.isEmpty, entry.refresh == nil else { return }
        entry.audio.beginRefresh()
        Self.post("wsurf-resend", to: page)
        entry.refresh = Task { [weak self, weak page, weak entry] in
            try? await Task.sleep(for: Self.refreshWindow)
            guard let self, let page, let entry, !Task.isCancelled else { return }
            entry.refresh = nil
            updateAudio(of: page) { $0.endRefresh() }
        }
    }

    func forgetAudio(of page: BrowserPage) {
        Self.pageAudio.object(forKey: page)?.refresh?.cancel()
        Self.pageAudio.removeObject(forKey: page)
    }

    /// What the page's parts have said so far.
    func audio(of page: BrowserPage) -> FrameAudio {
        Self.pageAudio.object(forKey: page)?.audio ?? FrameAudio()
    }

    /// Chromium tells which frames of the page are gone, or show another document, which no script could say for them.
    /// `media` finds the window's center for the page, as the script messages' own route does.
    static func watchFrames(of page: BrowserPage, media: @escaping (BrowserPage) -> MediaCenter?) {
        page.onFramesRetired = { [weak page] ids in
            guard let page else { return }
            media(page)?.forgetFrames(ids, of: page)
        }
    }
}
