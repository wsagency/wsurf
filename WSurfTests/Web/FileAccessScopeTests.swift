// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

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

    /// What `attribute` of the document's root element says once the document has recorded anything.
    private func recorded(_ attribute: String, in page: BrowserPage) async -> String? {
        var result: String?
        _ = await waitUntil {
            result = (try? await page.evaluateJavaScript("document.documentElement.getAttribute('\(attribute)')")) as? String
            return result?.isEmpty == false
        }
        return result
    }

    /// What the document recorded about the image beside it and, for a page, the stylesheet.
    private func outcome(in page: BrowserPage, of document: URL) async -> (image: String?, style: String?) {
        let image = await recorded("data-sibling", in: page)
        return (image, document.pathExtension == "html" ? await recorded("data-style", in: page) : nil)
    }

    private func opened(_ document: URL, engine: BrowserEngine, dragged: Bool) async throws -> (image: String?, style: String?) {
        var found: (image: String?, style: String?) = (nil, nil)
        try await withTab(engine: engine) { tab in
            if dragged {
                #expect(ContentNavBar.openDropped([NSItemProvider(object: document as NSURL)]) { tab.load($0) })
            } else {
                tab.load(document)
            }
            found = await outcome(in: tab.page, of: document)
        }
        return found
    }

    private func typed(_ document: URL) async throws -> (image: String?, style: String?) {
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

        let found = await outcome(in: view, of: document)
        tab.detach()
        await view.close()
        return found
    }

    /// WebKit keeps a single-file grant to the one file for every document type but HTML, which it lets read its folder (see
    /// `FileAccessScope`). That one case is recorded as a known issue, so the day WebKit or WSurf closes it the run says so.
    private func expectBlocked(_ found: (image: String?, style: String?), _ document: URL, engine: BrowserEngine) {
        let isHTML = document.pathExtension == "html"
        let expectation = {
            #expect(found.image == "blocked", "\(document.lastPathComponent) read the image beside it, engine \(engine)")
            #expect(!isHTML || found.style == "blocked", "\(document.lastPathComponent) loaded the stylesheet beside it, engine \(engine)")
        }
        if engine == .webKit && isHTML {
            withKnownIssue("WebKit lets an HTML file read its folder whatever it was granted", isIntermittent: true, expectation)
        } else {
            expectation()
        }
    }

    @Test(arguments: BrowserEngine.allCases)
    func aMailedPageOrDrawingCannotReadItsNeighbours(engine: BrowserEngine) async throws {
        let site = try makeSite()
        defer { site.remove() }

        for document in [site.mailedPage, site.mailedDrawing] {
            expectBlocked(try await opened(document, engine: engine, dragged: false), document, engine: engine)
        }
    }

    @Test(arguments: BrowserEngine.allCases)
    func aSavedPageLoadsItsStylesheetAndImages(engine: BrowserEngine) async throws {
        let site = try makeSite()
        defer { site.remove() }

        for document in [site.page, site.drawing] {
            let found = try await opened(document, engine: engine, dragged: false)

            #expect(found.image == "read", "\(document.lastPathComponent) could not read the image beside it, engine \(engine)")
            #expect(document.pathExtension != "html" || found.style == "read", "\(document.lastPathComponent) could not load the stylesheet beside it, engine \(engine)")
        }
    }

    @Test(arguments: BrowserEngine.allCases)
    func aDraggedFileFollowsTheSameRule(engine: BrowserEngine) async throws {
        let site = try makeSite()
        defer { site.remove() }

        for document in [site.mailedPage, site.mailedDrawing] {
            expectBlocked(try await opened(document, engine: engine, dragged: true), document, engine: engine)
        }
        for document in [site.page, site.drawing] {
            let found = try await opened(document, engine: engine, dragged: true)
            #expect(found.image == "read", "\(document.lastPathComponent) could not read the image beside it, engine \(engine)")
        }
    }

    @Test func aTypedFileAddressFollowsTheSameRule() async throws {
        let site = try makeSite()
        defer { site.remove() }

        expectBlocked(try await typed(site.mailedPage), site.mailedPage, engine: .webKit)

        let saved = try await typed(site.page)
        #expect(saved.image == "read" && saved.style == "read")
    }

    @Test func droppingNothingOpensNothing() {
        #expect(!ContentNavBar.openDropped([]) { _ in Issue.record("nothing was dropped") })
    }
}
