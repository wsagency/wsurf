// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Foundation
import Testing

@testable import WSurf

@MainActor
@Suite(.serialized, .exclusiveExternalApp)
struct ExternalAppPermissionTests {
    private let slack = ExternalAppPermission(scheme: "slack", bundleIdentifier: "com.tinyspeck.slackmacgap", name: "Slack")
    private let origin = "https://slack.com"

    private func withPolicy(
        privately: Bool = false,
        _ body: (SitePermissions, TabExternalAppPolicy, URL, URL) async -> Void
    ) async {
        let file = URL.temporaryDirectory.appending(path: "ExternalAppTests-\(UUID().uuidString).json")
        let store = SitePermissions(storageURL: file)
        ExternalApp.resolverForTesting = { _ in
            .init(url: URL(filePath: "/Applications/Slack.app"), name: "Slack", bundleIdentifier: "com.tinyspeck.slackmacgap")
        }
        defer {
            ExternalApp.openerForTesting = nil
            ExternalApp.requestObserverForTesting = nil
            ExternalApp.resolverForTesting = nil
            ExternalApp.presenterForTesting = nil
            try? FileManager.default.removeItem(at: file)
        }
        await body(store, TabExternalAppPolicy(store: store, isPrivate: privately), URL(string: "slack://open?code=secret")!, file)
        await store.waitForPendingSave()
    }

    @Test func aSavedChoiceSurvivesReloadAndCanBeRevoked() async {
        await withPolicy { store, policy, _, file in
            policy.remember(slack, from: origin)
            await store.waitForPendingSave()
            let restored = SitePermissions(storageURL: file)
            #expect(restored.externalApps(for: origin) == [slack])
            #expect(SitePermissions.changedSiteCount(in: file) == 1)
            restored.removeExternalApp(slack, for: origin)
            await restored.waitForPendingSave()
            #expect(SitePermissions(storageURL: file).externalApps(for: origin).isEmpty)
        }
    }

    @Test func choicesAreScopedToTheOriginSchemeAndInstalledApp() async {
        await withPolicy { store, policy, _, _ in
            policy.remember(slack, from: "HTTPS://SLACK.COM.:443/path")
            #expect(policy.allows(slack, from: origin))
            for otherOrigin in ["http://slack.com", "https://slack.com:8443", "https://other.slack.com", "", "slack.com"] {
                #expect(!policy.allows(slack, from: otherOrigin))
            }
            #expect(!policy.allows(.init(scheme: "other", bundleIdentifier: slack.bundleIdentifier, name: "Slack"), from: origin))
            #expect(!policy.allows(.init(scheme: "slack", bundleIdentifier: "other.app", name: "Slack"), from: origin))
            #expect(store.externalAppRecords.keys.sorted() == [origin])
        }
    }

    @Test func privateChoicesStayInThePrivateTabWithoutWriting() async {
        await withPolicy(privately: true) { store, policy, _, file in
            policy.remember(slack, from: "HTTPS://SLACK.COM.:443/path")
            #expect(policy.allows(slack, from: origin))
            #expect(store.externalApps(for: origin).isEmpty)
            #expect(!TabExternalAppPolicy(store: store, isPrivate: true).allows(slack, from: origin))
            await store.waitForPendingSave()
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }
    }

