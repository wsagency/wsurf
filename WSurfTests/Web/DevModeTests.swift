// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Foundation
import Testing

@testable import WSurf

/// Developer mode for websites: which sites use it, where a choice is kept, what leaves WSurf through "Open In", and that it
/// stays apart from the access an external connection can be given to developer sites. The page and engine behavior is in
/// `DevModePageTests`.
@MainActor
struct DevModeTests {
    private func withSuite(_ body: (UserDefaults) throws -> Void) throws {
        let name = AppDatabase.defaultsSuite("DevModeTests.\(UUID().uuidString)")
        let suite = try #require(UserDefaults(suiteName: name))
        defer { UserDefaults().removePersistentDomain(forName: name) }
        try body(suite)
    }

    // MARK: Which websites

    @Test(arguments: [
        "http://localhost:5173/?seed=35144",
        "http://LOCALHOST:3000",
        "http://app.localhost:3000",
        "http://sub.app.localhost:3000",
        "http://127.0.0.1:8080",
        "http://127.0.0.2/",
        "http://[::1]:8000",
        "http://0.0.0.0:4000",
        "https://game.test",
        "http://mac-studio.local:5173",
    ])
    func localHostsStartInDeveloperMode(_ address: String) throws {
        try withSuite { suite in
            #expect(BrowserSettings(defaults: suite).usesDevMode(for: URL(string: address)))
        }
    }

    @Test(arguments: [
        "https://example.com",
        "http://127.example.com",
        "http://localhost.example.com",
        "http://notlocalhost/",
        "http://testing.example.com",
        "http://192.168.1.10:3000/",
        "file:///Users/me/index.html",
        "wsurf://settings",
        "wsurf://start",
        "about:blank",
        "javascript:alert(1)",
    ])
    func otherAddressesDoNot(_ address: String) throws {
        try withSuite { suite in
            #expect(!BrowserSettings(defaults: suite).usesDevMode(for: URL(string: address)))
        }
    }

    @Test func noAddressIsNeverInDeveloperMode() throws {
        try withSuite { suite in
            #expect(!BrowserSettings(defaults: suite).usesDevMode(for: nil))
        }
    }

    @Test func aChoiceIsKeptPerHostAndOnlyOverridesAreStored() throws {
        try withSuite { suite in
            let settings = BrowserSettings(defaults: suite)
            let staging = URL(string: "https://staging.example.com/path")
            let local = URL(string: "http://localhost:5173")

            settings.setDevMode(true, for: staging)
            settings.setDevMode(false, for: local)
            let restored = BrowserSettings(defaults: suite)
            #expect(restored.usesDevMode(for: URL(string: "https://staging.example.com/other")))
            #expect(!restored.usesDevMode(for: URL(string: "http://localhost:3000")), "the choice is for the host, whatever the port")
            #expect(!restored.usesDevMode(for: URL(string: "https://example.com")), "a sibling or parent site is not turned on")
            #expect(!restored.usesDevMode(for: URL(string: "https://app.staging.example.com")), "a subdomain is not turned on")

            restored.setDevMode(true, for: local)
            restored.setDevMode(false, for: staging)
            #expect(restored.devModeSites.enabled.isEmpty)
            #expect(restored.devModeSites.disabled.isEmpty)
            #expect(restored.usesDevMode(for: local))
        }
    }

    @Test func aLocalSiteCanBeTurnedOffAndBackOn() throws {
        try withSuite { suite in
            let settings = BrowserSettings(defaults: suite)
            let local = URL(string: "http://app.localhost:3000")
            #expect(settings.usesDevMode(for: local))
            settings.setDevMode(false, for: local)
            #expect(!settings.usesDevMode(for: local))
            #expect(settings.devModeSites.disabled == ["app.localhost"])
            #expect(!BrowserSettings(defaults: suite).usesDevMode(for: local))
            settings.setDevMode(true, for: local)
            #expect(settings.usesDevMode(for: local))
            #expect(settings.devModeSites == DevModeSites())
        }
    }

    @Test func aChoiceForAnAddressWithoutAHostChangesNothing() throws {
        try withSuite { suite in
            let settings = BrowserSettings(defaults: suite)
            for address in ["wsurf://settings", "file:///tmp/a.html", "about:blank"] {
                settings.setDevMode(true, for: URL(string: address))
            }
            settings.setDevMode(true, for: nil)
            #expect(settings.devModeSites == DevModeSites())
        }
    }

