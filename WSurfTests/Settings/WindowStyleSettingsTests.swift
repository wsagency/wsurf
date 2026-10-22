// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import WSurf

/// The app-wide window choices: the full address and the window style. Every case owns its settings and a throwaway
/// defaults suite.
@MainActor
struct WindowStyleSettingsTests {
    private func withSettings(_ test: (BrowserSettings, UserDefaults) throws -> Void) throws {
        let name = AppDatabase.defaultsSuite("WindowStyleSettingsTests-\(UUID().uuidString)")
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try test(BrowserSettings(defaults: defaults, appliesAppearanceGlobally: false), defaults)
    }

    private func resting(_ url: String, full: Bool) -> AskRestingContent? {
        AskRestingContent.resolve(
            isListening: false,
            transcript: "",
            agentMessage: nil,
            mirrorsPageURL: true,
            isFocused: false,
            typedText: "",
            notice: nil,
            status: nil,
            placeholder: "Search",
            currentURL: url,
            showsFullAddress: full
        )
    }

    // MARK: - Full address

    @Test func theAddressShowsTheWebsiteNameUnlessTheFullAddressIsOn() {
        let url = "https://www.example.com/docs/page?query=1#part"

        #expect(resting(url, full: false) == .address("example.com"))
        #expect(resting(url, full: true) == .address("www.example.com", scheme: "https://", rest: "/docs/page?query=1#part"))
        #expect(AskRestingContent.displayAddress(for: url) == "example.com", "the default stays the website name")
        #expect(resting("http://example.test:8080/a", full: true) == .address("example.test", scheme: "http://", rest: ":8080/a"))
    }

    @Test func signInDetailsInTheAddressNeverPoseAsTheWebsite() {
        let spoof = "https://bank.com@evil.com/login"
        #expect(resting(spoof, full: true) == .address("evil.com", scheme: "https://", rest: "/login"))
        #expect(resting(spoof, full: false) == .address("evil.com"))

        let withPassword = "https://user:secret@evil.com:8443/a?b=1"
        #expect(resting(withPassword, full: true) == .address("evil.com", scheme: "https://", rest: ":8443/a?b=1"))
        let spoken = resting(withPassword, full: true)?.accessibilityValue(fallback: withPassword) ?? ""
        #expect(!spoken.contains("user") && !spoken.contains("secret"), "VoiceOver hears the address that is drawn")
    }

    @Test func aRawAddressWithSignInDetailsAndInvalidCharactersIsRebuilt() {
        let raw = "https://bank.com@evil.com/<x> y"
        #expect(resting(raw, full: true) == .address("evil.com", scheme: "https://", rest: "/%3Cx%3E%20y"))
        #expect(resting(raw, full: false) == .address("evil.com"))
    }

    @Test func everyNonASCIIWebsiteNameShowsAsPunycode() throws {
        // Latin Extended look-alikes (dotless "ı", IPA "ɡ"), a Cyrillic "а" among Latin letters, a whole name of Cyrillic
        // look-alikes, and an ordinary German name: none is drawn in Unicode.
        for url in ["https://gıthub.com/", "https://ɡoogle.com/", "https://аpple.com/", "https://аррӏе.com/", "https://bücher.de/"] {
            let encoded = try #require(URLComponents(string: url)?.encodedHost)
            #expect(encoded.allSatisfy(\.isASCII) && encoded.contains("xn--"), "\(url)")
            #expect(resting(url, full: true) == .address(encoded, scheme: "https://", rest: "/"), "\(url)")
            #expect(resting(url, full: false) == .address(encoded), "\(url)")
        }
        #expect(resting("https://аpple.com/", full: true) == .address("xn--pple-43d.com", scheme: "https://", rest: "/"))
    }

    @Test func anAddressThatDoesNotParseShowsThePlaceholderNotItsText() {
        for raw in ["https://exa mple.com/", "http://[::1", "ht tp://bank.com", "https://bank.com%40evil.com/"] {
            #expect(resting(raw, full: true) == .placeholder("Search"), "\(raw)")
            #expect(resting(raw, full: false) == .placeholder("Search"), "\(raw)")
            #expect(AskRestingContent.displayAddress(for: raw) == nil, "\(raw)")
        }
    }

