// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
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
        private(set) var opened: [URL] = []
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
            downloads.openFile = { [weak self] file in self?.opened.append(file) }
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

        /// The one file in the download folder, once the download list says it finished.
        func savedFile() async throws -> URL {
            try #require(await waitUntil(timeout: .seconds(30)) { downloads.items.first?.state == .finished }, "a download finished")
            let item = try #require(downloads.items.first)
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
            ],
            respond: { request in
                log.record(request)
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
            #expect(await waitUntil { rig.opened == [saved] }, "the saved copy was opened, once")
            #expect(!rig.tab.opensNextPDFDownload)
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

    // MARK: - Pieces

    @Test func aChromiumPDFOpensOnlyForTheNextPDFDownloadAfterTheRequest() throws {
        let model = BrowserModel(database: .temporary())
        let tab = model.newTab()
        defer { model.close(tab) }
        #expect(!tab.takesPDFOpening(forDownloadNamed: "report.pdf"), "nothing was asked")
        tab.opensNextPDFDownload = true
        #expect(!tab.takesPDFOpening(forDownloadNamed: "archive.zip"), "another file leaves the request for the PDF")
        #expect(tab.takesPDFOpening(forDownloadNamed: "Report.PDF"))
        #expect(!tab.takesPDFOpening(forDownloadNamed: "report.pdf"), "the request is used once")
    }
}
