// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import OSLog
import SwiftUI

/// The Developer Tools button in the address field of a website that uses Developer mode.
struct DevModeBadge: View {
    let tab: BrowserTab
    let coordinator: AppCoordinator

    @State private var anchor = DevModeMenuAnchorBox()

    var body: some View {
        ChromeIcon(symbol: "ladybug", size: 10, weight: .semibold, help: String(localized: "Developer Tools")) {
            let menu = DevModeMenu.make(for: tab, coordinator: coordinator)
            guard let view = anchor.view else {
                menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
                return
            }
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: -4), in: view)
        }
        .background { DevModeMenuAnchor(box: anchor) }
    }
}

extension AppCoordinator {
    /// Turns Developer mode on or off for the website `tab` shows, in this profile. Every other open tab of the profile, in
    /// any window, follows at once, so the inspector of a website that was just turned off is not left on in another tab.
    func setDevMode(_ isOn: Bool, for tab: BrowserTab) {
        withAnimation(Theme.Motion.drift) {
            tab.setDevMode(isOn)
        }
        let windows = application?.windows.filter { !$0.isClosed && $0.context === context } ?? [self]
        for window in windows {
            for other in window.browser.tabs where other !== tab && other.isMaterialised {
                other.syncDevMode()
            }
        }
    }

    /// Turns Developer mode on or off for `host`, the website a menu item named, only while `tab` still shows that host: a page
    /// that moved on while the menu was open is not a website the person chose. Returns whether anything was changed.
    @discardableResult
    func setDevMode(_ isOn: Bool, for tab: BrowserTab, named host: String) -> Bool {
        guard DevMode.host(of: URL(string: tab.urlString)) == host else { return false }
        setDevMode(isOn, for: tab)
        return true
    }

    func copyScreenshot(of tab: BrowserTab) {
        guard tab.isMaterialised else { return }
        let page = tab.shownPage
        Task { @MainActor [weak self] in
            do {
                try await DevModeScreenshot.copy(page, to: .general)
                self?.show(notice: String(localized: "Screenshot Copied"))
            } catch {
                DevMode.log.notice("Screenshot failed: \(error.localizedDescription, privacy: .public)")
                self?.show(notice: String(localized: "Couldn’t take a screenshot"))
            }
        }
    }

    /// Asks, then clears the website data of the exact address `tab` shows (see `BrowserTab.clearDevModeSiteData`).
    func confirmClearingSiteData(for tab: BrowserTab) {
        guard let url = tab.liveView?.url, DevMode.host(of: url) != nil else { return }
        let origin = SitePermissions.origin(for: url)
        Task { @MainActor [weak self, weak tab] in
            guard await ConfirmAlert.destructive(
                "Clear website data for “\(origin)”?",
                detail: "Storage, caches and cookies of this exact address are removed, and the page reloads. Other addresses, including its subdomains and parent domain, are left alone.",
                verb: "Clear"
            ), let tab else { return }
            // The website that was confirmed, not whichever one the tab shows by now.
            switch await tab.clearDevModeSiteData(origin: origin) {
            case .cleared(let report) where report.failed.isEmpty:
                self?.show(notice: String(localized: "Website Data Cleared"))
            case .stale:
                self?.show(notice: String(localized: "The page changed, so nothing was cleared"))
            default:
                self?.show(notice: String(localized: "Couldn’t clear all website data"))
            }
        }
    }
}

/// Puts the picture of a page on a pasteboard, the way the person sees it.
@MainActor
enum DevModeScreenshot {
    static func copy(_ page: BrowserPage, to pasteboard: NSPasteboard) async throws {
        let image = try await page.capture(afterScreenUpdates: true)
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        flash(over: page)
    }

    private static func flash(over page: BrowserPage) {
        guard let container = page.superview else { return }
        let flash = NSView(frame: page.frame)
        flash.wantsLayer = true
        flash.layer?.backgroundColor = NSColor.black.cgColor
        flash.alphaValue = 0.45
        container.addSubview(flash, positioned: .above, relativeTo: page)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.35
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            flash.animator().alphaValue = 0
        }
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            flash.removeFromSuperview()
        }
    }
}

