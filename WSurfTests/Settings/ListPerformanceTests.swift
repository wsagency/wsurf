// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import SwiftUI
import WebKit
import XCTest

@testable import WSurf

// The long lists outside the sidebar, hosted the way their pages lay them out: Website data, What's New, Downloads, and the favicon
// lookup that every site row makes. Each case is one thing a person does on one of those screens: scroll the list down, update one row,
// remove one site. Nothing here is real data. The budgets in Tools/check-performance.sh are far above what a healthy build takes and
// far below what these screens took when every row was built, drawn and looked up again on each change.
//
// XCTest owns and runs one instance serially. Sendable lets its synchronous measurement callback enter the app target's main-actor
// boundary.
nonisolated final class ListPerformanceTests: XCTestCase, @unchecked Sendable {
    // MARK: Hosting

    /// A window as tall as `height` points, so a lazy list lays out the screens that many points down, as scrolling would.
    @MainActor
    private static func mount(_ view: some View, width: CGFloat = 760, height: CGFloat) -> (host: NSHostingView<AnyView>, window: NSWindow) {
        let host = NSHostingView(rootView: AnyView(view))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        return (host, window)
    }

    @MainActor
    private static func settle(_ host: NSView) {
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
    }

    /// Runs `work` to its end from this synchronous test (`VaultScalePerformanceTests.finish`): the test is not an actor job itself, so
    /// the wait spins the run loop that WebKit's replies and the main-actor steps need.
    @MainActor
    private func finish(_ work: @escaping @MainActor () async throws -> Void) {
        let done = XCTestExpectation(description: "async step")
        Task {
            do {
                try await work()
            } catch {
                XCTFail("\(error)")
            }
            done.fulfill()
        }
        XCTAssertEqual(XCTWaiter().wait(for: [done], timeout: 120), .completed)
    }

    private nonisolated final class Counter: @unchecked Sendable {
        var value = 0
    }

    // MARK: Website data

    /// The rows of Settings › Privacy › Website data (the page's own components), 600 sites with no icon on disk, laid out four
    /// screens deep in a fresh window every run. Each row is a site icon looked up in the profile's favicon cache, two lines of text
    /// and a Remove button.
    func testLayingOutALongListOfSites() {
        MainActor.assumeIsolated {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wsurf-list-favicons-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let favicons = FaviconLoader(cacheDirectory: directory)
            favicons.schemeOverride = .light
            let entries = (0..<600).map { index in
                WebsiteData.Entry(
                    displayName: "site-\(index).example",
                    types: [WKWebsiteDataTypeCookies, WKWebsiteDataTypeLocalStorage, WKWebsiteDataTypeDiskCache]
                )
            }
            let appeared = Counter()
            let page = ScrollView {
                VStack(alignment: .leading, spacing: SettingsMetrics.sectionSpacing) {
                    SettingsSection(title: "Stored on this Mac", symbol: "internaldrive", isLongList: true) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            SiteRow(host: entry.displayName, summary: entry.summary) {
                                SettingsButton(title: "Remove…", isDestructive: true) {}
                            }
                            .onAppear { appeared.value += 1 }
                            .separated(above: index > 0)
                        }
                    }
                }
                .frame(maxWidth: SettingsMetrics.detailWidth, alignment: .leading)
                .padding(.horizontal, SettingsMetrics.pageInset)
                .padding(.top, 34)
                .frame(maxWidth: .infinity)
            }
            .scrollContentBackground(.hidden)
            .environment(\.profileFavicons, favicons)

            measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: .budgeted) {
                appeared.value = 0
                let (host, window) = Self.mount(page, height: 2_800)
                Self.settle(host)
                window.contentView = nil
                window.close()
                XCTAssertGreaterThan(appeared.value, 10, "the list laid out its first screens")
                XCTAssertLessThan(appeared.value, entries.count, "the list is lazy: it does not lay out all 600 rows")
            }
        }
    }

    private static func cookie(for host: String) -> HTTPCookie? {
        HTTPCookie(properties: [.domain: host, .path: "/", .name: "session", .value: "1"])
    }

    /// Removing three sites, one after another, from the Website data list of 1,500 sites, each with what the page does next to show the
    /// result. The data store is WebKit's own, in memory, so the removal is the real one. Each run removes the first three sites still
    /// listed; afterwards exactly the sites removed are gone and no other.
    func testRemovingASiteFromTheWebsiteDataList() {
        MainActor.assumeIsolated {
            let context = BrowserProfileContext(profile: .privateBrowsing())
            let hosts = (0..<1_500).map { "site-\($0).example" }
            finish {
                for host in hosts {
                    await context.dataStore.httpCookieStore.setCookie(try XCTUnwrap(Self.cookie(for: host)))
                }
            }
            var snapshot = WebsiteData.Snapshot(entries: [])
            finish { snapshot = try await WebsiteData.snapshot(context: context) }
            XCTAssertEqual(snapshot.entries.count, hosts.count)
            var removed: [String] = []

            measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: .budgeted) {
                for _ in 0..<3 {
                    guard let entry = snapshot.entries.first else { return XCTFail("The list ran out of sites.") }
                    removed.append(entry.displayName)
                    finish { try await WebsiteData.remove([entry], of: snapshot, context: context) }
                    snapshot = snapshot.removing([entry])
                }
            }

            XCTAssertGreaterThanOrEqual(removed.count, 18, "every measured run removed three sites")
            XCTAssertEqual(Set(snapshot.entries.map(\.displayName)), Set(hosts).subtracting(removed))
            // What the page shows is what the data store holds: nothing was left behind and nothing else went.
            finish {
                let counted = try await WebsiteData.snapshot(context: context)
                XCTAssertEqual(Set(counted.entries.map(\.displayName)), Set(hosts).subtracting(removed))
                await context.endPrivateSession()
            }
        }
    }

    // MARK: Favicons

    /// Every site row asks the favicon cache for its icon each time it is drawn. For 1,000 sites that have none, ten passes over
    /// the list: each answer was two failed reads of the cache directory.
    func testAskingForTheIconsOfSitesThatHaveNone() {
        MainActor.assumeIsolated {
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wsurf-list-favicons-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let loader = FaviconLoader(cacheDirectory: directory)
            loader.schemeOverride = .light
            let hosts = (0..<1_000).map { "no-icon-\($0).example" }

            measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: .budgeted) {
                var found = 0
                for _ in 0..<10 {
                    for host in hosts where loader.cached(for: host) != nil {
                        found += 1
                    }
                }
                XCTAssertEqual(found, 0)
            }
        }
    }

    // MARK: Websites with custom settings

    /// The list on Settings › Websites of every site that has a rule of its own: 1,000 sites with a camera rule, 500 of them allowing
    /// trackers, and 500 with an approved assistant action. Each of those 1,000 extra rules found its site's origins by reading all of them.
    func testIndexingTheSitesWithCustomSettings() {
        MainActor.assumeIsolated {
            let file = URL.temporaryDirectory.appending(path: "ListPerformanceTests-\(UUID().uuidString).json")
            let permissions = SitePermissions(storageURL: file, persists: false)
            let hosts = (0..<1_000).map { "site-\($0).example" }
            for host in hosts {
                permissions.set(.allow, for: "https://\(host)", .camera)
            }
            let exempt = Set(hosts.prefix(500))
            let grants = hosts.suffix(500).map { (host: $0, categories: [SensitiveAction.Category.purchase]) }

            measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: .budgeted) {
                let entries = SiteSettingsIndex.entries(permissions: permissions, grantsByHost: grants, exemptHosts: exempt)
                XCTAssertEqual(entries.count, hosts.count)
                XCTAssertEqual(entries.first?.host, "site-0.example")
            }
        }
    }

    // MARK: Downloads

    #if DEBUG
    /// Forty progress updates of the one download that is running among 300 finished ones, each drawn: the other rows have not changed
    /// and should not be built again.
    func testUpdatingOneDownloadInALongList() {
        MainActor.assumeIsolated {
            let browser = BrowserModel(database: .temporary())
            defer { browser.cancelPendingSave() }
            let downloads = DownloadManager(persists: false)
            downloads.stage((0..<300).map { index in
                StageSet.StagedDownload(
                    filename: "report-\(index).pdf",
                    host: "host-\(index % 40).example",
                    bytes: 4_000_000 + Int64(index),
                    finished: index != 0
                )
            })
            browser.downloads = downloads
            guard let running = downloads.items.first(where: \.isRunning)?.id else { return XCTFail("The staged list has no running download.") }
            let (host, window) = Self.mount(DownloadsView(browser: browser), height: 1_400)
            defer { window.close() }
            Self.settle(host)
            var tick: Int64 = 0

            measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: .budgeted) {
                for _ in 0..<40 {
                    tick += 1
                    downloads.noteProgress(received: tick * 50_000, expected: 4_000_000, for: running)
                    // The run loop gets its turn here, which is when SwiftUI applies the change.
                    RunLoop.current.run(until: Date().addingTimeInterval(0.001))
                    Self.settle(host)
                }
            }
            XCTAssertEqual(downloads.items.filter(\.isRunning).count, 1)
            XCTAssertEqual(downloads.items.first(where: \.isRunning)?.bytesReceived, tick * 50_000)
        }
    }
    #endif

    // MARK: What's New

    private static func releases(count: Int) throws -> [GitHubRelease] {
        let body = """
            ## Highlights

            - The sidebar keeps its place when you switch windows, and a long list of tabs scrolls without stalling.
            - Settings › Privacy › Website data removes a site in one step, with a spinner on its row.
            - Downloads, History and What's New open faster when the list is long.

            ### Fixed

            - A pinned page now comes back after a restart. See [the guide](https://example.com/guide) for the details.
            - The address bar no longer loses focus when a page finishes loading in the background tab.
            - Pasting a very long line into the assistant no longer freezes the window for a moment.
            - Importing bookmarks from another browser keeps the folder order and the original dates.

            ### Changed

            1. The default theme is a little less bright in the dark appearance.
            2. The update check runs at most once an hour, and never on a metered connection.
            """
        let json: [[String: Any]] = (0..<count).map { index in
            [
                "tag_name": "v0.1.\(count - index)",
                "name": "WSurf 0.1.\(count - index)",
                "body": body,
                "html_url": "https://example.com/releases/\(count - index)",
                "published_at": "2026-10-\(String(format: "%02d", 28 - index % 27))T08:00:00Z",
            ]
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([GitHubRelease].self, from: JSONSerialization.data(withJSONObject: json))
    }

    /// The Release Notes page with 40 published releases, each with a page of notes, laid out four screens deep in a fresh window every
    /// run.
    func testLayingOutManyReleaseNotes() throws {
        try MainActor.assumeIsolated {
            let releases = try Self.releases(count: 40)
            let list = DestinationPage {
                Text(verbatim: "Release Notes")
            } content: {
                ReleaseNotesList(releases: releases, isRunning: { $0.version == "0.1.40" })
            }

            measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: .budgeted) {
                let (host, window) = Self.mount(list, height: 2_800)
                Self.settle(host)
                window.contentView = nil
                window.close()
            }
        }
    }
}
