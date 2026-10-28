// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import CefKit
import Foundation
import GRDB
import Observation
import os
import SwiftUI
import WebKit
import WSurfVault

@MainActor
@Observable
final class BrowserModel {
    let windowID: UUID
    var context: BrowserProfileContext {
        didSet {
            oldValue.unregister(self)
            context.register(self)
        }
    }
    var tabs: [BrowserTab] = [] {
        didSet { refreshSidebarActive() }
    }
    var folders: [TabFolder] = []
    var storedTree = SidebarTree()
    var history: HistoryStore
    var tabArchive: TabArchive
    var sitePermissions: SitePermissions
    var downloads: DownloadManager
    let sidebarUndoManager = UndoManager()
    var folderRenameID: UUID? {
        didSet {
            guard folderRenameID != oldValue, let id = folderRenameID else { return }
            folder(id: id)?.nameRevision += 1
        }
    }
    /// The tab whose title is being edited in the sidebar, if any. A row sets it while its field is open.
    var tabRenameID: UUID?
    /// The tab the sidebar was last asked to show, and when; nil once its highlight is over. See `revealInSidebar`.
    var sidebarReveal: SidebarReveal?

    private let webViewFactory: (@MainActor () -> WKWebView)?

    init(
        context: BrowserProfileContext? = nil,
        windowID: UUID = BrowserModel.legacyWindowID,
        database: AppDatabase? = nil,
        history: HistoryStore? = nil,
        sitePermissions: SitePermissions? = nil,
        downloads: DownloadManager? = nil,
        webViewFactory: (@MainActor () -> WKWebView)? = nil
    ) {
        let selectedContext = context ?? .shared(for: .original())
        let selectedDatabase = database ?? selectedContext.database
        self.windowID = windowID
        self.context = selectedContext
        self.database = selectedDatabase
        self.webViewFactory = webViewFactory
        if let history {
            self.history = history
        } else if (selectedContext.database.writer as AnyObject) === (selectedDatabase.writer as AnyObject) {
            self.history = selectedContext.history
        } else {
            self.history = HistoryStore(database: selectedDatabase)
        }
        if (selectedContext.database.writer as AnyObject) === (selectedDatabase.writer as AnyObject) {
            tabArchive = selectedContext.tabArchive
        } else {
            tabArchive = TabArchive(database: selectedDatabase)
        }
        self.sitePermissions = sitePermissions ?? selectedContext.sitePermissions
        self.downloads = downloads ?? context?.downloads ?? DownloadManager()
        sessionRevision = Self.savedRevision(in: selectedDatabase, windowID: windowID)
        selectedContext.register(self)
        sidebarUndoManager.groupsByEvent = false
        sidebarUndoManager.levelsOfUndo = 20
    }
    let sidebarSelection = SidebarSelection()

