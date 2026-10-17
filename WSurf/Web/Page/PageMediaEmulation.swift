// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation

/// The media features and network state an MCP development lease asks one page to emulate. Nil leaves the page's own value.
struct DevelopmentMedia: Equatable {
    enum ColorScheme: String {
        case light, dark
    }

    var colorScheme: ColorScheme?
    /// True is `prefers-reduced-motion: reduce`, false is `no-preference`.
    var reducedMotion: Bool?
    var offline = false

    var isEmpty: Bool {
        self == DevelopmentMedia()
    }
}

/// What a lease changed on its page, so one release puts back exactly that and nothing else.
struct DevelopmentMediaState {
    var media = DevelopmentMedia()
    /// WebKit only: the view's own appearance before the first color-scheme override, which a release puts back.
    var originalAppearance: NSAppearance?

    /// Release path: puts back what this state applied now. A Chromium cleanup is reserved on the page's emulation queue
    /// before this returns, so a lease acquired straight afterwards applies after it; the task ends when the page is clean.
    @MainActor
    func remove(from owner: DevelopmentOwner) -> Task<Void, Never>? {
        guard let page = owner.page else { return nil }
        if let webKit = page.webKit {
            // Compare-then-restore: an appearance somebody else set since is left alone.
            if let scheme = media.colorScheme, webKit.appearance?.name == BrowserPage.appearance(for: scheme)?.name {
                webKit.appearance = originalAppearance
            }
            return nil
        }
        guard let chromium = page.chromium, !media.isEmpty else { return nil }
        return page.emulationQueue.enqueue { await chromium.forceMediaEmulation(DevelopmentMedia()) }
    }
}

struct MeasuredMedia: Equatable {
    let dark: Bool
    let reducedMotion: Bool
    let online: Bool
}

enum DevelopmentMediaOutcome {
    case applied(MeasuredMedia)
    case unsupported(String)
    /// The page did not report the requested values; everything was put back as it was.
    case missed(MeasuredMedia?, String)
    case stale
    /// The caller was cancelled: whatever the request applied was undone and nothing is reported as applied.
    case cancelled
}

extension BrowserPage {
    /// The WebKit view appearance that makes the page report `scheme` as its preferred color scheme.
    fileprivate static func appearance(for scheme: DevelopmentMedia.ColorScheme) -> NSAppearance? {
        NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
    }

    func measureMedia() async -> MeasuredMedia? {
        let script = PageDriver.scripted(
            """
            return JSON.stringify({ dark: matchMedia('(prefers-color-scheme: dark)').matches,
              reduce: matchMedia('(prefers-reduced-motion: reduce)').matches, online: navigator.onLine });
            """)
        guard let object = await PageDriver.evaluateJSON(script, in: self),
            let dark = object["dark"] as? Bool, let reduce = object["reduce"] as? Bool, let online = object["online"] as? Bool
        else { return nil }
        return MeasuredMedia(dark: dark, reducedMotion: reduce, online: online)
    }

    /// Moves the page to `target` (color scheme on either engine; reduced motion and offline on Chromium only), then reads the
    /// values back from the page. A value the page does not report is rolled back, so nothing unverified is kept. Callers
    /// reject what the engine cannot do before calling. The turn goes through the page's emulation queue, behind any cleanup
    /// an earlier lease reserved.
    func applyDevelopmentMedia(_ target: DevelopmentMedia, owner: DevelopmentOwner, tab: BrowserTab) async -> DevelopmentMediaOutcome {
        let previous = owner.media
        let turn = emulationQueue.enqueue { [self] in await runDevelopmentMedia(target, owner: owner, tab: tab) }
        let outcome = await withTaskCancellationHandler { await turn.value } onCancel: { turn.cancel() }
        // Cancelled after the turn finished but before this caller resumed: a success is never reported for it.
        if Task.isCancelled, case .applied = outcome {
            await emulationQueue.enqueue { [self] in
                guard tab.isCurrent(owner) else { return }
                let restored = DevelopmentMediaState(media: previous?.media ?? DevelopmentMedia(), originalAppearance: owner.media?.originalAppearance)
                await forceMedia(restored)
                owner.media = restored.media.isEmpty ? nil : restored
            }.value
            return .cancelled
        }
        return outcome
    }

    private func runDevelopmentMedia(_ target: DevelopmentMedia, owner: DevelopmentOwner, tab: BrowserTab) async -> DevelopmentMediaOutcome {
        guard !Task.isCancelled else { return .cancelled }
        guard tab.isCurrent(owner) else { return .stale }
        let before = owner.media ?? DevelopmentMediaState(originalAppearance: webKit?.appearance)
        var after = before
        after.media = target
        // Undoes this request: the lease's earlier state stays, or nothing remains if the lease itself ended.
        func undo() async {
            let current = tab.isCurrent(owner)
            await forceMedia(current ? before : DevelopmentMediaState(originalAppearance: before.originalAppearance))
            if current {
                owner.media = before.media.isEmpty ? nil : before
            }
        }
        do {
            try await transition(from: before, to: after)
        } catch {
            await undo()
            return .unsupported("Chromium rejected the emulation: \(error.localizedDescription)")
        }
        guard tab.isCurrent(owner), !Task.isCancelled else {
            let stale = !tab.isCurrent(owner)
            await undo()
            return stale ? .stale : .cancelled
        }
        owner.media = after.media.isEmpty ? nil : after
        var measured: MeasuredMedia?
        for attempt in 0..<20 {
            if attempt > 0 {
                do { try await Task.sleep(for: .milliseconds(50)) } catch {
                    await undo()
                    return .cancelled
                }
            }
            measured = await measureMedia()
            guard tab.isCurrent(owner) else {
                await undo()
                return .stale
            }
            if let measured, Self.reports(measured, target: target, previous: before.media) {
                return .applied(measured)
            }
        }
        await undo()
        return .missed(measured, "The page did not report the requested values; emulation was restored.")
    }

    /// Whether `measured` shows every axis `target` changed. An axis the request left alone is not checked.
    private static func reports(_ measured: MeasuredMedia, target: DevelopmentMedia, previous: DevelopmentMedia) -> Bool {
        if let scheme = target.colorScheme, measured.dark != (scheme == .dark) {
            return false
        }
        if let reduce = target.reducedMotion, measured.reducedMotion != reduce {
            return false
        }
        if target.offline != previous.offline, measured.online == target.offline {
            return false
        }
        return true
    }

    /// Applies only what differs between the two states. Throws when Chromium rejects a command; the caller undoes it.
    private func transition(from: DevelopmentMediaState, to: DevelopmentMediaState) async throws {
        if let webKit {
            if from.media.colorScheme != to.media.colorScheme {
                webKit.appearance = to.media.colorScheme.flatMap(Self.appearance(for:)) ?? from.originalAppearance
            }
            return
        }
        guard let chromium else { return }
        if from.media.colorScheme != to.media.colorScheme || from.media.reducedMotion != to.media.reducedMotion {
            try await chromium.setEmulatedMedia(to.media)
        }
        if from.media.offline != to.media.offline {
            try await chromium.setOffline(to.media.offline)
        }
    }

    /// Best effort: puts the page's emulation exactly at `state`, whatever a failed or cancelled request left behind.
    private func forceMedia(_ state: DevelopmentMediaState) async {
        if let webKit {
            webKit.appearance = state.media.colorScheme.flatMap(Self.appearance(for:)) ?? state.originalAppearance
        } else if let chromium {
            await chromium.forceMediaEmulation(state.media)
        }
    }
}
