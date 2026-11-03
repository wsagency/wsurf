// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import SwiftUI
import Testing

@testable import WSurf

/// The Release Notes page, and the "What's New" button that opens it, show WSurf's own notes: the sections of the
/// `CHANGELOG.md` inside the app, from the installed build down. Never the notes inherited from Linen, never the network.
@MainActor
struct ChangelogTests {
    /// The shape of the real file: a comment and the provenance paragraph first, WSurf's sections newest first, then the
    /// Linen history, whose own `## 0.1.1` and `## 0.1.0` share their numbers with WSurf's.
    private let file = """
        <!-- Modified for WSurf by wsagency in 2026; based on Linen by Kavoye. -->
        # Changelog
        This file preserves release notes inherited from the upstream project.
        New WSurf release notes will be added above this provenance record.

        ## 0.1.3 (build 3) — 2026-10-23

        Everything since 0.1.2.

        ### Browsing

        - Third build fix.
          Wrapped onto a second line.

        ## 0.1.2 (build 2) — 2026-10-22

        ### Passwords

        - Second build fix.

        ```
        ## not a heading, it is inside a fence
        ```

        ## 0.1.1 (build 1) — 2026-10-21

        - WSurf’s first build.

        ## 0.1.0 (build 0)

        - Fork baseline, no date.

        ## Upstream Linen history

        ## 0.7.1

        - Linen only: a new tab opens the palette.

        ## 0.1.1

        - Linen only: the first Linen notes.

        ## 0.1.0

        - Linen only: the very first.
        """

    // MARK: - Which sections

    @Test func theInstalledVersionsSectionComesFirstWithTheOlderOnesBelow() {
        let sections = Changelog.sections(in: file, installed: "0.1.2")

        #expect(sections.map(\.version) == ["0.1.2", "0.1.1", "0.1.0"])
        #expect(sections.first?.body.contains("Second build fix.") == true)
        #expect(!sections.contains { $0.version == "0.1.3" }, "the newer build is not part of the installed one's notes")
    }

    @Test func theNewestBuildShowsEverything() {
        let sections = Changelog.sections(in: file, installed: "0.1.3")

        #expect(sections.map(\.version) == ["0.1.3", "0.1.2", "0.1.1", "0.1.0"])
        #expect(sections.map(\.build) == [3, 2, 1, 0])
    }

    /// A development build can carry a version the changelog has no section for yet: it shows the newest section.
    @Test func aVersionWithoutASectionShowsTheNewestSection() {
        for unknown in ["0.1.9", "0.2.0", "", "dev"] {
            let sections = Changelog.sections(in: file, installed: unknown)

            #expect(sections.first?.version == "0.1.3", "installed \(unknown)")
            #expect(sections.map(\.version) == ["0.1.3", "0.1.2", "0.1.1", "0.1.0"])
        }
    }

    @Test func aFileWithoutSectionsShowsNothing() {
        #expect(Changelog.sections(in: "# Changelog\nNothing yet.", installed: "0.1.3").isEmpty)
        #expect(Changelog.sections(in: "", installed: "0.1.3").isEmpty)
    }

    // MARK: - What is left out

    /// Linen's notes follow `## Upstream Linen history`. Their `## 0.1.1` and `## 0.1.0` have the numbers of WSurf's own
    /// sections, so a reader that looked a version up by number anywhere in the file would show Linen's notes as WSurf's.
    @Test func theInheritedLinenNotesAreNotWSurfReleases() {
        let sections = Changelog.sections(in: file)
        let everything = sections.map { "\($0.title)\n\($0.body)" }.joined(separator: "\n")

        #expect(!sections.contains { $0.version == "0.7.1" })
        #expect(!everything.contains("Linen only"))
        #expect(!everything.contains("Upstream Linen history"))

        let first = Changelog.sections(in: file, installed: "0.1.1").first
        #expect(first?.body == "- WSurf’s first build.", "0.1.1 is WSurf's build 1, not Linen's 0.1.1")
    }

    @Test func theCommentAndTheProvenanceParagraphAreNotShown() {
        let everything = Changelog.sections(in: file).map(\.body).joined(separator: "\n")

        #expect(!everything.contains("Modified for WSurf"))
        #expect(!everything.contains("preserves release notes inherited"))
        #expect(!everything.contains("provenance record"))
        #expect(!everything.contains("# Changelog"))
    }

    // MARK: - Reading a section