    var hasNoActiveTab = false {
        didSet { refreshSidebarActive() }
    }
    var activeTabID: UUID? {
        didSet {
            if activeTabID != nil, hasNoActiveTab {
                hasNoActiveTab = false
            }
            guard oldValue != activeTabID else { return }
            refreshSidebarActive()
            followSpace(of: activeTab)
            sidebarSelection.dropMarks()
            noteUse(of: [oldValue, activeTabID])
            if let activeTabID {
                noteActivation(activeTabID)
            }
            let previous = oldValue.flatMap { id in tabs.first { $0.id == id } }
            let now = ContinuousClock.now
            stampPanes(of: oldValue, in: splits, at: now)
            stampForeground(at: now)
            noteFrontTabs()
            if previous.map({ !isVisibleInSplit($0) }) ?? false {
                previous?.refreshPreview()
                previous?.noteHoveredLink(nil)
            }
            activeTab?.realizeDeferredSession()
            activeTab?.probeReader()
            for id in activeSplit?.tabs ?? [] {
                tabsByID[id]?.realizeDeferredSession()
            }
            markVisibleTabsSeen()
            activeTab?.measureBandUnderBar()
            onActiveTabChanged?(activeTab, previous)
        }
    }
    var extensionPageHost: ((URL) -> ExtensionPageHost?)?
    var onTabOpened: ((BrowserTab) -> Void)?
    var onNavigationStarted: ((BrowserTab, URL) -> Void)?
    var onTabClosed: ((BrowserTab) -> Void)?
    var onTabWillTransferOut: ((BrowserTab) -> Void)?
    var onTabTransferredOut: ((BrowserTab, Int) -> Void)?
    var onTabTransferredIn: ((BrowserTab, BrowserModel, Int) -> Void)?
    var onActiveTabChanged: ((BrowserTab?, BrowserTab?) -> Void)?
    /// Asked to bring forward a row that stands for a page in a micro window, which is never in front itself.
    var onActivatingMicroPlaceholder: ((BrowserTab) -> Void)?
    var onAnchorChanged: ((UUID, UUID) -> Void)?
    var onContentProcessTerminated: ((BrowserTab) -> Void)?
    var onPageRetired: ((BrowserTab, BrowserPage) -> Void)?
    var onPictureInPictureChanged: ((BrowserTab, Bool) -> Void)?
    var onLinkHovered: ((BrowserTab, URL?, NSEvent.ModifierFlags, CGPoint) -> Void)?
    var onOpenInPeek: ((BrowserTab?, URL, CGPoint) -> Void)?
    var onOpenInNewWindow: ((BrowserTab, URL, Bool) -> Void)?
    var onSummarizeLink: ((BrowserTab?, URL, CGPoint) -> Void)?
    var onPictureReturnExpected: ((BrowserTab) -> Void)?

    var activeTab: BrowserTab? {
        guard let activeTabID else { return hasNoActiveTab ? nil : firstShownTab }
        return tabsByID[activeTabID] ?? firstShownTab
    }

    /// The space this window shows. Nil shows every tab: private windows, and models that never adopted spaces.
    /// Changed through `adoptSpaces(_:)`, `switchSpace(to:showing:)` and activation.
    var currentSpaceID: UUID? {
        didSet {
            if oldValue != currentSpaceID {
                refreshSidebarActive()
            }
        }
    }
    /// The spaces of the window's profile. A tab or folder naming any other space joins the current one.
    var knownSpaceIDs: Set<UUID> = []
    // MARK: - Tab management

    func makeTab(
        for url: URL? = nil,
        id: UUID = UUID(),
        adopting: WKWebView? = nil,
        adoptingPage: BrowserPage? = nil,
        restoring: Bool = false
    ) -> BrowserTab {
        let adopting = adopting ?? (restoring || adoptingPage != nil ? nil : webViewFactory?())
        let tab = BrowserTab(
            id: id,
            extensionHost: adopting == nil && adoptingPage == nil ? url.flatMap { extensionPageHost?($0) } : nil,
            adopting: adopting,
            adoptingPage: adoptingPage,
            restoring: restoring,
            opensBlank: url == nil,
            sitePermissions: sitePermissions,
            context: context
        )
        bindCallbacks(to: tab)
        if tab.isMaterialised {
            context.settings.apply(to: tab.page)
        }
        return tab
    }

