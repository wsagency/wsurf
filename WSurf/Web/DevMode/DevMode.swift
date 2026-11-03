// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import AppKit
import Foundation
import Network
import OSLog
import WebKit

/// Developer mode for websites: the address field shows the full address, the page has a Developer Tools button, and the
/// Web Inspector is available even when the Web Inspector setting is off. It is a browsing aid for the person's own sites
/// and has nothing to do with the access an external connection can be given to developer sites. Nothing here reads or
/// writes that access, and nothing there reads these choices (`DevModeTests` scans both directions).
nonisolated enum DevMode {
    static let log = Logger(subsystem: "io.wsagency.wsurf", category: "devmode")

    private static let localSuffixes = [".localhost", ".test", ".local"]

    /// The lowercased host of an http(s) address, without the brackets of an IPv6 literal. Nil for any other address.
    static func host(of url: URL?) -> String? {
        guard let url, let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty
        else { return nil }
        return host.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
    }

    /// The websites that use Developer mode without being asked: localhost and its subdomains, `.test` and `.local` names,
    /// the loopback addresses and 0.0.0.0. A name that only contains one of these (`localhost.example.com`) is not local.
    static func isLocal(_ host: String) -> Bool {
        if host == "localhost" || host == "0.0.0.0" {
            return true
        }
        if let address = IPv4Address(host) {
            return address.rawValue.first == 127
        }
        if let address = IPv6Address(host) {
            return address.isLoopback
        }
        return localSuffixes.contains { host.hasSuffix($0) }
    }
}

/// The websites a profile turned Developer mode on or off for by hand. A choice that matches the automatic rule is not
/// stored, so the lists only ever hold exceptions and the person can always get back to "automatic" by choosing again.
nonisolated struct DevModeSites: Equatable {
    var enabled: Set<String> = []
    var disabled: Set<String> = []

    func uses(_ url: URL?) -> Bool {
        guard let host = DevMode.host(of: url) else { return false }
        if enabled.contains(host) {
            return true
        }
        if disabled.contains(host) {
            return false
        }
        return DevMode.isLocal(host)
    }

    mutating func set(_ isOn: Bool, for url: URL?) {
        guard let host = DevMode.host(of: url) else { return }
        enabled.remove(host)
        disabled.remove(host)
        guard isOn != DevMode.isLocal(host) else { return }
        if isOn {
            enabled.insert(host)
        } else {
            disabled.insert(host)
        }
    }
}

/// What the Developer Tools menu changes in one tab. It lives only as long as the tab and only while Developer mode is on
/// for the tab's website.
nonisolated struct DevModeTools: Equatable {
    nonisolated enum Appearance: CaseIterable {
        case system
        case light
        case dark

        var title: LocalizedStringResource {
            switch self {
            case .system:
                "Match System"
            case .light:
                "Light"
            case .dark:
                "Dark"
            }
        }

        /// The `prefers-color-scheme` a Chromium page is given, where WebKit's is the view's appearance.
        var colorScheme: DevelopmentMedia.ColorScheme? {
            switch self {
            case .system:
                nil
            case .light:
                .light
            case .dark:
                .dark
            }
        }

        var appearance: NSAppearance? {
            switch self {
            case .system:
                nil
            case .light:
                NSAppearance(named: .aqua)
            case .dark:
                NSAppearance(named: .darkAqua)
            }
        }
    }

    var showsFrameRate = false
    var outlinesElements = false
    var appearance = Appearance.system

    var hasOverlays: Bool {
        showsFrameRate || outlinesElements
    }
}

/// Per-tab state kept beside the tab, so `BrowserTab` itself gains no stored property.
@MainActor
private final class DevModeState {
    var tools = DevModeTools()
    /// True while the overlay script has left an overlay in the document the tab shows.
    var overlaysShown = false
    /// The appearance this feature put on the web view, so only that is ever taken off again.
    var appliedAppearance: NSAppearance?
}

extension BrowserTab {
    private static let devModeStates = NSMapTable<BrowserTab, DevModeState>.weakToStrongObjects()

