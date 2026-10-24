// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Foundation
import Testing

@testable import WSurf

/// The update layer's judgement calls: how a GitHub release payload is
/// read, and what the banner tells the user at each phase.
@MainActor
struct UpdateSurfaceTests {
    private func decode(_ json: String) throws -> GitHubRelease {
        try decoder().decode(GitHubRelease.self, from: Data(json.utf8))
    }

    private func decodeList(_ json: String) throws -> [GitHubRelease] {
        try decoder().decode([GitHubRelease].self, from: Data(json.utf8))
    }

    private func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    @Test func readsAGitHubReleasePayload() throws {
        let release = try decode("""
        {
          "tag_name": "v1.2",
          "name": "Summer release",
          "body": "- Faster\\n- Smaller",
          "html_url": "https://github.com/wsagency/wsurf/releases/tag/v1.2",
          "published_at": "2026-08-01T12:00:00Z"
        }
        """)

        #expect(release.tagName == "v1.2")
        #expect(release.displayTitle == "Summer release")
        #expect(release.body?.contains("Faster") == true)
        #expect(release.publishedAt != nil)
    }

    /// GitHub lets a release go out untitled; the tag is always there to
    /// stand in.
    @Test func anUntitledReleaseIsNamedByItsTag() throws {
        let unnamed = try decode("""
        {"tag_name": "v1.3", "html_url": "https://example.com"}
        """)
        #expect(unnamed.displayTitle == "v1.3")

        let blank = try decode("""
        {"tag_name": "v1.4", "name": "   ", "html_url": "https://example.com"}
        """)
        #expect(blank.displayTitle == "v1.4")
    }