    func bindCallbacks(to tab: BrowserTab) {
        tab.onNavigationStarted = { [weak self, weak tab] url in
            guard let tab else { return }
            self?.heldInPageMove[tab.id] = nil
            self?.onNavigationStarted?(tab, url)
        }
        bindHistoryCallbacks(to: tab)
        tab.onSameDocumentNavigation = { [weak self] in
            self?.scheduleSave()
        }
        tab.onContentProcessTerminated = { [weak self, weak tab] in
            guard let tab else { return }
            self?.onContentProcessTerminated?(tab)
        }
        tab.mayUnloadAfterTermination = { [weak self, weak tab] in
            guard let self, let tab else { return false }
            return activeTab !== tab && !tab.isFavorite && protectionReason(for: tab) == nil
        }
        tab.isFrontTab = { [weak self, weak tab] in self?.activeTab === tab }
        bindOnScreen(to: tab)
        tab.onNavigationOutsideExtension = { [weak self] url in
            self?.newTab(url: url)
        }
        tab.onNewWindow = { [weak self, weak tab] view, activate in
            guard let opened = self?.newTab(activate: activate, adopting: view, after: tab), let tab else { return }
            self?.noteOpened(opened, by: tab)
        }
        tab.onOpenInNewTab = { [weak self, weak tab] url, activate in
            guard let self else { return }
            let opened = newTab(url: url, activate: activate, after: tab, transition: .link)
            if let tab {
                noteOpened(opened, by: tab)
            }
        }
        tab.onOpenInChromium = { [weak self, weak tab] url in if let tab { self?.openInChromium(url, from: tab) } }
        tab.onOpenInNewWindow = { [weak self, weak tab] url, isPrivate in
            guard let tab, !tab.isClosed else { return }
            self?.onOpenInNewWindow?(tab, url, isPrivate)
        }
        tab.onOpenInPeek = { [weak self, weak tab] url, origin in
            self?.onOpenInPeek?(tab, url, origin)
        }
        tab.onSummarizeLink = { [weak self, weak tab] url, anchor in
            self?.onSummarizeLink?(tab, url, anchor)
        }
        tab.onCloseRequested = { [weak self, weak tab] in
            guard let tab else { return }
            self?.closeFromPage(tab)
        }
        bindOpenerCallbacks(to: tab)
        tab.onPictureInPictureChanged = { [weak self, weak tab] isOut in
            guard let tab else { return }
            self?.onPictureInPictureChanged?(tab, isOut)
        }
        tab.onLinkHovered = { [weak self, weak tab] url, modifiers, anchor in
            guard let tab else { return }
            self?.onLinkHovered?(tab, url, modifiers, anchor)
        }
        tab.onPictureReturnExpected = { [weak self, weak tab] in
            guard let tab else { return }
            self?.onPictureReturnExpected?(tab)
        }
        tab.onDownload = { [weak self, weak tab] download, source in
            self?.downloads.adopt(
                download,
                suggestedSource: source,
                sourceTabID: tab?.id,
                privately: tab?.isPrivate ?? false
            )
        }
        tab.onSaveDocument = { [weak self, weak tab] data, filename, source, opensAfterSaving in
            guard let self, let tab, !tab.isClosed else { return }
            let destination = await downloads.save(
                data, suggestedFilename: filename, source: source,
                sourceTabID: tab.id, privately: tab.isPrivate, on: tab.page.window
            )
            if opensAfterSaving, let destination {
                NSWorkspace.shared.open(destination)
            }
        }
        tab.onChromiumDownload = { [weak self, weak tab] page, download, name, completion in
            guard let self, let tab, let chromium = page.chromium, !chromium.isClosed else {
                completion(.deny)
                return
            }
            let controls = ChromiumDownloadControls(
                pageID: ObjectIdentifier(chromium),
                isLive: { [weak page, weak chromium] in
                    guard let page, let chromium else { return false }
                    return !chromium.isClosed && page.chromium === chromium
                },
                cancel: { [weak chromium] id in chromium?.cancelDownload(id: id) },
                pause: { [weak chromium] id in chromium?.pauseDownload(id: id) },
                resume: { [weak chromium] id in chromium?.resumeDownload(id: id) }
            )
            self.downloads.decideChromiumDownload(
                ChromiumDownloadRequest(
                    download: download,
                    suggestedName: name,
                    sourceTabID: tab.id,
                    isPrivate: page.isPrivate,
                    window: page.window,
                    controls: controls
                ),
                completion: completion
            )
        }
        tab.onChromiumDownloadProgress = { [weak self] page, download in
            self?.downloads.noteChromiumDownload(download, from: page)
        }
        tab.onPageRetired = { [weak self, weak tab] page in
            self?.downloads.retireChromiumPage(page)
            guard let tab else { return }
            self?.onPageRetired?(tab, page)
        }
        tab.hasActiveDownload = { [weak self, weak tab] in
            guard let self, let tab else { return false }
            return self.downloads.hasActiveDownload(for: tab.id)
        }
    }