    private var devModeState: DevModeState {
        if let state = Self.devModeStates.object(forKey: self) {
            return state
        }
        let state = DevModeState()
        Self.devModeStates.setObject(state, forKey: self)
        return state
    }

    /// Whether this tab has ever used a Developer mode tool. Every document load asks, so a tab that never did costs nothing.
    private var hasDevModeState: Bool {
        Self.devModeStates.object(forKey: self) != nil
    }

    var devModeTools: DevModeTools {
        devModeState.tools
    }

    /// Whether the website this tab addresses uses Developer mode. False for WSurf's own pages and anything but http(s).
    var usesDevMode: Bool {
        context.settings.usesDevMode(for: URL(string: urlString))
    }

    /// Whether the document the page shows now does. What Developer mode does to the page itself (appearance, overlays) follows
    /// this, not the address field, which already shows the next page while it loads.
    private var documentUsesDevMode: Bool {
        context.settings.usesDevMode(for: liveView?.url)
    }

    /// True when the tab shows a page that has an inspector to open: WebKit's Web Inspector or Chromium's DevTools.
    var canShowWebInspector: Bool {
        liveView != nil && (context.settings.webInspectorEnabled || usesDevMode)
    }

    /// Opens the inspector of a WebKit page through WebKit's private `_inspector`, or Chromium's DevTools in a window of their
    /// own. Does nothing when the page has none or the inspector is off for it.
    func showWebInspector() {
        guard canShowWebInspector, let page = liveView else { return }
        if let chromium = page.chromium {
            chromium.showDevTools()
            return
        }
        guard let webView = page.webKit else { return }
        let accessor = NSSelectorFromString("_inspector")
        let show = NSSelectorFromString("show")
        guard webView.responds(to: accessor),
              let inspector = webView.perform(accessor)?.takeUnretainedValue() as? NSObject,
              inspector.responds(to: show)
        else { return }
        inspector.perform(show)
    }

    func updateDevModeTools(_ change: (inout DevModeTools) -> Void) {
        change(&devModeState.tools)
        applyDevModeAppearance()
        renderDevModeOverlays()
    }

    /// Turns Developer mode on or off for this tab's website and brings this tab in line.
    func setDevMode(_ isOn: Bool) {
        context.settings.setDevMode(isOn, for: URL(string: urlString))
        syncDevMode()
    }

    /// Brings the tab in line with the website's current choice: the inspector, the page appearance and the overlays.
    func syncDevMode() {
        if let webKit = liveView?.webKit {
            context.settings.applyInspector(to: webKit)
        } else if !canShowWebInspector {
            // WebKit closes its inspector when it stops being inspectable; Chromium's DevTools window is closed the same way.
            liveView?.chromium?.closeDevTools()
        }
        guard hasDevModeState || usesDevMode else { return }
        if !usesDevMode {
            devModeState.tools = DevModeTools()
        }
        applyDevModeAppearance()
        renderDevModeOverlays()
    }

    /// Puts the chosen appearance on the view (WebKit) or sets Chromium's `prefers-color-scheme`. WebKit's is taken off again
    /// only while the view still shows what this feature put there, so another setting is never undone.
    func applyDevModeAppearance() {
        guard hasDevModeState || documentUsesDevMode else { return }
        if let chromium = liveView?.chromium {
            chromium.setBaseColorScheme(documentUsesDevMode ? devModeState.tools.appearance.colorScheme : nil)
            return
        }
        guard let webKit = liveView?.webKit else { return }
        let state = devModeState
        let wanted = documentUsesDevMode ? state.tools.appearance.appearance : nil
        if let wanted {
            if webKit.appearance?.name != wanted.name {
                webKit.appearance = wanted
            }
            state.appliedAppearance = wanted
        } else if let applied = state.appliedAppearance {
            if webKit.appearance?.name == applied.name {
                webKit.appearance = nil
            }
            state.appliedAppearance = nil
        }
    }

