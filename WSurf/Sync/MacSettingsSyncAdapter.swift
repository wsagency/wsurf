// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Observation

extension Notification.Name {
    nonisolated static let wsurfMacSettingsDidChange = Notification.Name("wsurfMacSettingsDidChange")
    nonisolated static let wsurfProviderKeyConsentDidChange = Notification.Name("wsurfProviderKeyConsentDidChange")
}

@MainActor
enum MacSettingsChange {
    private static var receiving = false

    static func post(_ sender: AnyObject) {
        if !receiving {
            NotificationCenter.default.post(name: .wsurfMacSettingsDidChange, object: sender)
        }
    }

    nonisolated static func post(_ settings: LLMSettings) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { post(settings as AnyObject) }
        } else {
            Task { @MainActor in post(settings as AnyObject) }
        }
    }

    static func receive(_ change: () throws -> Void) rethrows {
        let previouslyReceiving = receiving
        receiving = true
        defer { receiving = previouslyReceiving }
        try change()
    }
}

@MainActor
struct MacSettingsStores {
    let web: BrowserSettings
    let permissions: SitePermissions
    let blocker: ContentBlocker
    let zoom: PageZoomStore
    let models: LLMSettings
}

@MainActor
final class MacSettingsSyncAdapter {
    enum Failure: Error {
        case invalidScope, invalidKey, invalidValue, accountUnavailable
    }

    private var profiles: [UUID: Profile]
    private let profileStore: ProfileStore?
    private let observedWebSettings = NSHashTable<BrowserSettings>.weakObjects()
    private let catalog: ProviderCatalog
    private let stores: (@MainActor (Profile) -> MacSettingsStores)?
    private let account: @MainActor () -> String?
    private let refreshWindows: @MainActor (MacSettingsCategory, UUID?, String) -> Void

