// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Which parts of one page make sound. The tab counts as playing while any of them does: the page's own document, or a frame inside
/// it (an embedded player, whatever site it is from).
///
/// A frame names itself with a key its script makes up for its document (`frameaudio:<key>:<1|0>`), so the frames of one page
/// are told apart on both engines, and the same script reports the same way from wherever it runs. The engine's own id for the
/// frame is kept beside the key when there is one, so that the engine's word that a frame is gone ends what it said
/// (`forget(engineFrames:)`) even when the frame could not say so itself.
nonisolated struct FrameAudio: Equatable, Sendable {
    /// What a frame's script said: the page's own document (`audio:`), or one of its frames.
    enum Report: Equatable {
        case document(playing: Bool)
        case frame(key: String, playing: Bool)
    }

    /// The most frames kept at once; a page that opens more than this many players is not made to cost more.
    static let maximumFrames = 32

    private(set) var isDocumentPlaying = false
    /// The frames that play: the key each made up, and the engine's id for it (empty when the engine has none).
    private(set) var frames: [String: String] = [:]
    /// The frames that have not confirmed what they said since `beginRefresh`.
    private(set) var unconfirmed: Set<String> = []

    var isPlaying: Bool {
        isDocumentPlaying || !frames.isEmpty
    }

    mutating func apply(_ report: Report, engineFrame: String? = nil) {
        switch report {
        case .document(let playing):
            isDocumentPlaying = playing
        case .frame(let key, let playing):
            unconfirmed.remove(key)
            if playing {
                guard frames[key] != nil || frames.count < Self.maximumFrames else { return }
                frames[key] = engineFrame ?? ""
            } else {
                frames[key] = nil
            }
        }
    }

    /// The engine says these frames are gone, or showed another document. A frame it gave no id (WebKit's) is not one of them.
    mutating func forget(engineFrames ids: Set<String>) {
        frames = frames.filter { $0.value.isEmpty || !ids.contains($0.value) }
    }

    /// The page's frames are asked again what they play: those that say so are kept, and the others are dropped at `endRefresh`.
    /// A frame that went without a word (removed, or showing another page) is found out this way, and the tab does not stop
    /// playing for the moment it takes.
    mutating func beginRefresh() {
        unconfirmed = Set(frames.keys)
    }

    mutating func endRefresh() {
        frames = frames.filter { !unconfirmed.contains($0.key) }
        unconfirmed = []
    }

    /// A new document in the page's own frame: what the old one and its frames said is over.
    mutating func startDocument() {
        isDocumentPlaying = false
        frames = [:]
        unconfirmed = []
    }

    /// The page's renderer is gone: nothing it played goes on.
    mutating func reset() {
        self = FrameAudio()
    }

    /// What a script said, from the message it sent: `audio:1` from the page's own document, `frameaudio:<key>:1` from a frame.
    nonisolated static func report(in message: String, isMainFrame: Bool) -> Report? {
        if message == "audio:1" || message == "audio:0" {
            return isMainFrame ? .document(playing: message.hasSuffix("1")) : nil
        }
        let prefix = "frameaudio:"
        guard !isMainFrame, message.hasPrefix(prefix) else { return nil }
        let fields = message.dropFirst(prefix.count).split(separator: ":", omittingEmptySubsequences: false)
        guard fields.count == 2, fields[1] == "1" || fields[1] == "0",
              (1...48).contains(fields[0].count),
              fields[0].allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return .frame(key: String(fields[0]), playing: fields[1] == "1")
    }
}
