// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import Testing

@testable import WSurf

/// What a finished download offers: Preview, Open With and Open in WSurf. The workspace is injected, so no test
/// asks the system which apps are installed or opens anything.
@MainActor
struct DownloadOpeningTests {
    private func app(_ name: String) -> URL {
        URL(fileURLWithPath: "/Applications/\(name).app", isDirectory: true)
    }

    private func workspace(
        apps: [URL], preferred: URL?, opened: @escaping (URL, URL) -> Void = { _, _ in }
    ) -> DownloadWorkspace {
        DownloadWorkspace(
            urlsForApplications: { _ in apps },
            urlForApplication: { _ in preferred },
            open: opened,
            ownApplication: app("WSurf")
        )
    }

    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// A finished download whose file is really on disk, unless `exists` is false.
    private func finished(_ name: String, in folder: URL, exists: Bool = true) throws -> DownloadManager.Item {
        let file = folder.appendingPathComponent(name)
        if exists {
            try Data("x".utf8).write(to: file)
        }
        var item = DownloadManager.Item(id: UUID(), filename: name, source: "example.com", sourceTabID: nil)
        item.destination = file
        item.state = .finished
        return item
    }

    // MARK: - Open With

    @Test func openWithListsTheDefaultAppFirstThenTheRestByName() {
        let file = URL(fileURLWithPath: "/tmp/Report.pdf")
        let apps = workspace(
            apps: [app("Safari"), app("Preview"), app("Adobe Acrobat"), app("Xcode")],
            preferred: app("Preview")
        ).applications(toOpen: file)

        #expect(apps.map(\.name) == ["Preview", "Adobe Acrobat", "Safari", "Xcode"])
        #expect(apps.map(\.isDefault) == [true, false, false, false])
        #expect(apps.first?.url == app("Preview"))
    }

    @Test func openWithLeavesOutWSurfItself() {
        let apps = workspace(apps: [app("WSurf"), app("Safari")], preferred: app("WSurf"))
            .applications(toOpen: URL(fileURLWithPath: "/tmp/page.html"))

        #expect(apps.map(\.name) == ["Safari"])
        #expect(!apps.contains { $0.isDefault })
    }

    @Test func openWithIsEmptyWhenNothingCanOpenTheFile() {
        let apps = workspace(apps: [], preferred: nil).applications(toOpen: URL(fileURLWithPath: "/tmp/data.xyz"))

        #expect(apps.isEmpty)
    }

    @Test func openWithAsksAboutTheFileItWasGiven() {
        var asked: [URL] = []
        let file = URL(fileURLWithPath: "/tmp/Report.pdf")
        let system = DownloadWorkspace(
            urlsForApplications: { file in
                asked.append(file)
                return []
            },
            urlForApplication: { file in
                asked.append(file)
                return nil
            },
            open: { _, _ in }
        )

        _ = system.applications(toOpen: file)
        #expect(asked == [file, file])
    }

    @Test func choosingAnAppOpensThatFileWithThatApp() throws {
        var opened: [(file: URL, app: URL)] = []
        let file = URL(fileURLWithPath: "/tmp/Report.pdf")
        let system = workspace(apps: [app("Safari")], preferred: nil) { opened.append((file: $0, app: $1)) }

        let safari = try #require(system.applications(toOpen: file).first)
        system.open(file, safari.url)
        #expect(opened.count == 1)
        #expect(opened.first?.file == file)
        #expect(opened.first?.app == app("Safari"))
    }

    // MARK: - Open in WSurf

    @Test(arguments: [
        "Report.pdf", "REPORT.PDF", "photo.png", "photo.jpg", "photo.JPEG", "anim.gif", "photo.webp",
        "icon.ico", "scan.bmp", "notes.txt",
    ])
    func theBrowserRendersTheseTypes(_ name: String) {
        #expect(DownloadWorkspace.rendersInBrowser(URL(fileURLWithPath: "/tmp/\(name)")))
    }

    @Test(arguments: [
        "page.html", "page.htm", "PAGE.HTML", "page.xhtml", "logo.svg", "LOGO.SVG", "logo.svgz",
        "archive.zip", "installer.dmg", "WSurf.app", "movie.mp4", "song.mp3", "letter.docx", "sheet.xlsx",
        "notes.md", "main.swift", "data.json", "photo.heic", "scan.tiff", "setup.pkg", "run.sh", "Download", "",
    ])
    func scriptableAndOtherTypesAreLeftToOtherApps(_ name: String) {
        #expect(!DownloadWorkspace.rendersInBrowser(URL(fileURLWithPath: "/tmp/\(name)")))
    }