    @Test func resetForgetsEveryChoice() throws {
        try withSuite { suite in
            let settings = BrowserSettings(defaults: suite)
            settings.setDevMode(true, for: URL(string: "https://staging.example.com"))
            settings.setDevMode(false, for: URL(string: "http://localhost:3000"))
            settings.resetToDefaults()
            #expect(settings.devModeSites == DevModeSites())
            #expect(BrowserSettings(defaults: suite).devModeSites == DevModeSites())
        }
    }

    // MARK: Where a choice is kept

    @Test func aChoiceIsAProfileSettingKeptOutOfTheApplicationDefaults() throws {
        try withSuite { app in
            try withSuite { work in
                try withSuite { personal in
                    let staging = URL(string: "https://staging.example.com")
                    let workSettings = BrowserSettings(defaults: app, sessionDefaults: work)
                    workSettings.setDevMode(true, for: staging)
                    workSettings.setDevMode(false, for: URL(string: "http://localhost:3000"))

                    let reopened = BrowserSettings(defaults: app, sessionDefaults: work)
                    #expect(reopened.usesDevMode(for: staging))
                    #expect(!reopened.usesDevMode(for: URL(string: "http://localhost:3000")))
                    let other = BrowserSettings(defaults: app, sessionDefaults: personal)
                    #expect(!other.usesDevMode(for: staging))
                    #expect(other.usesDevMode(for: URL(string: "http://localhost:3000")))

                    for key in [BrowserSettings.Key.devModeEnabledHosts, BrowserSettings.Key.devModeDisabledHosts] {
                        #expect(BrowserSettings.sessionKeys.contains(key))
                        #expect(app.object(forKey: key) == nil)
                        #expect(personal.object(forKey: key) == nil)
                    }
                }
            }
        }
    }

    @Test func aPrivateWindowsChoiceNeverReachesTheProfilesDisk() async throws {
        let owner = Profile(id: UUID(), name: "Dev mode owner", symbol: "hammer", color: .teal)
        defer { ProfileSettingsStore.forget(owner.id) }
        let staging = try #require(URL(string: "https://staging.example.com"))
        let context = BrowserProfileContext(profile: .privateBrowsing(), settingsOwner: owner)
        context.settings.setDevMode(true, for: staging)
        context.settings.setDevMode(false, for: URL(string: "http://localhost:3000"))
        #expect(context.settings.usesDevMode(for: staging))

        let onDisk = ProfileSettingsStore.defaults(for: owner)
        #expect(onDisk.object(forKey: BrowserSettings.Key.devModeEnabledHosts) == nil)
        #expect(onDisk.object(forKey: BrowserSettings.Key.devModeDisabledHosts) == nil)
        // The next private window starts from the profile's own choices, not from this one's.
        let next = BrowserProfileContext(profile: .privateBrowsing(), settingsOwner: owner)
        #expect(!next.settings.usesDevMode(for: staging))
        #expect(next.settings.usesDevMode(for: URL(string: "http://localhost:3000")))
        await context.endPrivateSession()
        await next.endPrivateSession()
    }

    // MARK: Open In

    @Test func openInNeverOffersAWSurfBuild() {
        for own in [
            "io.wsagency.wsurf", "io.wsagency.wsurf.stage.0a1b2c", "io.wsagency.wsurf.dev-linen093a", "io.wsagency.wsurf.ci-1-1",
            "IO.WSAGENCY.WSURF", "io.wsagency.wsurf.CredentialExchange",
        ] {
            #expect(DevModeOpenIn.isOwn(own, running: nil), "\(own)")
        }
        // Something that cannot be told apart is not offered either.
        #expect(DevModeOpenIn.isOwn(nil, running: nil))
        #expect(DevModeOpenIn.isOwn("", running: nil))
        for other in ["com.apple.Safari", "org.mozilla.firefox", "com.google.Chrome", "company.thebrowser.Browser"] {
            #expect(!DevModeOpenIn.isOwn(other, running: nil), "\(other)")
        }
        // The running build is left out under whatever identifier it has.
        #expect(DevModeOpenIn.isOwn("com.example.renamed-fork", running: "com.example.Renamed-Fork"))
        #expect(DevModeOpenIn.isOwn(Bundle.main.bundleIdentifier))
        #expect(Bundle.main.bundleIdentifier?.lowercased().hasPrefix(DevModeOpenIn.ownIdentifierPrefix) == true)
    }

