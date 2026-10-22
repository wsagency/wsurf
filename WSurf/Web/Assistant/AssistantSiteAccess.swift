// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Foundation
import Observation

nonisolated enum AssistantPageCapability: Sendable {
    case read
    case control
}

/// What a tab does with a page request: use the page, prompt first, or refuse.
nonisolated enum AssistantAccessDecision: Equatable, Sendable {
    case allow
    case ask
    case deny
}

extension AssistantAccessPolicy {
    nonisolated func allows(_ capability: AssistantPageCapability) -> Bool {
        switch (self, capability) {
        case (.readOnly, .read), (.control, _):
            true
        case (.ask, _), (.readOnly, .control), (.deny, _):
            false
        }
    }
}

@MainActor
@Observable
final class TabAssistantAccessCenter {
    private let store: SitePermissions

    /// The page's own origin. Requests are checked against it, so a page that moves to another origin needs a new look.
    private(set) var origin = ""
    /// The website `origin` belongs to (`SitePermissions.site(for:)`). A choice, saved or for this visit, covers all of it.
    private(set) var site = ""
    var persistsAnswers = true
    private(set) var sessionPolicy: AssistantAccessPolicy?

    /// A frame's center answers from its own record or a prompt. The default covers only the visible page.
    private var isEmbedded = false

    /// The origin whose page last showed a password or payment field to a control request. Under an Allow Control
    /// default, that page asks first.
    private var sensitiveOrigin: String?

    /// Whether the page shows a password or payment field. No page, or a page that does not answer, counts as yes.
    @ObservationIgnored var sensitivePageProbe: @MainActor (BrowserPage?) async -> Bool = { page in
        guard let page else { return true }
        return await PageSensitiveProbe.hasSensitiveField(in: page)
    }

    /// Called after the effective policy may have changed (an answer, a new origin, cleared site data).
    @ObservationIgnored var onPolicyChanged: (() -> Void)?

    var displayHost: String {
        SitePermissions.displayName(for: site)
    }

    /// The website's own choice: this visit's answer in a private tab, else its saved record. `nil` follows the default.
    var explicitPolicy: AssistantAccessPolicy? {
        sessionPolicy ?? store.assistantRecord(for: origin)
    }

    /// What a website without a choice of its own gets. Private tabs and frames always ask.
    var defaultPolicy: AssistantAccessPolicy {
        persistsAnswers && !isEmbedded ? store.assistantDefault : .ask
    }

    var effectivePolicy: AssistantAccessPolicy {
        explicitPolicy ?? defaultPolicy
    }

    /// True when this tab's page asks before control only because of a password or payment field.
    var isCappedBySensitiveField: Bool {
        !origin.isEmpty && sensitiveOrigin == origin && explicitPolicy == nil && defaultPolicy == .control
    }

    func decision(for capability: AssistantPageCapability) -> AssistantAccessDecision {
        if let explicit = explicitPolicy {
            if explicit.allows(capability) {
                return .allow
            }
            return explicit == .ask ? .ask : .deny
        }
        switch (defaultPolicy, capability) {
        case (.control, .read), (.readOnly, .read):
            return .allow
        case (.control, .control):
            return isCappedBySensitiveField ? .ask : .allow
        case (.readOnly, .control), (.ask, _), (.deny, _):
            return .ask
        }
    }

    init(store: SitePermissions) {
        self.store = store
    }

    func embeddedAccess(for url: URL) -> TabAssistantAccessCenter {
        let access = TabAssistantAccessCenter(store: store)
        access.persistsAnswers = persistsAnswers
        access.isEmbedded = true
        access.pageChanged(url: url)
        return access
    }

    func authorize(
        _ capability: AssistantPageCapability,
        in page: BrowserPage? = nil,
        pageOrigin: String? = nil
    ) async -> Bool {
        let requestedOrigin = origin
        guard !Task.isCancelled, !requestedOrigin.isEmpty else { return false }

        let owner = AgentActionConsent.scopedWindow
        guard Self.isRunningTests || owner != nil,
              owner.map({ Self.owns($0, page: page, origin: pageOrigin) }) ?? true else { return false }

        // The page can show a login form after the last control request, so each one looks again.
        if capability == .control, explicitPolicy == nil, defaultPolicy == .control {
            let sensitive = await sensitivePageProbe(page)
            guard !Task.isCancelled, origin == requestedOrigin,
                  owner.map({ Self.owns($0, page: page, origin: pageOrigin) }) ?? true else { return false }
            sensitiveOrigin = sensitive ? requestedOrigin : nil
        }
        switch decision(for: capability) {
        case .allow:
            return true
        case .deny:
            return false
        case .ask:
            break
        }

        let answer: AssistantAccessPolicy
        if let stub = Self.decisionForTesting {
            answer = stub.decide(capability, requestedOrigin)
        } else {
            guard let window = owner?.nativeWindow else { return false }
            answer = await Self.ask(
                capability: capability,
                origin: requestedOrigin,
                site: site,
                pageHasSensitiveField: isCappedBySensitiveField,
                in: window
            )
        }

        guard !Task.isCancelled, origin == requestedOrigin,
              owner.map({ Self.owns($0, page: page, origin: pageOrigin) }) ?? Self.isRunningTests else { return false }
        if answer != .ask {
            set(answer)
        }
        return answer.allows(capability)
    }

