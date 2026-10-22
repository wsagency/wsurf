// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import WSurf

/// The app-wide window choices: the full address. Every case owns its settings and a throwaway defaults suite.
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

    @Test func aLookAlikeWebsiteNameShowsAsPunycode() throws {
        // A Cyrillic "а" among Latin letters, a whole name of Cyrillic look-alikes, and a Latin dotless "ı".
        for spoof in ["https://аpple.com/", "https://аррӏе.com/", "https://gıthub.com/"] {
            let encoded = try #require(URLComponents(string: spoof)?.encodedHost)
            #expect(encoded.hasPrefix("xn--"))
            #expect(resting(spoof, full: true) == .address(encoded, scheme: "https://", rest: "/"), "\(spoof)")
            #expect(resting(spoof, full: false) == .address(encoded), "\(spoof)")
        }
        #expect(resting("https://аpple.com/", full: false) == .address("xn--pple-43d.com"))
    }

    @Test func aWebsiteNameInOneScriptReadsAsWritten() {
        #expect(resting("https://bücher.de/", full: false) == .address("bücher.de"))
        #expect(resting("https://xn--bcher-kva.de/", full: false) == .address("bücher.de"), "punycode from the engine")
        #expect(resting("https://пример.рф/", full: true) == .address("пример.рф", scheme: "https://", rest: "/"))
    }

    @Test func invisibleAndReorderingCharactersInThePathStayEncoded() {
        let url = "https://example.com/%E2%80%AEtxt.exe"
        #expect(resting(url, full: true) == .address("example.com", scheme: "https://", rest: "/%E2%80%AEtxt.exe"))
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
        let address = try #require(AddressText("https://accounts.example.com/" + String(repeating: "very-long-path/", count: 20) + "?q=1"))
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
