// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import AppKit
import Foundation
import GRDB
import Testing
import WebKit

@testable import WSurf

@MainActor
@Suite(.serialized, .boundedWebViews)
struct BrowserSmokeTests {

    private func permissions(_ name: String) -> SitePermissions {
        SitePermissions(
            storageURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("\(name)-\(UUID().uuidString).json")
        )
    }

    private func page(using dataStore: WKWebsiteDataStore) -> WKWebView {
        let configuration = WebViewPool.makeConfiguration()
        configuration.websiteDataStore = dataStore
        return WKWebView(
            frame: CGRect(x: 0, y: 0, width: 800, height: 600),
            configuration: configuration
        )
    }

    @Test func navigationHistoryPermissionsAndAgentHandoffStayConnected() async throws {
        let server = try await HTTPFixtureServer.start(routes: [
            "/first": .html("""
                <title>First fixture</title>
                <h1>First page</h1>
                <a href="/second">Next page</a>
                """),
            "/second": .html("<title>Second fixture</title><h1>Second page</h1>"),
        ])
        let firstURL = try server.url("/first")
        let secondURL = try server.url("/second")
        let permissions = SitePermissions(
            storageURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("BrowserSmoke-\(UUID().uuidString).json")
        )
        let browser = BrowserModel(database: .temporary(), sitePermissions: permissions)
        let tab = browser.newTab(url: firstURL)

        #expect(await PageSettle.untilIdle(tab.page, timeout: .seconds(30)))
        #expect(await waitUntil { tab.urlString == firstURL.absoluteString })
        #expect(await waitUntil { tab.title == "First fixture" })

        tab.assistantAccess.persistsAnswers = false
        tab.assistantAccess.pageChanged(url: firstURL)
        tab.assistantAccess.set(.control)
        let toolkit = AgentToolkit(
            browser: browser,
            media: MediaCenter(),
            log: ConversationLog(database: .temporary())
        )
        toolkit.beginTask(AgentTaskContext(id: UUID(), tabID: tab.id))

        let observation = await toolkit.readPage()
        #expect(observation.contains("First page"))
        #expect(observation.contains(secondURL.absoluteString))

        let click = await toolkit.clickOnPage(ref: 0, label: "Next page")
        #expect(click.contains("Second page"))
        #expect(await waitUntil { tab.urlString == secondURL.absoluteString && tab.canGoBack })
        #expect(await waitUntil { tab.title == "Second fixture" })

        let back = await toolkit.goBack()
        #expect(back.contains("First page"))
        #expect(await waitUntil { tab.urlString == firstURL.absoluteString && tab.canGoForward })

        tab.goForward()
        #expect(await PageSettle.untilIdle(tab.page, timeout: .seconds(30)))
        #expect(await waitUntil { tab.urlString == secondURL.absoluteString && tab.canGoBack })
    }

    @Test func submittingARealFormNavigatesWithoutCrashing() async throws {
        let server = try await HTTPFixtureServer.start(routes: [
            "/form": .html("<title>Form</title><form action='/submitted'><input name='name' value='Ada'><button>Send</button></form>"),
            "/submitted": .html("<title>Submitted</title>Saved"),
        ])
        let browser = BrowserModel(database: .temporary(), sitePermissions: permissions("FormSmoke"))
        let tab = browser.newTab(url: try server.url("/form"))
        defer { browser.closeAllTabs() }
        try #require(await waitUntil { tab.title == "Form" && !tab.isLoading })
        _ = try await tab.page.evaluateJavaScript("document.forms[0].requestSubmit(); true")
        try #require(await waitUntil { tab.title == "Submitted" && !tab.isLoading })
        #expect(tab.pendingTransition == .formSubmit)
        #expect(tab.urlString.hasPrefix(try server.url("/submitted").absoluteString))
    }

