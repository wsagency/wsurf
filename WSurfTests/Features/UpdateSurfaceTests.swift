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
