// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import CCef
import Foundation
import Testing
import WebKit

@testable import WSurf

/// The items WSurf adds to a Chromium tab's context menu that a WebKit tab's has, which of them a right-click gets, what they do,
/// and how a Chromium tab answers a click on a link with Command, the middle button or Shift, or a pop-up the blocker refused.
/// `OpenInNewTabMenuTests` covers the Open Link commands and `NavigationPolicyTests` the same clicks in WebKit.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct ChromiumContextMenuTests {
    private static let link = URL(string: "https://link.example/target")!
    private static let image = URL(string: "https://image.example/cat.png")!
    private static let frame = URL(string: "https://frame.example/")!

    private func titles(_ entries: [ChromiumClient.ContextEntry]) -> [String] {
        entries.map { String(localized: $0.title) }
    }

    // MARK: - Which items

    @Test func aLinkGetsTheWebKitLinkItemsInTheirOrderAndDownloadLinkedFileLast() {
        let items = ChromiumClient.contextItems(for: .init(link: Self.link), isPrivate: false)

        #expect(items.leading.count == 1)
        #expect(titles(items.leading[0]) == [
            String(localized: "Open Link in New Tab"), String(localized: "Open Link in New Window"),
            String(localized: "Open Link in New Private Window"), String(localized: "Open Link in Peek"),
            String(localized: "Summarize Link"),
        ])
        #expect(titles(items.trailing) == [String(localized: "Download Linked File")])
    }

    @Test func aPrivateTabOffersNoPlainWindowButStillPeeksAndSummarizes() {
        let items = ChromiumClient.contextItems(for: .init(link: Self.link), isPrivate: true)

        #expect(items.leading[0].map(\.id) == [
            ChromiumClient.linkCommands(isPrivate: true)[0].id, ChromiumClient.linkCommands(isPrivate: true)[1].id,
            ChromiumClient.peekCommand, ChromiumClient.summarizeCommand,
        ])
        #expect(!titles(items.leading[0]).contains(String(localized: "Open Link in New Window")))
    }

    @Test func anImageGetsOpenImageAndDownloadImageAndNoLinkItems() {
        let items = ChromiumClient.contextItems(for: .init(image: Self.image), isPrivate: false)

        #expect(items.leading.count == 1)
        #expect(titles(items.leading[0]) == [String(localized: "Open Image in New Tab"), String(localized: "Download Image")])
        #expect(items.trailing.isEmpty)
    }

    @Test func anImageInALinkGetsTheLinkGroupThenTheImageGroup() {
        let items = ChromiumClient.contextItems(for: .init(link: Self.link, image: Self.image), isPrivate: false)

        #expect(items.leading.count == 2)
        #expect(items.leading[0].map(\.id).contains(ChromiumClient.peekCommand))
        #expect(items.leading[1].map(\.id) == [ChromiumClient.openImageCommand, ChromiumClient.downloadImageCommand])
        #expect(items.trailing.map(\.id) == [ChromiumClient.downloadLinkCommand])
    }

    @Test func aRightClickOnNothingOfTheseGetsNoLinkOrImageItems() {
        let items = ChromiumClient.contextItems(for: .init(isPage: true), isPrivate: false)

        #expect(items.leading.isEmpty && items.trailing.isEmpty)
    }

    @Test func thePageItemsAreSaveThenPrint() {
        #expect(titles(ChromiumClient.pageCommands) == [String(localized: "Save Page As…"), String(localized: "Print Page…")])
    }

    @Test func everyCommandHasAnIdOfItsOwnThatTheEngineLeavesToTheApplication() {
        let ids = ChromiumClient.linkCommands(isPrivate: false).map(\.id) + [
            ChromiumClient.pickCredentialCommand, ChromiumClient.downloadPDFCommand, ChromiumClient.openPDFCommand,
            ChromiumClient.peekCommand, ChromiumClient.summarizeCommand, ChromiumClient.savePageCommand,
            ChromiumClient.printPageCommand, ChromiumClient.openImageCommand, ChromiumClient.downloadImageCommand,
            ChromiumClient.downloadLinkCommand,
        ]

        #expect(Set(ids).count == ids.count)
        #expect(ids.allSatisfy { (Int32(MENU_ID_USER_FIRST.rawValue)...Int32(MENU_ID_USER_LAST.rawValue)).contains($0) })
    }

    @Test func theTypeFlagsOfThePageBackgroundAreTheOnlyOnesThatGetThePageItems() {
        func flags(_ values: cef_context_menu_type_flags_t...) -> UInt32 {
            values.reduce(0) { $0 | UInt32($1.rawValue) }
        }
        #expect(ChromiumClient.isPageBackground(typeFlags: flags(CM_TYPEFLAG_PAGE)))
        #expect(ChromiumClient.isPageBackground(typeFlags: flags(CM_TYPEFLAG_PAGE, CM_TYPEFLAG_FRAME)))
        #expect(!ChromiumClient.isPageBackground(typeFlags: flags(CM_TYPEFLAG_PAGE, CM_TYPEFLAG_LINK)))
        #expect(!ChromiumClient.isPageBackground(typeFlags: flags(CM_TYPEFLAG_PAGE, CM_TYPEFLAG_MEDIA)))
        #expect(!ChromiumClient.isPageBackground(typeFlags: flags(CM_TYPEFLAG_PAGE, CM_TYPEFLAG_SELECTION)))
        #expect(!ChromiumClient.isPageBackground(typeFlags: flags(CM_TYPEFLAG_FRAME, CM_TYPEFLAG_EDITABLE)))
        #expect(!ChromiumClient.isPageBackground(typeFlags: 0))
    }

    // MARK: - What choosing one does

    private struct Chosen {
        var actions: [ChromiumClient.ContextAction] = []
        var opened: [(URL, URL?, ChromiumPage.LinkOpening)] = []
    }

    /// Chooses `command` in a menu that was opened on `target`, and says what the page was asked to do.
    private func choose(_ command: Int32, on target: ChromiumClient.ContextTarget) async -> (Bool, Chosen) {
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let page = ChromiumPage(context: context)
        let client = ChromiumClient(page: page)
        var chosen = Chosen()
        page.onContextAction = { chosen.actions.append($0) }
        page.openLinkFromMenu = { chosen.opened.append(($0, $1, $2)) }
        page.contextTarget = target
        let handled = client.runContextItem(command)
        withExtendedLifetime(page) {}
        client.close()
        await context.endPrivateSession()
        return (handled, chosen)
    }

    @Test func peekAndSummarizeActOnTheLink() async {
        let target = ChromiumClient.ContextTarget(link: Self.link, frameURL: Self.frame)

        let (peeked, peek) = await choose(ChromiumClient.peekCommand, on: target)
        let (summarized, summary) = await choose(ChromiumClient.summarizeCommand, on: target)

        #expect(peeked && peek.actions == [.peek(Self.link)])
        #expect(summarized && summary.actions == [.summarize(Self.link)])
    }

    @Test func downloadLinkedFileAndDownloadImageDownloadTheirOwnAddress() async {
        let target = ChromiumClient.ContextTarget(link: Self.link, image: Self.image)

        let (_, file) = await choose(ChromiumClient.downloadLinkCommand, on: target)
        let (_, picture) = await choose(ChromiumClient.downloadImageCommand, on: target)

        #expect(file.actions == [.download(Self.link)])
        #expect(picture.actions == [.download(Self.image)])
    }

    @Test func openImageOpensTheImageInATabFromItsFrame() async {
        let target = ChromiumClient.ContextTarget(link: Self.link, image: Self.image, frameURL: Self.frame)

        let (handled, chosen) = await choose(ChromiumClient.openImageCommand, on: target)

        #expect(handled && chosen.actions.isEmpty)
        #expect(chosen.opened.count == 1)
        #expect(chosen.opened.first?.0 == Self.image && chosen.opened.first?.1 == Self.frame && chosen.opened.first?.2 == .tab)
    }

    @Test func openLinkStillOpensTheLinkAsBefore() async {
        let command = ChromiumClient.linkCommands(isPrivate: false)[2]

        let (handled, chosen) = await choose(command.id, on: .init(link: Self.link, frameURL: Self.frame))

        #expect(handled && chosen.opened.count == 1)
        #expect(chosen.opened.first?.0 == Self.link && chosen.opened.first?.2 == command.opening)
    }

    @Test func savePageAndPrintPageActOnlyForThePageBackground() async {
        let (saved, save) = await choose(ChromiumClient.savePageCommand, on: .init(isPage: true))
        let (printed, printing) = await choose(ChromiumClient.printPageCommand, on: .init(isPage: true))
        let (notOffered, none) = await choose(ChromiumClient.printPageCommand, on: .init(link: Self.link))

        #expect(saved && save.actions == [.savePage])
        #expect(printed && printing.actions == [.printPage])
        #expect(!notOffered && none.actions.isEmpty)
    }

    @Test func anItemThatWasNotOfferedForThisMenuDoesNothing() async {
        let (peeked, peek) = await choose(ChromiumClient.peekCommand, on: .init(image: Self.image))
        let (openedImage, image) = await choose(ChromiumClient.openImageCommand, on: .init(link: Self.link))

        #expect(!peeked && peek.actions.isEmpty)
        #expect(!openedImage && image.opened.isEmpty)
    }

    @Test func aMenuNobodyOpenedHasNothingToRun() async {
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let page = ChromiumPage(context: context)
        let client = ChromiumClient(page: page)
        var asked = 0
        page.onContextAction = { _ in asked += 1 }

        #expect(!client.runContextItem(ChromiumClient.peekCommand))
        #expect(asked == 0)
        withExtendedLifetime(page) {}
        client.close()
        await context.endPrivateSession()
    }

    @Test func aChoiceIsUsedUpAfterItRuns() async {
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let page = ChromiumPage(context: context)
        let client = ChromiumClient(page: page)
        var actions: [ChromiumClient.ContextAction] = []
        page.onContextAction = { actions.append($0) }
        page.contextTarget = .init(link: Self.link)

        #expect(client.runContextItem(ChromiumClient.peekCommand))
        #expect(!client.runContextItem(ChromiumClient.peekCommand))
        #expect(actions == [.peek(Self.link)])
        withExtendedLifetime(page) {}
        client.close()
        await context.endPrivateSession()
    }

    // MARK: - Clicks

    @Test func theEnginesWindowKindsAreTheClicksWebKitTellsApart() {
        #expect(ChromiumPage.ClickDisposition(CEF_WOD_NEW_BACKGROUND_TAB) == .backgroundTab)
        #expect(ChromiumPage.ClickDisposition(CEF_WOD_NEW_FOREGROUND_TAB) == .foregroundTab)
        #expect(ChromiumPage.ClickDisposition(CEF_WOD_NEW_WINDOW) == .window)
        #expect(ChromiumPage.ClickDisposition(CEF_WOD_NEW_POPUP) == .other)
        #expect(ChromiumPage.ClickDisposition(CEF_WOD_CURRENT_TAB) == .other)
    }

    private final class Opened {
        var tabs: [(URL, Bool)] = []
        var peeks: [URL] = []
    }

    private func tab(blocking: PopupPolicy = .blockAndNotify) -> (BrowserTab, Opened) {
        let page = URL(string: "https://page.example/")!
        let permissions = SitePermissions(
            storageURL: AppDatabase.supportDirectory.appendingPathComponent("ChromiumContextMenu-\(UUID().uuidString).json"))
        permissions.setPopups(blocking, for: SitePermissions.origin(for: page))
        let tab = BrowserTab(sitePermissions: permissions)
        tab.popups.pageChanged(url: page)
        let opened = Opened()
        tab.onOpenInNewTab = { opened.tabs.append(($0, $1)) }
        tab.onOpenInPeek = { url, _ in opened.peeks.append(url) }
        return (tab, opened)
    }

    @Test func commandOrMiddleClickOpensATabInTheBackground() {
        let (tab, opened) = tab()

        tab.openChromiumWindow(Self.link, userGesture: true, sourceURL: nil, sourceFrame: nil, click: .backgroundTab)

        #expect(opened.tabs.map(\.0) == [Self.link] && opened.tabs.map(\.1) == [false])
        #expect(opened.peeks.isEmpty)
    }

    @Test func commandShiftClickOpensATabInFront() {
        let (tab, opened) = tab()

        tab.openChromiumWindow(Self.link, userGesture: true, sourceURL: nil, sourceFrame: nil, click: .foregroundTab)

        #expect(opened.tabs.map(\.1) == [true])
    }

    @Test func shiftClickPeeksAtTheLinkAndOpensNoTab() {
        let (tab, opened) = tab()

        tab.openChromiumWindow(Self.link, userGesture: true, sourceURL: nil, sourceFrame: nil, click: .window)

        #expect(opened.peeks == [Self.link])
        #expect(opened.tabs.isEmpty)
    }

    @Test func aWindowNoClickStartedIsNeitherAPeekNorAnOpenedTabWhereTheSiteBlocksPopups() {
        let (tab, opened) = tab()

        tab.openChromiumWindow(Self.link, userGesture: false, sourceURL: nil, sourceFrame: nil, click: .window)

        #expect(opened.peeks.isEmpty && opened.tabs.isEmpty)
        #expect(tab.popups.blocked == Self.link, "the notice WebKit tabs show")
    }

    @Test func aTabThatCannotPeekOpensTheShiftClickedLinkAsATab() {
        let (tab, opened) = tab()
        tab.onOpenInPeek = nil

        tab.openChromiumWindow(Self.link, userGesture: true, sourceURL: nil, sourceFrame: nil, click: .window)

        #expect(opened.tabs.map(\.0) == [Self.link])
    }

    @Test func aPlainWindowTheSiteMayOpenIsAForegroundTabOnlyWithAClick() {
        let (tab, opened) = tab(blocking: .allow)

        tab.openChromiumWindow(Self.link, userGesture: true, sourceURL: nil, sourceFrame: nil)
        tab.openChromiumWindow(Self.link, userGesture: false, sourceURL: nil, sourceFrame: nil)

        #expect(opened.tabs.map(\.1) == [true, false])
    }

    // MARK: - Blocked pop-ups

    @Test func aWindowOpenCallWithoutAClickRaisesTheNoticeWhereTheSiteBlocksPopups() {
        let (tab, _) = tab()

        tab.noteChromiumWindowOpen(Self.link, userGesture: true)
        #expect(tab.popups.blocked == nil, "a click was behind it")
        tab.noteChromiumWindowOpen(URL(string: "about:blank")!, userGesture: false)
        #expect(tab.popups.blocked == nil, "no address, no notice, as in WebKit tabs")
        tab.noteChromiumWindowOpen(Self.link, userGesture: false)

        #expect(tab.popups.blocked == Self.link)
    }

    @Test func aSiteThatMayOpenPopupsGetsNoNoticeAndOneThatOnlyBlocksGetsNone() {
        let (allowing, _) = tab(blocking: .allow)
        let (silent, _) = tab(blocking: .block)

        allowing.noteChromiumWindowOpen(Self.link, userGesture: false)
        silent.noteChromiumWindowOpen(Self.link, userGesture: false)

        #expect(allowing.popups.blocked == nil && silent.popups.blocked == nil)
    }

    @Test func theEnginesWindowOpenEventReachesThePage() async {
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let page = ChromiumPage(context: context)
        let devTools = ChromiumDevTools(page: page)
        var attempts: [(URL, Bool)] = []
        page.windowOpenAttempt = { attempts.append(($0, $1)) }
        func deliver(_ json: String) {
            let data = Data(json.utf8)
            data.withUnsafeBytes { devTools.receiveEvent(name: "Page.windowOpen", pointer: $0.baseAddress, size: data.count) }
        }

        deliver(#"{"url":"https://ad.example/x","windowName":"","windowFeatures":[],"userGesture":false}"#)
        deliver(#"{"url":"https://ok.example/y","windowName":"","windowFeatures":[],"userGesture":true}"#)
        deliver(#"{"url":"","windowName":"","windowFeatures":[],"userGesture":false}"#)
        deliver(#"{"url":"https://nogesture.example/z"}"#)

        #expect(attempts.map(\.0.absoluteString) == ["https://ad.example/x", "https://ok.example/y", "https://nogesture.example/z"])
        #expect(attempts.map(\.1) == [false, true, true])
        withExtendedLifetime(page) {}
        await context.endPrivateSession()
    }
}