    @Test func openInListsOneEntryPerBrowserInNameOrder() {
        let apps = [
            "/Applications/Safari.app", "/Applications/WSurf.app", "/Applications/Firefox.app", "/Applications/Firefox 2.app",
            "/Applications/Arc.app", "/Applications/WSurf Stage.app", "/Applications/NoIdentifier.app",
        ].map { URL(filePath: $0) }
        let identifiers = [
            "Safari": "com.apple.Safari", "WSurf": "io.wsagency.wsurf", "Firefox": "org.mozilla.firefox",
            "Firefox 2": "ORG.MOZILLA.FIREFOX", "Arc": "company.thebrowser.Browser", "WSurf Stage": "io.wsagency.wsurf.stage.ab12",
        ]
        let browsers = DevModeOpenIn.browsers(
            among: apps,
            identifier: { identifiers[$0.deletingPathExtension().lastPathComponent] },
            name: { $0.deletingPathExtension().lastPathComponent }
        )
        #expect(browsers.map { $0.deletingPathExtension().lastPathComponent } == ["Arc", "Firefox", "Safari"])
    }

    @Test func theSystemsOwnListNeverHoldsAWSurfBuildAndIsEmptyInAPrivateWindow() {
        for browser in DevModeOpenIn.installedBrowsers(isPrivate: false) {
            let identifier = Bundle(url: browser)?.bundleIdentifier ?? ""
            #expect(!identifier.lowercased().hasPrefix(DevModeOpenIn.ownIdentifierPrefix), "\(browser.path)")
            #expect(!identifier.isEmpty, "\(browser.path)")
        }
        #expect(DevModeOpenIn.installedBrowsers(isPrivate: true).isEmpty)
    }

    @Test func onlyAWebAddressOfAWindowThatIsNotPrivateMayLeave() {
        #expect(DevModeOpenIn.shareableURL("http://localhost:3000/a?b=1", isPrivate: false)?.absoluteString == "http://localhost:3000/a?b=1")
        #expect(DevModeOpenIn.shareableURL("https://example.com", isPrivate: false) != nil)
        #expect(DevModeOpenIn.shareableURL("https://example.com", isPrivate: true) == nil)
        #expect(DevModeOpenIn.shareableURL("http://localhost:3000", isPrivate: true) == nil)
        for address in ["wsurf://settings", "wsurf://start", "file:///etc/hosts", "javascript:alert(1)", "about:blank", "mailto:a@b.c", ""] {
            #expect(DevModeOpenIn.shareableURL(address, isPrivate: false) == nil, "\(address)")
        }
    }

    @Test func openingChecksTheRulesAgainWhateverTheMenuWasBuiltFrom() {
        var handed: [(URL, URL)] = []
        let hand: (URL, URL) -> Void = { handed.append(($0, $1)) }
        let safari = URL(filePath: "/Applications/Safari.app")
        let theyAreNotWSurf: (URL) -> String? = { _ in "com.apple.Safari" }

        #expect(DevModeOpenIn.open("http://localhost:3000/x?q=1", isPrivate: false, in: safari, identifier: theyAreNotWSurf, hand: hand))
        #expect(handed.count == 1)
        #expect(handed.first?.0.absoluteString == "http://localhost:3000/x?q=1")
        #expect(handed.first?.1 == safari)

        // A private window hands nothing over, whichever application the menu offered.
        #expect(!DevModeOpenIn.open("http://localhost:3000/x", isPrivate: true, in: safari, identifier: theyAreNotWSurf, hand: hand))
        // A WSurf build is refused, by identifier and for the running build's own bundle.
        for own in ["io.wsagency.wsurf", "io.wsagency.wsurf.stage.ab12", Bundle.main.bundleIdentifier] {
            #expect(!DevModeOpenIn.open("http://localhost:3000/x", isPrivate: false, in: safari, identifier: { _ in own }, hand: hand))
        }
        #expect(!DevModeOpenIn.open("http://localhost:3000/x", isPrivate: false, in: Bundle.main.bundleURL, hand: hand), "this build's own bundle")
        #expect(!DevModeOpenIn.open("wsurf://settings", isPrivate: false, in: safari, identifier: theyAreNotWSurf, hand: hand))
        #expect(handed.count == 1, "nothing else was handed over")
    }

    // MARK: Apart from the access of external connections

