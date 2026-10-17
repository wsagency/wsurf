// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import MCP
import WebKit

extension MCPDevelopmentTools {
    static func value(_ media: DevelopmentMedia) -> Value {
        .object([
            "colorScheme": media.colorScheme.map { Value.string($0.rawValue) } ?? "system",
            "reducedMotion": media.reducedMotion.map { Value.string($0 ? "reduce" : "no-preference") } ?? "system",
            "offline": .bool(media.offline),
        ])
    }

    static func value(_ measured: MeasuredMedia) -> Value {
        .object(["prefersDark": .bool(measured.dark), "prefersReducedMotion": .bool(measured.reducedMotion), "online": .bool(measured.online)])
    }
}

/// What an `emulateMedia` call asks for. An axis it leaves out keeps its value.
private struct MediaRequest {
    enum Setting<Item: Equatable>: Equatable {
        case unchanged, system
        case set(Item)

        func applied(to current: Item?) -> Item? {
            switch self {
            case .unchanged:
                current
            case .system:
                nil
            case .set(let value):
                value
            }
        }
    }

    var colorScheme = Setting<DevelopmentMedia.ColorScheme>.unchanged
    var reducedMotion = Setting<Bool>.unchanged
    var offline: Bool?

    /// Nil when nothing is asked or a value is not one of the documented words.
    init?(_ arguments: [String: Value]) {
        if let word = arguments["colorScheme"]?.stringValue {
            switch word {
            case "system":
                colorScheme = .system
            default:
                guard let scheme = DevelopmentMedia.ColorScheme(rawValue: word) else { return nil }
                colorScheme = .set(scheme)
            }
        }
        if let word = arguments["reducedMotion"]?.stringValue {
            switch word {
            case "system":
                reducedMotion = .system
            case "reduce":
                reducedMotion = .set(true)
            case "no-preference":
                reducedMotion = .set(false)
            default:
                return nil
            }
        }
        offline = arguments["offline"]?.boolValue
        guard colorScheme != .unchanged || reducedMotion != .unchanged || offline != nil else { return nil }
    }

    /// Asked for something only Chromium can do.
    var needsChromium: Bool {
        reducedMotion != .unchanged || offline != nil
    }

    func applying(to current: DevelopmentMedia) -> DevelopmentMedia {
        DevelopmentMedia(
            colorScheme: colorScheme.applied(to: current.colorScheme), reducedMotion: reducedMotion.applied(to: current.reducedMotion),
            offline: offline ?? current.offline)
    }
}

@MainActor
extension MCPBrowserSession {
    /// What a development lease needs from the connection's grant: media emulation is Developer-tier work, so a lease that
    /// holds it ends as soon as the tier stops applying, even while Development access remains.
    func leaseScope(of owner: DevelopmentOwner?) -> Scope {
        owner?.media == nil ? .development : .developer
    }

    func emulateMedia(arguments: [String: Value], tab: BrowserTab, view: BrowserPage) async -> CallTool.Result {
        guard let request = MediaRequest(arguments) else {
            return MCPDevelopmentTools.result(
                .invalidInput, tabID: tab.id,
                message:
                    "Give at least one of colorScheme (dark, light or system), reducedMotion (reduce, no-preference or system) and offline (true or false).")
        }
        // Everything the engine cannot do is rejected before the tab is claimed or touched.
        if request.needsChromium, view.chromium == nil {
            return MCPDevelopmentTools.result(
                .unsupported, tabID: tab.id,
                message:
                    "WebKit has no public override for reduced motion (it follows the system setting) or offline mode. Only colorScheme can be emulated here. Nothing was changed.",
                ["capabilities": MCPDevelopmentTools.value(view.developmentCapabilities)])
        }
        guard let owner = acquireDevelopment(tab, view: view) else { return refusal(tab, view: view) }
        let target = request.applying(to: owner.media?.media ?? DevelopmentMedia())
        switch await view.applyDevelopmentMedia(target, owner: owner, tab: tab) {
        case .applied(let measured):
            guard tab.isCurrent(owner) else {
                return MCPDevelopmentTools.result(.stale, tabID: tab.id, message: "The development lease ended while the emulation was applied.")
            }
            releaseIfIdle(owner, tab: tab)
            return MCPDevelopmentTools.result(
                .ok, tabID: tab.id, ["emulation": MCPDevelopmentTools.value(target), "measured": MCPDevelopmentTools.value(measured)])
        case .unsupported(let message):
            releaseIfIdle(owner, tab: tab)
            return MCPDevelopmentTools.result(.unsupported, tabID: tab.id, message: message)
        case .missed(let measured, let message):
            releaseIfIdle(owner, tab: tab)
            return MCPDevelopmentTools.result(
                .unsupported, tabID: tab.id, message: message, measured.map { ["measured": MCPDevelopmentTools.value($0)] } ?? [:])
        case .cancelled:
            releaseIfIdle(owner, tab: tab)
            return MCPDevelopmentTools.result(.stale, tabID: tab.id, message: "The request was cancelled; no emulation was applied.")
        case .stale:
            return MCPDevelopmentTools.result(.stale, tabID: tab.id, message: "The development lease ended before the emulation was applied.")
        }
    }

