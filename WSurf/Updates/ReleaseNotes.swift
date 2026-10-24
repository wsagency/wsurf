// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import Observation

@MainActor
@Observable
final class ReleaseNotesModel {
    static let seenKey = "updates.notesSeenVersion"

    /// The version this launch is the first of. The sidebar says so until it is opened, or `noticeDuration` has passed.
    private(set) var updatedVersion: String?

    @ObservationIgnored private var hasAttempted = false
    @ObservationIgnored private var expiry: Task<Void, Never>?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let currentVersion: String
    @ObservationIgnored private let noticeDuration: Duration
    @ObservationIgnored private let changelog: () -> String?
    @ObservationIgnored private var cachedSections: [ChangelogSection]?

    init(
        defaults: UserDefaults = .standard,
        currentVersion: String = UpdateFeed.currentVersion,
        noticeDuration: Duration = .seconds(30),
        changelog: @escaping () -> String? = { Changelog.bundledText() }
    ) {
        self.defaults = defaults
        self.currentVersion = currentVersion
        self.noticeDuration = noticeDuration
        self.changelog = changelog
    }

    /// What the Release Notes page shows: the installed build's section of the bundled `CHANGELOG.md` and the older ones
    /// below it, or the newest section when this version has none. Read once, from the app itself, never from the network.
    var sections: [ChangelogSection] {
        if let cachedSections {
            return cachedSections
        }
        let sections = changelog().map { Changelog.sections(in: $0, installed: currentVersion) } ?? []
        cachedSections = sections
        return sections
    }

    func isRunning(_ section: ChangelogSection) -> Bool {
        section.version == currentVersion
    }

    /// Notes the first launch of a version that is not the one last run. WSurf's versions are `0.1.<build>`, one per
    /// installed build, so a different version is a different build. The version is remembered at once, not when the
    /// notice goes: a candidate gets relaunched within seconds, and the notice is for one launch per build. Nothing here
    /// reads the notes: the Release Notes page does, from the bundled changelog, when it is opened.
    func checkForNewVersion() {
        guard !hasAttempted else { return }
        hasAttempted = true

        guard let seen = defaults.string(forKey: Self.seenKey) else {
            defaults.set(currentVersion, forKey: Self.seenKey)
            return
        }
        guard seen != currentVersion else { return }

        defaults.set(currentVersion, forKey: Self.seenKey)
        updatedVersion = currentVersion
        expiry = Task { [weak self, noticeDuration] in
            try? await Task.sleep(for: noticeDuration)
            self?.acknowledgeUpdate()
        }
    }

    func acknowledgeUpdate() {
        expiry?.cancel()
        expiry = nil
        updatedVersion = nil
    }
}