    @Test(arguments: ["Report.pdf", "photo.png", "photo.jpg", "anim.gif", "photo.webp", "icon.ico", "scan.bmp", "notes.txt"])
    func aDownloadOpenedInATabMayReadOnlyItself(_ name: String) {
        let file = URL(fileURLWithPath: "/Users/someone/Downloads/\(name)")

        #expect(FileAccessScope.readAccess(for: file) == file)
    }

    // MARK: - What is available

    @Test func aFinishedFileOnDiskCanBePreviewedAndOpenedInATab() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let item = try finished("Report.pdf", in: folder)

        #expect(item.availableFile == item.destination)
        #expect(item.browserFile == item.destination)
    }

    @Test func aFileThatOnlyOtherAppsOpenCanBePreviewedButNotOpenedInATab() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let item = try finished("archive.zip", in: folder)

        #expect(item.availableFile == item.destination)
        #expect(item.browserFile == nil)
    }

    @Test func aDownloadThatIsNotFinishedOffersNeither() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let states: [DownloadManager.Item.State] = [
            .running, .cancelled, .failed("Network error"), .interrupted("Download paused"),
        ]
        for state in states {
            var item = try finished("Report.pdf", in: folder)
            item.state = state
            #expect(item.availableFile == nil)
            #expect(item.browserFile == nil)
        }
    }

    @Test func aFileMovedOrDeletedAfterwardsOffersNeither() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let gone = try finished("Report.pdf", in: folder, exists: false)
        #expect(gone.availableFile == nil)
        #expect(gone.browserFile == nil)

        var unplaced = try finished("Report.pdf", in: folder)
        unplaced.destination = nil
        #expect(unplaced.availableFile == nil)
    }

    @Test func lookingAtAFileLeavesItsQuarantineAlone() throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let item = try finished("Report.pdf", in: folder)
        var file = try #require(item.destination)
        var values = URLResourceValues()
        values.quarantineProperties = [
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload,
            kLSQuarantineAgentNameKey as String: "WSurf",
        ]
        try file.setResourceValues(values)

        _ = item.availableFile
        _ = item.browserFile
        _ = workspace(apps: [app("Preview")], preferred: app("Preview")).applications(toOpen: file)

        let kept = try file.resourceValues(forKeys: [.quarantinePropertiesKey]).quarantineProperties
        #expect(kept?[kLSQuarantineAgentNameKey as String] as? String == "WSurf")
        #expect(kept?[kLSQuarantineTypeKey as String] as? String == kLSQuarantineTypeWebDownload as String)
    }
}

/// "Open in WSurf" opens a tab for the types a tab renders, and for nothing else.
@MainActor
@Suite(.serialized, .boundedWebViews)
struct DownloadOpenInTabTests {
    private func finished(_ name: String, in folder: URL) throws -> DownloadManager.Item {
        let file = folder.appendingPathComponent(name)
        try Data("x".utf8).write(to: file)
        var item = DownloadManager.Item(id: UUID(), filename: name, source: "example.com", sourceTabID: nil)
        item.destination = file
        item.state = .finished
        return item
    }

    @Test func aRenderableFileOpensInANewActiveTab() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = BrowserModel(database: .temporary())

        let item = try finished("Report.pdf", in: folder)
        let tab = try #require(model.openDownloadInTab(item))
        #expect(model.tabs.count == 1)
        #expect(model.activeTab === tab)
    }

    @Test func aFileTheBrowserWouldOnlyDownloadOpensNoTab() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = BrowserModel(database: .temporary())

        for name in ["page.html", "page.htm", "logo.svg", "archive.zip", "notes.md", "installer.dmg", "letter.docx"] {
            let item = try finished(name, in: folder)
            #expect(model.openDownloadInTab(item) == nil)
        }
        #expect(model.tabs.isEmpty)
    }

    @Test func aRenderableDownloadThatIsNotFinishedOpensNoTab() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let model = BrowserModel(database: .temporary())
        var item = try finished("Report.pdf", in: folder)
        item.state = .running

        #expect(model.openDownloadInTab(item) == nil)
        #expect(model.tabs.isEmpty)
    }
}
