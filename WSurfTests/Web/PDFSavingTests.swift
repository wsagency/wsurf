// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import CefKit
import Foundation
import PDFKit
import Testing
import WebKit

@testable import WSurf

/// Saving a PDF a tab shows, driven the way a person does it on a real page in both engines: the right-click menu of the PDF, and
/// ⌘S through the File menu. The fixture is one loopback server with a PDF, a PDF behind a sign-in cookie and a plain page. What
/// is read is what reached the download folder and the Downloads list.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct PDFSavingTests {
    // MARK: - Fixture

    /// A valid one-page PDF, so both engines draw it in their viewers.
    private static let pdf: Data = {
        let image = NSImage(size: NSSize(width: 612, height: 792), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            NSAttributedString(string: "WSurf PDF fixture", attributes: [.font: NSFont.systemFont(ofSize: 48)])
                .draw(at: NSPoint(x: 60, y: 600))
            return true
        }
        let document = PDFDocument()
        document.insert(PDFPage(image: image) ?? PDFPage(), at: 0)
        return document.dataRepresentation() ?? Data()
    }()

    /// What the server was asked, by path.
    nonisolated final class RequestLog: @unchecked Sendable {
        private let lock = NSLock()
        private var all: [HTTPFixtureServer.Request] = []
        private var refused: Set<String> = []
        private var disguised: [String: HTTPFixtureServer.Response] = [:]

        /// From now on the server refuses `path`, which it served before.
        func refuse(_ path: String) {
            lock.withLock { _ = refused.insert(path) }
        }

        /// From now on the server answers `path` with `response`.
        func disguise(_ path: String, as response: HTTPFixtureServer.Response) {
            lock.withLock { disguised[path] = response }
        }

        func disguise(for path: String) -> HTTPFixtureServer.Response? {
            lock.withLock { disguised[path] }
        }

        func refuses(_ path: String) -> Bool {
            lock.withLock { refused.contains(path) }
        }

        func record(_ request: HTTPFixtureServer.Request) {
            lock.withLock { all.append(request) }
        }

        func requests(for path: String) -> [HTTPFixtureServer.Request] {
            lock.withLock { all.filter { $0.path == path } }
        }
    }

    private nonisolated static func pdfResponse(_ body: Data, name: String) -> HTTPFixtureServer.Response {
        HTTPFixtureServer.Response(
            status: "200 OK",
            headers: ["Content-Type": "application/pdf", "Content-Disposition": "inline; filename=\"\(name)\""],
            body: body
        )
    }

    @MainActor
    final class Rig {
        let engine: BrowserEngine
        let server: HTTPFixtureServer
        let log: RequestLog
        let folder: URL
        let history: URL
        let downloads: DownloadManager
        let browser: BrowserModel
        let window: NSWindow
        let tab: BrowserTab
        private(set) var opened: [(file: URL, app: URL)] = []
        static let previewURL = URL(fileURLWithPath: "/Applications/Preview.app")
        private var menuObserver: NSObjectProtocol?
        lazy var coordinator = AppCoordinator(browser: browser)
        /// The titles of the last context menu, a separator as "—".
        private(set) var offered: [String] = []
        private var chosen = false
        private var seenMenu = false

        init(
            engine: BrowserEngine, server: HTTPFixtureServer, log: RequestLog, folder: URL, history: URL,
            downloads: DownloadManager, browser: BrowserModel, tab: BrowserTab, window: NSWindow
        ) {
            self.engine = engine
            self.server = server
            self.log = log
            self.folder = folder
            self.history = history
            self.downloads = downloads
            self.browser = browser
            self.tab = tab
            self.window = window
            downloads.workspace.urlForPreview = { Self.previewURL }
            downloads.workspace.open = { [weak self] file, app in self?.opened.append((file, app)) }
        }

        var page: BrowserPage {
            tab.page
        }

        func close() async {
            if let menuObserver {
                NotificationCenter.default.removeObserver(menuObserver)
            }
            window.contentView = nil
            window.close()
            browser.close(tab)
            await tab.waitForRetirement()
        }

        /// Loads `path` in the tab and waits until the page, and a PDF's viewer, is up.
        func load(_ path: String, isPDF: Bool) async throws {
            let url = try server.url(path)
            tab.load(url)
            try #require(await waitUntil(timeout: .seconds(60)) { page.url == url && !page.isLoading })
            try #require(await waitUntil { page.window === window })
            if isPDF {
                try #require(await waitUntil { tab.shownPDF == url }, "the tab knows it shows a PDF")
                if let native = page.webKit {
                    try #require(await waitUntil { native.isDisplayingPDF }, "WebKit's viewer is up")
                }
                // The viewer draws after the page has loaded; the engine takes no click before.
                try await Task.sleep(for: .milliseconds(1500))
            } else {
                try await Task.sleep(for: .milliseconds(300))
            }
        }

        /// Right-clicks the page at `point` (in the page's own coordinates) and chooses the first item `choose` accepts. The menu is the
        /// real one, read a moment after it began to track: WebKit's as its viewer and `TabWebView` left it, Chromium's as CEF shows it.
        @discardableResult
        func rightClick(at point: CGPoint, choosing choose: @escaping @MainActor (String) -> Bool = { _ in false }) async throws -> Bool {
            offered = []
            chosen = false
            seenMenu = false
            if let menuObserver {
                NotificationCenter.default.removeObserver(menuObserver)
            }
            menuObserver = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification, object: nil, queue: nil) { [weak self] note in
                nonisolated(unsafe) let tracked = note.object as? NSMenu
                MainActor.assumeIsolated {
                    guard let self, let menu = tracked, !self.seenMenu else { return }
                    self.seenMenu = true
                    // Whatever the test does, the menu does not stay: a menu that stays holds the whole test run.
                    let watchdog = Timer(timeInterval: 8, repeats: false) { _ in menu.cancelTracking() }
                    RunLoop.main.add(watchdog, forMode: .common)
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(300))
                        self.offered = menu.items.map { $0.isSeparatorItem ? "—" : $0.title }
                        let index = menu.items.firstIndex { !$0.isSeparatorItem && choose($0.title) }
                        self.chosen = index != nil
                        if let index {
                            menu.performActionForItem(at: index)
                        }
                        menu.cancelTracking()
                        watchdog.invalidate()
                    }
                }
            }
            if let chromium = page.chromium {
                _ = try await chromium.command("Input.dispatchMouseEvent", params: [
                    "type": "mouseMoved", "x": Double(point.x), "y": Double(point.y), "button": "none", "buttons": 0,
                ])
                for (type, buttons) in [("mousePressed", 2), ("mouseReleased", 0)] {
                    _ = try await chromium.command("Input.dispatchMouseEvent", params: [
                        "type": type, "x": Double(point.x), "y": Double(point.y), "button": "right", "buttons": buttons, "clickCount": 1,
                    ])
                }
            } else {
                let native = try #require(page.webKit)
                let location = native.convert(point, to: nil)
                for type in [NSEvent.EventType.rightMouseDown, .rightMouseUp] {
                    window.sendEvent(try #require(NSEvent.mouseEvent(
                        with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                        windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                        pressure: type == .rightMouseDown ? 1 : 0
                    )))
                }
            }
            _ = await waitUntil(timeout: .seconds(10)) { !self.offered.isEmpty }
            // The chosen action runs in the turn after the menu was read.
            try await Task.sleep(for: .milliseconds(100))
            return chosen
        }

        /// The file of the download that finished, once the download list says one did.
        func savedFile() async throws -> URL {
            try #require(await waitUntil(timeout: .seconds(30)) { downloads.items.contains { $0.state == .finished } }, "a download finished")
            let item = try #require(downloads.items.first { $0.state == .finished })
            return try #require(item.destination)
        }

        var filesInFolder: [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).filter { $0 != "Downloads.json" }.sorted()
        }
    }

    private func withRig(
        _ engine: BrowserEngine, privately: Bool = false, body: (Rig, String) async throws -> Void
    ) async throws {
        let token = UUID().uuidString
        let log = RequestLog()
        let pdf = Self.pdf
        let server = try await HTTPFixtureServer.start(
            routes: [
                "/": .html("<!doctype html><title>Plain page</title><p>Not a PDF.</p>"),
                "/login": .html("<!doctype html><title>Login</title><p>Signed in.</p>", headers: ["Set-Cookie": "pdfsession=\(token); Path=/"]),
                "/report": Self.pdfResponse(pdf, name: "Quarterly Report.pdf"),
                "/trap": Self.pdfResponse(pdf, name: "Trap.pdf"),
                "/flaky": Self.pdfResponse(pdf, name: "Flaky.pdf"),
                "/attachment": HTTPFixtureServer.Response(
                    status: "200 OK",
                    headers: ["Content-Type": "application/pdf", "Content-Disposition": "attachment; filename=\"Page Chose This.pdf\""],
                    body: pdf
                ),
            ],
            respond: { request in
                log.record(request)
                if let disguise = log.disguise(for: request.path) {
                    return disguise
                }
                if log.refuses(request.path) {
                    return HTTPFixtureServer.Response(status: "404 Not Found", headers: ["Content-Type": "text/plain"], body: Data("gone".utf8))
                }
                guard request.path == "/secret" else { return nil }
                guard request.headers["cookie"]?.contains("pdfsession=\(token)") == true else {
                    return HTTPFixtureServer.Response(
                        status: "403 Forbidden", headers: ["Content-Type": "text/plain"], body: Data("signed out".utf8)
                    )
                }
                return Self.pdfResponse(pdf, name: "Secret.pdf")
            }
        )
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let history = folder.appendingPathComponent("Downloads.json")
        let downloads = DownloadManager(destinationFolder: folder, asksWhereToSave: false, file: history)
        let url = try server.url("/")
        let permissions = SitePermissions(
            storageURL: AppDatabase.supportDirectory.appendingPathComponent("PDFSaving-\(UUID().uuidString).json"))
        if engine == .chromium {
            try ChromiumRuntime.shared.ensureInitialized()
            permissions.setEngine(.chromium, for: SitePermissions.origin(for: url))
        }
        let browser = BrowserModel(database: .temporary(), sitePermissions: permissions, downloads: downloads)
        if privately {
            browser.adopt(database: .temporary(), sitePermissions: permissions, privately: true)
        }
        let tab = browser.newTab(url: url)
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 800, height: 500), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = WebViewContainer(page: tab.page)
        window.orderBack(nil)
        let rig = Rig(engine: engine, server: server, log: log, folder: folder, history: history, downloads: downloads, browser: browser, tab: tab, window: window)
        do {
            try #require(await waitUntil(timeout: .seconds(60)) { tab.page.url == url && !tab.page.isLoading })
            #expect((tab.page.chromium != nil) == (engine == .chromium), "the page runs on \(engine)")
            try await body(rig, token)
        } catch {
            await rig.close()
            throw error
        }
        await rig.close()
        withExtendedLifetime(server) {}
    }

    private static let onThePDF = CGPoint(x: 300, y: 250)
    private static let onThePlainPage = CGPoint(x: 100, y: 100)
    private static let download: @MainActor (String) -> Bool = { $0 == "Download PDF" }

    // MARK: - The right-click menu

    @Test(arguments: BrowserEngine.allCases)
    func theMenuOfAPDFDownloadsItsBytes(engine: BrowserEngine) async throws {
        try await withRig(engine) { rig, _ in
            try await rig.load("/report", isPDF: true)
            let chosen = try await rig.rightClick(at: Self.onThePDF, choosing: Self.download)
            try #require(chosen, "the menu offers Download PDF; it offered \(rig.offered)")
            #expect(rig.offered.filter { $0 == "Download PDF" }.count == 1)
            if engine == .chromium {
                #expect(rig.offered.contains("Open in Preview"))
            } else {
                #expect(rig.offered.filter { $0.contains("Preview") }.count == 1, "WebKit's own Open with Preview is the only one")
            }

            let saved = try await rig.savedFile()
            #expect(try Data(contentsOf: saved) == Self.pdf, "exactly the PDF's bytes")
            #expect(saved.lastPathComponent == "Quarterly Report.pdf")
            #expect(rig.filesInFolder == ["Quarterly Report.pdf"], "one file, nothing else in the folder")
            let item = try #require(rig.downloads.items.first)
            #expect(rig.downloads.items.count == 1)
            #expect(item.sourceTabID == rig.tab.id)
            #expect(item.sourceOrigin == SitePermissions.origin(for: try rig.server.url("/report")))
        }
    }

    @Test func openInPreviewSavesAChromiumPDFAndOpensTheCopy() async throws {
        try await withRig(.chromium) { rig, _ in
            try await rig.load("/report", isPDF: true)
            let chosen = try await rig.rightClick(at: Self.onThePDF) { $0 == "Open in Preview" }
            try #require(chosen, "the menu offers Open in Preview; it offered \(rig.offered)")

            let saved = try await rig.savedFile()
            #expect(try Data(contentsOf: saved) == Self.pdf)
            #expect(await waitUntil { rig.opened.count == 1 }, "the saved copy was opened, once")
            #expect(rig.opened.first?.file == saved && rig.opened.first?.app == Rig.previewURL, "in Preview itself")
            let quarantine = try saved.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
            #expect(quarantine != nil, "the quarantine flag stays")
            #expect(rig.tab.pendingPDFOpening == nil, "the request was used by its download")
        }
    }

    @Test(arguments: BrowserEngine.allCases)
    func aPlainPageGetsNoPDFItems(engine: BrowserEngine) async throws {
        try await withRig(engine) { rig, _ in
            try await rig.load("/", isPDF: false)
            #expect(rig.tab.shownPDF == nil)
            try await rig.rightClick(at: Self.onThePlainPage)
            try #require(!rig.offered.isEmpty, "the page has a menu")
            #expect(!rig.offered.contains("Download PDF") && !rig.offered.contains("Open in Preview"), "it offered \(rig.offered)")
            if engine == .webKit {
                #expect(rig.offered.contains("Save Page As…") && rig.offered.contains("Print Page…"), "WebKit's page items are as they were")
            }
            #expect(rig.downloads.items.isEmpty)
        }
    }

    // MARK: - ⌘S

    @Test(arguments: BrowserEngine.allCases)
    func commandSOnAPDFSavesThePDF(engine: BrowserEngine) async throws {
        try await withRig(engine) { rig, _ in
            try await rig.load("/report", isPDF: true)
            let menu = MainMenu(coordinator: rig.coordinator)
            menu.install()
            defer { NSApp.mainMenu = nil }
            let root = try #require(NSApp.mainMenu)
            let item = try #require(root.items.compactMap(\.submenu).flatMap(\.items)
                .first { $0.title == String(localized: "Save Page As…") })
            #expect(item.keyEquivalent == "s" && item.keyEquivalentModifierMask == [.command])
            #expect(menu.validateMenuItem(item))

            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0, windowNumber: 0, context: nil,
                characters: "s", charactersIgnoringModifiers: "s", isARepeat: false, keyCode: 1
            ))
            #expect(root.performKeyEquivalent(with: event), "⌘S is the File menu's Save Page As…")

            let saved = try await rig.savedFile()
            #expect(try Data(contentsOf: saved) == Self.pdf, "the PDF itself, not an archive of the viewer")
            #expect(saved.lastPathComponent == "Quarterly Report.pdf")
            #expect(rig.filesInFolder == ["Quarterly Report.pdf"])
        }
    }

    // MARK: - The tab's own session

    @Test(arguments: BrowserEngine.allCases)
    func aPDFBehindASignInIsSavedWithTheTabsCookies(engine: BrowserEngine) async throws {
        try await withRig(engine) { rig, _ in
            try await rig.load("/login", isPDF: false)
            try await rig.load("/secret", isPDF: true)
            rig.tab.savePDF()

            let saved = try await rig.savedFile()
            #expect(try Data(contentsOf: saved) == Self.pdf, "the signed-in PDF, not the sign-in refusal")
            let asked = rig.log.requests(for: "/secret")
            #expect(asked.allSatisfy { $0.headers["cookie"]?.contains("pdfsession=") == true }, "every request carried the tab's cookie")
            if engine == .webKit {
                #expect(asked.count == 1, "WebKit's own bytes: no second request")
            }
        }
    }

    @Test(arguments: BrowserEngine.allCases)
    func aPrivateWindowSavesThePDFToDownloadsAndKeepsItOutOfTheList(engine: BrowserEngine) async throws {
        try await withRig(engine, privately: true) { rig, _ in
            try await rig.load("/report", isPDF: true)
            rig.tab.savePDF()

            let saved = try await rig.savedFile()
            #expect(saved.deletingLastPathComponent().standardizedFileURL == rig.folder.standardizedFileURL)
            #expect(try Data(contentsOf: saved) == Self.pdf)
            #expect(rig.downloads.items.first?.isPrivate == true)
            rig.downloads.writeNow()
            #expect(DownloadManager(file: rig.history).items.isEmpty, "a private download is not written to the saved list")
        }
    }

    // MARK: - Open in Preview opens only what it started

    private func download(_ address: String, asked original: String? = nil) -> CefDownload {
        CefDownload(
            id: 1, url: URL(string: address), receivedBytes: 0, totalBytes: 0, isComplete: false, isCanceled: false, fullPath: nil,
            originalURL: URL(string: original ?? address)
        )
    }

    /// Two tabs of a model, for what depends on which page a request belongs to.
    private struct Pair {
        let model = BrowserModel(database: .temporary())
        let tab: BrowserTab
        let other: BrowserTab

        init() {
            tab = model.newTab()
            other = model.newTab()
        }

        var page: BrowserPage {
            tab.page
        }

        func close() {
            model.close(tab)
            model.close(other)
        }
    }

    @Test func openInPreviewIsBoundToTheDownloadItAskedFor() {
        let pair = Pair()
        defer { pair.close() }
        let (tab, page, otherPage) = (pair.tab, pair.page, pair.other.page)
        tab.awaitPDFOpening(of: URL(string: "https://example.com/report.pdf#page=2")!, in: page)

        #expect(!tab.takesPDFOpening(for: download("https://example.com/other.pdf"), in: page), "another address")
        #expect(!tab.takesPDFOpening(for: download("https://example.com/report.pdf"), in: otherPage), "another page")
        #expect(tab.pendingPDFOpening != nil, "those leave the request for the download it waits for")
        #expect(
            tab.takesPDFOpening(for: download("https://cdn.example.com/x", asked: "https://example.com/report.pdf"), in: page),
            "the address as it was asked for, whatever redirect followed"
        )
        #expect(!tab.takesPDFOpening(for: download("https://example.com/report.pdf"), in: page), "it opens once")
        #expect(tab.pendingPDFOpening == nil)
    }

    @Test func aNavigationEndsAPendingOpenInPreview() {
        let pair = Pair()
        defer { pair.close() }
        let (tab, page) = (pair.tab, pair.page)
        let report = URL(string: "https://example.com/report.pdf")!

        tab.awaitPDFOpening(of: report, in: page)
        tab.navigationStarted(nil, url: URL(string: "https://example.com/next"))
        #expect(tab.pendingPDFOpening == nil, "the next navigation started")
        #expect(!tab.takesPDFOpening(for: download(report.absoluteString), in: page))

        tab.awaitPDFOpening(of: report, in: page)
        tab.navigationCommitted(nil)
        #expect(tab.pendingPDFOpening == nil, "the next document committed")
    }

    @Test func aPendingOpenInPreviewExpires() async {
        let pair = Pair()
        defer { pair.close() }
        let (tab, page) = (pair.tab, pair.page)
        let report = URL(string: "https://example.com/report.pdf")!
        tab.pdfOpeningLifetime = .milliseconds(50)

        tab.awaitPDFOpening(of: report, in: page)

        #expect(await waitUntil { tab.pendingPDFOpening == nil }, "the request went when its time was up")
        #expect(!tab.takesPDFOpening(for: download(report.absoluteString), in: page))
    }

    @Test func aLaterRequestReplacesAnEarlierOne() async {
        let pair = Pair()
        defer { pair.close() }
        let (tab, page) = (pair.tab, pair.page)
        tab.pdfOpeningLifetime = .milliseconds(200)
        tab.awaitPDFOpening(of: URL(string: "https://example.com/first.pdf")!, in: page)
        tab.awaitPDFOpening(of: URL(string: "https://example.com/second.pdf")!, in: page)

        #expect(!tab.takesPDFOpening(for: download("https://example.com/first.pdf"), in: page))
        #expect(tab.takesPDFOpening(for: download("https://example.com/second.pdf"), in: page))
    }

    /// What a page downloads on its own after an Open in Preview that never got its file is saved like any download and never opened.
    @Test func aPageDownloadAfterAFailedOpenInPreviewIsNotOpened() async throws {
        try await withRig(.chromium) { rig, _ in
            try await rig.load("/flaky", isPDF: true)
            rig.log.refuse("/flaky")
            rig.tab.savePDF(opening: true)
            try #require(rig.tab.pendingPDFOpening != nil, "the tab waits for the download it started")

            let attachment = try rig.server.url("/attachment")
            try #require(rig.page.chromium).startDownload(of: attachment)

            let saved = try await rig.savedFile()
            #expect(saved.lastPathComponent == "Page Chose This.pdf")
            #expect(try Data(contentsOf: saved) == Self.pdf)
            try await Task.sleep(for: .milliseconds(500))
            #expect(rig.opened.isEmpty, "the page's own download was not opened; it opened \(rig.opened)")
        }
    }

    /// A server can answer the second request with anything: a download that is not a PDF by name and type is saved and not opened.
    @Test(arguments: [("text/html", "Trap.pdf"), ("application/pdf", "Trap.command"), ("application/octet-stream", "Trap.app")])
    func aDisguisedPDFIsDownloadedButNotOpened(type: String, name: String) async throws {
        try await withRig(.chromium) { rig, _ in
            try await rig.load("/trap", isPDF: true)
            rig.log.disguise("/trap", as: HTTPFixtureServer.Response(
                status: "200 OK",
                headers: ["Content-Type": type, "Content-Disposition": "attachment; filename=\"\(name)\""],
                body: type == "text/html" ? Data("<html>not a PDF</html>".utf8) : Self.pdf
            ))
            rig.tab.savePDF(opening: true)

            let saved = try await rig.savedFile()
            #expect(saved.lastPathComponent == name)
            try await Task.sleep(for: .milliseconds(500))
            #expect(rig.opened.isEmpty, "it was downloaded and not opened; it opened \(rig.opened)")
        }
    }

    // MARK: - What the download list opens

    private func request(
        _ id: UInt32, in folder: URL, live: Bool = true, opens: Bool
    ) -> (ChromiumDownloadRequest, ChromiumDownloadControls) {
        let token = NSObject()
        let controls = ChromiumDownloadControls(
            pageID: ObjectIdentifier(token), isLive: { live }, cancel: { _ in }, pause: { _ in }, resume: { _ in }
        )
        let item = CefDownload(
            id: id, url: URL(string: "https://example.com/report.pdf"), receivedBytes: 0, totalBytes: 10, isComplete: false,
            isCanceled: false, fullPath: nil
        )
        return (
            ChromiumDownloadRequest(
                download: item, suggestedName: "Report.pdf", sourceTabID: nil, isPrivate: false, window: nil, controls: controls,
                opensWhenFinished: opens
            ),
            controls
        )
    }

    private func finished(_ id: UInt32, at file: URL, canceled: Bool = false) -> CefDownload {
        CefDownload(
            id: id, url: nil, receivedBytes: 10, totalBytes: 10, isComplete: !canceled, isCanceled: canceled, fullPath: file
        )
    }

    private func decide(
        _ downloads: DownloadManager, _ request: ChromiumDownloadRequest
    ) async throws -> CefDownloadDecision {
        var decision: CefDownloadDecision?
        downloads.decideChromiumDownload(request) { decision = $0 }
        try #require(await waitUntil { decision != nil })
        return try #require(decision)
    }

    struct Kind: CustomTestStringConvertible {
        let name: String
        let type: String?
        let hasHeader: Bool
        let opens: Bool
        var testDescription: String { "\(name) as \(type ?? "?"), header \(hasHeader)" }
    }

    @Test(arguments: [
        Kind(name: "Report.pdf", type: "application/pdf", hasHeader: true, opens: true),
        Kind(name: "Report.PDF", type: nil, hasHeader: true, opens: true),
        Kind(name: "Report.pdf", type: "text/html", hasHeader: true, opens: false),
        Kind(name: "Report.command", type: "application/pdf", hasHeader: true, opens: false),
        Kind(name: "Report.app", type: "application/pdf", hasHeader: true, opens: false),
        Kind(name: "Report.pdf", type: "application/pdf", hasHeader: false, opens: false),
    ])
    func aFinishedDownloadOpensInPreviewOnlyWhenItIsAPDF(kind: Kind) async throws {
        let (name, type, hasHeader, opens) = (kind.name, kind.type, kind.hasHeader, kind.opens)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let downloads = DownloadManager(destinationFolder: folder, asksWhereToSave: false)
        var opened: [(URL, URL)] = []
        downloads.workspace.urlForPreview = { Rig.previewURL }
        downloads.workspace.open = { opened.append(($0, $1)) }
        var item = request(1, in: folder, opens: true).0
        item = ChromiumDownloadRequest(
            download: item.download, suggestedName: name, sourceTabID: nil, isPrivate: false, window: nil,
            controls: item.controls, opensWhenFinished: true
        )
        guard case .allow(let destination?) = try await decide(downloads, item) else {
            Issue.record("the download was allowed")
            return
        }
        try Data((hasHeader ? "%PDF-1.4 body" : "<html></html>").utf8).write(to: destination)
        var done = finished(1, at: destination)
        done.mimeType = type
        downloads.noteChromiumDownload(done)

        #expect(opened.count == (opens ? 1 : 0), "\(name) as \(type ?? "?"): opened \(opened)")
        if opens {
            #expect(opened.first?.0 == destination && opened.first?.1 == Rig.previewURL)
        }
    }

    @Test func aPDFIsNotOpenedWhenPreviewCannotBeFound() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Report.pdf")
        try Data("%PDF-1.4".utf8).write(to: file)
        let downloads = DownloadManager(destinationFolder: folder, asksWhereToSave: false)
        var opened = 0
        downloads.workspace.urlForPreview = { nil }
        downloads.workspace.open = { _, _ in opened += 1 }
        downloads.openInPreview(file, mimeType: "application/pdf")
        #expect(opened == 0)
        #expect(DownloadWorkspace.system.urlForPreview()?.lastPathComponent == "Preview.app", "the system names Preview by its bundle identifier")
    }

    @Test func aDeniedOrStoppedDownloadNeverOpensItsFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let downloads = DownloadManager(destinationFolder: folder, asksWhereToSave: false)
        var opened: [URL] = []
        downloads.workspace.urlForPreview = { Rig.previewURL }
        downloads.workspace.open = { file, _ in opened.append(file) }

        // Denied: the page was gone when the engine asked.
        let gone = request(1, in: folder, live: false, opens: true).0
        guard case .deny = try await decide(downloads, gone) else {
            Issue.record("a download of a closed page is denied")
            return
        }
        downloads.noteChromiumDownload(finished(1, at: folder.appendingPathComponent("Report.pdf")))

        // Cancelled after it began, and then reported complete by a late update.
        let cancelled = request(2, in: folder, opens: true).0
        guard case .allow(let destination?) = try await decide(downloads, cancelled) else {
            Issue.record("the download was allowed")
            return
        }
        try Data("PDF".utf8).write(to: destination)
        downloads.noteChromiumDownload(finished(2, at: destination, canceled: true))
        downloads.noteChromiumDownload(finished(2, at: destination))

        #expect(opened.isEmpty, "nothing was opened; it opened \(opened)")
    }
}