    /// What a tab remembers of its History: the last visit it recorded and the trail that visit is on. The trail is the
    /// tab's own, so a tab a page opened takes the visit as its referrer but starts a trail of its own.
    struct VisitMemory: Equatable {
        var visit: Int64
        var trail: Int64?
    }

    var lastVisitID: [UUID: VisitMemory] = [:]
    /// In-page moves waiting for a title: the address a tab moved to while the title was still the last visit's.
    private var heldInPageMove: [UUID: String] = [:]

    /// A page opened `opened`: the tab continues that page's visit, and the page is remembered as its opener.
    /// "Continue in Chromium" on a WebKit passkey sheet: the page again, in a Chromium tab of this profile next to its tab. The
    /// engine is that tab's own override, never written to the site's setting.
    private func openInChromium(_ url: URL, from tab: BrowserTab) {
        guard !tab.isClosed else { return }
        noteOpened(newTab(url: url, after: tab, transition: .link, engine: .chromium), by: tab)
    }

    private func noteOpened(_ opened: BrowserTab, by tab: BrowserTab) {
        openerByTab[opened.id] = tab.id
        if let origin = lastVisitID[tab.id] {
            lastVisitID[opened.id] = VisitMemory(visit: origin.visit, trail: nil)
        }
    }

    /// For a tab a page opened (a popup, or a link opened in a new tab), the tab of that page, where Back from the tab's first
    /// page returns. A tab a person, an extension or an agent opened is absent, so an agent is told only about tabs its own
    /// page opened.
    var openerByTab: [UUID: UUID] = [:]

    /// A peek is not one of the window's tabs: it is on screen while its panel is.
    private func bindOnScreen(to tab: BrowserTab) {
        tab.isOnScreen = { [weak self, weak tab] in
            guard let self, let tab else { return false }
            return tabsByID[tab.id] !== tab || activeTab === tab || isVisibleInSplit(tab)
        }
    }

    /// Back from the first page of a tab a page opened shows that page's tab again and closes this one, as in Safari.
    private func bindOpenerCallbacks(to tab: BrowserTab) {
        tab.hasOpener = { [weak self, weak tab] in
            guard let self, let tab else { return false }
            return openerByTab[tab.id].flatMap { tabsByID[$0] } != nil
        }
        tab.onBackToOpener = { [weak self, weak tab] in
            guard let self, let tab, let opener = openerByTab[tab.id].flatMap({ tabsByID[$0] }) else { return }
            activate(opener)
            close(tab)
        }
        tab.onNewChromiumPopup = { [weak self, weak tab] page, activate in
            guard let opened = self?.newTab(activate: activate, adoptingPage: page, after: tab), let tab else { return }
            self?.noteOpened(opened, by: tab)
        }
    }

    /// The events that write History: a finished load, a move the page made itself, and a title that arrived later.
    private func bindHistoryCallbacks(to tab: BrowserTab) {
        tab.onNavigationFinished = { [weak self, weak tab] wasRestore in
            self?.scheduleSave()
            guard let tab else { return }
            self?.noteNavigationFinished(of: tab, wasRestore: wasRestore)
        }
        tab.onInPageMove = { [weak self, weak tab] in
            guard let tab else { return }
            self?.noteInPageMove(of: tab)
        }
        tab.onTitleChanged = { [weak self, weak tab] in
            guard let tab else { return }
            self?.noteTitleChange(of: tab)
        }
    }

    private func lastVisit(of tab: BrowserTab) -> HistoryStore.VisitedPage? {
        guard let last = lastVisitID[tab.id]?.visit else { return nil }
        return history.visits.first { $0.id == last }
    }

