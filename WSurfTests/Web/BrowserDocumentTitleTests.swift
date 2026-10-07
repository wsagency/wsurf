// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0

import CCef
import CoreGraphics
import Darwin
import Foundation
import MachO
import Testing
import WebKit

@testable import WSurf

@MainActor
@Suite(.serialized, .boundedWebViews)
struct BrowserDocumentTitleTests {
    private func pdf() throws -> Data {
        let data = NSMutableData()
        let consumer = try #require(CGDataConsumer(data: data))
        var bounds = CGRect(x: 0, y: 0, width: 300, height: 200)
        let context = try #require(CGContext(consumer: consumer, mediaBox: &bounds, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 20, y: 20, width: 100, height: 100))
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    @Test(arguments: [BrowserEngine.webKit, .chromium], ["/Quarterly%20Report.pdf", "/download", "/download#page=1"])
    func aPDFUsesItsFilenameAndKeepsItWhenGoingBack(engine: BrowserEngine, path: String) async throws {
        let route = String(path.prefix { $0 != "#" })
        var headers = ["Content-Type": "application/pdf"]
        if route == "/download" {
            headers["Content-Disposition"] = "inline; filename=\"Quarterly Report.pdf\""
        }
        let server = try await HTTPFixtureServer.start(routes: [
            route: .init(status: "200 OK", headers: headers, body: try pdf()),
            "/untitled": .html("<!doctype html><p>Page</p>"),
        ])
        defer { withExtendedLifetime(server) {} }
        let url = try server.url(path)
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: storage) }
        let permissions = SitePermissions(storageURL: storage)
        permissions.setEngine(engine, for: SitePermissions.origin(for: url))
        let tab = BrowserTab(opensBlank: false, privately: true, sitePermissions: permissions, context: BrowserProfileContext(profile: .privateBrowsing()))
        defer { tab.detach() }

        tab.load(url)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tab.page
        window.orderFront(nil)
        defer { window.close() }
        #expect(await settled(tab, at: url))
        #expect(tab.title == "Quarterly Report.pdf")
        #expect(!tab.isShowingStartPage)
        #expect(tab.page.engine == engine)
        #expect(tab.documentFilename(for: url) == "Quarterly Report.pdf")
        tab.customTitle = "My document"
        tab.refreshChrome()
        #expect(tab.title == "My document")
        tab.customTitle = ""

        let website = try server.url("/untitled")
        tab.load(website)
        #expect(await settled(tab, at: website))
        #expect(tab.title == "New Page")

