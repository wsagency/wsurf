// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit

// D4 (out-of-process Chromium), phase 3: the view a person's keyboard, pointer and text input reach for a page that runs in the Chromium
// service. A page in process hosts CEF's own view, which is the first responder and the text input client; here nothing of CEF is in
// WSurf's process, so this transparent view stands where that view would. It is made by `materializeRemote` and by nothing else, so a
// page in process never has one. It draws nothing and has no layer of its own: the page's frames are the frame sink's layer.
//
// Pointer, wheel and cursor are in `+Pointer` (D4-12), keys and focus in `+Keys` (D4-12). Text input (D4-13) and the rest of phase 3
// land on this view too, never on `ChromiumPage`, whose responder behaviour in process must not change (plan C1).

@MainActor
final class ChromiumRemoteContentView: NSView {
    /// The page's browser in the service, set when the view is installed (`attachRemoteFrameLayer`); nothing is sent without it.
    weak var browser: ChromiumRemoteBrowser?

    // The pointer (`+Pointer`).
    var trackingArea: NSTrackingArea?
    var remoteCursor = NSCursor.arrow
    var scrollResidual = CGPoint.zero
    /// A test's own point for an event that cannot carry a window location (a wheel or thumb-button event made from a CGEvent).
    var eventPoint: ((NSEvent) -> CGPoint)?

    /// The key-down events sent to the page that it has not answered, oldest first: the page reports a key it did not handle by its
    /// key code only, and the event that goes on in the app is the one made for it (`+Keys`).
    var sentKeyDowns: [NSEvent] = []
    /// The key-down this view handed on to the app (`redispatchUnhandledKey`) while the hand-on runs. Whatever the app does with it, it
    /// never comes back to the page: the view neither sends it again nor claims it as a key equivalent.
    var redispatching: NSEvent?
    /// An editable field of the page has the focus (`text.input`): see `lineKey(for:)`.
    var editableFocused = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
    }

    required init?(coder: NSCoder) {
        nil
    }

    var owningPage: ChromiumPage? {
        browser?.page
    }

    override var isFlipped: Bool {
        true
    }

    override var acceptsFirstResponder: Bool {
        true
    }
}