    /// The page is the whole history, so the payload is a list. GitHub sends
    /// the flags on every entry; a payload without them is still readable.
    @Test func readsAListOfReleases() throws {
        let releases = try decodeList("""
        [
          {"tag_name": "v1.2", "html_url": "https://example.com/2",
           "published_at": "2026-08-01T12:00:00Z", "prerelease": false, "draft": false},
          {"tag_name": "v1.1", "html_url": "https://example.com/1",
           "published_at": "2026-07-01T12:00:00Z", "prerelease": false, "draft": false}
        ]
        """)

        #expect(releases.map(\.tagName) == ["v1.2", "v1.1"])
        #expect(releases.allSatisfy { !$0.isPrerelease && !$0.isDraft })

        let bare = try decode(#"{"tag_name": "v1.0", "html_url": "https://example.com"}"#)
        #expect(!bare.isPrerelease)
        #expect(!bare.isDraft)
    }

    /// The rolling `tip` pre-release is one entry that never stops moving, and
    /// a draft belongs to whoever is writing it. Neither is a version shipped.
    @Test func theHistoryHoldsShippedVersionsNewestFirst() throws {
        let releases = try decodeList("""
        [
          {"tag_name": "tip", "html_url": "https://example.com/tip",
           "published_at": "2026-08-20T12:00:00Z", "prerelease": true, "draft": false},
          {"tag_name": "v1.1", "html_url": "https://example.com/1",
           "published_at": "2026-07-01T12:00:00Z", "prerelease": false, "draft": false},
          {"tag_name": "v1.3", "html_url": "https://example.com/3",
           "published_at": "2026-08-10T12:00:00Z", "prerelease": false, "draft": true},
          {"tag_name": "v1.2", "html_url": "https://example.com/2",
           "published_at": "2026-08-01T12:00:00Z", "prerelease": false, "draft": false}
        ]
        """)

        let shipped = ReleaseNotesModel.published(releases)

        #expect(shipped.map(\.tagName) == ["v1.2", "v1.1"])
    }

    /// A tag names its version with or without the `v`, and the running build
    /// is the one the page badges.
    @Test func aTagNamesItsVersionEitherWay() throws {
        let prefixed = try decode(#"{"tag_name": "v0.1.1", "html_url": "https://example.com"}"#)
        let bare = try decode(#"{"tag_name": "0.1.1", "html_url": "https://example.com"}"#)

        #expect(prefixed.version == "0.1.1")
        #expect(bare.version == "0.1.1")
        #expect(prefixed.version != "0.1.2")
    }

    /// Quiet while idle, and quiet again once dismissed.
    @Test func theBannerKnowsWhenToAppear() {
        let model = UpdateModel()

        #expect(!model.isBannerVisible)
        model.phase = .checking
        #expect(model.isBannerVisible)

        model.phase = .available
        #expect(model.isBannerVisible)

        model.isDismissed = true
        #expect(!model.isBannerVisible)
    }

    // MARK: - The notice after an update

    /// A model over its own preferences, as a launch of the given version. `seen` is the version the last launch left.
    private func launch(
        _ version: String,
        after seen: String?,
        duration: Duration = .seconds(30),
        _ body: (ReleaseNotesModel, UserDefaults) async throws -> Void
    ) async rethrows {
        let suite = AppDatabase.defaultsSuite("UpdateNotice-\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        if let seen {
            defaults.set(seen, forKey: ReleaseNotesModel.seenKey)
        }
        let model = ReleaseNotesModel(defaults: defaults, currentVersion: version, noticeDuration: duration)
        try await body(model, defaults)
    }

    /// A fresh install has nothing to announce; it only learns which version it is.
    @Test func theFirstLaunchRemembersTheVersionAndSaysNothing() async {
        await launch("0.1.10", after: nil) { model, defaults in
            model.checkForNewVersion()

            #expect(model.updatedVersion == nil)
            #expect(defaults.string(forKey: ReleaseNotesModel.seenKey) == "0.1.10")
        }
    }

    @Test func theSameVersionSaysNothing() async {
        await launch("0.1.10", after: "0.1.10") { model, _ in
            model.checkForNewVersion()

            #expect(model.updatedVersion == nil)
        }
    }

    /// WSurf's versions are `0.1.<build>`, one per installed build, so a changed version is the first launch of a new build.
    /// It is announced at once and remembered at once: a relaunch seconds later does not announce it again.
    @Test func aNewBuildIsAnnouncedOncePerInstall() async {
        await launch("0.1.11", after: "0.1.10") { model, defaults in
            model.checkForNewVersion()

            #expect(model.updatedVersion == "0.1.11")
            #expect(defaults.string(forKey: ReleaseNotesModel.seenKey) == "0.1.11", "remembered when it is announced")

            let relaunch = ReleaseNotesModel(defaults: defaults, currentVersion: "0.1.11")
            relaunch.checkForNewVersion()
            #expect(relaunch.updatedVersion == nil, "the relaunch of the same build")

            let next = ReleaseNotesModel(defaults: defaults, currentVersion: "0.1.12")
            next.checkForNewVersion()
            #expect(next.updatedVersion == "0.1.12", "and the next build, once")
        }
    }

    /// A candidate has no published release, and the notice must not wait for one: the GitHub releases are never asked at
    /// launch, and nothing is loaded for the notice.
    @Test func theNoticeDoesNotWaitForPublishedNotes() async {
        await launch("0.1.11", after: "0.1.10") { model, _ in
            model.checkForNewVersion()

            #expect(model.updatedVersion == "0.1.11")
            #expect(model.releases.isEmpty)
            #expect(!model.isLoading)
        }
    }

    @Test func aModelChecksOncePerLaunch() async {
        await launch("0.1.11", after: "0.1.10") { model, _ in
            model.checkForNewVersion()
            model.acknowledgeUpdate()
            model.checkForNewVersion()

            #expect(model.updatedVersion == nil)
        }
    }

    @Test func openingTheNotesClearsTheNotice() async {
        await launch("0.1.11", after: "0.1.10") { model, defaults in
            model.checkForNewVersion()
            model.acknowledgeUpdate()

            #expect(model.updatedVersion == nil)
            #expect(defaults.string(forKey: ReleaseNotesModel.seenKey) == "0.1.11")
        }
    }

    @Test func theNoticeRunsItsCourse() async throws {
        try await launch("0.1.11", after: "0.1.10", duration: .milliseconds(30)) { model, _ in
            model.checkForNewVersion()
            try #require(model.updatedVersion != nil)

            #expect(await waitUntil { model.updatedVersion == nil })
        }
    }

    /// An update on offer outranks the news that one was installed, and either one makes the sidebar draw the card.
    @Test func theBannerShowsTheUpdateBeforeTheNews() async {
        typealias Presence = UpdateBanner.Presence
        #expect(Presence.of(isBannerVisible: false, updatedVersion: nil) == .hidden)
        #expect(Presence.of(isBannerVisible: false, updatedVersion: "0.1.11") == .updated)
        #expect(Presence.of(isBannerVisible: true, updatedVersion: nil) == .update)
        #expect(Presence.of(isBannerVisible: true, updatedVersion: "0.1.11") == .update)

        await launch("0.1.11", after: "0.1.10") { notes, _ in
            let updates = UpdateModel()
            #expect(!UpdateBanner.isVisible(model: updates, notes: notes))
            notes.checkForNewVersion()
            #expect(UpdateBanner.isVisible(model: updates, notes: notes), "the pinned card gets its height")
            notes.acknowledgeUpdate()
            #expect(!UpdateBanner.isVisible(model: updates, notes: notes))
        }
    }

    @Test func theTooltipNamesTheCandidateWhenThereIsOne() {
        #expect(UpdateBanner.updatedHelp(version: "0.1.11", candidateLine: nil) == "Updated to 0.1.11")
        #expect(
            UpdateBanner.updatedHelp(version: "0.1.11", candidateLine: "Candidate 0.1.11-b3 · 4b1870a3")
                == "Updated to 0.1.11 · Candidate 0.1.11-b3 · 4b1870a3"
        )
    }

    /// The release notes used to open by themselves after an update. They open when asked, from the notice or the menu.
    @Test func launchNoLongerOpensTheReleaseNotes() throws {
        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appending(path: "WSurf/App/AppCoordinator+Bootstrap.swift"), encoding: .utf8)

        #expect(source.contains("releaseNotes.checkForNewVersion()"))
        #expect(!source.contains("showReleaseNotes()"))
    }

    /// The caption sits on one line beside the pop-up menu. Two lines push the
    /// row taller than the ones around it.
    @Test func aChannelCaptionFitsBesideTheMenu() {
        let budget = SettingsMetrics.detailWidth
            - SettingsMetrics.cardInset * 2
            - 24
            - SettingsMetrics.controlWidth

        for channel in UpdateChannel.allCases {
            let width = (String(localized: channel.caption) as NSString)
                .size(withAttributes: [.font: NSFont.systemFont(ofSize: 11.5)])
                .width
            #expect(width <= budget)
        }
    }

}
