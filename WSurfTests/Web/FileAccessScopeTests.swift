// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import Testing
import WebKit

@testable import WSurf

/// What a `file:` page may read depends on whether its file carries the quarantine attribute: a downloaded file reads only itself,
/// the person's own file its folder, and a folder that is opened its own contents. However it was opened: typed, dragged, opened
/// from Finder or from Downloads, in either engine.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct FileAccessScopeTests {
    // MARK: Files

    /// A folder with a space in its name and, beside each other: the person's own `page.html`, `drawing.svg`, `style.css`,
    /// `sibling.png` and `img/logo.png`, and `mailed.html` and `mailed.svg`, which carry quarantine as if they were downloaded.
    /// Each document tries to load `sibling.png` (and the pages `style.css`) and records `read` or `blocked` on its root element.
    private struct Site {
        let folder: URL
        var page: URL { folder.appendingPathComponent("page.html") }
        var drawing: URL { folder.appendingPathComponent("drawing.svg") }
        var mailedPage: URL { folder.appendingPathComponent("mailed.html") }
        var mailedDrawing: URL { folder.appendingPathComponent("mailed.svg") }
        var style: URL { folder.appendingPathComponent("style.css") }
        var logo: URL { folder.appendingPathComponent("img/logo.png") }
        var outside: URL { folder.deletingLastPathComponent().appendingPathComponent("outside-\(UUID().uuidString).txt") }

        func remove() {
            try? FileManager.default.removeItem(at: folder)
        }
    }

    private static let imageProbe = """
    document.documentElement.setAttribute('data-ran', 'yes');
    const image = new Image();
    image.onload = () => document.documentElement.setAttribute('data-sibling', 'read');
    image.onerror = () => document.documentElement.setAttribute('data-sibling', 'blocked');
    image.src = 'sibling.png';
    """

    private static let styleProbe = """
    const link = document.createElement('link');
    link.rel = 'stylesheet';
    link.onload = () => document.documentElement.setAttribute('data-style', 'read');
    link.onerror = () => document.documentElement.setAttribute('data-style', 'blocked');
    link.href = 'style.css';
    document.head.append(link);
    """

    /// WSurf asks the system to quarantine every file it creates (`LSFileQuarantineEnabled`), so whatever a test writes starts out
    /// quarantined. A file that stands for the person's own is cleared here, on a file this test has just made; the app never
    /// clears quarantine.
    private func own(_ file: URL) {
        file.withUnsafeFileSystemRepresentation { _ = removexattr($0, FileAccessScope.quarantineAttribute, 0) }
    }

    private func mailed(_ file: URL) throws {
        var file = file
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload,
            kLSQuarantineAgentNameKey as String: "Mail",
        ]
        try file.setResourceValues(values)
    }

    private func makeSite() throws -> Site {
        let png = try #require(Data(
            base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
        ))
        // Not the temporary directory: WebKit's web content process may read all of that, which would hide the scope under test.
        let caches = try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let folder = caches.appendingPathComponent("io.wsagency.wsurf.tests/Probe Site \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("img"), withIntermediateDirectories: true)
        let site = Site(folder: folder)
        let html = "<!doctype html><title>Probe</title><script>\(Self.imageProbe)\n\(Self.styleProbe)</script>"
        let svg = #"<svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><script>\#(Self.imageProbe)</script></svg>"#
        for (file, text) in [
            (site.page, html), (site.mailedPage, html), (site.drawing, svg), (site.mailedDrawing, svg),
            (site.style, "body { color: black; }"),
        ] {
            try text.write(to: file, atomically: true, encoding: .utf8)
        }
        try png.write(to: folder.appendingPathComponent("sibling.png"))
        try png.write(to: site.logo)
        for file in [site.page, site.drawing, site.style, site.logo, folder.appendingPathComponent("sibling.png")] {
            own(file)
        }
        try mailed(site.mailedPage)
        try mailed(site.mailedDrawing)
        #expect(!FileAccessScope.isQuarantined(site.page) && FileAccessScope.isQuarantined(site.mailedPage), "the fixture is not what it says")
        return site
    }

    private func path(_ url: URL) -> String {
        var path = url.path(percentEncoded: false)
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return path
    }

    // MARK: What the scope is

    @Test func aQuarantinedFileAddressedByTypingReadsOnlyThatFile() throws {
        let site = try makeSite()
        defer { site.remove() }
        let typed = try #require(Omnibox.location(for: site.mailedPage.absoluteString + "?draft=1#top"))

        let scope = FileAccessScope.readAccess(for: typed)

        #expect(path(scope) == path(site.mailedPage))
        #expect(scope.query() == nil && scope.fragment() == nil)
        #expect(!scope.hasDirectoryPath)
    }

    @Test(arguments: ["page.html", "page.htm", "logo.svg", "app.js", "style.css", "notes.md", "data.json", "Report.pdf", "photo.png"])
    func aDownloadedFileOfAnyKindReadsOnlyItself(_ name: String) throws {
        let site = try makeSite()
        defer { site.remove() }
        let dropped = site.folder.appendingPathComponent(name)
        try Data("x".utf8).write(to: dropped)
        try mailed(dropped)

        #expect(path(FileAccessScope.readAccess(for: dropped)) == path(dropped))
        #expect(!FileAccessScope.readAccess(for: dropped).hasDirectoryPath)
    }

    @Test func aFileOfThePersonsOwnReadsItsFolder() throws {
        let site = try makeSite()
        defer { site.remove() }

        for file in [site.page, site.drawing, site.logo] {
            let scope = FileAccessScope.readAccess(for: file)
            #expect(path(scope) == path(file.deletingLastPathComponent()), "\(file.lastPathComponent)")
            #expect(scope.hasDirectoryPath)
        }
    }

    @Test func aFolderThePersonOpensReadsThatFolder() throws {
        let site = try makeSite()
        defer { site.remove() }
        let bare = try #require(URL(string: String(site.folder.absoluteString.dropLast())))

        for folder in [site.folder, bare] {
            let scope = FileAccessScope.readAccess(for: folder)
            #expect(path(scope) == path(site.folder), "\(folder.absoluteString)")
            #expect(scope.hasDirectoryPath)
        }
    }

    @Test func aFileThatCannotBeInspectedReadsOnlyItself() throws {
        let site = try makeSite()
        defer { site.remove() }
        let gone = site.folder.appendingPathComponent("gone.html")

        let scope = FileAccessScope.readAccess(for: gone)

        #expect(path(scope) == path(gone))
        #expect(!scope.hasDirectoryPath)
    }

    @Test func dotsInTheAddressDoNotWidenTheScope() throws {
        let site = try makeSite()
        defer { site.remove() }
        let typed = try #require(URL(string: site.folder.absoluteString + "sub/../mailed.html"))

        #expect(path(FileAccessScope.readAccess(for: typed)) == path(site.mailedPage))
    }

    @Test func workingOutTheScopeLeavesQuarantineAsItWas() throws {
        let site = try makeSite()
        defer { site.remove() }
        func agent(_ file: URL) throws -> String? {
            try file.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties?[kLSQuarantineAgentNameKey as String] as? String
        }

        _ = FileAccessScope.readAccess(for: site.mailedPage)
        _ = FileAccessScope.readAccess(for: site.page)
        _ = FileAccessScope.allows(site.style, from: site.mailedPage)
        _ = FileAccessScope.allows(site.style, from: site.page)

        #expect(try agent(site.mailedPage) == "Mail")
        #expect(try agent(site.page) == nil, "reading the scope put quarantine on a file")
    }

    // MARK: Script in a downloaded page (WebKit)

    /// A file of `name` in the site's folder, quarantined as if downloaded, or the person's own.
    private func file(_ name: String, in site: Site, downloaded: Bool) throws -> URL {
        let file = site.folder.appendingPathComponent(name)
        try Data("<html></html>".utf8).write(to: file)
        if downloaded {
            try mailed(file)
        } else {
            own(file)
        }
        return file
    }

    /// Everything that may carry script, or that nobody can say does, runs none when it is downloaded.
    @Test(arguments: [
        "mailed.html", "MAILED.HTM", "mailed.xhtml", "mailed.svg", "Mailed.SVG", "mailed.svgz", "mailed.xml", "mailed.xsl",
        "mailed.webarchive", "mailed.mhtml", "mailed.json", "mailed.css", "mailed.unheardof", "mailed",
    ])
    func aDownloadedFileThatMayCarryScriptRunsNone(_ name: String) throws {
        let site = try makeSite()
        defer { site.remove() }
        let downloaded = try file(name, in: site, downloaded: true)

        #expect(!FileAccessScope.allowsScript(inFile: downloaded))
        let typed = try #require(Omnibox.location(for: downloaded.absoluteString + "?draft=1#top"))
        #expect(!FileAccessScope.allowsScript(inFile: typed), "an address with a query and a fragment")
    }

    @Test(arguments: [
        "mailed.png", "MAILED.JPG", "mailed.jpeg", "mailed.gif", "mailed.webp", "mailed.heic", "mailed.pdf", "mailed.PDF",
        "mailed.txt", "mailed.mp4", "mailed.mov", "mailed.mp3", "mailed.m4a", "mailed.wav",
    ])
    func aDownloadedImagePDFTextAudioOrVideoFileIsUnaffected(_ name: String) throws {
        let site = try makeSite()
        defer { site.remove() }
        let downloaded = try file(name, in: site, downloaded: true)

        #expect(FileAccessScope.allowsScript(inFile: downloaded))
    }

    @Test(arguments: ["own.html", "own.xhtml", "own.svg", "own.xml", "own.webarchive", "own.unheardof", "own", "own.png", "own.pdf"])
    func thePersonsOwnFilesKeepTheirScripts(_ name: String) throws {
        let site = try makeSite()
        defer { site.remove() }

        #expect(FileAccessScope.allowsScript(inFile: try file(name, in: site, downloaded: false)))
    }

    @Test func aFolderAWebAddressAndAMissingFileAreJudgedByTheSameRule() throws {
        let site = try makeSite()
        defer { site.remove() }

        #expect(FileAccessScope.allowsScript(inFile: site.folder), "a folder listing")
        #expect(FileAccessScope.allowsScript(inFile: URL(string: "https://example.test/mailed.html")!), "a web address")
        #expect(!FileAccessScope.allowsScript(inFile: site.folder.appendingPathComponent("gone.html")), "a file that cannot be inspected")
    }

    @Test func aFrameIsRefusedWhereItWouldRunADownloadedFileOrSitInADownloadedPage() throws {
        let site = try makeSite()
        defer { site.remove() }
        let downloadedImage = try file("mailed.png", in: site, downloaded: true)
        let ownImage = try file("own.png", in: site, downloaded: false)
        let web = try #require(URL(string: "https://example.test/"))
        func refused(_ target: URL, in page: URL?) -> Bool {
            FileAccessScope.refusesSubframe(to: target, inPageAt: page)
        }

        // Every file frame of a downloaded page, whatever the file.
        #expect(refused(site.mailedPage, in: site.mailedPage), "a page framing itself")
        #expect(refused(site.page, in: site.mailedPage))
        #expect(refused(ownImage, in: site.mailedPage))
        #expect(refused(downloadedImage, in: site.mailedPage))
        // A downloaded file that could run script, in any page.
        #expect(refused(site.mailedPage, in: site.page))
        #expect(refused(site.mailedDrawing, in: site.page))
        #expect(refused(site.mailedPage, in: nil))
        #expect(refused(site.mailedPage, in: web))
        // What stays: the person's own pages, inert downloads in them, and anything that is not a file.
        #expect(!refused(site.drawing, in: site.page))
        #expect(!refused(downloadedImage, in: site.page))
        #expect(!refused(site.page, in: nil))
        #expect(!refused(site.page, in: web))
        for target in ["about:blank", "https://example.test/a", "data:text/html,hi", "blob:https://example.test/1"] {
            #expect(!refused(try #require(URL(string: target)), in: site.mailedPage), "\(target)")
        }
    }

    // MARK: What a document may load

    @Test func aSavedPageMayLoadItsFolderAndAMailedOneOnlyItself() throws {
        let site = try makeSite()
        defer { site.remove() }
        let neighbourFolder = URL(fileURLWithPath: path(site.folder) + "-2/x.png")

        #expect(FileAccessScope.allows(site.style, from: site.page))
        #expect(FileAccessScope.allows(site.logo, from: site.page), "a file in a folder below")
        #expect(FileAccessScope.allows(site.page, from: site.page))
        #expect(!FileAccessScope.allows(site.outside, from: site.page))
        #expect(!FileAccessScope.allows(neighbourFolder, from: site.page), "a folder whose name starts the same is another folder")

        #expect(!FileAccessScope.allows(site.style, from: site.mailedPage))
        #expect(!FileAccessScope.allows(site.logo, from: site.mailedPage))
        #expect(!FileAccessScope.allows(site.page, from: site.mailedPage))
        let withFragment = try #require(URL(string: site.mailedPage.absoluteString + "?v=2#top"))
        #expect(FileAccessScope.allows(withFragment, from: site.mailedPage))
    }

    @Test func aFolderListingMayLoadWhatIsInsideThatFolder() throws {
        let listing = try #require(URL(string: "file:///Users/me/site/"))
        func allowed(_ address: String) throws -> Bool {
            FileAccessScope.allows(try #require(URL(string: address)), from: listing)
        }

        #expect(try allowed("file:///Users/me/site/index.html"))
        #expect(try allowed("file:///Users/me/site/img/logo.png"))
        #expect(try !allowed("file:///Users/me/site-2/index.html"), "a folder whose name starts the same is another folder")
        #expect(try !allowed("file:///Users/me/index.html"))
        #expect(try !allowed("file:///Users/me/site/../secret.txt"))
    }

    @Test func aFileThatCannotBeInspectedMayLoadOnlyItself() throws {
        let page = try #require(URL(string: "file:///Users/nobody/site/index.html#intro"))
        func allowed(_ address: String) throws -> Bool {
            FileAccessScope.allows(try #require(URL(string: address)), from: page)
        }

        #expect(try allowed("file:///Users/nobody/site/index.html"))
        #expect(try !allowed("file:///Users/nobody/site/style.css"))
        #expect(try !allowed("file:///Users/nobody/secret.txt"))
        #expect(try !allowed("file:///Users/nobody/site/../site2/index.html"))
    }

    @Test func aWebResourceIsNotAFileReadButAFileOnAWebPageIsRefused() throws {
        let file = try #require(URL(string: "file:///Users/nobody/site/index.html"))
        let web = try #require(URL(string: "https://example.test/a"))
        let sibling = try #require(URL(string: "file:///Users/nobody/site/style.css"))

        #expect(FileAccessScope.allows(web, from: file), "a web resource is not a file read")
        #expect(FileAccessScope.allows(web, from: web))
        #expect(!FileAccessScope.allows(sibling, from: web), "only a file page may read a file")
    }

    // MARK: Chromium's gate

    /// The gate of a Chromium page whose main frame is going to `address`, which is how CEF reports a navigation before any
    /// subresource of it is asked for.
    private func gate(navigatedTo address: String?) throws -> ChromiumFileScope {
        let gate = ChromiumFileScope()
        if let address {
            gate.mainFrameNavigation(to: try #require(URL(string: address)))
        }
        return gate
    }

    private func refused(_ gate: ChromiumFileScope, _ resource: String, by document: String?) throws -> Bool {
        gate.refuses(try #require(URL(string: resource)), requestedBy: try document.map { try #require(URL(string: $0)) })
    }

    private func refused(_ gate: ChromiumFileScope, _ resource: URL, by document: URL?) -> Bool {
        gate.refuses(resource, requestedBy: document)
    }

    @Test func aMailedPagesSubresourceFromASiblingFileIsRefused() throws {
        let site = try makeSite()
        defer { site.remove() }
        let gate = try gate(navigatedTo: site.mailedPage.absoluteString)

        #expect(refused(gate, site.style, by: site.mailedPage))
        #expect(refused(gate, site.logo, by: site.mailedPage))
        #expect(refused(gate, site.outside, by: site.mailedPage))
        #expect(!refused(gate, site.mailedPage, by: site.mailedPage), "its own file still loads")
    }

    @Test func aSavedPageStillLoadsItsStylesheetAndImages() throws {
        let site = try makeSite()
        defer { site.remove() }
        let gate = try gate(navigatedTo: site.page.absoluteString + "?draft=1")

        #expect(!refused(gate, site.style, by: site.page))
        #expect(!refused(gate, site.logo, by: site.page))
        #expect(!refused(gate, site.page, by: site.page))
        #expect(refused(gate, site.outside, by: site.page))
    }

    @Test func aStaleDocumentIsRefusedWhenTheNavigationMovesToAnotherFolder() throws {
        let first = try makeSite()
        let second = try makeSite()
        defer {
            first.remove()
            second.remove()
        }
        let gate = try gate(navigatedTo: first.page.absoluteString)
        #expect(!refused(gate, first.style, by: first.page))

        gate.mainFrameNavigation(to: second.page)

        #expect(refused(gate, second.style, by: first.page), "the new page's stylesheet, asked for by the old document")
        #expect(refused(gate, first.style, by: first.page), "the old page's stylesheet, now outside the scope")
        #expect(!refused(gate, second.style, by: second.page), "once the new document has committed")
    }

    @Test func anUnknownScopeIsRefusedEvenForASavedPage() throws {
        let site = try makeSite()
        defer { site.remove() }
        let gate = try gate(navigatedTo: nil)

        #expect(refused(gate, site.style, by: site.page))
        #expect(refused(gate, site.page, by: site.page))
        #expect(refused(gate, site.style, by: nil))
    }

    @Test func aFrameWhoseDocumentIsUnknownOrNotAFileIsRefusedEvenForASavedPage() throws {
        let site = try makeSite()
        defer { site.remove() }
        let gate = try gate(navigatedTo: site.page.absoluteString)

        #expect(refused(gate, site.style, by: nil))
        #expect(try refused(gate, site.style.absoluteString, by: "about:blank"))
        #expect(try refused(gate, site.style.absoluteString, by: "https://example.test/"))
        #expect(try refused(gate, site.style.absoluteString, by: "chrome-extension://abcdef/index.html"))
        #expect(refused(gate, site.style, by: site.outside), "a document outside the scope")
    }

    @Test func navigatingToAWebPageLeavesNoScope() throws {
        let site = try makeSite()
        defer { site.remove() }
        let gate = try gate(navigatedTo: site.page.absoluteString)

        gate.mainFrameNavigation(to: try #require(URL(string: "https://example.test/")))

        #expect(refused(gate, site.style, by: site.page))
    }

    @Test func aFolderListingCoversItsFolderAndAMailedFileInsideItReadsOnlyItself() throws {
        let site = try makeSite()
        defer { site.remove() }
        let gate = try gate(navigatedTo: site.folder.absoluteString)

        #expect(!refused(gate, site.style, by: site.folder))
        #expect(refused(gate, site.outside, by: site.folder))
        #expect(!refused(gate, site.mailedPage, by: site.mailedPage))
        #expect(refused(gate, site.style, by: site.mailedPage))
    }

    @Test func aFileThatCannotBeInspectedIsRefusedItsNeighbours() throws {
        let gate = try gate(navigatedTo: "file:///Users/nobody/site/index.html")
        let page = "file:///Users/nobody/site/index.html"

        #expect(try refused(gate, "file:///Users/nobody/site/style.css", by: page))
        #expect(try !refused(gate, page, by: page))
    }

    @Test func aResourceThatIsNotAFileIsNeverRefused() throws {
        let gate = try gate(navigatedTo: nil)

        for resource in ["https://example.test/a.png", "data:text/plain,hello", "blob:https://example.test/1", "chrome-extension://abc/x.js"] {
            #expect(try !refused(gate, resource, by: nil), "\(resource)")
        }
    }

    // MARK: What a page can read

    /// A fresh tab on `engine` showing nothing yet, in a window so Chromium loads.
    private func withTab(engine: BrowserEngine, body: (BrowserTab) async throws -> Void) async throws {
        if engine == .chromium {
            try ChromiumRuntime.shared.ensureInitialized()
        }
        let context = BrowserProfileContext(profile: .privateBrowsing())
        let tab = BrowserTab(opensBlank: false, privately: true, context: context)
        tab.engineOverride = engine
        let page = tab.page
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page
        window.orderBack(nil)
        defer {
            window.contentView = nil
            window.close()
        }
        do {
            #expect(page.engine == engine)
            try await body(tab)
        } catch {
            tab.detach()
            await page.close()
            await context.endPrivateSession()
            throw error
        }
        tab.detach()
        await page.close()
        await context.endPrivateSession()
    }

    /// What the document in `page` has on its root element under `attribute`, nil if nothing. `inClientWorld` reads where a page
    /// without script still answers.
    private func read(_ attribute: String, in page: BrowserPage, inClientWorld: Bool = false) async -> String? {
        let script = "document.documentElement.getAttribute('\(attribute)')"
        let value: Any?
        if inClientWorld {
            value = try? await page.evaluateJavaScript(script, in: nil, contentWorld: .defaultClient)
        } else {
            value = try? await page.evaluateJavaScript(script)
        }
        return value as? String
    }

    /// What the document in `page` has recorded under `attribute` once it has recorded anything.
    private func recorded(_ attribute: String, in page: BrowserPage) async -> String? {
        var result: String?
        _ = await waitUntil {
            result = await read(attribute, in: page)
            return result?.isEmpty == false
        }
        return result
    }

    private struct Outcome {
        var loaded = true
        var ran: String?
        var image: String?
        var style: String?
    }

    /// What the document `document`, shown in `page`, did: whether its script ran, and what it found about the image beside it
    /// and, for a page, the stylesheet. A document that is held back from running script records nothing, so it is looked at
    /// once, after it has loaded, instead of waited for.
    private func outcome(in page: BrowserPage, of document: URL, scripted: Bool) async -> Outcome {
        let isPage = document.pathExtension == "html"
        guard scripted else {
            let root = isPage ? "html" : "svg"
            let loaded = await waitUntil {
                guard page.url?.lastPathComponent == document.lastPathComponent, !page.isLoading else { return false }
                let state = try? await page.evaluateJavaScript(
                    "document.readyState + ':' + document.documentElement.localName", in: nil, contentWorld: .defaultClient
                )
                return state as? String == "complete:" + root
            }
            return Outcome(
                loaded: loaded,
                ran: await read("data-ran", in: page, inClientWorld: true),
                image: await read("data-sibling", in: page, inClientWorld: true),
                style: await read("data-style", in: page, inClientWorld: true)
            )
        }
        let image = await recorded("data-sibling", in: page)
        let style = isPage ? await recorded("data-style", in: page) : nil
        return Outcome(ran: await read("data-ran", in: page), image: image, style: style)
    }

    /// Whether script runs in a downloaded page or drawing in `engine`: Chromium confines it by its gate and lets it run, WebKit
    /// holds it back from running script (see `FileAccessScope`).
    private func runsScript(_ document: URL, in engine: BrowserEngine) -> Bool {
        engine == .chromium || !document.lastPathComponent.hasPrefix("mailed")
    }

    private func opened(_ document: URL, engine: BrowserEngine, dragged: Bool) async throws -> Outcome {
        var found = Outcome()
        try await withTab(engine: engine) { tab in
            if dragged {
                #expect(ContentNavBar.openDropped([NSItemProvider(object: document as NSURL)]) { tab.load($0) })
            } else {
                tab.load(document)
            }
            found = await outcome(in: tab.page, of: document, scripted: runsScript(document, in: engine))
        }
        return found
    }

    private func typed(_ document: URL) async throws -> Outcome {
        let model = BrowserModel(database: .temporary())
        let tab = model.newTab()
        let view = tab.page
        let host = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: .borderless, backing: .buffered, defer: false)
        host.isReleasedWhenClosed = false
        host.contentView = view
        host.orderBack(nil)
        defer {
            host.contentView = nil
            host.close()
        }

        model.handleAddressInput(document.absoluteString)

        let found = await outcome(in: view, of: document, scripted: runsScript(document, in: .webKit))
        tab.detach()
        await view.close()
        return found
    }

    /// A downloaded document cannot read its neighbours: Chromium lets its script run and refuses the files, WebKit does not
    /// run its script at all.
    private func expectHeldBack(_ found: Outcome, _ document: URL, engine: BrowserEngine) {
        let name = "\(document.lastPathComponent), engine \(engine)"
        if engine == .webKit {
            #expect(found.loaded, "\(name) did not load")
            #expect(found.ran == nil, "\(name) ran its script")
            #expect(found.image == nil && found.style == nil, "\(name) read a file beside it")
        } else {
            #expect(found.image == "blocked", "\(name) read the image beside it")
            #expect(document.pathExtension != "html" || found.style == "blocked", "\(name) loaded the stylesheet beside it")
        }
    }

    private func expectReads(_ found: Outcome, _ document: URL, engine: BrowserEngine) {
        let name = "\(document.lastPathComponent), engine \(engine)"
        #expect(found.ran == "yes", "\(name) did not run its script")
        #expect(found.image == "read", "\(name) could not read the image beside it")
        #expect(document.pathExtension != "html" || found.style == "read", "\(name) could not load the stylesheet beside it")
    }

    @Test(arguments: BrowserEngine.allCases)
    func aMailedPageOrDrawingCannotReadItsNeighbours(engine: BrowserEngine) async throws {
        let site = try makeSite()
        defer { site.remove() }

        for document in [site.mailedPage, site.mailedDrawing] {
            expectHeldBack(try await opened(document, engine: engine, dragged: false), document, engine: engine)
        }
    }

    @Test(arguments: BrowserEngine.allCases)
    func aSavedPageLoadsItsStylesheetAndImages(engine: BrowserEngine) async throws {
        let site = try makeSite()
        defer { site.remove() }

        for document in [site.page, site.drawing] {
            expectReads(try await opened(document, engine: engine, dragged: false), document, engine: engine)
        }
    }

    @Test(arguments: BrowserEngine.allCases)
    func aDraggedFileFollowsTheSameRule(engine: BrowserEngine) async throws {
        let site = try makeSite()
        defer { site.remove() }

        for document in [site.mailedPage, site.mailedDrawing] {
            expectHeldBack(try await opened(document, engine: engine, dragged: true), document, engine: engine)
        }
        for document in [site.page, site.drawing] {
            expectReads(try await opened(document, engine: engine, dragged: true), document, engine: engine)
        }
    }

    @Test func aTypedFileAddressFollowsTheSameRule() async throws {
        let site = try makeSite()
        defer { site.remove() }

        expectHeldBack(try await typed(site.mailedPage), site.mailedPage, engine: .webKit)
        expectReads(try await typed(site.page), site.page, engine: .webKit)
    }

    // MARK: Frames (WebKit)

    /// Pages that frame a sibling. The inner pages post `ran` to their parent if their script runs, and hold a frame of their own, so
    /// the outer page can tell, from the number of frames in its frame, that the sibling loaded.
    private struct FramePages {
        let framesItself: URL
        let downloadedFramesDownloaded: URL
        let ownFramesDownloaded: URL
        let ownFramesOwn: URL
    }

    private func makeFramePages(in site: Site) throws -> FramePages {
        let post = "parent.postMessage('ran', '*');"
        let listen = "window.addEventListener('message', event => document.documentElement.setAttribute('data-child', String(event.data)));"
        func page(_ name: String, body: String, downloaded: Bool) throws -> URL {
            let file = site.folder.appendingPathComponent(name)
            try "<!doctype html><title>Frames</title>\(body)".write(to: file, atomically: true, encoding: .utf8)
            if downloaded {
                try mailed(file)
            } else {
                own(file)
            }
            return file
        }
        _ = try page("mailed-inner.html", body: "<script>\(post)</script><iframe srcdoc='x'></iframe>", downloaded: true)
        _ = try page("own-inner.html", body: "<script>\(post)</script><iframe srcdoc='x'></iframe>", downloaded: false)
        return FramePages(
            framesItself: try page("mailed-itself.html", body: "<iframe src='mailed-itself.html'></iframe>", downloaded: true),
            downloadedFramesDownloaded: try page("mailed-outer.html", body: "<iframe src='mailed-inner.html'></iframe>", downloaded: true),
            ownFramesDownloaded: try page("own-outer-downloaded.html", body: "<script>\(listen)</script><iframe src='mailed-inner.html'></iframe>", downloaded: false),
            ownFramesOwn: try page("own-outer-own.html", body: "<script>\(listen)</script><iframe src='own-inner.html'></iframe>", downloaded: false)
        )
    }

    /// How many frames the first frame of `document` holds (nil when it holds none to count) and what its script posted to its
    /// parent, once `document` has loaded and its frames have had time to.
    private func framed(_ document: URL) async throws -> (frames: String?, message: String?) {
        var found: (frames: String?, message: String?) = (nil, nil)
        try await withTab(engine: .webKit) { tab in
            tab.load(document)
            let page = tab.page
            _ = await waitUntil { page.url?.lastPathComponent == document.lastPathComponent && !page.isLoading }
            try await Task.sleep(for: .seconds(1.5))
            @MainActor func ask(_ script: String) async -> String? {
                (try? await page.evaluateJavaScript(script, in: nil, contentWorld: .defaultClient)) as? String
            }
            found = (
                await ask("(() => { const frame = document.querySelector('iframe'); return frame ? String(frame.contentWindow.length) : 'no frame'; })()"),
                await ask("document.documentElement.getAttribute('data-child') ?? 'unset'")
            )
        }
        return found
    }

    @Test func aDownloadedPageCannotFrameItselfOrADownloadedSibling() async throws {
        let site = try makeSite()
        defer { site.remove() }
        let pages = try makeFramePages(in: site)

        let itself = try await framed(pages.framesItself)
        #expect(itself.frames == "0" && itself.message == "unset", "frames \(itself.frames ?? "nil"), message \(itself.message ?? "nil")")

        let sibling = try await framed(pages.downloadedFramesDownloaded)
        #expect(sibling.frames == "0", "the downloaded sibling was framed")
        #expect(sibling.message == "unset", "script ran in a downloaded page's frame")
    }

    @Test func aPageOfThePersonsOwnCannotRunADownloadedSiblingInAFrame() async throws {
        let site = try makeSite()
        defer { site.remove() }
        let pages = try makeFramePages(in: site)

        let result = try await framed(pages.ownFramesDownloaded)

        #expect(result.frames == "0", "the downloaded sibling was framed")
        #expect(result.message == "unset", "a downloaded page ran script in the person's page")
    }

    /// The probe sees a framed sibling when it is allowed, so the refusals above are the rule and not a broken fixture.
    @Test func aPageOfThePersonsOwnFramesItsOwnSiblingAndHearsFromIt() async throws {
        let site = try makeSite()
        defer { site.remove() }
        let pages = try makeFramePages(in: site)

        let result = try await framed(pages.ownFramesOwn)

        #expect(result.frames == "1", "the sibling did not load")
        #expect(result.message == "ran", "the sibling's script did not run")
    }

    @Test func droppingNothingOpensNothing() {
        #expect(!ContentNavBar.openDropped([]) { _ in Issue.record("nothing was dropped") })
    }
}
