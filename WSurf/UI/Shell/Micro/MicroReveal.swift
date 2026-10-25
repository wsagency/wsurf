// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Observation

/// Whether the micro bar is down. It is down while the pointer is at the top, for `hostFlash` after the page moves to another
/// site, and for as long as anything keeps it (see `MicroShell.keepsBar`): a prompt the page raised, a missing page, the
/// keyboard in the address. It goes up `hideDelay` after the last of those ends, and the traffic lights follow it.
///
/// Nothing here waits for a view or a poll. The model watches the window itself: AppKit says when a sheet is about to open on
/// it, which is how every page prompt (a JavaScript dialog, a sign-in, a certificate question, an app hand-off, a passkey step)
/// reaches the person, and when a popover is up. Observation says, before it changes, when a permission prompt or a save offer
/// is about to, and afterwards when the page or anything else that keeps the bar changes. So the bar comes down as the prompt
/// appears even when it is up out of the way, and what it cannot tell holds the bar rather than missing it. Durations are
/// inputs so a test does not wait seconds.
///
/// The Minimal window's bar uses the same model with `restsRevealed`: there the bar is shown until the page scrolls down,
/// and scrolling up, a new page or a new site brings it back to rest. The pointer at its edge and every rule above still
/// hold it as they hold the micro bar.
@MainActor
@Observable
final class MicroReveal {
    private(set) var isRevealed = false
    private(set) var isFlashing = false
    /// Sheets and popovers open on the window right now. A prompt of the page's is one of them.
    private(set) var openPrompts = 0
    @ObservationIgnored private(set) var pointerInZone = false
    /// Shown unless the page was scrolled down: the Minimal bar. The micro bar rests hidden.
    @ObservationIgnored let restsRevealed: Bool
    @ObservationIgnored private(set) var isScrolledAway = false
    @ObservationIgnored var hideDelay: Duration
    @ObservationIgnored var hostFlash: Duration
    /// What keeps the bar down whatever the pointer does. Anything it cannot tell is a reason to keep it.
    @ObservationIgnored var keeps: () -> Bool
    /// Whether a page is asking something right now. It is watched on its own, because the bar has to be down before the
    /// prompt is drawn, not a turn of the run loop after.
    @ObservationIgnored private let pending: () -> Bool
    @ObservationIgnored private let window: () -> NSWindow?
    @ObservationIgnored private let host: () -> String?
    @ObservationIgnored private let focusToken: () -> Int
    @ObservationIgnored private var lastHost: String?
    @ObservationIgnored private var lastToken = 0
    @ObservationIgnored private var popovers: Set<ObjectIdentifier> = []
    @ObservationIgnored private var tokens: [any NSObjectProtocol] = []
    @ObservationIgnored private var isStopped = false
    /// Bumped at every start, so a watcher left over from an earlier run never re-arms itself.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var check: Task<Void, Never>?
    @ObservationIgnored private var flash: Task<Void, Never>?

    init(
        hideDelay: Duration = MicroShell.hideDelay,
        hostFlash: Duration = MicroShell.hostFlash,
        restsRevealed: Bool = false,
        window: @escaping () -> NSWindow? = { nil },
        host: @escaping () -> String? = { nil },
        focusToken: @escaping () -> Int = { 0 },
        pending: @escaping () -> Bool = { false },
        keeps: @escaping () -> Bool = { false }
    ) {
        self.hideDelay = hideDelay
        self.hostFlash = hostFlash
        self.restsRevealed = restsRevealed
        isRevealed = restsRevealed
        self.window = window
        self.host = host
        self.focusToken = focusToken
        self.pending = pending
        self.keeps = keeps
    }

    private var holds: Bool {
        restsHere || pointerInZone || isFlashing || openPrompts > 0 || pending() || keeps()
    }

    /// The Minimal bar at rest: nothing scrolled it away. Ending it is always an explicit call, so it needs no checking.
    private var restsHere: Bool {
        restsRevealed && !isScrolledAway
    }

    // MARK: - Watching

