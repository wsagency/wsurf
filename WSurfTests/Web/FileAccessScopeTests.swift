// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing
import WebKit

@testable import WSurf

/// A `file:` page reads the file it was opened from and nothing next to it, however it was opened: typed, dragged, opened from
/// Finder or from Downloads. A folder's listing reads that folder only.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct FileAccessScopeTests {
    // MARK: What the scope is

    @Test func aTypedFileAddressReadsOnlyThatFile() throws {
        let typed = try #require(Omnibox.location(for: "file:///Users/me/My%20Site/page.html?draft=1#top"))

        let scope = FileAccessScope.readAccess(for: typed)

        #expect(scope.path(percentEncoded: false) == "/Users/me/My Site/page.html")
        #expect(scope.query() == nil && scope.fragment() == nil)
        #expect(!scope.hasDirectoryPath)
        #expect(scope != typed.deletingLastPathComponent(), "the folder was the scope before")
    }

    @Test(arguments: [
        "page.html", "page.htm", "logo.svg", "app.js", "style.css", "notes.md", "data.json", "Report.pdf", "photo.png",
    ])
    func aDraggedFileReadsOnlyItself(_ name: String) throws {
        let dropped = URL(fileURLWithPath: "/Users/me/My Site/\(name)")

        #expect(FileAccessScope.readAccess(for: dropped) == dropped)
        #expect(FileAccessScope.readAccess(for: dropped) != dropped.deletingLastPathComponent())
    }

    @Test func aFolderListingReadsThatFolderOnly() {
        let folder = URL(fileURLWithPath: "/Users/me/My Site", isDirectory: true)

        let scope = FileAccessScope.readAccess(for: folder)

        #expect(scope.path(percentEncoded: false) == "/Users/me/My Site/")
        #expect(scope.hasDirectoryPath)
    }

    @Test func dotsInTheAddressDoNotWidenTheScope() throws {
        let typed = try #require(URL(string: "file:///Users/me/site/sub/../../other/page.html"))

        #expect(FileAccessScope.readAccess(for: typed).path(percentEncoded: false) == "/Users/me/other/page.html")
    }

    @Test func aPageMayLoadOnlyItsOwnFile() throws {
        let page = try #require(URL(string: "file:///Users/me/site/index.html#intro"))
        func allowed(_ address: String) throws -> Bool {
            FileAccessScope.allows(try #require(URL(string: address)), from: page)
        }

        #expect(try allowed("file:///Users/me/site/index.html"))
        #expect(try allowed("file:///Users/me/site/index.html?v=2#other"))
        #expect(try !allowed("file:///Users/me/site/style.css"))
        #expect(try !allowed("file:///Users/me/site/img/logo.png"))
        #expect(try !allowed("file:///Users/me/secret.txt"))
        #expect(try !allowed("file:///Users/me/site/index.html.bak"))
        #expect(try !allowed("file:///Users/me/site/../site2/index.html"))
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

    @Test func aWebResourceIsNotAFileReadButAFileOnAWebPageIsRefused() throws {
        let file = try #require(URL(string: "file:///Users/me/site/index.html"))
        let web = try #require(URL(string: "https://example.test/a"))
        let sibling = try #require(URL(string: "file:///Users/me/site/style.css"))

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

    @Test func aSubresourceFromASiblingFileIsRefused() throws {
        let gate = try gate(navigatedTo: "file:///Users/me/site/index.html")
        let page = "file:///Users/me/site/index.html"

        #expect(try refused(gate, "file:///Users/me/site/style.css", by: page))
        #expect(try refused(gate, "file:///Users/me/site/img/logo.png", by: page))
        #expect(try refused(gate, "file:///Users/me/secret.txt", by: page))
        #expect(try refused(gate, "file:///Users/me/site/../secret.txt", by: page))
    }

    @Test func thePagesOwnFileStillLoads() throws {
        let gate = try gate(navigatedTo: "file:///Users/me/My%20Site/index.html?draft=1")
        let page = "file:///Users/me/My%20Site/index.html#top"

        #expect(try !refused(gate, "file:///Users/me/My%20Site/index.html", by: page))
        #expect(try !refused(gate, "file:///Users/me/My%20Site/index.html?draft=2", by: page))
    }

    @Test func aSubresourceBeforeAnyNavigationIsRefused() throws {
        let gate = try gate(navigatedTo: nil)

        #expect(try refused(gate, "file:///Users/me/site/index.html", by: "file:///Users/me/site/index.html"))
        #expect(try refused(gate, "file:///Users/me/site/style.css", by: nil))
    }

    @Test func aSubresourceDuringANavigationIsRefusedWhileTheFrameStillShowsTheOldDocument() throws {
        let gate = try gate(navigatedTo: "file:///Users/me/site/old.html")
        let old = "file:///Users/me/site/old.html"
        #expect(try !refused(gate, old, by: old))

        gate.mainFrameNavigation(to: try #require(URL(string: "file:///Users/me/site/new.html")))

        #expect(try refused(gate, "file:///Users/me/site/new.html", by: old), "the new page's file, asked for by the old document")
        #expect(try refused(gate, old, by: old), "the old page's own file, now outside the scope")
        #expect(try !refused(gate, "file:///Users/me/site/new.html", by: "file:///Users/me/site/new.html"), "once the new document has committed")
    }

    @Test func aFrameWhoseDocumentIsUnknownOrNotAFileIsRefused() throws {
        let gate = try gate(navigatedTo: "file:///Users/me/site/index.html")
        let own = "file:///Users/me/site/index.html"

        #expect(try refused(gate, own, by: nil))
        #expect(try refused(gate, own, by: "about:blank"))
        #expect(try refused(gate, own, by: "https://example.test/"))
        #expect(try refused(gate, own, by: "chrome-extension://abcdef/index.html"))
        #expect(try refused(gate, "file:///Users/me/site/other.html", by: "file:///Users/me/site/other.html"), "a document outside the scope")
    }

    @Test func navigatingToAWebPageLeavesNoScope() throws {
        let gate = try gate(navigatedTo: "file:///Users/me/site/index.html")

        gate.mainFrameNavigation(to: try #require(URL(string: "https://example.test/")))

        #expect(try refused(gate, "file:///Users/me/site/index.html", by: "file:///Users/me/site/index.html"))
    }

    @Test func aFolderListingCoversItsFolderAndAFileInsideItReadsOnlyItself() throws {
        let gate = try gate(navigatedTo: "file:///Users/me/site/")

        #expect(try !refused(gate, "file:///Users/me/site/index.html", by: "file:///Users/me/site/"))
        #expect(try refused(gate, "file:///Users/me/other/index.html", by: "file:///Users/me/site/"))
        #expect(try !refused(gate, "file:///Users/me/site/index.html", by: "file:///Users/me/site/index.html"))
        #expect(try refused(gate, "file:///Users/me/site/style.css", by: "file:///Users/me/site/index.html"))
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

    /// A folder with a page, an SVG and a PNG beside them. Each of the two documents tries to load the PNG and records whether
    /// it could in `data-sibling` on its root element.
    private func withSite(_ body: (_ folder: URL, _ page: URL, _ drawing: URL) async throws -> Void) async throws {
        let png = try #require(Data(
            base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
        ))
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Probe Site \(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let script = """
        const image = new Image();
        image.onload = () => document.documentElement.setAttribute('data-sibling', 'read');
        image.onerror = () => document.documentElement.setAttribute('data-sibling', 'blocked');
        image.src = 'sibling.png';
        """
        let page = folder.appendingPathComponent("page.html")
        let drawing = folder.appendingPathComponent("drawing.svg")
        try png.write(to: folder.appendingPathComponent("sibling.png"))
        try "<!doctype html><title>Probe</title><script>\(script)</script>".write(to: page, atomically: true, encoding: .utf8)
        try """
        <svg xmlns="http://www.w3.org/2000/svg" width="10" height="10"><script>\(script)</script></svg>
        """.write(to: drawing, atomically: true, encoding: .utf8)
        try await body(folder, page, drawing)
    }

    /// What the document in `page` recorded about the PNG beside it, once it has recorded anything.
    private func sibling(in page: BrowserPage) async -> String? {
        var result: String?
        _ = await waitUntil {
            result = (try? await page.evaluateJavaScript("document.documentElement.getAttribute('data-sibling')")) as? String
            return result?.isEmpty == false
        }
        return result
    }

    @Test(arguments: BrowserEngine.allCases)
    func aPageOpenedFromAFileAddressCannotReadItsNeighbours(engine: BrowserEngine) async throws {
        try await withSite { _, page, drawing in
            for document in [page, drawing] {
                try await withTab(engine: engine) { tab in
                    tab.load(document)

                    #expect(await sibling(in: tab.page) == "blocked", "\(document.lastPathComponent) read the PNG beside it, engine \(engine)")
                }
            }
        }
    }

    /// The probe sees a neighbour when it is allowed to, so "blocked" above is the scope and not a broken fixture.
    @Test func theSameDocumentsReadTheirNeighbourWhenTheFolderIsAllowed() async throws {
        try await withSite { folder, page, drawing in
            for document in [page, drawing] {
                try await withTab(engine: .webKit) { tab in
                    tab.page.loadFileURL(document, allowingReadAccessTo: folder)

                    #expect(await sibling(in: tab.page) == "read", "\(document.lastPathComponent) could not read the PNG beside it")
                }
            }
        }
    }

    @Test func aTypedFileAddressOpensThePageWithoutItsNeighbours() async throws {
        try await withSite { _, page, _ in
            let model = BrowserModel(database: .temporary())
            let tab = model.newTab()
            let host = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                styleMask: .borderless, backing: .buffered, defer: false)
            host.isReleasedWhenClosed = false
            host.contentView = tab.page
            host.orderBack(nil)
            defer {
                host.contentView = nil
                host.close()
            }
            let view = tab.page

            model.handleAddressInput(page.absoluteString)

            #expect(await sibling(in: view) == "blocked")
            tab.detach()
            await view.close()
        }
    }

    @Test(arguments: BrowserEngine.allCases)
    func aDraggedFileOpensWithoutItsNeighbours(engine: BrowserEngine) async throws {
        try await withSite { _, page, drawing in
            for document in [page, drawing] {
                try await withTab(engine: engine) { tab in
                    let provider = NSItemProvider(object: document as NSURL)

                    #expect(ContentNavBar.openDropped([provider]) { tab.load($0) })

                    #expect(await sibling(in: tab.page) == "blocked", "\(document.lastPathComponent) read the PNG beside it, engine \(engine)")
                }
            }
        }
    }

    @Test func droppingNothingOpensNothing() {
        #expect(!ContentNavBar.openDropped([]) { _ in Issue.record("nothing was dropped") })
    }
}