    @Test func relaunchRestoresALiveWebKitHistoryStack() async throws {
        let server = try await HTTPFixtureServer.start(routes: [
            "/one": .html("<title>Restored one</title><h1>One</h1>"),
            "/two": .html("<title>Restored two</title><h1>Two</h1>"),
        ])
        let one = try server.url("/one")
        let two = try server.url("/two")
        let database = AppDatabase.temporary()
        let original = BrowserModel(database: database, sitePermissions: permissions("LaunchSmoke"))
        let tab = original.newTab(url: one)

        #expect(await waitUntil(timeout: .seconds(10)) { tab.title == "Restored one" })
        tab.load(two)
        #expect(await waitUntil(timeout: .seconds(10)) {
            tab.urlString == two.absoluteString && tab.title == "Restored two" && tab.canGoBack
        })
        original.saveBlocking()

        let relaunched = BrowserModel(database: database, sitePermissions: permissions("LaunchSmoke"))
        relaunched.restoreSession()
        let restored = try #require(relaunched.tabs.first { $0.id == tab.id })

        #expect(relaunched.activeTabID == restored.id)
        #expect(await waitUntil(timeout: .seconds(10)) {
            restored.urlString == two.absoluteString
                && restored.title == "Restored two"
                && restored.canGoBack
        })

        restored.goBack()
        #expect(await waitUntil(timeout: .seconds(10)) {
            restored.urlString == one.absoluteString
                && restored.title == "Restored one"
                && restored.canGoForward
        })
    }

    @Test func aWebKitDownloadReachesItsIsolatedDestination() async throws {
        let payload = Data("fixture download\n".utf8)
        let server = try await HTTPFixtureServer.start(routes: [
            "/file": .download(payload, filename: "fixture.txt"),
        ])
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wsurf-download-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let downloads = DownloadManager(destinationFolder: folder, asksWhereToSave: false)
        let browser = BrowserModel(
            database: .temporary(),
            sitePermissions: permissions("DownloadSmoke"),
            downloads: downloads
        )
        let tab = browser.newTab(url: try server.url("/file"))

        #expect(await waitUntil(timeout: .seconds(10)) {
            downloads.items.first?.state == .finished
        })
        let item = try #require(downloads.items.first)
        let destination = try #require(item.destination)

        #expect(item.filename == "fixture.txt")
        #expect(item.sourceTabID == tab.id)
        #expect(destination.deletingLastPathComponent() == folder)
        #expect(try Data(contentsOf: destination) == payload)
    }

    @Test func attachmentPolicyUsesTheDispositionTokenOfSuccessfulHTTPResponses() throws {
        let url = URL(string: "https://example.test/sample.mp4")!
        let cases: [(Int, String?, Bool)] = [
            (200, "attachment", true),
            (200, "ATTACHMENT; filename=\"sample.mp4\"", true),
            (200, "attachment; filename*=UTF-8''sample.mp4", true),
            (206, " \tAtTaChMeNt \r\n ; filename=\"sample; clip.mp4\"", true),
            (200, "inline; filename=attachment", false),
            (200, "form-data; name=\"attachment\"", false),
            (200, "attachment-extra", false),
            (200, ";attachment", false),
            (200, "\u{00A0}attachment", false),
            (200, "", false),
            (200, nil, false),
            (302, "attachment", false),
            (403, "attachment", false),
            (404, "attachment", false),
            (500, "attachment", false),
        ]
        for (status, disposition, expected) in cases {
            let headers = disposition.map { ["cOnTeNt-dIsPoSiTiOn": $0] }
            let response = try #require(HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
            ))
            #expect(TabNavigationDelegate.isAttachment(response) == expected, "HTTP \(status), disposition \(disposition ?? "(absent)")")
        }
        let nonHTTP = URLResponse(url: URL(fileURLWithPath: "/sample.mp4"), mimeType: "video/mp4", expectedContentLength: 0, textEncodingName: nil)
        #expect(!TabNavigationDelegate.isAttachment(nonHTTP))
    }

    enum VideoDownloadNavigation: CaseIterable {
        case mainFrame, hiddenFrame, emptyPopup, redirectedPopup, committedPopup, committedPopupFrame, newTab
    }

    @Test(arguments: VideoDownloadNavigation.allCases)
    func webKitDownloadsAnMP4Attachment(navigation: VideoDownloadNavigation) async throws {
        let payload = try videoSample()
        let server = try await HTTPFixtureServer.start(routes: [
            "/page": .html("<title>Opener</title>"),
            "/popup": .html("""
                <title>Popup</title>
                <a id="download" href="/attachment">Download anyway</a>
                <a id="frame-download" href="/attachment" target="download-frame">Download in frame</a>
                <iframe hidden name="download-frame"></iframe>
                """),
            "/redirect": .init(status: "302 Found", headers: ["Location": "/attachment"], body: Data()),
            "/attachment": videoResponse(payload, disposition: "attachment"),
        ])
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("wsurf-video-download-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let closesPopup = navigation == .emptyPopup || navigation == .redirectedPopup
        let downloads = DownloadManager(destinationFolder: folder, asksWhereToSave: closesPopup, persists: false)
        let browser = BrowserModel(
            database: .temporary(), sitePermissions: permissions("VideoDownload"), downloads: downloads
        )
        defer { browser.closeAllTabs() }

        let pageURL = try server.url("/page")
        let attachmentURL = try server.url("/attachment")
        let opener = browser.newTab(url: pageURL)
        try #require(await waitUntil { opener.title == "Opener" })
        browser.setPopups(.allow, for: opener)

        var source = opener
        switch navigation {
        case .mainFrame:
            opener.load(attachmentURL)
        case .hiddenFrame:
            _ = try await opener.page.evaluateJavaScript("""
                const frame = document.createElement('iframe');
                frame.hidden = true;
                frame.src = '/attachment';
                document.body.append(frame);
                true;
                """)
        case .emptyPopup, .redirectedPopup:
            let window = NSWindow()
            browser.onTabOpened = { tab in window.contentView?.addSubview(tab.page) }
            browser.onTabClosed = { tab in tab.liveView?.removeFromSuperview() }
            downloads.selectSaveLocation = { filename, folder, presentingWindow in
                #expect(presentingWindow === window)
                return folder.appendingPathComponent(filename)
            }
            let path = navigation == .redirectedPopup ? "/redirect" : "/attachment"
            _ = try await opener.page.evaluateJavaScript("window.open('\(path)'); true")
        case .committedPopup, .committedPopupFrame:
            _ = try await opener.page.evaluateJavaScript("window.open('/popup'); true")
            try #require(await waitUntil { browser.activeTab?.title == "Popup" })
            source = try #require(browser.activeTab)
            let link = navigation == .committedPopup ? "download" : "frame-download"
            _ = try await source.page.evaluateJavaScript("document.getElementById('\(link)').click(); true")
        case .newTab:
            source = browser.newTab(url: attachmentURL, byPerson: true)
        }

        try #require(await waitUntil(timeout: .seconds(10)) { downloads.items.first?.state == .finished })
        let item = try #require(downloads.items.first)
        let destination = try #require(item.destination)
        #expect(downloads.items.count == 1)
        #expect(item.filename == "sample.mp4")
        #expect(try Data(contentsOf: destination) == payload)
        if closesPopup {
            #expect(item.sourceTabID != nil && item.sourceTabID != opener.id)
            #expect(browser.tabs.map(\.id) == [opener.id])
            #expect(browser.activeTabID == opener.id)
        } else {
            #expect(item.sourceTabID == source.id)
            #expect(browser.tabs.contains { $0 === source })
            #expect(source.committedURL != attachmentURL)
        }
        if navigation == .committedPopup || navigation == .committedPopupFrame {
            #expect(source.committedURL == (try server.url("/popup")))
            #expect(source.title == "Popup")
            #expect(browser.activeTabID == source.id)
        }
    }

    @Test func aDownloadPopupStaysOpenWhenItsOpenerClosed() async throws {
        let gate = ResponseGate()
        let payload = try videoSample()
        var attachment = videoResponse(payload, disposition: "attachment")
        attachment.gate = gate
        let server = try await HTTPFixtureServer.start(routes: [
            "/page": .html("<title>Opener</title>"), "/attachment": attachment,
        ])
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("wsurf-download-\(UUID())", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let downloads = DownloadManager(destinationFolder: folder, asksWhereToSave: false, persists: false)
        let browser = BrowserModel(database: .temporary(), sitePermissions: permissions("LastPopup"), downloads: downloads)
        defer {
            gate.open()
            browser.closeAllTabs()
        }
        let opener = browser.newTab(url: try server.url("/page"))
        try #require(await waitUntil { opener.title == "Opener" })
        browser.setPopups(.allow, for: opener)
        _ = try await opener.page.evaluateJavaScript("window.open('/attachment'); true")
        try #require(await waitUntil { gate.requestCount > 0 })
        let popup = try #require(browser.activeTab)
        try #require(popup !== opener)
        try #require(browser.tabs.count == 2)

        browser.close(opener)
        try #require(browser.tabs.map(\.id) == [popup.id])
        gate.open()

        try #require(await waitUntil { downloads.items.first?.state == .finished })
        let item = try #require(downloads.items.first)
        #expect(item.sourceTabID == popup.id)
        #expect(try Data(contentsOf: #require(item.destination)) == payload)
        #expect(browser.tabs.map(\.id) == [popup.id])
        #expect(browser.activeTabID == popup.id)
    }

    @Test func webKitDisplaysAnInlineMP4() async throws {
        let server = try await HTTPFixtureServer.start(routes: [
            "/inline": videoResponse(try videoSample(), disposition: "inline"),
        ])
        let downloads = DownloadManager(persists: false)
        let browser = BrowserModel(
            database: .temporary(), sitePermissions: permissions("InlineVideo"), downloads: downloads
        )
        defer { browser.closeAllTabs() }
        let url = try server.url("/inline")
        let tab = browser.newTab(url: url)

        try #require(await waitUntil { tab.committedURL == url && !tab.isLoading })
        let showsPlayer = try await tab.page.evaluateJavaScript("""
            const video = document.querySelector('video');
            document.contentType === 'video/mp4' && video?.controls && video.src === location.href;
            """)
        #expect(showsPlayer as? Bool == true)
        #expect(downloads.items.isEmpty)
    }

    private final class VideoFixtureBundle {}

    private func videoSample() throws -> Data {
        let url = try #require(Bundle(for: VideoFixtureBundle.self).url(
            forResource: "attachment-sample", withExtension: "mp4"
        ))
        return try Data(contentsOf: url)
    }

    private func videoResponse(_ payload: Data, disposition: String) -> HTTPFixtureServer.Response {
        .init(
            status: "200 OK",
            headers: [
                "Content-Type": "video/mp4",
                "Content-Disposition": "\(disposition); filename=\"sample.mp4\"",
            ],
            body: payload
        )
    }

    @Test func aFreshPrivateSessionHasNoPriorTabsCookiesOrAgentLog() async throws {
        let server = try await HTTPFixtureServer.start(routes: [
            "/set": .html(
                "<title>Private state</title><h1>Private</h1>",
                headers: ["Set-Cookie": "privateToken=secret; Path=/; SameSite=Lax"]
            ),
            "/read": .html("<title>Fresh private state</title><h1>Fresh</h1>"),
        ])

        do {
            let session = PrivateBrowsingSession()
            let store = permissions("PrivateSmoke")
            let browser = BrowserModel(database: session.database, sitePermissions: store)
            browser.adopt(database: session.database, sitePermissions: store, privately: true)
            let tab = browser.newTab(
                url: try server.url("/set"),
                adopting: page(using: session.dataStore)
            )

            #expect(await waitUntil(timeout: .seconds(10)) { tab.title == "Private state" })
            let cookie = try await tab.page.evaluateJavaScript("document.cookie") as? String
            #expect(cookie?.contains("privateToken=secret") == true)

            let log = ConversationLog(database: session.database)
            let task = log.beginTask("Private request", tabID: tab.id)
            log.completeTask(task, response: "Private response")
            browser.saveBlocking()

            let savedTabs = try await session.database.writer.read { database in
                try Int.fetchOne(database, sql: "SELECT COUNT(*) FROM sessionTab")
            }
            #expect(savedTabs == 1)
            #expect(!log.traces.isEmpty)
            browser.closeAllTabs()
        }

        let fresh = PrivateBrowsingSession()
        let freshPermissions = permissions("PrivateSmoke")
        let browser = BrowserModel(database: fresh.database, sitePermissions: freshPermissions)
        browser.adopt(database: fresh.database, sitePermissions: freshPermissions, privately: true)
        browser.restoreSession()
        #expect(browser.tabs.isEmpty)
        #expect(ConversationLog(database: fresh.database).traces.isEmpty)

        let tab = browser.newTab(
            url: try server.url("/read"),
            adopting: page(using: fresh.dataStore)
        )
        #expect(await waitUntil(timeout: .seconds(10)) { tab.title == "Fresh private state" })
        let cookie = try await tab.page.evaluateJavaScript("document.cookie") as? String
        #expect(cookie?.isEmpty == true)
    }

    @Test func extensionEnablementLoadsAndUnloadsItsWebKitContext() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wsurf-extension-smoke-\(UUID().uuidString)", isDirectory: true)
        let id = "smoke-extension"
        let package = directory.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data(
            #"{"manifest_version":3,"name":"Smoke Extension","version":"1.0"}"#.utf8
        ).write(to: package.appendingPathComponent("manifest.json"))
        defer { try? FileManager.default.removeItem(at: directory) }

        let library = ExtensionLibrary(baseDirectory: directory)
        library.recordInstall(id: id)
        let browser = BrowserModel(database: .temporary())
        let manager = ExtensionManager(profile: .original(), library: library)
        manager.register(browser: browser)
        defer { manager.unregister(browser: browser) }

        await manager.start()
        #expect(manager.installed.first?.displayName == "Smoke Extension")
        #expect(manager.contexts[id] != nil)

        manager.setEnabled(false, id: id)
        #expect(manager.installed.first?.enabled == false)
        #expect(manager.contexts[id] == nil)
        let disabledLibrary = ExtensionLibrary(baseDirectory: directory)
        disabledLibrary.load()
        #expect(disabledLibrary.records.first?.enabled == false)

        manager.setEnabled(true, id: id)
        #expect(await waitUntil { manager.contexts[id] != nil })
        #expect(manager.installed.first?.enabled == true)
        let enabledLibrary = ExtensionLibrary(baseDirectory: directory)
        enabledLibrary.load()
        #expect(enabledLibrary.records.first?.enabled == true)

        manager.setEnabled(false, id: id)
    }
}
