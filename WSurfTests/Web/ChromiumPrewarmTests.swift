// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing

@testable import WSurf

/// Chromium starts early only for a session that uses it, only when the app has been left alone, and only once.
@MainActor
struct ChromiumPrewarmTests {
    private let idle = Duration.seconds(2)

    private func temporaryPermissions() -> SitePermissions {
        SitePermissions(storageURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("ChromiumPrewarm-\(UUID().uuidString).json"))
    }

    private func addTab(on site: String, in browser: BrowserModel, favourite: Bool = false) -> BrowserTab {
        let tab = browser.makeTab(for: nil)
        tab.urlString = "\(site)/page"
        tab.isFavorite = favourite
        browser.tabs.append(tab)
        return tab
    }

    private func uniqueSite() -> String {
        "https://prewarm-\(UUID().uuidString.prefix(8).lowercased()).example"
    }

    /// A prewarm over a manual clock; `starts` counts what it started.
    @MainActor
    private final class Rig {
        let clock = TestClock()
        private(set) var starts = 0
        var started = false
        var busy = false
        private(set) var prewarm: ChromiumPrewarm!

        init(idle: Duration, usesChromium: @escaping @MainActor () -> Bool) {
            prewarm = ChromiumPrewarm(
                clock: clock, idleInterval: idle, usesChromium: usesChromium,
                isStarted: { [unowned self] in started },
                isBusy: { [unowned self] in busy },
                start: { [unowned self] in
                    starts += 1
                    started = true
                })
        }
    }