    /// The two features share a word and nothing else: no code of one names the other's types or settings.
    @Test func developerModeAndExternalConnectionAccessNeverNameEachOther() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        func sources(_ directory: String) throws -> [(name: String, code: String)] {
            let files = try #require(FileManager.default.enumerator(at: root.appending(path: directory), includingPropertiesForKeys: nil))
            return try files.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }.map { file in
                let code = try String(contentsOf: file, encoding: .utf8)
                    .split(separator: "\n", omittingEmptySubsequences: false)
                    .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                    .joined(separator: "\n")
                return (file.lastPathComponent, code)
            }
        }

        let devMode = try sources("WSurf/Web/DevMode") + sources("WSurf/UI/DevMode")
        #expect(devMode.count >= 3)
        let access = [
            "MCP", "TrustStore", "DeveloperAccess", "developerSites", "developerProfile", "DevelopmentOwner", "developmentOwner",
            "emulationQueue", "DevelopmentViewport",
        ]
        for (name, code) in devMode {
            for word in access {
                #expect(!code.contains(word), "\(name) names \(word)")
            }
        }

        let connections = try sources("WSurf/MCP")
        #expect(connections.count > 10)
        let devModeNames = ["DevMode", "devModeSites", "usesDevMode", "setDevMode", "devMode."]
        for (name, code) in connections {
            for word in devModeNames {
                #expect(!code.contains(word), "\(name) names \(word)")
            }
        }
    }

    // MARK: The palette

    @Test func theCommandPaletteOffersTheInspectorAndTheScreenshotOnlyWhenTheyCanRun() {
        func ids(_ context: CommandPaletteContext) -> Set<String> {
            Set(CommandPaletteCatalog.commands(context: context, perform: { _ in }).map(\.id))
        }
        let idle = ids(CommandPaletteContext(tabCount: 1, hasActiveTab: true))
        #expect(!idle.contains("action-showWebInspector"))
        #expect(!idle.contains("action-copyScreenshot"))

        let ready = CommandPaletteCatalog.commands(
            context: CommandPaletteContext(tabCount: 1, hasActiveTab: true, canInspect: true, canScreenshot: true),
            perform: { _ in }
        )
        let inspector = ready.first { $0.id == "action-showWebInspector" }
        #expect(inspector?.shortcut == "⌥⌘I")
        #expect(inspector?.group == .page)
        #expect(ready.contains { $0.id == "action-copyScreenshot" })
        for word in ["devtools", "inspect element", "console"] {
            #expect(CommandPaletteCatalog.matching(word, in: ready).first?.id == "action-showWebInspector", "\(word)")
        }
        for word in ["screenshot", "capture page"] {
            #expect(CommandPaletteCatalog.matching(word, in: ready).first?.id == "action-copyScreenshot", "\(word)")
        }
        // One without a WebKit page to inspect still takes a screenshot.
        let chromium = ids(CommandPaletteContext(tabCount: 1, hasActiveTab: true, canInspect: false, canScreenshot: true))
        #expect(!chromium.contains("action-showWebInspector"))
        #expect(chromium.contains("action-copyScreenshot"))
    }

    @Test func theCopyScreenshotCommandNeedsAPageThatIsLoaded() async throws {
        let coordinator = AppCoordinator(browser: BrowserModel(database: .temporary()))
        defer { coordinator.closeWindow() }
        let tab = await parkTab(coordinator.browser, at: try #require(URL(string: "http://localhost:3000/")))
        #expect(tab.isMaterialised)
        #expect(coordinator.browser.activeTab === tab)
        let model = CommandPaletteModel(browser: coordinator.browser, coordinator: coordinator) {}
        model.prepare()

        model.interaction.query = "> copy screenshot"
        #expect(model.sections.flattened.contains { $0.id == "action-copyScreenshot" })
        model.interaction.query = "> web inspector"
        #expect(model.sections.flattened.contains { $0.id == "action-showWebInspector" }, "a WebKit page has an inspector")

        // With the page unloaded there is nothing on screen to capture or inspect.
        #expect(coordinator.browser.unload(tab))
        #expect(!tab.isMaterialised)
        model.interaction.query = "> copy screenshot"
        #expect(!model.sections.flattened.contains { $0.id == "action-copyScreenshot" })
        model.interaction.query = "> web inspector"
        #expect(!model.sections.flattened.contains { $0.id == "action-showWebInspector" })
    }
}