    /// A finished load is a visit, unless it only ends the wait of an address change that was recorded already.
    private func noteNavigationFinished(of tab: BrowserTab, wasRestore: Bool) {
        defer { tab.noteNavigationEnded() }
        guard !wasRestore, !tab.isPrivate else { return }
        heldInPageMove[tab.id] = nil
        if tab.awaitsVisit || lastVisit(of: tab)?.url != tab.urlString {
            recordVisit(for: tab)
        }
    }

    /// A move the page made itself is a visit once its title shows which page it is. While the old title still stands,
    /// the move is held for the title; while a load is under way it belongs to the load.
    private func noteInPageMove(of tab: BrowserTab) {
        guard !tab.isPrivate else { return }
        if tab.awaitsVisit || lastVisit(of: tab)?.title == tab.pageTitle {
            heldInPageMove[tab.id] = tab.urlString
        } else {
            heldInPageMove[tab.id] = nil
            recordVisit(for: tab, transition: .inPage)
        }
    }

    /// A title that arrives after the load names the page that was recorded. For a held move it is the title that makes
    /// the move a visit.
    private func noteTitleChange(of tab: BrowserTab) {
        guard !tab.isPrivate else { return }
        if let held = heldInPageMove[tab.id], held == tab.urlString {
            guard tab.awaitsVisit || lastVisit(of: tab)?.title != tab.pageTitle else { return }
            heldInPageMove[tab.id] = nil
            recordVisit(for: tab, transition: .inPage)
            return
        }
        guard let visit = lastVisitID[tab.id]?.visit else { return }
        history.retitle(visit: visit, url: tab.urlString, title: tab.pageTitle)
    }

    private func recordVisit(for tab: BrowserTab, transition: HistoryStore.Transition? = nil) {
        guard !tab.isPrivate, !tab.isClosed, tabsByID[tab.id] === tab else { return }
        let transition = tab.awaitsVisit ? tab.pendingTransition : transition ?? tab.pendingTransition
        tab.noteNavigationEnded()
        let previous = lastVisitID[tab.id]
        let trail = continuesTrail(from: previous?.visit, to: tab.urlString) ? previous?.trail : nil
        let visitID = history.record(
            url: tab.urlString,
            title: tab.pageTitle,
            transition: transition,
            fromVisit: previous?.visit,
            trail: trail
        )
        guard let visitID else { return }
        lastVisitID[tab.id] = VisitMemory(visit: visitID, trail: history.visits.first { $0.id == visitID }?.trail)
    }

    /// A trail stays inside one website, so it goes on only while the new page is of the site of the last one.
    private func continuesTrail(from visit: Int64?, to url: String) -> Bool {
        guard let visit, let previous = history.visits.first(where: { $0.id == visit }) else { return false }
        return Self.site(of: previous.url) == Self.site(of: url)
    }

    private static func site(of url: String) -> String? {
        guard let host = URL(string: url)?.host()?.lowercased() else { return nil }
        return RelyingPartyPolicy.registrableDomain(of: host) ?? host
    }

    var recentlyActive: [UUID] = []

    var switcherRecency: [UUID]?

    private func noteActivation(_ id: UUID) {
        recentlyActive.removeAll { $0 == id }
        recentlyActive.insert(id, at: 0)
        if recentlyActive.count > 32 {
            recentlyActive.removeLast(recentlyActive.count - 32)
        }
    }

    @discardableResult
    func newTab(
        url: URL? = nil,
        activate: Bool = true,
        adopting: WKWebView? = nil,
        adoptingPage: BrowserPage? = nil,
        after opener: BrowserTab? = nil,
        transition: HistoryStore.Transition = .typed,
        engine: BrowserEngine? = nil
    ) -> BrowserTab {
        let tab = makeTab(for: url, adopting: adopting, adoptingPage: adoptingPage)
        tab.engineOverride = engine
        insert(tab, after: opener)
        // With no active tab the first tab is the one on screen, so a tab inserted there is seen at once.
        tab.isUnseen = !activate && activeTab !== tab
        onTabOpened?(tab)
        if activate {
            activeTabID = tab.id
        }
        if let url {
            tab.load(url, transition: transition)
        }
        if transition != .agent {
            revealWhenAddressed(tab, hasAddress: url != nil || adopting != nil || adoptingPage != nil)
        }
        scheduleSave()
        return tab
    }

