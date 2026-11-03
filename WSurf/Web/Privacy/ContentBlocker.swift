// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import CryptoKit
import Foundation
import Observation
import os
import WebKit

@MainActor
@Observable
final class ContentBlocker {

    @ObservationIgnored private(set) var ruleList: WKContentRuleList?

    private(set) var exemptHosts: Set<String> = []

    @ObservationIgnored private var controllers = NSHashTable<WKUserContentController>.weakObjects()

    @ObservationIgnored private var compileTask: Task<Void, Never>?

    /// The lists are named `WSurf.trackers.<scope>.<hash of the rules>` (see `identifier(scope:exemptHosts:)`). A name this
    /// prefix and a random UUID is a list an earlier build compiled on every launch and never removed.
    private static let identifierPrefix = "WSurf.trackers."
    /// Whose list this is: the profile. Profiles share one store, and a profile removes only its own stale lists.
    private let scope: String
    /// How many times this blocker asked WebKit to compile its rules, not counting lists found already compiled.
    @ObservationIgnored private(set) var compilations = 0
    /// The list this blocker last compiled or found, so a private session can remove it.
    @ObservationIgnored private var currentIdentifier: String?
    private static let exemptDefaultsKey = "content.blockerExceptions"
    private let settings: BrowserSettings
    private let persists: Bool
    private let ruleStore: WKContentRuleListStore?
    private let temporaryDirectory: URL?
    private var sessionEnded = false
    private(set) var isCompiling = false
    @ObservationIgnored private var defaults: UserDefaults

    init(
        defaults: UserDefaults,
        settings: BrowserSettings,
        persists: Bool = true,
        ruleStore: WKContentRuleListStore? = nil,
        scope: String = "default"
    ) {
        self.defaults = defaults
        self.settings = settings
        self.persists = persists
        self.scope = scope
        if let ruleStore {
            self.ruleStore = ruleStore
            temporaryDirectory = nil
        } else if persists {
            self.ruleStore = .default()
            temporaryDirectory = nil
        } else {
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("WSurf-private-rules-" + UUID().uuidString, isDirectory: true)
            temporaryDirectory = directory
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.ruleStore = WKContentRuleListStore(url: directory)
        }
        exemptHosts = Set((defaults.stringArray(forKey: Self.exemptDefaultsKey) ?? []).map(Self.normalized))
    }

    // MARK: - Compiling

