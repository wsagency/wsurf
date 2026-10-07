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

    private(set) var origin = ""
    var persistsAnswers = true
    private(set) var sessionPolicy: AssistantAccessPolicy?

    var displayHost: String {
        SitePermissions.displayName(for: origin)
    }

    var effectivePolicy: AssistantAccessPolicy {
        sessionPolicy ?? store.assistantAccess(for: origin)
    }

    init(store: SitePermissions) {
        self.store = store
    }

    func embeddedAccess(for url: URL) -> TabAssistantAccessCenter {
        let access = TabAssistantAccessCenter(store: store)
        access.persistsAnswers = persistsAnswers
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

        let current = effectivePolicy
        if current != .ask {
            return current.allows(capability)
        }

        let answer: AssistantAccessPolicy
        if let stub = Self.decisionForTesting {
            answer = stub.decide(capability, requestedOrigin)
        } else {
            guard let window = owner?.nativeWindow else { return false }
            answer = await Self.ask(capability: capability, origin: requestedOrigin, in: window)
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

    func set(_ policy: AssistantAccessPolicy) {
        guard !origin.isEmpty else { return }
        if persistsAnswers {
            store.setAssistantAccess(policy, for: origin)
        } else {
            sessionPolicy = policy == .ask ? nil : policy
        }
    }

    func pageChanged(url: URL?) {
        let scheme = url?.scheme?.lowercased()
        let nextOrigin = scheme == "http" || scheme == "https"
            ? SitePermissions.origin(for: url)
            : ""
        guard nextOrigin != origin else { return }
        origin = nextOrigin
        sessionPolicy = nil
    }

    func siteDataCleared() {
        sessionPolicy = nil
    }

    func denialMessage(for capability: AssistantPageCapability) -> String {
        guard !origin.isEmpty else {
            return String(localized: "No webpage is open yet.")
        }
        return switch (effectivePolicy, capability) {
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
        in window: NSWindow
    ) async -> AssistantAccessPolicy {
        guard !isRunningTests || presentsNativeSheetForTesting else { return .ask }

        let site = SitePermissions.displayName(for: origin)
        let alert = NSAlert()
        alert.messageText = String(localized: "Allow Assistant on \(site)?")
        alert.informativeText = body(capability: capability, site: site)

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

    static func body(capability: AssistantPageCapability, site: String) -> String {
        return switch capability {
        case .read:
            String(localized: "Read Only lets the assistant see page text on \(site). Allow Control also lets it click, type, scroll, and navigate. Password and payment fields stay blocked.")
        case .control:
            String(localized: "Allow Control lets the assistant read and use page controls on \(site). Read Only blocks this action. Password and payment fields stay blocked.")
        }
    }
}