    private static func owns(
        _ owner: ExtensionWindowAdapter,
        page: BrowserPage?,
        origin: String?
    ) -> Bool {
        guard let browser = owner.browser, owner.nativeWindow != nil,
              browser.sessionClosedAt == nil, browser.context.isRegistered(browser),
              browser.context.extensions.adapter(for: browser) === owner else { return false }
        guard let page else { return origin == nil }
        guard browser.tabs.contains(where: { $0.page === page }) else { return false }
        guard let origin else { return true }
        return SitePermissions.origin(for: page.url) == origin
    }

    /// `nil` makes the website follow the default again.
    func set(_ policy: AssistantAccessPolicy?) {
        guard !origin.isEmpty else { return }
        if persistsAnswers {
            store.setAssistantAccess(policy, for: origin)
        } else {
            sessionPolicy = policy == .ask ? nil : policy
        }
        onPolicyChanged?()
    }

    func pageChanged(url: URL?) {
        let scheme = url?.scheme?.lowercased()
        let nextOrigin = scheme == "http" || scheme == "https"
            ? SitePermissions.origin(for: url)
            : ""
        guard nextOrigin != origin else { return }
        origin = nextOrigin
        let nextSite = SitePermissions.site(for: nextOrigin)
        if nextSite != site {
            site = nextSite
            sessionPolicy = nil
        }
        sensitiveOrigin = nil
        onPolicyChanged?()
    }

    func siteDataCleared() {
        sessionPolicy = nil
        sensitiveOrigin = nil
        onPolicyChanged?()
    }

    func denialMessage(for capability: AssistantPageCapability) -> String {
        guard !origin.isEmpty else {
            return String(localized: "No webpage is open yet.")
        }
        // Only the website's own choice names itself in the message. A question the person declined was not a setting.
        return switch (explicitPolicy, capability) {
        case (.readOnly, .control):
            String(localized: "This website is Read Only for the assistant. Change Assistant Access in Site Settings to allow control.")
        case (.deny, _):
            String(localized: "Assistant access is off for \(displayHost). Change it in Site Settings.")
        default:
            String(localized: "Assistant access wasn’t allowed on \(displayHost).")
        }
    }

    // MARK: - Decision prompt

    struct Stub: @unchecked Sendable {
        let decide: (AssistantPageCapability, String) -> AssistantAccessPolicy

        init(_ decide: @escaping (AssistantPageCapability, String) -> AssistantAccessPolicy) {
            self.decide = decide
        }
    }

    @TaskLocal static var decisionForTesting: Stub?
    @TaskLocal static var presentsNativeSheetForTesting = false

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }

    private static func ask(
        capability: AssistantPageCapability,
        origin: String,
        site: String,
        pageHasSensitiveField: Bool,
        in window: NSWindow
    ) async -> AssistantAccessPolicy {
        guard !isRunningTests || presentsNativeSheetForTesting else { return .ask }

        let siteName = SitePermissions.displayName(for: site)
        let alert = NSAlert()
        alert.messageText = String(localized: "Allow Assistant on \(siteName)?")
        alert.informativeText = body(capability: capability, site: siteName, pageHasSensitiveField: pageHasSensitiveField)
            + "\n\n" + coverage(origin: origin, site: site)

        let choices: [(LocalizedStringResource, AssistantAccessPolicy)] = switch capability {
        case .read:
            [("Read Only", .readOnly), ("Allow Control", .control), ("Don’t Allow", .deny)]
        case .control:
            [("Allow Control", .control), ("Read Only", .readOnly), ("Don’t Allow", .deny)]
        }
        for choice in choices {
            alert.addButton(withTitle: String(localized: choice.0))
        }
        alert.buttons.last?.keyEquivalent = "\u{1b}"

        let response = await withCheckedContinuation { continuation in
            alert.beginSheetModal(for: window) { continuation.resume(returning: $0) }
        }

        return switch response {
        case .alertFirstButtonReturn:
            choices[0].1
        case .alertSecondButtonReturn:
            choices[1].1
        case .alertThirdButtonReturn:
            choices[2].1
        default:
            .ask
        }
    }

    /// Says that the answer covers the whole website, naming the page's own host when it is not the site itself.
    static func coverage(origin: String, site: String) -> String {
        let siteName = SitePermissions.displayName(for: site)
        let pageName = SitePermissions.displayName(for: origin)
        guard pageName != siteName, pageName != "www." + siteName else {
            return String(localized: "This applies to every page on \(siteName).")
        }
        return String(localized: "This includes \(pageName) and other pages on \(siteName).")
    }

    static func body(capability: AssistantPageCapability, site: String, pageHasSensitiveField: Bool = false) -> String {
        let text = switch capability {
        case .read:
            String(localized: "Read Only lets the assistant see page text on \(site). Allow Control also lets it click, type, scroll, and navigate. Password and payment fields stay blocked.")
        case .control:
            String(localized: "Allow Control lets the assistant read and use page controls on \(site). Read Only blocks this action. Password and payment fields stay blocked.")
        }
        guard pageHasSensitiveField else { return text }
        return String(localized: "This page has a password or payment field.") + " " + text
    }
}