    func refresh() {
        guard !sessionEnded else { return }
        let previous = compileTask
        previous?.cancel()
        guard settings.blocksTrackers else {
            removeFromAll()
            return
        }
        compileTask = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            await self?.compile()
        }
    }

    func waitForPendingCompilation() async {
        await compileTask?.value
    }

    func endPrivateSession() async {
        guard !persists else { return }
        sessionEnded = true
        compileTask?.cancel()
        await compileTask?.value
        compileTask = nil
        removeFromAll()
        ruleList = nil
        exemptHosts = []
        if let ruleStore, let currentIdentifier {
            try? await ruleStore.removeContentRuleList(forIdentifier: currentIdentifier)
        }
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
    }

    private func compile() async {
        guard let ruleStore, !sessionEnded,
              let json = Self.rulesJSON(exemptHosts: exemptHosts)
        else { return }
        isCompiling = true
        defer { isCompiling = false }
        let identifier = Self.identifier(scope: scope, rulesJSON: json)
        currentIdentifier = identifier
        do {
            // The name holds a hash of the rules, so a list with that name is the list for these rules. It is compiled
            // when the rules change (an exception was added, the tracker list changed) and not on every launch.
            var found: WKContentRuleList?
            if persists {
                do {
                    found = try await ruleStore.contentRuleList(forIdentifier: identifier)
                } catch {
                    // Not compiled yet, or compiled by a WebKit that this one cannot read: compile it.
                    found = nil
                }
            }
            let compiled: WKContentRuleList?
            if let found {
                compiled = found
            } else {
                compilations += 1
                compiled = try await ruleStore.compileContentRuleList(
                    forIdentifier: identifier, encodedContentRuleList: json
                )
            }
            if !persists {
                try await ruleStore.removeContentRuleList(forIdentifier: identifier)
            }
            guard !Task.isCancelled, !sessionEnded, let compiled else { return }
            ruleList = compiled
            for controller in controllers.allObjects {
                controller.remove(compiled)
                controller.add(compiled)
            }
            Pipeline.log.notice("content blocking: \(TrackerList.domains.count, privacy: .public) rules ready")
            if persists {
                await removeStaleLists(keeping: identifier, in: ruleStore)
            }
        } catch {
            if !persists {
                try? await ruleStore.removeContentRuleList(forIdentifier: identifier)
            }
            Pipeline.log.error("content blocking: compile failed")
        }
    }

    /// Removes the lists WSurf compiled for these rules before: this profile's lists for other rules, and the lists with a
    /// random name that every launch of an earlier build left behind. A list of another profile or of anything else stays.
    private func removeStaleLists(keeping identifier: String, in ruleStore: WKContentRuleListStore) async {
        guard let available = await ruleStore.availableIdentifiers() else { return }
        for stale in available where Self.isStale(stale, keeping: identifier, scope: scope) {
            try? await ruleStore.removeContentRuleList(forIdentifier: stale)
        }
    }

    static func isStale(_ candidate: String, keeping identifier: String, scope: String) -> Bool {
        guard candidate != identifier, candidate.hasPrefix(identifierPrefix) else { return false }
        let name = candidate.dropFirst(identifierPrefix.count)
        return UUID(uuidString: String(name)) != nil || name.hasPrefix(scope + ".")
    }

    func apply(to controller: WKUserContentController) {
        controllers.add(controller)
        guard settings.blocksTrackers, let ruleList else { return }
        controller.add(ruleList)
    }

    private func removeFromAll() {
        guard let ruleList else { return }
        for controller in controllers.allObjects {
            controller.remove(ruleList)
        }
    }

    // MARK: - Per-website exceptions

    func isExempt(_ host: String) -> Bool {
        exemptHosts.contains(Self.normalized(host))
    }

    func setExempt(_ exempt: Bool, for host: String) {
        let host = Self.normalized(host)
        guard !host.isEmpty else { return }
        let changed = exempt ? exemptHosts.insert(host).inserted : exemptHosts.remove(host) != nil
        guard changed else { return }
        if persists {
            defaults.set(Array(exemptHosts).sorted(), forKey: Self.exemptDefaultsKey)
        }
        refresh()
        settings.onWebPreferencesChanged?()
    }

    func forgetExceptions() {
        guard !exemptHosts.isEmpty else { return }
        exemptHosts = []
        if persists {
            defaults.removeObject(forKey: Self.exemptDefaultsKey)
        }
        refresh()
        settings.onWebPreferencesChanged?()
    }

    static func normalized(_ host: String) -> String {
        var host = host.lowercased()
        if host.hasPrefix("www.") {
            host.removeFirst(4)
        }
        return host
    }

    // MARK: - Rules

    static func rulesJSON(exemptHosts: Set<String>) -> String? {
        var rules: [[String: Any]] = TrackerList.domains.map { domain in
            [
                "trigger": [
                    "url-filter": TrackerList.filter(for: domain),
                    "load-type": ["third-party"],
                ],
                "action": ["type": "block"],
            ]
        }

        rules.append([
            "trigger": [
                "url-filter": ".*",
                "resource-type": ["document"],
                "load-context": ["top-frame"],
            ],
            "action": ["type": "ignore-previous-rules"],
        ])

        if !exemptHosts.isEmpty {
            rules.append([
                "trigger": [
                    "url-filter": ".*",
                    "if-domain": exemptHosts.sorted().map { "*\($0)" },
                ],
                "action": ["type": "ignore-previous-rules"],
            ])
        }

        // Sorted keys: the same rules are the same text in every launch, since a dictionary's order changes with each one, and
        // `identifier(scope:rulesJSON:)` hashes the text.
        guard let data = try? JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The name of the compiled list for `rulesJSON`: the same rules have the same name in every launch, and other rules
    /// another one.
    static func identifier(scope: String, rulesJSON: String) -> String {
        let digest = SHA256.hash(data: Data(rulesJSON.utf8))
        return identifierPrefix + scope + "." + digest.prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    static func identifier(scope: String, exemptHosts: Set<String>) -> String? {
        rulesJSON(exemptHosts: exemptHosts).map { identifier(scope: scope, rulesJSON: $0) }
    }
}