    /// Called when a document finishes loading, which has none of the overlays yet.
    func applyDevModeOverlays() {
        guard hasDevModeState || documentUsesDevMode else { return }
        devModeState.overlaysShown = false
        guard documentUsesDevMode, devModeState.tools.hasOverlays else { return }
        renderDevModeOverlays()
    }

    private func renderDevModeOverlays() {
        let state = devModeState
        let tools = documentUsesDevMode ? state.tools : DevModeTools()
        guard tools.hasOverlays || state.overlaysShown, let page = liveView else { return }
        state.overlaysShown = tools.hasOverlays
        // The script runs a moment later, in whatever document the page shows by then. It names the origin it was asked
        // about and does nothing in any other, so an overlay never lands on a website that is not in Developer mode.
        let origin = SitePermissions.origin(for: page.url)
        guard !origin.isEmpty else { return }
        Task {
            _ = try? await page.callAsyncJavaScript(
                DevModeOverlay.source,
                arguments: ["fps": tools.showsFrameRate, "outlines": tools.outlinesElements, "origin": origin],
                in: nil,
                contentWorld: DevModeOverlay.world
            )
        }
    }

    /// Removes the cookies and storage of `confirmed`, the origin the person was asked about, and no other website's: not its
    /// subdomains, not its parent domain, not another port's storage. Reloads from the network afterwards. The page may have
    /// moved on while the question was open (a redirect, a script, a click), so this clears only while the tab still shows
    /// exactly that origin and the website still uses Developer mode, checks both again before each step, and otherwise clears
    /// nothing and answers `.stale`. The caller has already asked the person.
    @discardableResult
    func clearDevModeSiteData(origin confirmed: String) async -> DevelopmentSiteDataOutcome {
        func isStillTheConfirmedWebsite(_ page: BrowserPage) -> Bool {
            guard let url = page.url, DevMode.host(of: url) != nil else { return false }
            return SitePermissions.origin(for: url) == confirmed && context.settings.usesDevMode(for: url)
        }
        guard let page = liveView, isStillTheConfirmedWebsite(page), let url = page.url else { return .stale }
        let outcome = await page.clearDevelopmentSiteData(for: url) { [weak self, weak page] in
            guard let self, let page, !isClosed, liveView === page else { return false }
            return isStillTheConfirmedWebsite(page)
        }
        if case .cleared = outcome, liveView === page {
            page.reloadFromOrigin()
        }
        return outcome
    }
}

/// The frame rate badge and the element outlines. They run in a world of their own, so the page cannot see the script or its
/// state. While they are on, the badge and the style rule are in the page's DOM, and a page can look for them.
enum DevModeOverlay {
    static let world = WKContentWorld.world(name: "WSurfDevMode")

    static let source = """
    if (location.origin !== origin) return;
    const state = window.__wsurfDevMode ??= {};
    if (fps && !state.fps) {
        const badge = document.createElement("div");
        badge.style.cssText = "position:fixed;top:8px;left:8px;z-index:2147483647;pointer-events:none;"
            + "padding:4px 7px;border-radius:6px;background:rgba(0,0,0,.7);color:#fff;"
            + "font:600 11px/1.2 ui-monospace,monospace;";
        document.documentElement.appendChild(badge);
        let frames = 0, start = performance.now(), running = true;
        const tick = (now) => {
            if (!running) return;
            frames += 1;
            if (now - start >= 500) {
                badge.textContent = Math.round(frames * 1000 / (now - start)) + " fps";
                frames = 0;
                start = now;
            }
            requestAnimationFrame(tick);
        };
        requestAnimationFrame(tick);
        state.fps = () => { running = false; badge.remove(); };
    } else if (!fps && state.fps) {
        state.fps();
        delete state.fps;
    }
    if (outlines && !state.outlines) {
        const style = document.createElement("style");
        style.textContent = "* { outline: 1px solid rgba(255, 59, 48, .5) !important; outline-offset: -1px !important; }";
        document.documentElement.appendChild(style);
        state.outlines = () => style.remove();
    } else if (!outlines && state.outlines) {
        state.outlines();
        delete state.outlines;
    }
    """
}