        tab.goBack()
        #expect(await settled(tab, at: url))
        #expect(tab.title == "Quarterly Report.pdf")
        tab.detach()
        await tab.waitForRetirement()
    }

    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func aLocalPDFUsesItsFilename(engine: BrowserEngine) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Local Report.pdf")
        try pdf().write(to: url)
        let tab = BrowserTab(opensBlank: false, context: BrowserProfileContext(profile: .privateBrowsing()))

        defer { tab.detach() }
        if engine == .chromium {
            // File URLs are WebKit by product policy; exercise the CEF response
            // adapter directly without changing that engine-selection policy.
            tab.adopt(BrowserPage(chromium: ChromiumPage(context: tab.context)))
            tab.page.loadFileURL(url, allowingReadAccessTo: directory)
        } else {
            tab.load(url)
        }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tab.page
        window.orderFront(nil)
        defer { window.close() }
        #expect(await settled(tab, at: url))
        #expect(tab.title == "Local Report.pdf")
        #expect(!tab.isShowingStartPage)
        #expect(tab.documentFilename(for: url) == "Local Report.pdf")
        tab.detach()
        await tab.waitForRetirement()
    }

    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func aPDFKeepsItsFilenameAfterSessionRestore(engine: BrowserEngine) async throws {
        let server = try await HTTPFixtureServer.start(routes: [
            "/download": .init(
                status: "200 OK",
                headers: [
                    "Content-Type": "application/pdf",
                    "Content-Disposition": "inline; filename=\"Restored Report.pdf\"",
                ],
                body: try pdf()
            ),
        ])
        defer { withExtendedLifetime(server) {} }
        let url = try server.url("/download")
        let database = AppDatabase.temporary()
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: storage) }
        let permissions = SitePermissions(storageURL: storage)
        permissions.setEngine(engine, for: SitePermissions.origin(for: url))
        let model = BrowserModel(database: database, sitePermissions: permissions)
        let tab = model.newTab(url: url)
        defer { tab.detach() }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tab.page
        window.orderFront(nil)
        defer { window.close() }
        #expect(await settled(tab, at: url))
        #expect(tab.title == "Restored Report.pdf")
        model.saveBlocking()

        let reopened = BrowserModel(database: database, sitePermissions: permissions)
        reopened.restoreSession()
        let restored = try #require(reopened.activeTab)
        defer { restored.detach() }
        window.contentView = restored.page
        #expect(restored.title == "Restored Report.pdf")
        #expect(await waitUntil {
            !restored.isRestoring && restored.page.url == url && !restored.page.isLoading
        })
        #expect(restored.title == "Restored Report.pdf")
        #expect(restored.page.engine == engine)
        #expect(restored.documentFilename(for: url) == "Restored Report.pdf")
        tab.detach()
        restored.detach()
        await tab.waitForRetirement()
        await restored.waitForRetirement()
    }

    @Test func cefResponseCopiesResolvedURLStatusMIMEAndDispositionBeforeRelease() throws {
        try ChromiumRuntime.shared.ensureInitialized()
        // These factories are not trampolined by the pinned CCef shim.
        let path = try #require((0..<_dyld_image_count()).lazy.compactMap { _dyld_get_image_name($0) }
            .first { String(cString: $0).hasSuffix("/Chromium Embedded Framework") })
        let library = try #require(dlopen(path, RTLD_LAZY | RTLD_NOLOAD))
        defer { dlclose(library) }
        let createRequest = unsafeBitCast(
            try #require(dlsym(library, "cef_request_create")),
            to: (@convention(c) () -> UnsafeMutablePointer<cef_request_t>?).self
        )
        let createResponse = unsafeBitCast(
            try #require(dlsym(library, "cef_response_create")),
            to: (@convention(c) () -> UnsafeMutablePointer<cef_response_t>?).self
        )
        let copied: HTTPURLResponse? = try {
            let request = try #require(createRequest())
            let response = try #require(createResponse())
            defer {
                ChromiumInterop.release(UnsafeMutableRawPointer(request))
                ChromiumInterop.release(UnsafeMutableRawPointer(response))
            }
            ChromiumInterop.withString("https://example.test/original") { request.pointee.set_url?(request, $0) }
            ChromiumInterop.withString("https://example.test/resolved") { response.pointee.set_url?(response, $0) }
            response.pointee.set_status?(response, 206)
            ChromiumInterop.withString("application/pdf") { response.pointee.set_mime_type?(response, $0) }
            ChromiumInterop.withString("Content-Disposition") { name in
                ChromiumInterop.withString("inline; filename=\"Resolved Report.pdf\"") { value in
                    response.pointee.set_header_by_name?(response, name, value, 1)
                }
            }
            return ChromiumClient.documentResponse(response, request: request)
        }()
        let response = try #require(copied)
        #expect(response.url?.absoluteString == "https://example.test/resolved")
        #expect(response.statusCode == 206)
        #expect(response.mimeType == "application/pdf")
        #expect(response.suggestedFilename == "Resolved Report.pdf")
        let tab = BrowserTab(opensBlank: false, context: BrowserProfileContext(profile: .privateBrowsing()))
        tab.noteMainFrameResponse(response)
        #expect(tab.documentFilename(for: response.url) == "Resolved Report.pdf")
    }

    @Test func documentResponsesAreAttributedWithoutGuessingFromExtensions() throws {
        let tab = BrowserTab(opensBlank: false, context: BrowserProfileContext(profile: .privateBrowsing()))
        defer { tab.detach() }
        let url = URL(string: "https://example.test/not-a-pdf.pdf")!
        let pdf = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [
            "Content-Type": "application/pdf", "Content-Disposition": "inline; filename=\"Real name.pdf\"",
        ]))
        tab.noteMainFrameResponse(pdf)
        #expect(tab.documentFilename(for: URL(string: "\(url.absoluteString)#page=2")) == "Real name.pdf")
        let html = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                              headerFields: ["Content-Type": "text/html"]))
        tab.noteMainFrameResponse(html)
        #expect(tab.documentFilename(for: url) == nil)
    }

    @Test(arguments: [false, true])
    func chromiumRejectsResponsesFromReplacedRequestsIncludingTheSameURL(nativeArrivesFirst: Bool) throws {
        let responses = ChromiumDocumentResponses()
        let url = URL(string: "https://example.test/document")!
        let old = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [
            "Content-Type": "application/pdf", "Content-Disposition": "inline; filename=\"Old.pdf\"",
        ]))
        let current = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [
            "Content-Type": "application/pdf", "Content-Disposition": "inline; filename=\"Current.pdf\"",
        ]))
        responses.reset()
        responses.reset()
        // Both navigation intents precede the old request's first IO callback.
        #expect(responses.receive(old) == nil)
        #expect(responses.confirm(old, frameID: "main", loaderID: "old") == nil)
        #expect(responses.commit(frameID: "main", loaderID: "current") == nil)
        #expect(responses.confirm(current, frameID: "child", loaderID: "current") == nil)
        if nativeArrivesFirst {
            #expect(responses.receive(current) == nil)
        }
        let confirmed = responses.confirm(current, frameID: "main", loaderID: "current")
        let delivered = nativeArrivesFirst ? confirmed : responses.receive(current)
        #expect(delivered?.suggestedFilename == "Current.pdf")
        #expect(responses.receive(old) == nil)
        responses.reset()
        #expect(responses.receive(old) == nil)
        #expect(responses.commit(frameID: "main", loaderID: "next") == nil)
    }

    @Test func aRetiredPagesQueuedResponseCannotChangeDocumentNames() throws {
        let tab = BrowserTab(context: BrowserProfileContext(profile: .privateBrowsing()))
        let responseHandler = try #require(tab.page.onMainFrameResponse)
        tab.detach()
        let url = URL(string: "https://example.test/document")!
        let response = URLResponse(url: url, mimeType: "application/pdf",
                                   expectedContentLength: 10, textEncodingName: nil)
        responseHandler(response)
        #expect(tab.documentFilename(for: url) == nil)
    }

    @Test(arguments: [BrowserEngine.webKit, .chromium])
    func subframePDFResponsesDoNotRenameTheMainDocument(engine: BrowserEngine) async throws {
        let server = try await HTTPFixtureServer.start(routes: [
            "/": .html("<title>Main document</title><iframe src='/embedded'></iframe>"),
            "/embedded": .init(status: "200 OK", headers: [
                "Content-Type": "application/pdf", "Content-Disposition": "inline; filename=\"Embedded.pdf\"",
            ], body: try pdf()),
        ])
        defer { withExtendedLifetime(server) {} }
        let url = try server.url()
        let storage = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: storage) }
        let permissions = SitePermissions(storageURL: storage)
        permissions.setEngine(engine, for: SitePermissions.origin(for: url))
        let tab = BrowserTab(opensBlank: false, privately: true, sitePermissions: permissions, context: BrowserProfileContext(profile: .privateBrowsing()))
        defer { tab.detach() }
        tab.load(url)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 800, height: 600),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = tab.page
        window.orderFront(nil)
        defer { window.close() }
        #expect(await settled(tab, at: url))
        #expect(tab.page.engine == engine)
        #expect(tab.title == "Main document")
        #expect(tab.documentFilename(for: try server.url("/embedded")) == nil)
        tab.detach()
        await tab.waitForRetirement()
    }
}
