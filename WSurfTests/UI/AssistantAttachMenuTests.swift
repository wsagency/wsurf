// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import SwiftUI
import Testing

@testable import WSurf

/// The add menu lists tabs for the assistant to read. It must keep to the window it is open in.
@MainActor
struct AssistantAttachMenuTests {
    @Test func theSearchFieldClearsTheRoundedEdgesOfTheAttachMenu() throws {
        let browser = model()
        defer { browser.closeAllTabs(saving: false) }
        let menu = AssistantAttachMenu(browser: browser, attachedTabIDs: [], onAttachTab: { _ in }, onChooseFiles: {}, onCancel: {})
        let host = NSHostingView(rootView: menu)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: host.fittingSize), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        host.layoutSubtreeIfNeeded()

        func editor(in view: NSView) -> NSTextField? {
            if let field = view as? MentionTextField {
                return field
            }
            return view.subviews.lazy.compactMap { editor(in: $0) }.first
        }
        window.orderBack(nil)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        host.layoutSubtreeIfNeeded()
        let field = try #require(editor(in: host))
        let frame = host.convert(field.bounds, from: field)
        #expect(frame.minX >= 17 && host.bounds.maxX - frame.maxX >= 17, "search field \(frame) in \(host.bounds)")
    }

    private func model(privately: Bool = false, profile: Profile? = nil) -> BrowserModel {
        let context = profile.map { BrowserProfileContext(profile: $0) }
            ?? (privately ? BrowserProfileContext(profile: .privateBrowsing()) : nil)
        return BrowserModel(context: context, database: .temporary())
    }

    private func page(
        _ title: String,
        context: BrowserProfileContext? = nil,
        privately: Bool = false
    ) -> BrowserTab {
        let tab = BrowserTab(opensBlank: false, privately: privately, context: context)
        tab.title = title
        tab.urlString = "https://example.com/\(title.lowercased())"
        return tab
    }

    @Test func aNormalWindowNeverListsAPrivateWindowsTab() {
        let browser = model()
        let own = page("Own")
        let leaked = page("Leaked", context: BrowserProfileContext(profile: .privateBrowsing()), privately: true)
        browser.tabs = [own, leaked]

        let listed = AskSurfaceInteraction.attachCandidates(fragment: "", in: browser, mentionedTabIDs: [])
        #expect(listed.map(\.title) == ["Own"])
        #expect(!AskSurfaceInteraction.isAttachable(leaked, in: browser))
    }

    @Test func aPrivateWindowNeverListsANormalWindowsTab() {
        let browser = model(privately: true)
        let privateContext = browser.context
        let own = page("Own", context: privateContext, privately: true)
        let leaked = page("Leaked")
        browser.tabs = [own, leaked]

        let listed = AskSurfaceInteraction.attachCandidates(fragment: "", in: browser, mentionedTabIDs: [])
        #expect(listed.map(\.title) == ["Own"])
        #expect(!AskSurfaceInteraction.isAttachable(leaked, in: browser))
    }

    @Test func aWindowNeverListsAnotherProfilesTab() {
        let work = Profile(id: UUID(), name: "Work", symbol: "briefcase", color: .blue)
        let browser = model(profile: work)
        let own = page("Own", context: browser.context)
        let other = page("Other")  // the original profile's
        browser.tabs = [own, other]

        let listed = AskSurfaceInteraction.attachCandidates(fragment: "", in: browser, mentionedTabIDs: [])
        #expect(listed.map(\.title) == ["Own"])
    }

    @Test func theMenuRefusesWhatTheMentionListRefuses() {
        let browser = model()
        let real = page("Real")
        let blank = BrowserTab(opensBlank: false)
        let settings = BrowserTab(opensBlank: false)
        settings.urlString = "wsurf://settings"
        let attached = page("Attached")
        browser.tabs = [real, blank, settings, attached]

        let listed = AskSurfaceInteraction.attachCandidates(
            fragment: "", in: browser, mentionedTabIDs: [attached.id]
        )
        #expect(listed.map(\.title) == ["Real"])
    }

    @Test func anExtensionPageIsNotOffered() {
        let browser = model()
        let own = page("Own")
        let extensionPage = BrowserTab(extensionHost: ExtensionPageHost(
            configuration: WebViewPool.makeConfiguration(),
            baseURL: URL(string: "webkit-extension://stub/")!,
            name: "Stub Extension",
            icon: nil
        ))
        extensionPage.urlString = "webkit-extension://stub/popup.html"
        browser.tabs = [own, extensionPage]

        // The page rules of the `@` list alone let it through, so the extension rule is what keeps it out.
        #expect(
            AskSurfaceInteraction.mentionCandidates(
                fragment: "", tabs: [extensionPage], mentionedTabIDs: [], activeTabID: nil
            ).map(\.id) == [extensionPage.id]
        )
        #expect(!AskSurfaceInteraction.isAttachable(extensionPage, in: browser))
        #expect(
            AskSurfaceInteraction.attachCandidates(fragment: "", in: browser, mentionedTabIDs: []).map(\.id)
                == [own.id]
        )
    }

    @Test func searchAndTheLimitStillApplyInsideTheWindow() {
        let browser = model()
        browser.tabs = (0..<8).map { page("Item\($0)") }

        #expect(AskSurfaceInteraction.attachCandidates(fragment: "", in: browser, mentionedTabIDs: []).count == 5)
        #expect(
            AskSurfaceInteraction.attachCandidates(fragment: "", in: browser, mentionedTabIDs: [], limit: .max).count == 8
        )
        #expect(
            AskSurfaceInteraction.attachCandidates(fragment: "item3", in: browser, mentionedTabIDs: []).map(\.title)
                == ["Item3"]
        )
    }
}