    /// A tab on screen is no longer new, whether it is the active tab or a pane beside it.
    func markVisibleTabsSeen() {
        activeTab?.isUnseen = false
        for id in activeSplit?.tabs ?? [] {
            tabsByID[id]?.isUnseen = false
        }
    }

    /// Tells each tab whether it is on screen, the active tab and the other panes of its split, so one that leaves starts the
    /// wait before its page is hidden and one that comes back stops it (`BrowserTab.isInFront`).
    func noteFrontTabs() {
        var shown = Set(activeSplit?.tabs ?? [])
        if let activeTabID {
            shown.insert(activeTabID)
        }
        for tab in tabs {
            tab.isInFront = shown.contains(tab.id)
        }
    }

    func insert(_ tab: BrowserTab, after opener: BrowserTab?) {
        // A page opened from another page stays in that page's space, even when it is not the space on screen.
        if tab.spaceID == nil, let space = opener?.spaceID {
            tab.spaceID = space
        }
        let keptRun = keptRunAtTop()
        // A page opened from above the pin line, a pinned folder's page included, lands just under the line.
        if let anchor = opener.flatMap(insertionAnchor(after:)),
           !isPinned(.tab(anchor.id)),
           let index = tabs.firstIndex(where: { $0 === anchor }) {
            tabs.insert(tab, at: tabs.index(after: index))
            storedTree = reconciledTree().inserting(.tab(tab.id), after: .tab(anchor.id))
        } else if let kept = keptRun.last {
            tabs.insert(tab, at: 0)
            storedTree = reconciledTree().inserting(.tab(tab.id), after: kept)
            syncTabOrder()
        } else {
            tabs.insert(tab, at: 0)
            place([.tab(tab.id)], in: nil, before: reconciledTree().root.first)
        }
        sidebarDidChange()
    }

    // MARK: - Peek

    /// Exclude peeked pages from the sidebar, saved session, and extensions until kept.
    func makePeekTab(_ url: URL) -> BrowserTab {
        let tab = makeTab(for: url)
        tab.onOpenInPeek = nil
        tab.onSummarizeLink = nil
        tab.load(url, transition: .link)
        return tab
    }

    func keepPeekTab(_ tab: BrowserTab, after opener: BrowserTab?) {
        insert(tab, after: opener)
        onTabOpened?(tab)
        activeTabID = tab.id
        revealInSidebar(tab)
        scheduleSave()
    }

    func keepPeekTab(_ tab: BrowserTab, besidePage anchor: BrowserTab) {
        keepPeekTab(tab, after: anchor)
        guard splits.split(containing: anchor.id)?.isFull != true else { return }
        if splits.contains(anchor.id) {
            insertIntoSplit(tab, beside: anchor, edge: .right)
        } else {
            split(anchor, with: tab, axis: .sideBySide)
        }
        activate(tab)
    }

    func dismissPeekTab(_ tab: BrowserTab) {
        tab.detach()
    }

    private func insertionAnchor(after opener: BrowserTab) -> BrowserTab? {
        let anchor = Set(anchorTabs(anchorID(of: opener.id)).map(\.id))
        guard !anchor.isEmpty else { return tabs.contains { $0 === opener } ? opener : nil }
        return tabs.last { anchor.contains($0.id) }
    }