    /// Starts watching the window and the page. Again after `stop()`, for a view that comes back.
    func start() {
        guard tokens.isEmpty else { return }
        isStopped = false
        generation &+= 1
        lastHost = host()
        lastToken = focusToken()
        // `object: nil` and no queue: the window may not exist yet, and the bar must come down before the prompt does.
        let center = NotificationCenter.default
        func watchSheets(_ name: Notification.Name, _ handle: @escaping @MainActor (MicroReveal, NSWindow?) -> Void) {
            tokens.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                let window = note.object as? NSWindow
                MainActor.assumeIsolated {
                    if let self, !self.isStopped {
                        handle(self, window)
                    }
                }
            })
        }
        func watchPopovers(_ name: Notification.Name, _ handle: @escaping @MainActor (MicroReveal, NSPopover?) -> Void) {
            tokens.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                let popover = note.object as? NSPopover
                MainActor.assumeIsolated {
                    if let self, !self.isStopped {
                        handle(self, popover)
                    }
                }
            })
        }
        watchSheets(NSWindow.willBeginSheetNotification) { $0.sheetBegan($1) }
        watchSheets(NSWindow.didEndSheetNotification) { $0.sheetEnded($1) }
        watchPopovers(NSPopover.didShowNotification) { $0.popoverShown($1) }
        watchPopovers(NSPopover.didCloseNotification) { $0.popoverClosed($1) }
        watchInputs()
        watchPending()
        update()
    }

    func stop() {
        isStopped = true
        check?.cancel()
        flash?.cancel()
        check = nil
        flash = nil
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens = []
    }

    // ponytail: Observation re-arms after each change, so there is one watcher; it reads what keeps the bar and where the page is.
    private func watchInputs() {
        guard !isStopped else { return }
        let run = generation
        withObservationTracking {
            _ = host()
            _ = focusToken()
            _ = keeps()
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard self?.generation == run else { return }
                self?.inputsChanged()
            }
        }
    }

    private func watchPending() {
        guard !isStopped else { return }
        let run = generation
        withObservationTracking {
            _ = pending()
        } onChange: { [weak self] in
            // This runs as the flag is about to change, on the thread that changes it, before the prompt it stands for can
            // be drawn: the bar comes down now, and what it settles to is read after.
            MainActor.assumeIsolated {
                self?.show()
            }
            Task { @MainActor [weak self] in
                guard self?.generation == run else { return }
                self?.update()
                self?.watchPending()
            }
        }
    }

    private func inputsChanged() {
        guard !isStopped else { return }
        let current = host()
        let token = focusToken()
        defer {
            watchInputs()
        }
        if current != lastHost {
            lastHost = current
            lastToken = token
            siteChanged()
        } else if token != lastToken {
            lastToken = token
            show()
        } else {
            update()
        }
    }

    private func sheetBegan(_ sheeted: NSWindow?) {
        guard let target = window(), sheeted === target else { return }
        openPrompts += 1
        update()
    }

    private func sheetEnded(_ sheeted: NSWindow?) {
        guard let target = window(), sheeted === target else { return }
        openPrompts = max(openPrompts - 1, 0)
        update()
    }

    private func popoverShown(_ popover: NSPopover?) {
        // Shown, not about to be: a popover's window is a child of the window it hangs from only once it is up.
        guard let popover, let target = window(),
              popover.contentViewController?.view.window?.parent === target,
              popovers.insert(ObjectIdentifier(popover)).inserted else { return }
        openPrompts += 1
        update()
    }

    private func popoverClosed(_ popover: NSPopover?) {
        guard let popover, popovers.remove(ObjectIdentifier(popover)) != nil else { return }
        openPrompts = max(openPrompts - 1, 0)
        update()
    }

    // MARK: - Showing and hiding

    func pointer(inZone: Bool) {
        pointerInZone = inZone
        update()
    }

    /// Something that keeps the bar changed: bring it down if it now holds, and look again later if it does not.
    func update() {
        guard !isStopped else { return }
        if holds {
            isRevealed = true
        }
        if isRevealed, !restsHere {
            scheduleCheck()
        }
    }

    /// The page scrolled: down puts a resting bar away at once unless something holds it, up brings it back to rest.
    func scrolled(towardTop: Bool) {
        guard !isStopped else { return }
        isScrolledAway = !towardTop
        if !towardTop, !holds {
            hide()
        } else {
            update()
        }
    }

    /// Back to rest, as if nothing had scrolled: another tab, another page, the bar moved to the other edge.
    func rest() {
        guard !isStopped else { return }
        isScrolledAway = false
        update()
    }

    /// Brings the bar down for a moment, as the address command does before the address has the keyboard.
    func show() {
        guard !isStopped else { return }
        isRevealed = true
        scheduleCheck()
    }

    /// The page moved to another site: the address shows for `hostFlash`, so a page never has the window to itself.
    func siteChanged() {
        guard !isStopped else { return }
        isScrolledAway = false
        isFlashing = true
        isRevealed = true
        flash?.cancel()
        flash = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: hostFlash)
            guard !Task.isCancelled else { return }
            isFlashing = false
            flash = nil
            if holds {
                scheduleCheck()
            } else {
                hide()
            }
        }
        update()
    }

    private func hide() {
        check?.cancel()
        check = nil
        isRevealed = false
    }

    // ponytail: while the bar is down and held it looks again every hideDelay, because the address having the keyboard and a
    // panel that hangs from the window say nothing when they come or go. A notification from the field editor would replace it.
    private func scheduleCheck() {
        check?.cancel()
        check = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: hideDelay)
            guard !Task.isCancelled else { return }
            check = nil
            if restsHere {
                return
            } else if holds {
                scheduleCheck()
            } else {
                hide()
            }
        }
    }
}