    @Test func aHeadingGivesVersionBuildAndDate() throws {
        let section = try #require(Changelog.sections(in: file).first)

        #expect(section.version == "0.1.3")
        #expect(section.build == 3)
        #expect(section.title == "0.1.3 (build 3)")
        #expect(section.id == "0.1.3")
        let date = try #require(section.date)
        let parts = Calendar(identifier: .gregorian).dateComponents(in: try #require(TimeZone(identifier: "UTC")), from: date)
        #expect([parts.year, parts.month, parts.day] == [2026, 10, 23])
    }

    @Test func aHeadingWithoutADateHasNone() throws {
        let baseline = try #require(Changelog.sections(in: file).last)

        #expect(baseline.version == "0.1.0")
        #expect(baseline.date == nil)
        #expect(baseline.body == "- Fork baseline, no date.")
    }

    /// The body runs to the next `##` heading, keeps its own `###` headings and wrapped lines, and loses only the blank
    /// lines around it. A `##` line inside a code fence is text.
    @Test func aBodyRunsToTheNextSectionAndKeepsItsStructure() throws {
        let sections = Changelog.sections(in: file)
        let third = try #require(sections.first { $0.version == "0.1.3" })
        let second = try #require(sections.first { $0.version == "0.1.2" })

        #expect(third.body.hasPrefix("Everything since 0.1.2."))
        #expect(third.body.contains("### Browsing"))
        #expect(third.body.hasSuffix("Wrapped onto a second line."))
        #expect(second.body.contains("## not a heading, it is inside a fence"))
        #expect(second.body.hasSuffix("```"))
        #expect(!third.body.contains("Second build fix."))
    }

    @Test func sectionsComeNewestBuildFirstWhateverTheFileOrder() {
        let shuffled = """
            ## 0.1.1 (build 1) — 2026-10-21

            - One.

            ## 0.1.3 (build 3) — 2026-10-23

            - Three.

            ## 0.1.2 (build 2) — 2026-10-22

            - Two.
            """

        #expect(Changelog.sections(in: shuffled).map(\.version) == ["0.1.3", "0.1.2", "0.1.1"])
    }

    @Test func aLooseLookingHeadingIsNotASection() {
        let text = """
            ## 0.1.3 (build x) — 2026-10-23

            - Not a build.

            ## Unreleased (build 4)
            """

        #expect(Changelog.sections(in: text).isEmpty)
    }

    // MARK: - The model the page reads

    @Test func theModelServesTheInstalledBuildsSections() {
        let defaults = UserDefaults(suiteName: AppDatabase.defaultsSuite("Changelog-\(UUID().uuidString)"))!
        let model = ReleaseNotesModel(defaults: defaults, currentVersion: "0.1.2", changelog: { file })

        #expect(model.sections.map(\.version) == ["0.1.2", "0.1.1", "0.1.0"])
        #expect(model.isRunning(model.sections[0]))
        #expect(!model.isRunning(model.sections[1]))
    }

    @Test func aDevelopmentBuildsModelServesTheNewestAndMarksNoneInstalled() {
        let defaults = UserDefaults(suiteName: AppDatabase.defaultsSuite("Changelog-\(UUID().uuidString)"))!
        let model = ReleaseNotesModel(defaults: defaults, currentVersion: "0.1.9", changelog: { file })

        #expect(model.sections.first?.version == "0.1.3")
        #expect(!model.sections.contains { model.isRunning($0) })
    }

    @Test func theModelReadsTheChangelogOnce() {
        final class Reads {
            var count = 0
        }
        let reads = Reads()
        let defaults = UserDefaults(suiteName: AppDatabase.defaultsSuite("Changelog-\(UUID().uuidString)"))!
        let model = ReleaseNotesModel(defaults: defaults, currentVersion: "0.1.2", changelog: {
            reads.count += 1
            return file
        })

        _ = model.sections
        _ = model.sections

        #expect(reads.count == 1)
    }

    @Test func aMissingChangelogShowsNoSections() {
        let defaults = UserDefaults(suiteName: AppDatabase.defaultsSuite("Changelog-\(UUID().uuidString)"))!
        let model = ReleaseNotesModel(defaults: defaults, currentVersion: "0.1.2", changelog: { nil })

        #expect(model.sections.isEmpty)
    }

    // MARK: - The file in the app

    /// The test host is the app, so `Bundle.main` is the one a person runs: `CHANGELOG.md` is copied into it.
    @Test func theChangelogIsInsideTheBuiltApp() throws {
        let url = try #require(Bundle.main.url(forResource: Changelog.resource, withExtension: Changelog.fileExtension))
        #expect(url.path.contains(".app/Contents/Resources/"))

        let text = try #require(Changelog.bundledText())
        #expect(text.contains("# Changelog"))
    }

    /// What the app ships parses into WSurf's builds only, the newest first, ending at the first build.
    @Test func theBundledChangelogHoldsWSurfsBuildsAndNotLinens() throws {
        let text = try #require(Changelog.bundledText())
        let sections = Changelog.sections(in: text)

        try #require(sections.count >= 2)
        #expect(sections.map(\.build) == sections.map(\.build).sorted(by: >), "newest first")
        #expect(sections.last?.version == "0.1.0")
        #expect(sections.last?.build == 1)
        #expect(Set(sections.map(\.version)).count == sections.count, "one section per version, so none of Linen's")
        #expect(!sections.contains { $0.version == "0.7.1" }, "a Linen-only version")
        for section in sections {
            #expect(!section.body.contains("Upstream Linen history"), "\(section.title)")
            #expect(!section.body.contains("preserves release notes inherited"), "\(section.title)")
        }
    }

    /// `Tools/check-changelog.sh` makes every candidate add its section, so the installed build has its own notes.
    @Test func theInstalledBuildHasItsOwnSectionInTheBundledChangelog() throws {
        let text = try #require(Changelog.bundledText())
        let sections = Changelog.sections(in: text, installed: UpdateFeed.currentVersion)

        #expect(sections.first?.version == UpdateFeed.currentVersion)
        #expect(sections.first?.body.isEmpty == false)
    }

    /// One file, not a copy: the project refers to the repository's `CHANGELOG.md`, and no second one sits in the app's
    /// sources where it could drift from the one the changelog rule checks.
    @Test func theProjectBundlesTheRepositoryChangelogAndNoCopy() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let project = try String(
            contentsOf: root.appending(path: "WSurf.xcodeproj/project.pbxproj"), encoding: .utf8
        )

        #expect(project.contains("CHANGELOG.md in Resources"))
        #expect(project.contains("path = CHANGELOG.md; sourceTree = \"<group>\""))
        let enumerator = try #require(FileManager.default.enumerator(at: root.appending(path: "WSurf"), includingPropertiesForKeys: nil))
        for case let item as URL in enumerator {
            #expect(item.lastPathComponent != "CHANGELOG.md", "\(item.path)")
        }
    }