    @Test func unknownAndNonWebOriginsCannotAcquirePrivateOrPersistentGrants() async {
        await withPolicy { store, policy, _, file in
            let privatePolicy = TabExternalAppPolicy(store: store, isPrivate: true)
            for source in ["", "slack.com", "file:///tmp/page.html", "data:text/html,hello", "about:blank", "slack://open"] {
                policy.remember(slack, from: source)
                privatePolicy.remember(slack, from: source)
                #expect(!policy.allows(slack, from: source))
                #expect(!privatePolicy.allows(slack, from: source))
            }
            await store.waitForPendingSave()
            #expect(store.externalAppRecords.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }
    }

    @Test func resettingAllWebsiteSettingsClearsAppChoices() async {
        await withPolicy { store, policy, _, file in
            policy.remember(slack, from: origin)
            store.removeEverything()
            await store.waitForPendingSave()
            #expect(!policy.allows(slack, from: origin))
            #expect(SitePermissions(storageURL: file).externalApps(for: origin).isEmpty)
        }
    }

    @Test func oldPermissionFilesStillLoad() throws {
        let file = URL.temporaryDirectory.appending(path: "ExternalAppTests-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("{\"assistantAccess\":{\"https://slack.com\":\"control\"}}".utf8).write(to: file)
        let store = SitePermissions(storageURL: file)
        #expect(store.assistantAccess(for: origin) == .control)
        #expect(store.externalApps(for: origin).isEmpty)
    }

    @Test func rememberingAnAllowedRequestSkipsTheNextPromptUntilRevoked() async {
        await withPolicy { store, policy, url, _ in
            var prompts = 0
            var opened: [URL] = []
            ExternalApp.openerForTesting = { opened.append($0) }
            ExternalApp.presenterForTesting = { alert in
                prompts += 1
                #expect(!alert.informativeText.contains("secret"))
                #expect(alert.showsSuppressionButton)
                #expect(alert.suppressionButton?.state == .off)
                alert.suppressionButton?.state = .on
                return .alertFirstButtonReturn
            }
            for _ in 0..<2 {
                await ExternalApp.offerToOpen(url, from: origin, policy: policy, in: nil, isCurrent: { true })
            }
            #expect(prompts == 1)
            #expect(opened == [url, url])
            #expect(store.externalApps(for: origin) == [slack])
            store.removeExternalApp(slack, for: origin)
            await ExternalApp.offerToOpen(url, from: origin, policy: policy, in: nil, isCurrent: { true })
            #expect(prompts == 2)
            #expect(opened == [url, url, url])
        }
    }

    @Test func cancellingNeverOpensOrSavesEvenWithTheCheckboxSelected() async {
        await withPolicy { store, policy, url, file in
            var opened: [URL] = []
            ExternalApp.openerForTesting = { opened.append($0) }
            ExternalApp.presenterForTesting = { alert in
                alert.suppressionButton?.state = .on
                return .alertSecondButtonReturn
            }
            await ExternalApp.offerToOpen(url, from: origin, policy: policy, in: nil, isCurrent: { true })
            await store.waitForPendingSave()
            #expect(opened.isEmpty)
            #expect(store.externalAppRecords.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }
    }

    @Test func openingOnceAsksAgainAndUnknownSourcesCannotBeRemembered() async {
        await withPolicy { store, policy, url, file in
            var prompts = 0
            var opened: [URL] = []
            ExternalApp.openerForTesting = { opened.append($0) }
            ExternalApp.presenterForTesting = { alert in
                prompts += 1
                if prompts > 2 {
                    #expect(!alert.showsSuppressionButton)
                }
                return .alertFirstButtonReturn
            }
            let origins = [origin, origin, "", "file:///tmp/page.html", "data:text/html,hello", "slack.com"]
            for source in origins {
                await ExternalApp.offerToOpen(url, from: source, policy: policy, in: nil, isCurrent: { true })
            }
            await store.waitForPendingSave()
            #expect(prompts == origins.count)
            #expect(opened == Array(repeating: url, count: origins.count))
            #expect(store.externalAppRecords.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: file.path))
        }
    }

    @Test func aMissingApplicationDoesNotOpenOrOfferToRememberTheLink() async {
        await withPolicy { store, policy, url, _ in
            var opened: [URL] = []
            var shown = false
            ExternalApp.resolverForTesting = { _ in nil }
            ExternalApp.openerForTesting = { opened.append($0) }
            ExternalApp.presenterForTesting = { alert in
                shown = true
                #expect(!alert.showsSuppressionButton)
                return .alertFirstButtonReturn
            }
            await ExternalApp.offerToOpen(url, from: origin, policy: policy, in: nil, isCurrent: { true })
            #expect(shown)
            #expect(opened.isEmpty)
            #expect(store.externalAppRecords.isEmpty)
        }
    }

    @Test func changingTheInstalledHandlerAsksAgain() async {
        await withPolicy { store, policy, url, _ in
            policy.remember(slack, from: origin)
            ExternalApp.resolverForTesting = { _ in
                .init(url: URL(filePath: "/Applications/Other.app"), name: "Other", bundleIdentifier: "other.app")
            }
            var prompted = false
            var opened: [URL] = []
            ExternalApp.openerForTesting = { opened.append($0) }
            ExternalApp.presenterForTesting = { _ in
                prompted = true
                return .alertSecondButtonReturn
            }
            await ExternalApp.offerToOpen(url, from: origin, policy: policy, in: nil, isCurrent: { true })
            #expect(prompted)
            #expect(opened.isEmpty)
            #expect(store.externalApps(for: origin) == [slack])
        }
    }

    enum Suspension: CaseIterable {
        case resolving, rememberedResolving, confirming
    }

    @Test(.boundedWebViews, arguments: Suspension.allCases, [false, true])
    func aClosedOrRetiredPageCannotFinishAnAppHandoff(at suspension: Suspension, closesTab: Bool) async {
        await withPolicy { store, policy, url, _ in
            let tab = BrowserTab(opensBlank: false, sitePermissions: store)
            let view = tab.page
            defer { tab.detach() }
            if suspension == .rememberedResolving {
                policy.remember(slack, from: origin)
            }
            let saved = store.externalApps(for: origin)
            var prompts = 0
            var opened: [URL] = []
            let invalidate: () async -> Void = {
                if closesTab {
                    tab.detach()
                } else {
                    #expect(await tab.switchEngine(to: .chromium))
                }
            }
            ExternalApp.resolverForTesting = { _ in
                if suspension != .confirming {
                    await invalidate()
                }
                return .init(url: URL(filePath: "/Applications/Slack.app"), name: "Slack",
                             bundleIdentifier: slack.bundleIdentifier)
            }
            ExternalApp.presenterForTesting = { alert in
                prompts += 1
                alert.suppressionButton?.state = .on
                await invalidate()
                return .alertFirstButtonReturn
            }
            ExternalApp.openerForTesting = { opened.append($0) }
            await ExternalApp.offerToOpen(url, from: origin, policy: policy, in: nil, isCurrent: {
                !tab.isClosed && tab.liveView === view
            })
            #expect(prompts == (suspension == .confirming ? 1 : 0))
            #expect(opened.isEmpty)
            #expect(store.externalApps(for: origin) == saved)
            tab.detach()
            await tab.waitForRetirement()
        }
    }
}