@MainActor
enum DevModeMenu {
    static func make(for tab: BrowserTab, coordinator: AppCoordinator) -> NSMenu {
        let menu = NSMenu()
        // Chromium has no inspector in WSurf, so a Chromium tab gets no Show Web Inspector item rather than one that does nothing.
        if tab.canShowWebInspector {
            menu.addItem(
                title: String(localized: "Show Web Inspector"),
                image: symbol("wrench.and.screwdriver"),
                key: "i",
                modifiers: [.command, .option]
            ) { [weak tab] in
                tab?.showWebInspector()
            }
        }
        menu.addItem(title: String(localized: "Copy Screenshot"), image: symbol("camera.viewfinder")) { [weak tab, weak coordinator] in
            guard let tab, let coordinator else { return }
            coordinator.copyScreenshot(of: tab)
        }

        menu.addItem(.separator())
        menu.addItem(title: String(localized: "Show Frame Rate"), image: symbol("gauge.with.needle")) { [weak tab] in
            tab?.updateDevModeTools { $0.showsFrameRate.toggle() }
        }.state = tab.devModeTools.showsFrameRate ? .on : .off
        menu.addItem(title: String(localized: "Outline Elements"), image: symbol("square.dashed")) { [weak tab] in
            tab?.updateDevModeTools { $0.outlinesElements.toggle() }
        }.state = tab.devModeTools.outlinesElements ? .on : .off
        // The page appearance is WebKit's view appearance; there is nothing to set on a Chromium page.
        if tab.liveView?.webKit != nil {
            menu.addItem(submenu(appearanceMenu(for: tab), title: String(localized: "Page Appearance"), image: symbol("circle.lefthalf.filled")))
        }

        if DevModeOpenIn.shareableURL(tab.urlString, isPrivate: tab.isPrivate) != nil {
            let browsers = DevModeOpenIn.installedBrowsers(isPrivate: tab.isPrivate)
            if !browsers.isEmpty {
                menu.addItem(.separator())
                menu.addItem(submenu(openInMenu(for: tab, browsers: browsers), title: String(localized: "Open In"), image: symbol("arrow.up.forward.app")))
            }
        }

        menu.addItem(.separator())
        menu.addItem(title: String(localized: "Restart Page"), image: symbol("arrow.trianglehead.2.clockwise")) { [weak tab] in
            tab?.restartPage()
        }
        menu.addItem(title: String(localized: "Clear Website Data…"), image: symbol("trash")) { [weak tab, weak coordinator] in
            guard let tab, let coordinator else { return }
            coordinator.confirmClearingSiteData(for: tab)
        }
        if let host = DevMode.host(of: URL(string: tab.urlString)) {
            menu.addItem(.separator())
            menu.addItem(title: String(localized: "Turn Off Developer Mode for “\(host)”")) { [weak tab, weak coordinator] in
                guard let tab, let coordinator else { return }
                coordinator.setDevMode(false, for: tab, named: host)
            }
        }
        return menu
    }

    private static func appearanceMenu(for tab: BrowserTab) -> NSMenu {
        let menu = NSMenu()
        for appearance in DevModeTools.Appearance.allCases {
            if appearance == .light {
                menu.addItem(.separator())
            }
            menu.addItem(title: String(localized: appearance.title)) { [weak tab] in
                tab?.updateDevModeTools { $0.appearance = appearance }
            }.state = tab.devModeTools.appearance == appearance ? .on : .off
        }
        return menu
    }

    private static func openInMenu(for tab: BrowserTab, browsers: [URL]) -> NSMenu {
        let menu = NSMenu()
        for browser in browsers {
            let icon = NSWorkspace.shared.icon(forFile: browser.path(percentEncoded: false))
            icon.size = NSSize(width: 16, height: 16)
            menu.addItem(title: FileManager.default.displayName(atPath: browser.path(percentEncoded: false)), image: icon) { [weak tab] in
                // Checked again at the click: the address and the window decide, not what the menu was built from.
                guard let tab else { return }
                DevModeOpenIn.open(tab.urlString, isPrivate: tab.isPrivate, in: browser)
            }
        }
        return menu
    }

    private static func submenu(_ menu: NSMenu, title: String, image: NSImage?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = image
        item.submenu = menu
        return item
    }

    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }
}

@MainActor
private final class DevModeMenuAnchorBox {
    weak var view: NSView?
}

private struct DevModeMenuAnchor: NSViewRepresentable {
    let box: DevModeMenuAnchorBox

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        box.view = nsView
    }
}