    // MARK: - No network

    @Test func theNotesPageAndItsModelNeverTouchTheNetwork() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for path in ["WSurf/Updates/ReleaseNotes.swift", "WSurf/Updates/ReleaseNotesView.swift", "WSurf/Updates/Changelog.swift"] {
            let text = try String(contentsOf: root.appending(path: path), encoding: .utf8)
            #expect(!text.contains("URLSession"), "\(path)")
            #expect(!text.contains("URLRequest"), "\(path)")
            #expect(!text.contains("api.github.com"), "\(path)")
            #expect(!text.contains("GitHub"), "\(path)")
        }
        let feed = try String(contentsOf: root.appending(path: "WSurf/Updates/UpdateFeed.swift"), encoding: .utf8)
        #expect(!feed.contains("releasesAPI"))
    }

    // MARK: - The page

    /// The page draws the sections without a fetch: a hosted page, given the model alone, is not blank.
    @Test func theNotesPageDrawsItsSections() throws {
        let browser = BrowserModel(database: .temporary())
        defer { browser.cancelPendingSave() }
        let defaults = UserDefaults(suiteName: AppDatabase.defaultsSuite("Changelog-\(UUID().uuidString)"))!
        let model = ReleaseNotesModel(defaults: defaults, currentVersion: "0.1.2", changelog: { file })
        let size = CGSize(width: 820, height: 600)
        let host = NSHostingView(rootView: ReleaseNotesView(browser: browser, notes: model).frame(width: size.width, height: size.height))
        host.frame = CGRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.colorSpace = .pixelTests
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = host
        defer { window.close() }
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()

        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        var distinct: Set<UInt32> = []
        for y in stride(from: 0, to: bitmap.pixelsHigh, by: 3) {
            for x in stride(from: 0, to: bitmap.pixelsWide, by: 3) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                distinct.insert(UInt32(color.redComponent * 255) << 16 | UInt32(color.greenComponent * 255) << 8 | UInt32(color.blueComponent * 255))
            }
        }

        #expect(distinct.count > 4, "text was drawn")
    }
}
