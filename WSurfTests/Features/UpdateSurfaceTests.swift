// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import AppKit
import Foundation
import Testing

@testable import WSurf

/// The update layer's judgement calls: what the banner tells the user at each phase,
/// and when the sidebar says WSurf was updated.
@MainActor
struct UpdateSurfaceTests {
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
        changelog: @escaping () -> String? = { nil },
        _ body: (ReleaseNotesModel, UserDefaults) async throws -> Void
    ) async rethrows {
        let suite = AppDatabase.defaultsSuite("UpdateNotice-\(UUID().uuidString)")
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        if let seen {
            defaults.set(seen, forKey: ReleaseNotesModel.seenKey)
        }
        let model = ReleaseNotesModel(
            defaults: defaults, currentVersion: version, noticeDuration: duration, changelog: changelog
        )
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

    /// A candidate has no published release and the notice must not wait for notes: the launch reads no notes at all, and
    /// asks no one. The page reads the bundled changelog when it is opened.
    @Test func theNoticeReadsNothingAtLaunch() async {
        final class Reads {
            var count = 0
        }
        let reads = Reads()
        await launch("0.1.11", after: "0.1.10", changelog: { reads.count += 1; return nil }) { model, _ in
            model.checkForNewVersion()

            #expect(model.updatedVersion == "0.1.11")
            #expect(reads.count == 0)
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

    /// The close button hides the banner; the next check brings it back.
    @Test func closingTheBannerHidesItUntilTheNextCheck() {
        let updates = UpdateController()
        updates.model.phase = .failed("offline")
        #expect(updates.model.isBannerVisible)

        updates.dismiss()
        #expect(!updates.model.isBannerVisible)

        updates.checkNow()
        #expect(!updates.model.isDismissed)
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