    @discardableResult
    func importBookmarksFolder(named name: String, entries: [HistoryStore.Entry]) -> TabFolder? {
        let imported = entries.compactMap { mark -> BrowserTab? in
            guard let url = URL(string: mark.url), url.scheme?.hasPrefix("http") == true else {
                return nil
            }
            let tab = makeTab(for: url, restoring: true)
            tab.title = mark.title
            tab.urlString = mark.url
            tab.deferRestore(state: nil, url: url)
            if let host = url.host() {
                dressRow(tab, fromHost: host)
            }
            tabs.append(tab)
            onTabOpened?(tab)
            return tab
        }
        sidebarDidChange()
        guard !imported.isEmpty else { return nil }
        let folder = createFolder(named: name, containing: imported)
        folder.isExpanded = false
        scheduleSave()
        return folder
    }

    @discardableResult
    func duplicate(_ tab: BrowserTab) -> BrowserTab {
        let copy = makeTab(for: URL(string: tab.urlString))
        copy.pageTitle = tab.pageTitle
        copy.customTitle = tab.customTitle
        copy.urlString = tab.urlString
        copy.deferRestore(state: tab.sessionState, url: URL(string: tab.urlString))
        copy.realizeDeferredSession()
        copy.pinnedURL = tab.pinnedURL
        copy.pinnedTitle = tab.pinnedTitle
        copy.spaceID = tab.spaceID

        let at = (tabs.firstIndex { $0 === tab }).map { $0 + 1 } ?? tabs.endIndex
        tabs.insert(copy, at: at)
        storedTree = reconciledTree().inserting(.tab(copy.id), after: .tab(tab.id))
        sidebarDidChange()
        onTabOpened?(copy)
        activeTabID = copy.id
        revealInSidebar(copy)
        scheduleSave()
        return copy
    }

    /// A pane that a change removes from the visible split leaves the foreground now.
    var splits = TabSplits() {
        didSet {
            stampPanes(of: activeTabID, in: oldValue, at: .now)
            markVisibleTabsSeen()
            noteFrontTabs()
        }
    }

    var tabAnchors: [UUID: UUID] = [:]

    var paneInAir: UUID?

    var closedTabs: [ClosedTab] = []

    var sidebarTree = SidebarTree()

    var tabsByID: [UUID: BrowserTab] = [:] {
        didSet { refreshSidebarActive() }
    }
    var foldersByID: [UUID: TabFolder] = [:]

    @ObservationIgnored private weak var sidebarActiveTab: BrowserTab?

    /// Marks the active tab for the sidebar and clears the mark of the one it replaces. Everything `activeTab` is made
    /// of calls this: the tabs, their index, the space on screen and which tab is chosen.
    private func refreshSidebarActive() {
        let active = activeTab
        guard active !== sidebarActiveTab else { return }
        sidebarActiveTab?.isSidebarActive = false
        active?.isSidebarActive = true
        sidebarActiveTab = active
    }

    @ObservationIgnored var saveTask: Task<Void, Never>?

    @ObservationIgnored var saveChain: Task<Void, Never>?
    @ObservationIgnored var sessionRevision: Int64 = 0
    @ObservationIgnored var sessionClosedAt: Date?
    @ObservationIgnored let archiveSweeper = TabArchiveSweeper()

    @ObservationIgnored var saveWaitingSince: ContinuousClock.Instant?

    /// Set while this window shows and publishes the profile's pins, from restore until it closes or leaves the profile.
    @ObservationIgnored var attachedPinStore: ProfilePinStore?
    /// Folders of this window that are profile pins. They are saved with the profile, not with the window.
    @ObservationIgnored var profileFolderIDs: Set<UUID> = []
    @ObservationIgnored var isApplyingProfilePins = false

    @ObservationIgnored var saveDebounce: Duration = .seconds(2)

    @ObservationIgnored var saveDeadline: Duration = .seconds(8)

    var database: AppDatabase

    var writtenStateGeneration: [UUID: Int] = [:]

    var opensPrivately: Bool {
        context.profile.isPrivate
    }

    /// Set once by `BrowserApplication.newWindow` before the window's coordinator exists, and never changed afterwards.
    @ObservationIgnored var windowKind: WindowKind = .standard
}