    @Test func invisibleAndReorderingCharactersInThePathStayEncoded() {
        let url = "https://example.com/%E2%80%AEtxt.exe"
        #expect(resting(url, full: true) == .address("example.com", scheme: "https://", rest: "/%E2%80%AEtxt.exe"))
        #expect(resting("https://example.com/\u{202E}txt.exe", full: true)
            == .address("example.com", scheme: "https://", rest: "/%E2%80%AEtxt.exe"))
    }

    @Test func anAddressWithoutAHostIsRebuiltToo() {
        #expect(resting("about:blank", full: false) == .address("about:blank"))
        #expect(resting("file:///Users/me/a.html", full: true) == .address("", scheme: "file://", rest: "/Users/me/a.html"))
    }

    @Test func aPageWithoutAnAddressStillShowsThePlaceholder() {
        #expect(resting("", full: true) == .placeholder("Search"))
        #expect(resting("", full: false) == .placeholder("Search"))
    }

    @Test func theFullAddressIsOneAppWideChoiceThatSurvivesARestartAndResets() throws {
        try withSettings { settings, defaults in
            #expect(!settings.showsFullAddress, "off by default")

            let profile = BrowserSettings(defaults: defaults, appliesAppearanceGlobally: false, application: settings)
            profile.showsFullAddress = true
            #expect(settings.showsFullAddress, "a profile writes the app-wide value")
            #expect(defaults.object(forKey: BrowserSettings.Key.fullAddress) as? Bool == true)
            #expect(BrowserSettings(defaults: defaults, appliesAppearanceGlobally: false).showsFullAddress)

            settings.resetToDefaults()
            #expect(!settings.showsFullAddress)
            #expect(!profile.showsFullAddress)
        }
    }

    // MARK: - Window style

    @Test func standardStaysTheDefaultWithTheBarAtTheBottom() throws {
        try withSettings { settings, _ in
            #expect(settings.windowStyle == .standard)
            #expect(settings.minimalBarEdge == .bottom)
            #expect(!settings.hidesMinimalBar)
        }
    }

    @Test func theWindowStyleIsOneAppWideChoiceThatSurvivesARestartAndResets() throws {
        try withSettings { settings, defaults in
            let profile = BrowserSettings(defaults: defaults, appliesAppearanceGlobally: false, application: settings)
            profile.windowStyle = .minimal
            profile.minimalBarEdge = .top
            profile.hidesMinimalBar = true
            #expect(settings.windowStyle == .minimal && settings.minimalBarEdge == .top && settings.hidesMinimalBar)
            #expect(defaults.string(forKey: BrowserSettings.Key.windowStyle) == "minimal")
            #expect(defaults.string(forKey: BrowserSettings.Key.minimalBarEdge) == "top")

            let reopened = BrowserSettings(defaults: defaults, appliesAppearanceGlobally: false)
            #expect(reopened.windowStyle == .minimal && reopened.minimalBarEdge == .top && reopened.hidesMinimalBar)

            settings.resetToDefaults()
            #expect(settings.windowStyle == .standard && settings.minimalBarEdge == .bottom && !settings.hidesMinimalBar)
        }
    }

    @Test func theMinimalSidebarIsNotKeptOpenByDefault() throws {
        try withSettings { settings, _ in
            #expect(!settings.keepsMinimalSidebarOpen, "nothing changes for anyone who never pins it")
        }
    }

    @Test func keepingTheMinimalSidebarOpenIsOneAppWideChoiceThatSurvivesARestartAndResets() throws {
        try withSettings { settings, defaults in
            let profile = BrowserSettings(defaults: defaults, appliesAppearanceGlobally: false, application: settings)
            profile.keepsMinimalSidebarOpen = true
            #expect(settings.keepsMinimalSidebarOpen, "a profile writes the app-wide value")
            #expect(defaults.object(forKey: BrowserSettings.Key.minimalSidebarPinned) as? Bool == true)
            #expect(settings.windowStyle == .standard, "pinning the list does not pick the Minimal window")

            let reopened = BrowserSettings(defaults: defaults, appliesAppearanceGlobally: false)
            #expect(reopened.keepsMinimalSidebarOpen)

            settings.resetToDefaults()
            #expect(!settings.keepsMinimalSidebarOpen && !profile.keepsMinimalSidebarOpen)
            #expect(defaults.object(forKey: BrowserSettings.Key.minimalSidebarPinned) as? Bool == false)
        }
    }

    @Test func anUnknownStoredStyleFallsBackToStandard() throws {
        try withSettings { _, defaults in
            defaults.set("floating", forKey: BrowserSettings.Key.windowStyle)
            defaults.set("left", forKey: BrowserSettings.Key.minimalBarEdge)
            let settings = BrowserSettings(defaults: defaults, appliesAppearanceGlobally: false)
            #expect(settings.windowStyle == .standard)
            #expect(settings.minimalBarEdge == .bottom)
        }
    }

    @Test func searchFindsTheWindowCard() {
        for (query, id) in [
            ("minimal", "appearance.window"), ("window style", "appearance.window"),
            ("bar position", "appearance.minimalBar"), ("auto hide", "appearance.minimalBarAutoHide"),
        ] {
            #expect(SettingsIndex.search(query).contains { $0.id == id }, "\(query)")
        }
        #expect(SettingsIndex.all.filter { $0.id.hasPrefix("appearance.minimal") || $0.id == "appearance.window" }
            .allSatisfy { $0.category == .appearance })
    }

    @Test func searchFindsTheFullAddressRowInGeneral() throws {
        let entries = SettingsIndex.all.filter { $0.id == "general.fullAddress" }
        let entry = try #require(entries.first)

        #expect(entries.count == 1)
        #expect(entry.category == .general)
        for query in ["full address", "full url", "path", "url bar"] {
            #expect(SettingsIndex.search(query).contains { $0.id == "general.fullAddress" }, "\(query)")
        }
    }
}

/// The full address on a line too short for it: the path and query give way, the website name keeps its whole width.
@MainActor
struct FullAddressLineTests {
    @Test func aLongPathIsCutBeforeTheWebsiteName() throws {
        let long = "https://accounts.example.com/" + String(repeating: "very-long-path/", count: 20) + "?q=1"
        let address = try #require(AddressText(URL(string: long)))
        var hostWidth: CGFloat = 0
        let line = FullAddressLine(address: address, fontSize: 12.5, onHostWidth: { hostWidth = $0 })
            .frame(width: 240, alignment: .leading)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 240, height: 30),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: line)
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        let whole = NSHostingView(rootView: FullAddressLine(address: address, fontSize: 12.5)).fittingSize.width
        let name = NSHostingView(
            rootView: Text(verbatim: address.host).font(.system(size: 12.5)).fontWeight(.medium).lineLimit(1)
        ).fittingSize.width
        #expect(whole > 240, "the address does not fit, so something is cut")
        #expect(abs(hostWidth - name) < 1, "the website name keeps its full width (\(hostWidth) of \(name))")
    }
}
