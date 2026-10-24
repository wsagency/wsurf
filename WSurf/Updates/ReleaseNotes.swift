// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import Observation
import os

nonisolated struct GitHubRelease: Decodable, Equatable, Identifiable, Sendable {
    let tagName: String
    let name: String?
    let body: String?
    let htmlURL: URL
    let publishedAt: Date?
    let isPrerelease: Bool
    let isDraft: Bool

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case body
        case htmlURL = "html_url"
        case publishedAt = "published_at"
        case isPrerelease = "prerelease"
        case isDraft = "draft"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tagName = try container.decode(String.self, forKey: .tagName)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        body = try container.decodeIfPresent(String.self, forKey: .body)
        htmlURL = try container.decode(URL.self, forKey: .htmlURL)
        publishedAt = try container.decodeIfPresent(Date.self, forKey: .publishedAt)
        isPrerelease = try container.decodeIfPresent(Bool.self, forKey: .isPrerelease) ?? false
        isDraft = try container.decodeIfPresent(Bool.self, forKey: .isDraft) ?? false
    }

    var id: String {
        tagName
    }

    var displayTitle: String {
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            return name
        }
        return tagName
    }

    /// `v0.1.1` and `0.1.1` name the same version.
    var version: String {
        tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName
    }
}

@MainActor
@Observable
final class ReleaseNotesModel {
    static let seenKey = "updates.notesSeenVersion"

    private(set) var releases: [GitHubRelease] = []
    private(set) var isLoading = false
    /// The version this launch is the first of. The sidebar says so until it is opened, or `noticeDuration` has passed.
    private(set) var updatedVersion: String?

    @ObservationIgnored private var hasAttempted = false
    @ObservationIgnored private var expiry: Task<Void, Never>?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let currentVersion: String
    @ObservationIgnored private let noticeDuration: Duration

    init(
        defaults: UserDefaults = .standard,
        currentVersion: String = UpdateFeed.currentVersion,
        noticeDuration: Duration = .seconds(30)
    ) {
        self.defaults = defaults
        self.currentVersion = currentVersion
        self.noticeDuration = noticeDuration
    }

    /// Notes the first launch of a version that is not the one last run. WSurf's versions are `0.1.<build>`, one per
    /// installed build, so a different version is a different build. The version is remembered at once, not when the
    /// notice goes: a candidate gets relaunched within seconds, and the notice is for one launch per build. Nothing here
    /// waits for published release notes, because a candidate has none. The Release Notes page loads them when opened.
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

    func isRunning(_ release: GitHubRelease) -> Bool {
        release.version == UpdateFeed.currentVersion
    }

    func load() async {
        guard releases.isEmpty, !isLoading else { return }
        isLoading = true
        releases = await Self.fetchReleases()
        isLoading = false
    }

    func reload() async {
        releases = []
        await load()
    }

    nonisolated static func published(_ releases: [GitHubRelease]) -> [GitHubRelease] {
        releases
            .filter { !$0.isDraft && !$0.isPrerelease }
            .sorted { left, right in
                (left.publishedAt ?? .distantPast) > (right.publishedAt ?? .distantPast)
            }
    }

    private static func fetchReleases() async -> [GitHubRelease] {
        var request = URLRequest(url: UpdateFeed.releasesAPI())
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 12

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return []
            }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return published(try decoder.decode([GitHubRelease].self, from: data))
        } catch {
            Pipeline.log.error("release notes: fetch failed")
            return []
        }
    }
}
