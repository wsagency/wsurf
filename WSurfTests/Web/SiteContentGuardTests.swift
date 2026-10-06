// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import Testing
import WebKit

@testable import WSurf

@MainActor
/// The page-side half of the auto-play and pop-up answers. WebKit fixes the
/// media policy when a view is made, so nothing but this script enforces what
/// a website was told.
@Suite(.serialized, .boundedWebViews)
final class SiteContentGuardTests {
    private let defaultsName = "SiteContentGuardTests-" + UUID().uuidString
    private let settings: BrowserSettings

    init() {
        settings = BrowserSettings(defaults: UserDefaults(suiteName: defaultsName)!)
    }

    deinit {
        UserDefaults.standard.removePersistentDomain(forName: defaultsName)
    }

    private final class Reports {
        var count = 0
        var url: URL?
    }

    private func temporaryPermissions() -> SitePermissions {
        SitePermissions(
            storageURL: FileManager.default.temporaryDirectory
                .appending(path: "SiteContentGuardTests-\(UUID().uuidString).json")
        )
    }

    private static let markup = """
        <!doctype html><html><body style="margin:0">
        <video style="width:640px;height:360px"></video>
        </body></html>
        """

    private func page(permissions: SitePermissions, reports: Reports? = nil, at address: URL? = nil) async -> BrowserPage {
        let configuration = WebViewPool.makeConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let view = BrowserPage(webKit: TabWebView(
            frame: NSRect(x: 0, y: 0, width: 800, height: 600),
            configuration: configuration
        ))
        SiteContentGuard.shared.install(in: view, permissions: permissions, settings: settings) {
            reports?.url = $0
            reports?.count += 1
        }
        if let address {
            view.load(URLRequest(url: address))
        } else {
            view.loadHTMLString(Self.markup, baseURL: nil)
        }
        #expect(await PageSettle.untilIdle(view, timeout: .seconds(30)))
        #expect(
            await waitUntil {
                let settled = try? await view.evaluateJavaScript(
                    "!!(window.__wsurfSiteGuard && window.__wsurfSiteGuard.autoplay)"
                )
                return (settled as? NSNumber)?.boolValue == true
            },
            "the page never heard back which policy it is under"
        )
        return view
    }

    /// `pause` is replaced rather than watched: a player with no source throws
    /// on the real call, and the count is what the test is asking about.
    private func play(in view: BrowserPage, startedByHand: Bool = false) async {
        _ = try? await view.evaluateJavaScript(
            """
            (() => {
              Object.defineProperty(navigator, 'userActivation', {
                configurable: true,
                get() { return { hasBeenActive: \(startedByHand), isActive: \(startedByHand) }; }
              });
              const video = document.querySelector('video');
              window.__pauses = 0;
              video.pause = () => { window.__pauses += 1; };
              video.dispatchEvent(new Event('play'));
              return true;
            })()
            """
        )
    }

    private func pauses(in view: BrowserPage) async -> Int {
        let count = try? await view.evaluateJavaScript("window.__pauses")
        return (count as? NSNumber)?.intValue ?? -1
    }

    private func isMuted(in view: BrowserPage) async -> Bool {
        let muted = try? await view.evaluateJavaScript("document.querySelector('video').muted")
        return (muted as? NSNumber)?.boolValue ?? false
    }

    // MARK: - Auto-play

    @Test func aWebsiteToldNeverIsStopped() async {
        settings.autoplay = .block

        let view = await page(permissions: temporaryPermissions())
        await play(in: view)

        #expect(await pauses(in: view) == 1)
        #expect(await isMuted(in: view) == false, "stopping a player is not muting it")
    }

    @Test func aWebsiteToldMutedPlaysWithoutSound() async {
        settings.autoplay = .silent

        let view = await page(permissions: temporaryPermissions())
        await play(in: view)

        #expect(await pauses(in: view) == 0, "a muted player is still a playing one")
        #expect(await isMuted(in: view))
    }

    @Test func aWebsiteToldAllowIsLeftAlone() async {
        settings.autoplay = .allow

        let view = await page(permissions: temporaryPermissions())
        await play(in: view)

        #expect(await pauses(in: view) == 0)
        #expect(await isMuted(in: view) == false)
    }

    /// The answer is about what a website starts by itself. A video the person
    /// pressed play on is theirs, whatever the website was told.
    @Test func aPlayerThePersonStartedIsNeverStopped() async {
        settings.autoplay = .block

        let view = await page(permissions: temporaryPermissions())
        await play(in: view, startedByHand: true)

        #expect(await pauses(in: view) == 0)
    }

    /// A website's own answer outranks the setting every other website is under.
    @Test func aWebsiteWithItsOwnAnswerIsNotUnderTheSetting() async throws {
        settings.autoplay = .allow

        let server = try await HTTPFixtureServer.start(routes: ["/": .html(Self.markup)])
        let address = try server.url()
        let permissions = temporaryPermissions()
        permissions.setAutoplay(.block, for: SitePermissions.origin(for: address))

        let view = await page(permissions: permissions, at: address)
        await play(in: view)

        #expect(await pauses(in: view) == 1)
    }

    // MARK: - Pop-ups

    @Test func aBlockedPopUpIsReportedWithTheAddressItWanted() async {
        settings.blocksPopups = true

        let reports = Reports()
        let view = await page(permissions: temporaryPermissions(), reports: reports)

        _ = try? await view.evaluateJavaScript("window.open('https://example.com/popup'); true")

        #expect(await waitUntil { reports.count > 0 })
        #expect(reports.url == URL(string: "https://example.com/popup"))
    }

    @Test func aWebsiteAllowedItsPopUpsReportsNothing() async throws {
        settings.blocksPopups = false

        let reports = Reports()
        let view = await page(permissions: temporaryPermissions(), reports: reports)

        _ = try? await view.evaluateJavaScript("window.open('https://example.com/popup'); true")
        try await view.finishPendingPageMessages()

        #expect(reports.count == 0, "nothing was blocked, so there is nothing to say")
    }
}