    /// Lets what an advance of the clock resumed run: a task the clock released has had its turn once the main actor has been given up
    /// a few times. A start that should not happen would have happened by then.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(100))
    }

    @Test func aSessionWithoutChromiumNeverStartsIt() async throws {
        let rig = Rig(idle: idle) { false }
        rig.prewarm.arm()
        try #require(await waitUntil { rig.clock.pendingCount == 1 })
        rig.clock.advance(by: idle)
        try #require(await waitUntil { rig.prewarm.isFinished })
        #expect(rig.starts == 0)
        // The attempt is over: more idle time and more input change nothing.
        rig.prewarm.noteInput()
        rig.prewarm.arm()
        #expect(rig.clock.pendingCount == 0)
    }

    @Test func aChromiumTabStartsItOnceTheAppIsIdle() async throws {
        let browser = BrowserModel(database: .temporary(), sitePermissions: temporaryPermissions())
        let tab = addTab(on: uniqueSite(), in: browser)
        tab.engineOverride = .chromium
        let models = [browser]
        let permissions = [browser.sitePermissions]
        let rig = Rig(idle: idle) { ChromiumPrewarm.sessionUsesChromium(models: models, permissions: permissions) }
        rig.prewarm.arm()
        try #require(await waitUntil { rig.clock.pendingCount == 1 })
        rig.clock.advance(by: idle - .milliseconds(1))
        await settle()
        #expect(rig.starts == 0 && !rig.prewarm.isFinished, "not before the idle time has passed")
        #expect(rig.clock.pendingCount == 1, "and the wait is still there")
        rig.clock.advance(by: .milliseconds(1))
        try #require(await waitUntil { rig.starts == 1 })
    }

    @Test func aChromiumFavouriteStartsItOnceTheAppIsIdle() async throws {
        let site = uniqueSite()
        let browser = BrowserModel(database: .temporary(), sitePermissions: temporaryPermissions())
        let favourite = addTab(on: site, in: browser, favourite: true)
        // Another tab of the site moved the site's setting; the favourite keeps Chromium for the site.
        favourite.pinnedEngine = (origin: SitePermissions.origin(for: URL(string: site)), engine: .chromium)
        #expect(browser.engine(for: favourite) == .chromium)
        let models = [browser]
        let permissions = [browser.sitePermissions]
        let rig = Rig(idle: idle) { ChromiumPrewarm.sessionUsesChromium(models: models, permissions: permissions) }
        rig.prewarm.arm()
        try #require(await waitUntil { rig.clock.pendingCount == 1 })
        rig.clock.advance(by: idle)
        try #require(await waitUntil { rig.starts == 1 })
    }

    @Test func aSiteRuleForChromiumStartsItWithoutAnyTab() async throws {
        let permissions = temporaryPermissions()
        let browser = BrowserModel(database: .temporary(), sitePermissions: temporaryPermissions())
        #expect(!ChromiumPrewarm.sessionUsesChromium(models: [browser], permissions: [permissions]))
        permissions.setEngine(.chromium, for: uniqueSite())
        #expect(ChromiumPrewarm.sessionUsesChromium(models: [browser], permissions: [permissions]))
        let rig = Rig(idle: idle) { ChromiumPrewarm.sessionUsesChromium(models: [browser], permissions: [permissions]) }
        rig.prewarm.arm()
        try #require(await waitUntil { rig.clock.pendingCount == 1 })
        rig.clock.advance(by: idle)
        try #require(await waitUntil { rig.starts == 1 })
    }

    @Test func webKitTabsAloneDoNotCountAsChromium() {
        let browser = BrowserModel(database: .temporary(), sitePermissions: temporaryPermissions())
        _ = addTab(on: uniqueSite(), in: browser)
        _ = addTab(on: uniqueSite(), in: browser, favourite: true)
        #expect(!ChromiumPrewarm.sessionUsesChromium(models: [browser], permissions: [browser.sitePermissions]))
    }

    @Test func inputPostponesTheStart() async throws {
        let rig = Rig(idle: idle) { true }
        rig.prewarm.arm()
        try #require(await waitUntil { rig.clock.pendingCount == 1 })
        rig.clock.advance(by: .seconds(1.5))
        rig.prewarm.noteInput()
        try #require(await waitUntil { rig.clock.pendingCount == 1 })
        // 1.5 s after the key press is 3 s after arming: the first wait would have ended, the second has not.
        rig.clock.advance(by: .seconds(1.5))
        await settle()
        #expect(rig.starts == 0)
        #expect(!rig.prewarm.isFinished)
        #expect(rig.clock.pendingCount == 1, "the wait started again from the input")
        rig.clock.advance(by: .seconds(0.5))
        try #require(await waitUntil { rig.starts == 1 })
    }

    @Test func aStartedChromiumIsNotStartedAgain() async throws {
        let started = Rig(idle: idle) { true }
        started.started = true
        started.prewarm.arm()
        try #require(await waitUntil { started.clock.pendingCount == 1 })
        started.clock.advance(by: idle)
        try #require(await waitUntil { started.prewarm.isFinished })
        #expect(started.starts == 0, "a session that already started Chromium is left alone")

        let twice = Rig(idle: idle) { true }
        twice.prewarm.arm()
        twice.prewarm.arm()
        try #require(await waitUntil { twice.clock.pendingCount == 1 })
        twice.clock.advance(by: idle)
        try #require(await waitUntil { twice.starts == 1 })
        twice.prewarm.arm()
        twice.prewarm.noteInput()
        twice.clock.advance(by: .seconds(10))
        #expect(twice.starts == 1, "one start per launch")
    }

    @Test func aMouseButtonHeldDownIsNotIdleTime() async throws {
        let rig = Rig(idle: idle) { true }
        rig.busy = true
        rig.prewarm.arm()
        try #require(await waitUntil { rig.clock.pendingCount == 1 })
        rig.clock.advance(by: idle)
        await settle()
        #expect(rig.starts == 0 && !rig.prewarm.isFinished, "a drag in progress is use of the app")
        try #require(await waitUntil { rig.clock.pendingCount == 1 }, "and the wait begins again")
        rig.busy = false
        rig.clock.advance(by: idle)
        try #require(await waitUntil { rig.starts == 1 })
    }

    @Test func cancellingStopsTheWait() async throws {
        let rig = Rig(idle: idle) { true }
        rig.prewarm.arm()
        try #require(await waitUntil { rig.clock.pendingCount == 1 })
        rig.prewarm.cancel()
        #expect(rig.clock.pendingCount == 0)
        rig.clock.advance(by: idle)
        #expect(rig.starts == 0)
    }
}
