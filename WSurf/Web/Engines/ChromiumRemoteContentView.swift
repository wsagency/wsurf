// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit

// D4 (out-of-process Chromium), phase 3, PR D4-11: the view a person's keyboard, pointer and text input will reach for a page that runs
// in the Chromium service. A page in process hosts CEF's own view, which is the first responder and the text input client; here nothing
// of CEF is in WSurf's process, so this transparent view stands where that view would. It is made by `materializeRemote` and by nothing
// else, so a page in process never has one. It draws nothing and has no layer of its own: the page's frames are the frame sink's layer.
//
// Input (D4-12), text input (D4-13) and the rest of phase 3 are not here yet. All of it lands on this view, never on `ChromiumPage`,
// whose responder behaviour in process must not change (plan C1).

@MainActor
final class ChromiumRemoteContentView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool {
        true
    }

    override var acceptsFirstResponder: Bool {
        true
    }
}
