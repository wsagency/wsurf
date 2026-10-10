// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import WebKit

/// Services shared by regular windows of one profile, or isolated to one private window.
@MainActor
final class BrowserProfileContext {
    private static var persistent: [UUID: BrowserProfileContext] = [:]

    static func shared(for profile: Profile, settingsOwner: Profile? = nil) -> BrowserProfileContext {
        if !profile.isPrivate, let context = persistent[profile.id] {
            return context
        }
        let context = BrowserProfileContext(profile: profile, settingsOwner: settingsOwner)
        if !profile.isPrivate {
            persistent[profile.id] = context
        }
        return context
    }

    static func existing(for profileID: UUID) -> BrowserProfileContext? {
        persistent[profileID]
    }

    static func forget(_ profileID: UUID) {
        persistent[profileID] = nil
    }

    let contextID = UUID()
    let profile: Profile
    let database: AppDatabase
    let dataStore: WKWebsiteDataStore
    let settings: BrowserSettings
    let modelSettings: LLMSettings
    let actionPolicy: AgentActionPolicy
    let sitePermissions: SitePermissions
    let pageZoom: PageZoomStore
    let contentBlocker: ContentBlocker
    let favicons: FaviconLoader
    let webViewPool: WebViewPool

    lazy var downloads = DownloadManager(
        file: profile.downloadsFile,
        persists: !profile.isPrivate && !AppDatabase.isRunningTests && AppDatabase.ownsSession,
        settings: settings
    )
    lazy var history = HistoryStore(database: database)
    lazy var conversationLog = ConversationLog(database: database)
    lazy var extensions = ExtensionManager(profile: profile, dataStore: dataStore)

    private var browsers = NSHashTable<BrowserModel>.weakObjects()
    private(set) var privateSessionEnded = false

    init(profile: Profile, settingsOwner: Profile? = nil) {
        self.profile = profile
        database = profile.makeDatabase()
        dataStore = profile.makeDataStore()
        let owner = profile.isPrivate ? (settingsOwner ?? .original()) : profile
        let profileDefaults = ProfileSettingsStore.defaults(for: owner)
        let defaults = profile.isPrivate
            ? InMemoryUserDefaults(inheriting: profileDefaults)
            : profileDefaults
        modelSettings = LLMSettings(defaults: defaults)
        actionPolicy = AgentActionPolicy(storage: profile.isPrivate ? SessionAgentGrantStorage() : defaults)
        settings = BrowserSettings(sessionDefaults: defaults, application: .application)
        sitePermissions = SitePermissions(storageURL: profile.permissionsFile, persists: !profile.isPrivate)
        pageZoom = PageZoomStore(file: profile.zoomFile, persists: !profile.isPrivate)
        contentBlocker = ContentBlocker(defaults: defaults, settings: settings, persists: !profile.isPrivate)
        favicons = FaviconLoader(cacheDirectory: FaviconLoader.cacheDirectory(for: owner))
        favicons.persistsToDisk = !profile.isPrivate
        if profile.isPrivate {
            favicons.schemeOverride = .dark
        }
        webViewPool = WebViewPool(dataStore: dataStore, settings: settings, contentBlocker: contentBlocker)
        settings.onContentBlockingChanged = { [weak contentBlocker] in contentBlocker?.refresh() }
        var provider = settings.passwordProvider
        settings.onPasswordProviderChanged = { [weak self] in
            // Synchronous on purpose: no pending request, ceremony or account pick of the old provider may outlive the switch.
            guard let self else { return }
            let previous = provider
            provider = self.settings.passwordProvider
            if previous == .credentialManager {
                CredentialManager.lock(profileID: self.profile.id, reason: .manual)
            }
            WebAuthnAdapter.providerChanged(in: self)
            AutofillSuggestions.shared.providerChanged(in: self)
            PasswordAutofill.shared.providerChanged(in: self)
        }
        sitePermissions.onEngineChanged = { [weak self] origin in
            guard let self, !self.privateSessionEnded else { return }
            for browser in self.browsers.allObjects
            where browser.context === self && browser.sitePermissions === self.sitePermissions
                && browser.sessionClosedAt == nil {
                Task { @MainActor [weak browser, weak self] in
                    guard let browser, let self, !self.privateSessionEnded,
                          browser.context === self, browser.sitePermissions === self.sitePermissions,
                          browser.sessionClosedAt == nil
                    else { return }
                    await browser.applyStoredEngine(to: origin)
                }
            }
        }
    }

    func register(_ browser: BrowserModel) {
        guard !privateSessionEnded, browser.context === self else { return }
        browsers.add(browser)
    }

    func unregister(_ browser: BrowserModel) {
        browsers.remove(browser)
    }

    func isRegistered(_ browser: BrowserModel) -> Bool {
        !privateSessionEnded && browser.context === self && browsers.contains(browser)
    }

    func endPrivateSession() async {
        guard profile.isPrivate, !privateSessionEnded else { return }
        privateSessionEnded = true
        downloads.forgetPrivateDownloads()
        extensions.stop()
        actionPolicy.revokeAll()
        await contentBlocker.endPrivateSession()
        favicons.forgetSessionOnlyIcons()
        await ChromiumRuntime.shared.releaseContext(contextID: contextID)
        await dataStore.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }
}