    // MARK: Site data

    /// Why site data may not be cleared in `view` at `url`, or nil. The Developer tier already implies a paired app, a
    /// developer site and the Developer profile; this asks again, and also refuses the everyday profile even when the owner
    /// chose it as the Developer profile, because deleting sign-ins there cannot be undone.
    func siteDataRefusal(view: BrowserPage, url: URL) -> String? {
        let profile = view.context.profile
        if profile.isPrivate || profile.isOriginal {
            return "Site data is never cleared in your everyday profile or a private window. Use the Developer profile."
        }
        guard MCPDeveloperAccess.isDeveloperProfile(profile, trust: trust), MCPDeveloperAccess.isDeveloperSite(url, trust: trust) else {
            return "Site data can be cleared only for a developer site in the Developer profile."
        }
        if let webKit = view.webKit, webKit.configuration.websiteDataStore !== view.context.dataStore {
            return "This page does not use the Developer profile's website data."
        }
        return nil
    }

    func clearSiteData(tab: BrowserTab, view: BrowserPage, generation: Int) async -> CallTool.Result {
        guard let url = webURL(of: tab) else { return MCPDevelopmentTools.result(.pageGone, tabID: tab.id, message: "The webpage is unavailable.") }
        if let reason = siteDataRefusal(view: view, url: url) {
            return MCPDevelopmentTools.result(.denied, tabID: tab.id, message: reason)
        }
        let origin = SitePermissions.origin(for: url)
        // Checked before every removal and after every wait: the page must still be this origin, in this tab, with the same
        // access, in the same profile.
        let authorize: @MainActor () -> Bool = { [weak self, weak tab, weak view] in
            guard let self, let tab, let view, tab.isLive(view, generation: generation), self.mayProceed(tab, capability: .developer),
                let current = self.webURL(of: tab), SitePermissions.origin(for: current) == origin
            else { return false }
            return self.siteDataRefusal(view: view, url: current) == nil
        }
        switch await view.clearDevelopmentSiteData(for: url, authorize: authorize) {
        case .cleared(let report):
            var message = "Cleared the saved website data of \(origin). Reload the page to start fresh."
            if report.blockedDatabases > 0 {
                message += " \(report.blockedDatabases) IndexedDB database(s) are still open in the page and go when it lets them go."
            }
            return MCPDevelopmentTools.result(
                .ok, tabID: tab.id, message: message,
                [
                    "origin": .string(origin), "cookieScope": "host",
                    "cleared": .object([
                        "localStorageItems": .int(report.localStorage), "sessionStorageItems": .int(report.sessionStorage),
                        "indexedDBDatabases": .int(report.indexedDB), "cacheStorageCaches": .int(report.cacheStorage),
                        "serviceWorkers": .int(report.serviceWorkers), "cookies": .int(report.cookies),
                    ]),
                    "blockedDatabases": .int(report.blockedDatabases), "failed": .array(report.failed.map { .string($0) }),
                    "notCleared": .array(["httpCache"]),
                ])
        case .stale:
            return MCPDevelopmentTools.result(
                .stale, tabID: tab.id, message: "Page access changed, so clearing stopped. Some data may already have been removed.")
        case .unavailable(let message):
            return MCPDevelopmentTools.result(.pageGone, tabID: tab.id, message: message)
        }
    }
}