    init(
        profiles: [Profile], profileStore: ProfileStore? = nil,
        catalog: ProviderCatalog = .shared,
        stores: (@MainActor (Profile) -> MacSettingsStores)? = nil,
        account: @escaping @MainActor () -> String? = { ProviderKeySharing.shared.accountContext },
        refreshWindows: @escaping @MainActor (MacSettingsCategory, UUID?, String) -> Void = MacSettingsSyncAdapter.refreshWindows
    ) {
        self.profiles = Dictionary(profiles.filter { !$0.isPrivate }.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest })
        self.profileStore = profileStore
        self.catalog = catalog
        self.stores = stores
        self.account = account
        self.refreshWindows = refreshWindows
    }

    func register(_ profile: Profile) {
        guard !profile.isPrivate else { return }
        profiles[profile.id] = profile
    }

    private func scoped(_ id: UUID?) throws -> MacSettingsStores {
        guard let id, let profile = profiles[id] else { throw Failure.invalidScope }
        if let stores {
            return stores(profile)
        }
        guard (profileStore ?? .shared).profiles.contains(where: { $0.id == id }) else { throw Failure.invalidScope }
        let context = BrowserProfileContext.shared(for: profile)
        return MacSettingsStores(
            web: context.settings, permissions: context.sitePermissions,
            blocker: context.contentBlocker, zoom: context.pageZoom, models: context.modelSettings
        )
    }

    func snapshot(_ channel: inout MacSettingChannel) throws -> [String: Data] {
        var values = try values(for: channel.category, profileID: channel.localProfileID)
        if channel.category == .providers, channel.localProfileID == nil {
            let localOnly = catalog.custom.map { "custom|" + $0.id }.filter { values[$0] == nil }
            channel.preserveLocalOnlyProviders(Set(localOnly), in: &values)
        }
        return values
    }

    func values(for category: MacSettingsCategory, profileID: UUID?) throws -> [String: Data] {
        switch category {
        case .websiteSettings:
            return try websiteValues(scoped(profileID))
        case .providers where profileID == nil:
            try flush(catalog.defaults)
            var result: [String: Data] = [:]
            for provider in catalog.custom {
                if let definition = Definition(provider) {
                    result["custom|" + provider.id] = try Self.encode(definition)
                }
            }
            return result
        case .providers:
            let models = try scoped(profileID).models
            try flush(models.defaults)
            var result: [String: Data] = [:]
            if let id = models.explicitProviderID, Self.providerID(id) {
                result["selection"] = try Self.encode(id)
            }
            if let effort = models.explicitReasoning {
                result["defaultEffort"] = try Self.encode(effort.rawValue)
            }
            let ids = Set(models.configuredIDs + catalog.retiredIDs + catalog.all.map(\.id) + [models.providerID])
            for id in ids where Self.providerID(id) {
                if let model = models.explicitModel(id), Self.validModel(model) {
                    result["model|" + id] = try Self.encode(model)
                }
                if let effort = models.explicitReasoning(id) {
                    result["effort|" + id] = try Self.encode(effort.rawValue)
                }
            }
            return result
        }
    }

    func apply(_ value: Data?, key: String, for category: MacSettingsCategory, profileID: UUID?) throws {
        guard key.utf8.count <= 4096, (value?.count ?? 0) <= 16_384 else { throw Failure.invalidValue }
        try MacSettingsChange.receive {
            switch category {
            case .websiteSettings:
                try applyWebsite(value, key: key, stores: scoped(profileID))
                refreshWindows(category, profileID, key)
            case .providers where profileID == nil:
                try applyDefinition(value, key: key)
                defer { refreshWindows(category, profileID, key) }
                try flush(catalog.defaults)
            case .providers:
                let models = try scoped(profileID).models
                try applySelection(value, key: key, models: models)
                defer { refreshWindows(category, profileID, key) }
                try flush(models.defaults)
            }
        }
    }

    private func flush(_ defaults: UserDefaults) throws {
        guard defaults.synchronize() else { throw CocoaError(.fileWriteUnknown) }
    }

    static func refreshWindows(category: MacSettingsCategory, profileID: UUID?, key: String) {
        guard category == .providers || key.hasPrefix("zoom|") else { return }
        for window in BrowserApplication.shared.windows where !window.isClosed && !window.context.profile.isPrivate
            && (profileID == nil || window.context.profile.id == profileID) {
            if category == .providers {
                window.configureEngines()
            } else if let (_, host) = try? parts(key) {
                for tab in window.browser.tabs where tab.liveView != nil && tab.zoomHost == host {
                    tab.zoomHost = ""
                    tab.applySiteZoom()
                }
            }
        }
    }

    private static func encode(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private static func decoded<T: Decodable>(_ value: Data?, as type: T.Type) throws -> T? {
        try value.map { try JSONDecoder().decode(type, from: $0) }
    }

    private static func parts(_ key: String) throws -> (String, String) {
        let fields = key.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard fields.count == 2, !fields[1].isEmpty else { throw Failure.invalidKey }
        return (String(fields[0]), String(fields[1]))
    }

    private static func providerID(_ id: String) -> Bool {
        if ProviderCatalog.builtIn.contains(where: { $0.id == id }) {
            return true
        }
        return id.hasPrefix("custom.") && (8...100).contains(id.utf8.count)
            && id.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || [45, 46, 95].contains($0) }
    }

    /// The custom-provider editor owns two fields. An endpoint received here cannot set credential sources or a model adapter.
    private struct Definition: Codable {
        let name: String
        let endpoint: URL

        init?(_ provider: Provider) {
            guard provider.isCustom, MacSettingsSyncAdapter.providerID(provider.id),
                  let endpoint = ProviderKeySharing.validEndpoint(provider.baseURL),
                  Self.validName(provider.name) else { return nil }
            self.name = provider.name
            self.endpoint = endpoint
        }

        init(from decoder: Decoder) throws {
            let fields = try decoder.singleValueContainer().decode([String: String].self)
            guard fields.count == 2, let name = fields["name"], Self.validName(name),
                  let endpoint = ProviderKeySharing.validEndpoint(fields["endpoint"].flatMap(URL.init(string:))) else {
                throw Failure.invalidValue
            }
            self.name = name
            self.endpoint = endpoint
        }

        static func validName(_ name: String) -> Bool {
            !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && name.utf8.count <= 512
                && !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        }
    }

    private func applyDefinition(_ data: Data?, key: String) throws {
        let (kind, id) = try Self.parts(key)
        guard kind == "custom", id.hasPrefix("custom."), Self.providerID(id) else { throw Failure.invalidKey }
        let old = catalog.provider(id: id)
        let incoming = try Self.decoded(data, as: Definition.self)
        if let old, Definition(old) == nil {
            return
        }
        guard let definition = incoming else {
            if let old {
                catalog.remove(old, received: true)
            }
            return
        }
        let url = definition.endpoint
        var next = old ?? ProviderCatalog.newCustom(id: id)
        next.name = definition.name
        next.baseURL = url
        next.isLocal = IntelligenceViewModel.isLocalNetwork(url)
        next.auth = next.isLocal ? .none : .bearer
        next.blurb = String(localized: "OpenAI-compatible endpoint at \(url.host() ?? "")")
        catalog.save(next, received: true)
    }

    private static func validModel(_ text: String) -> Bool {
        !text.isEmpty && text.utf8.count <= 1024 && text == text.trimmingCharacters(in: .whitespacesAndNewlines)
            && !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }

    private func applySelection(_ data: Data?, key: String, models: LLMSettings) throws {
        let text = try Self.decoded(data, as: String.self)
        if key == "selection" {
            guard text.map(Self.providerID) != false else { throw Failure.invalidValue }
            models.explicitProviderID = text
            return
        }
        func effort() throws -> LLMSettings.ReasoningEffort? {
            guard let text else { return nil }
            guard let effort = LLMSettings.ReasoningEffort(rawValue: text) else { throw Failure.invalidValue }
            return effort
        }
        if key == "defaultEffort" {
            models.explicitReasoning = try effort()
            return
        }
        let (kind, id) = try Self.parts(key)
        guard Self.providerID(id) else { throw Failure.invalidKey }
        switch kind {
        case "model":
            guard text.map(Self.validModel) != false else { throw Failure.invalidValue }
            models.setExplicitModel(text, for: id)
        case "effort":
            models.setExplicitReasoning(try effort(), for: id)
        default:
            throw Failure.invalidKey
        }
    }

    private static let webSwitches: [String: (preference: String, path: ReferenceWritableKeyPath<BrowserSettings, Bool>)] = [
        "javascript": (BrowserSettings.Key.javaScript, \.javaScriptEnabled),
        "popups": (BrowserSettings.Key.blockPopups, \.blocksPopups),
        "trackers": (BrowserSettings.Key.blockTrackers, \.blocksTrackers),
    ]

    /// An enabled channel re-reads the store on notification, registering again for the next edit.
    private func observeWebDefaults(_ settings: BrowserSettings) {
        guard !observedWebSettings.contains(settings) else { return }
        observedWebSettings.add(settings)
        withObservationTracking {
            _ = (settings.javaScriptEnabled, settings.blocksPopups, settings.blocksTrackers, settings.autoplay)
        } onChange: { [weak self, weak settings] in
            Task { @MainActor in
                guard let self, let settings else { return }
                self.observedWebSettings.remove(settings)
                MacSettingsChange.post(settings)
            }
        }
    }

    private func applyWebDefault(_ value: Data?, name: String, settings: BrowserSettings) throws {
        if let toggle = Self.webSwitches[name] {
            let choice = try Self.decoded(value, as: Bool.self)
            settings[keyPath: toggle.path] = choice ?? true
            settings.write(choice, forKey: toggle.preference)
        } else {
            let choice = try Self.decoded(value, as: AutoplayPolicy.self)
            settings.autoplay = choice ?? .allow
            settings.write(choice?.rawValue, forKey: BrowserSettings.Key.autoplay)
        }
    }

    private func websiteValues(_ stores: MacSettingsStores) throws -> [String: Data] {
        let sites = stores.permissions
        try stores.zoom.prepareForSync()
        try sites.prepareForSync()
        var result: [String: Data] = [:]
        func add(_ kind: String, _ address: String, _ value: some Encodable) throws {
            let key = kind + "|" + address
            if (try? Self.websiteKey(key)) != nil {
                result[key] = try Self.encode(value)
            }
        }
        observeWebDefaults(stores.web)
        // The website and model settings use the same profile domain. Read only explicit website preferences.
        let defaults = stores.models.defaults
        try flush(defaults)
        for (name, toggle) in Self.webSwitches where defaults.object(forKey: toggle.preference) != nil {
            try add("webDefault", name, stores.web[keyPath: toggle.path])
        }
        if defaults.object(forKey: BrowserSettings.Key.autoplay) != nil {
            try add("webDefault", "autoplay", stores.web.autoplay)
        }
        for (origin, records) in sites.records {
            for (permission, policy) in records {
                try add(permission.rawValue, origin, policy)
            }
        }
        for (permission, policy) in sites.defaults {
            try add("default", permission.rawValue, policy)
        }
        if sites.assistantDefault != .ask {
            try add("default", "assistant", sites.assistantDefault)
        }
        for (site, policy) in sites.assistantRecords {
            try add("assistant", site, policy)
        }
        for (origin, engine) in sites.engineRecords {
            try add("engine", origin, engine)
        }
        for (origin, policy) in sites.autoplayRecords {
            try add("autoplay", origin, policy)
        }
        for (origin, policy) in sites.popupRecords {
            try add("popups", origin, policy)
        }
        for origin in sites.keptActiveOrigins {
            try add("keepActive", origin, true)
        }
        for origin in sites.noAutomaticPictureOrigins {
            try add("blockPicture", origin, true)
        }
        for host in stores.blocker.exemptHosts {
            try add("trackers", host, true)
        }
        for (host, level) in stores.zoom.levels where TabWebView.zoomRange.contains(CGFloat(level)) {
            try add("zoom", host, level)
        }

        // The transport has seen the proposal, though this Mac has not granted it. Echoing the enforced answer would undo the peer's edit.
        guard !sites.pendingSyncGrants.isEmpty else { return result }
        // A transient account lookup must not turn a pending remote grant into an outgoing local denial.
        guard let account = account() else { throw Failure.accountUnavailable }
        for (key, grant) in sites.pendingSyncGrants where grant.account == account {
            result[key] = try grant.value.map(Self.encode)
        }
        return result
    }

    private static func websiteKey(_ key: String) throws -> (String, String) {
        let (kind, address) = try parts(key)
        switch kind {
        case "webDefault":
            guard webSwitches[address] != nil || address == "autoplay" else { throw Failure.invalidKey }
        case "default":
            guard address == "assistant" || WebPermission(rawValue: address) != nil else { throw Failure.invalidKey }
        case "zoom", "trackers":
            guard address.utf8.count <= 255, let url = URL(string: "https://" + address),
                  url.host()?.lowercased() == address, url.user == nil, url.port == nil,
                  kind != "trackers" || ContentBlocker.normalized(address) == address else { throw Failure.invalidKey }
        default:
            guard let url = URL(string: address), SitePermissions.webOrigin(for: url) == address,
                  kind != "assistant" || SitePermissions.site(for: address) == address else { throw Failure.invalidKey }
        }
        return (kind, address)
    }

    private func applyWebsite(_ data: Data?, key: String, stores: MacSettingsStores) throws {
        let (kind, address) = try Self.websiteKey(key)
        let sites = stores.permissions
        if kind != "zoom" && kind != "trackers" && kind != "webDefault" {
            try sites.loadIfNeeded()
        }
        if let permission = WebPermission(rawValue: kind) {
            let policy = try Self.decoded(data, as: PermissionPolicy.self)
            guard policy != .ask else { throw Failure.invalidValue }
            if policy == .allow && sites.policy(for: address, permission) != .allow {
                try propose(policy?.rawValue, key: key, in: sites)
            } else {
                try sites.applyDurably { $0.set(policy ?? .ask, for: address, permission) }
            }
            return
        }
        switch kind {
        case "webDefault":
            try applyWebDefault(data, name: address, settings: stores.web)
            try flush(stores.models.defaults)
        case "default", "assistant":
            try applyAccess(data, kind: kind, key: key, address: address, sites: sites)
        case "engine":
            let engine = try Self.decoded(data, as: BrowserEngine.self) ?? .webKit
            guard engine == .webKit || !SitePermissions.webKitOnlyOrigins.contains(address) else { throw Failure.invalidValue }
            try sites.applyDurably { $0.setEngine(engine, for: address) }
        case "autoplay":
            let policy = try Self.decoded(data, as: AutoplayPolicy.self)
            try sites.applyDurably { $0.setAutoplay(policy, for: address) }
        case "popups":
            let policy = try Self.decoded(data, as: PopupPolicy.self)
            try sites.applyDurably { $0.setPopups(policy, for: address) }
        case "zoom":
            let zoom = try Self.decoded(data, as: Double.self)
            guard zoom.map({ TabWebView.zoomRange.contains(CGFloat($0)) }) != false else { throw Failure.invalidValue }
            try stores.zoom.receiveOverride(zoom, for: address)
        case "keepActive", "blockPicture", "trackers":
            let flag = try Self.decoded(data, as: Bool.self)
            guard flag != false else { throw Failure.invalidValue }
            switch kind {
            case "keepActive":
                try sites.applyDurably { $0.setKeepsActive(flag == true, for: address) }
            case "blockPicture":
                try sites.applyDurably { $0.setAllowsAutomaticPicture(flag != true, for: address) }
            default:
                stores.blocker.setExempt(flag == true, for: address)
                try flush(stores.models.defaults)
            }
        default:
            throw Failure.invalidKey
        }
    }

    private func applyAccess(_ data: Data?, kind: String, key: String, address: String, sites: SitePermissions) throws {
        switch kind {
        case "default" where address == "assistant":
            let policy = try Self.decoded(data, as: AssistantAccessPolicy.self) ?? .ask
            guard policy != .deny else { throw Failure.invalidValue }
            if SitePermissions.stricter(policy, sites.assistantDefault) != policy {
                try propose(policy.rawValue, key: key, in: sites)
            } else {
                try sites.applyDurably { $0.setAssistantDefault(policy) }
            }
        case "default":
            let policy = try Self.decoded(data, as: PermissionPolicy.self)
            guard let permission = WebPermission(rawValue: address), policy == nil || policy == .deny else { throw Failure.invalidValue }
            try sites.applyDurably { $0.setDefault(policy ?? .ask, for: permission) }
        default:
            let policy = try Self.decoded(data, as: AssistantAccessPolicy.self)
            let effective = policy ?? sites.assistantDefault
            // An explicit exception outlives the default. Inherited access cannot consent to a lasting site grant.
            let existing = policy == nil ? sites.assistantAccess(for: address) : (sites.assistantRecord(for: address) ?? .ask)
            if (effective == .readOnly || effective == .control) && SitePermissions.stricter(effective, existing) != effective {
                try propose(policy?.rawValue, key: key, in: sites)
            } else {
                try sites.applyDurably { $0.setAssistantAccess(policy, for: address) }
            }
        }
    }

    private func propose(_ value: String?, key: String, in sites: SitePermissions) throws {
        guard let account = account() else { throw Failure.accountUnavailable }
        let grant: SitePermissions.SyncGrant
        if let previous = sites.pendingSyncGrants[key], previous.account == account, previous.value == value {
            grant = previous
        } else {
            grant = SitePermissions.SyncGrant(account: account, value: value, inheritedAccess: value == nil ? sites.assistantDefault : nil)
        }
        try sites.applyDurably { $0.setSyncGrant(grant, for: key) }
    }

    @discardableResult
    func reviewWebsiteGrant(_ grant: SitePermissions.SyncGrant, key: String, profileID: UUID, allow: Bool) -> Result<Void, Error> {
        guard let sites = try? scoped(profileID).permissions, grant.account == account(),
              grant.dismissed != true, sites.pendingSyncGrants[key] == grant, let (kind, address) = try? Self.websiteKey(key) else { return .success(()) }
        return Result {
            try sites.applyDurably { target in
                if !allow {
                    var declined = grant
                    declined.dismissed = true
                    target.setSyncGrant(declined, for: key)
                } else if kind == "default", address == "assistant", let value = grant.value, let policy = AssistantAccessPolicy(rawValue: value) {
                    target.setAssistantDefault(policy)
                } else if let permission = WebPermission(rawValue: kind) {
                    target.set(.allow, for: address, permission)
                } else if kind == "assistant" {
                    target.setAssistantAccess(grant.value.flatMap(AssistantAccessPolicy.init(rawValue:)), for: address)
                }
            }
        }
    }

    func discardWebsiteApprovals(profileID: UUID) throws {
        guard profileID != Profile.privateID else { return }
        // Startup pruning can lose the catalog entry before the permission file. Opening a browser context would recreate an erased profile.
        let injected = profiles[profileID].flatMap { stores?($0).permissions }
        let sites = injected ?? BrowserProfileContext.existing(for: profileID)?.sitePermissions
            ?? SitePermissions(storageURL: Profile.permissionsFile(for: profileID))
        try sites.discardSyncGrants()
    }
}
