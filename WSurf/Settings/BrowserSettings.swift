// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Observation
import SwiftUI
import WebKit

@Observable
final class BrowserSettings {
#if DEBUG
        static let application = BrowserSettings(defaults: StageMode.defaults, appliesAppearanceGlobally: true)
#else
        static let application = BrowserSettings(appliesAppearanceGlobally: true)
#endif

    static let sessionKeys: [String] = [
        Key.searchEngine, Key.customSearchName, Key.customSearchTemplate,
        Key.suggestions, Key.agentOnlyInput,
        Key.historyRetention, Key.clearOnQuit, Key.certificateExceptions,
        Key.paymentCardAutofill, Key.contactAutofill, Key.passwordAutofill, Key.inputHistory, Key.inputHistoryRetention, Key.inputHistoryExcludedSites,
        Key.javaScript, Key.blockPopups, Key.blockTrackers, Key.autoplay,
        Key.startPageOrder, Key.startPageHidden, Key.startPageHiddenSites,
        Key.translationTarget, Key.alwaysTranslate,
    ]

    private static let sessionKeySet = Set(sessionKeys)

    @ObservationIgnored private let appDefaults: UserDefaults
    @ObservationIgnored private let sessionDefaults: UserDefaults
    @ObservationIgnored let appliesAppearanceGlobally: Bool
    @ObservationIgnored private var applicationSettings: BrowserSettings?
    var globalSettings: BrowserSettings {
        applicationSettings ?? self
    }
    @ObservationIgnored var storedColorMode: AppearanceMode?
    @ObservationIgnored var storedThemeID: String?
    @ObservationIgnored var storedUserThemes: [ThemeDefinition]?
    @ObservationIgnored var storedThemeAdjustments: [String: ThemeAdjustment]?
    @ObservationIgnored var storedDockIcon: DockIconChoice?
    /// Where the Dock icon goes. Tests replace it, so they never touch the real Dock.
    @ObservationIgnored var showsDockIcon: (NSImage?) -> Void = { DockIconChoice.show($0) }
    /// Writes that wait for the next turn of the main run loop, by key. See `writeSoon`.
    @ObservationIgnored var pendingWrites: [String: Any] = [:]
    @ObservationIgnored var flushTask: Task<Void, Never>?
    /// The resolved colors of the selected theme, rebuilt after the theme, a saved theme or an adjustment changes.
    @ObservationIgnored var themeCache: ResolvedTheme?
    var themePreview: ThemePreview?
    var sidebarInk = ThemeSidebarInk()
    /// The page edge, row edges, corner rounding and favicon style of the shown theme. See `ThemeShape`.
    var chromeShape = ThemeShape()
    @ObservationIgnored var storedSidebarFontFamily: String?
    @ObservationIgnored var storedSidebarFontSize: Double?
    @ObservationIgnored var storedSidebarFontWeight: SidebarFontWeight?
    @ObservationIgnored var storedSidebarRowSpacing: Double?
    @ObservationIgnored var storedSidebarFolderTint: Double?
    @ObservationIgnored private var storedMatchesWebsiteColor: Bool?
    @ObservationIgnored private var storedUpdateChannel: UpdateChannel?
    @ObservationIgnored private var storedPageZoom: Double?
    @ObservationIgnored var storedShowsMediaPlayer: Bool?
    @ObservationIgnored var storedShowsLyrics: Bool?
    @ObservationIgnored var storedSleepsInactiveTabs: Bool?
    @ObservationIgnored var storedSleepAfterMinutes: Int?
    @ObservationIgnored var storedArchiveTabsAfter: TabArchiveDelay?
    @ObservationIgnored var storedShowsLinkPreview: Bool?
    @ObservationIgnored var storedPeeksAtLinks: Bool?
    @ObservationIgnored var storedRefractsTabColor: Bool?
    @ObservationIgnored var storedAutomaticPictureInPicture: Bool?
    @ObservationIgnored var storedShowsVideoInPlayer: Bool?
    @ObservationIgnored var storedDownloadFolder: URL?
    @ObservationIgnored var storedAsksWhereToSave: Bool?
    @ObservationIgnored var storedDownloadRetention: DownloadRetention?
    @ObservationIgnored var storedUserAgentMode: UserAgentMode?
    @ObservationIgnored var storedCustomUserAgent: String?
    @ObservationIgnored var storedWebInspectorEnabled: Bool?
    @ObservationIgnored var storedCommandPaletteOrder: [CommandPaletteSection]?

    @ObservationIgnored var onWebPreferencesChanged: (() -> Void)?
    @ObservationIgnored var onContentBlockingChanged: (() -> Void)?
    @ObservationIgnored var onUpdateChannelChanged: ((UpdateChannel) -> Void)?
    @ObservationIgnored var onLyricsChanged: ((Bool) -> Void)?
    @ObservationIgnored var onSleepPolicyChanged: (() -> Void)?
    @ObservationIgnored var onMediaPlayerChanged: ((Bool) -> Void)?
    @ObservationIgnored var onAutomaticPictureInPictureChanged: ((Bool) -> Void)?
    @ObservationIgnored var onVideoInPlayerChanged: ((Bool) -> Void)?
    @ObservationIgnored var sidebarFontCache: Font?
    @ObservationIgnored var sidebarEmphasizedFontCache: Font?
    @ObservationIgnored var sidebarLineHeightCache: CGFloat = 0
    @ObservationIgnored var sidebarTitleMidlineCache: CGFloat = 0

    private func store(for key: String) -> UserDefaults {
        Self.sessionKeySet.contains(key) ? sessionDefaults : appDefaults
    }

    func write(_ value: Any?, forKey key: String) {
        store(for: key).set(value, forKey: key)
    }

    private func remove(_ key: String) {
        store(for: key).removeObject(forKey: key)
    }

    private func string(_ key: String) -> String? {
        store(for: key).string(forKey: key)
    }

    private func bool(_ key: String) -> Bool {
        store(for: key).bool(forKey: key)
    }

    private func object(_ key: String) -> Any? {
        store(for: key).object(forKey: key)
    }

    private func double(_ key: String) -> Double {
        store(for: key).double(forKey: key)
    }

    private func stringArray(_ key: String) -> [String]? {
        store(for: key).stringArray(forKey: key)
    }
    func globalValue<Value>(
        _ keyPath: KeyPath<BrowserSettings, Value>,
        storage: Value?
    ) -> Value {
        if let applicationSettings {
            return applicationSettings[keyPath: keyPath]
        }
        access(keyPath: keyPath)
        return storage!
    }

    func setGlobal<Value: Equatable>(
        _ keyPath: ReferenceWritableKeyPath<BrowserSettings, Value>,
        storage: ReferenceWritableKeyPath<BrowserSettings, Value?>,
        value: Value,
        key: String,
        encode: (Value) -> Any? = { $0 },
        defersWrite: Bool = false,
        didChange: (BrowserSettings) -> Void = { _ in }
    ) {
        if let applicationSettings {
            applicationSettings[keyPath: keyPath] = value
            return
        }
        if let oldValue = self[keyPath: storage], oldValue == value {
            return
        }
        withMutation(keyPath: keyPath) {
            self[keyPath: storage] = value
            if let encoded = encode(value) {
                if defersWrite {
                    writeSoon(encoded, forKey: key)
                } else {
                    write(encoded, forKey: key)
                }
            }
            didChange(self)
        }
    }

    // MARK: - Appearance

    var matchesWebsiteColor: Bool {
        get { globalValue(\.matchesWebsiteColor, storage: storedMatchesWebsiteColor) }
        set { setGlobal(\BrowserSettings.matchesWebsiteColor, storage: \BrowserSettings.storedMatchesWebsiteColor, value: newValue, key: Key.websiteTint) }
    }

    var updateChannel: UpdateChannel {
        get { globalValue(\.updateChannel, storage: storedUpdateChannel) }
        set {
            setGlobal(\BrowserSettings.updateChannel, storage: \BrowserSettings.storedUpdateChannel, value: newValue, key: Key.updateChannel, encode: { $0.rawValue }) {
                $0.onUpdateChannelChanged?(newValue)
            }
        }
    }

    var pageZoom: Double {
        get { globalValue(\.pageZoom, storage: storedPageZoom) }
        set {
            setGlobal(\BrowserSettings.pageZoom, storage: \BrowserSettings.storedPageZoom, value: newValue, key: Key.pageZoom, didChange: {
                $0.onWebPreferencesChanged?()
            })
        }
    }

    // MARK: - Search

    var searchEngineID: String {
        didSet { write(searchEngineID, forKey: Key.searchEngine) }
    }

    var customSearchName: String {
        didSet { write(customSearchName, forKey: Key.customSearchName) }
    }

    var customSearchTemplate: String {
        didSet { write(customSearchTemplate, forKey: Key.customSearchTemplate) }
    }

    var searchEngine: SearchEngine {
        if searchEngineID == SearchEngine.customID {
            return SearchEngine.custom(name: customSearchName, template: customSearchTemplate)
        }
        return SearchEngine.catalog.first { $0.id == searchEngineID } ?? SearchEngine.duckDuckGo
    }

    var showsSearchSuggestions: Bool {
        didSet { write(showsSearchSuggestions, forKey: Key.suggestions) }
    }

    var agentOnlyInput: Bool {
        didSet { write(agentOnlyInput, forKey: Key.agentOnlyInput) }
    }

    // MARK: - Privacy

    var historyRetention: HistoryRetention {
        didSet { write(historyRetention.rawValue, forKey: Key.historyRetention) }
    }

    var clearsDataOnQuit: Bool {
        didSet { write(clearsDataOnQuit, forKey: Key.clearOnQuit) }
    }

    var allowsCertificateExceptions: Bool {
        didSet {
            guard allowsCertificateExceptions != oldValue else { return }
            write(allowsCertificateExceptions, forKey: Key.certificateExceptions)
            if !allowsCertificateExceptions {
                CertificateTrust.forgetAll()
            }
        }
    }

    // MARK: - What pages may do

    var javaScriptEnabled: Bool {
        didSet {
            guard javaScriptEnabled != oldValue else { return }
            write(javaScriptEnabled, forKey: Key.javaScript)
            onWebPreferencesChanged?()
        }
    }

    var blocksPopups: Bool {
        didSet {
            guard blocksPopups != oldValue else { return }
            write(blocksPopups, forKey: Key.blockPopups)
            onWebPreferencesChanged?()
        }
    }

    var blocksTrackers: Bool {
        didSet {
            guard blocksTrackers != oldValue else { return }
            write(blocksTrackers, forKey: Key.blockTrackers)
            onContentBlockingChanged?()
            onWebPreferencesChanged?()
        }
    }

    var autoplay: AutoplayPolicy {
        didSet {
            guard autoplay != oldValue else { return }
            write(autoplay.rawValue, forKey: Key.autoplay)
            onWebPreferencesChanged?()
        }
    }

    var fillsPasswords: Bool {
        didSet {
            write(fillsPasswords, forKey: Key.passwordAutofill)
            PasswordAutofill.shared.refreshPolicy()
        }
    }

    var fillsContacts: Bool {
        didSet {
            write(fillsContacts, forKey: Key.contactAutofill)
            AutofillSaveCoordinator.shared.refreshPolicy()
        }
    }

    var fillsPaymentCards: Bool {
        didSet {
            write(fillsPaymentCards, forKey: Key.paymentCardAutofill)
            AutofillSaveCoordinator.shared.refreshPolicy()
        }
    }

    var recordsInputHistory: Bool {
        didSet {
            guard recordsInputHistory != oldValue else { return }
            write(recordsInputHistory, forKey: Key.inputHistory)
            inputHistoryPolicyChanged()
        }
    }

    var inputHistoryRetention: InputHistoryRetention {
        didSet {
            guard inputHistoryRetention != oldValue else { return }
            write(inputHistoryRetention.rawValue, forKey: Key.inputHistoryRetention)
            inputHistoryRetentionChanged()
        }
    }

    var inputHistoryExcludedSites: [String] {
        didSet {
            guard inputHistoryExcludedSites != oldValue else { return }
            write(inputHistoryExcludedSites, forKey: Key.inputHistoryExcludedSites)
            inputHistoryPolicyChanged()
        }
    }

    // MARK: - Start page

    var startPageOrder: [StartPageSection] {
        didSet {
            guard startPageOrder != oldValue else { return }
            write(startPageOrder.map(\.rawValue), forKey: Key.startPageOrder)
        }
    }

    private var hiddenStartPageSections: Set<StartPageSection> {
        didSet {
            guard hiddenStartPageSections != oldValue else { return }
            write(hiddenStartPageSections.map(\.rawValue), forKey: Key.startPageHidden)
        }
    }

    func showsStartPageSection(_ section: StartPageSection) -> Bool {
        !hiddenStartPageSections.contains(section)
    }

    subscript(showsStartPageSection section: StartPageSection) -> Bool {
        get { showsStartPageSection(section) }
        set { setStartPageSection(section, shown: newValue) }
    }

    func setStartPageSection(_ section: StartPageSection, shown: Bool) {
        if shown {
            hiddenStartPageSections.remove(section)
        } else {
            hiddenStartPageSections.insert(section)
        }
    }

    private(set) var hiddenFrequentHosts: Set<String> = [] {
        didSet {
            guard hiddenFrequentHosts != oldValue else { return }
            write(Array(hiddenFrequentHosts), forKey: Key.startPageHiddenSites)
        }
    }

    /// The language a page was last translated to in this profile, as a `TranslationLanguage.key`; empty means the first
    /// preferred language.
    var translationTargetID: String = "" {
        didSet {
            guard translationTargetID != oldValue else { return }
            write(translationTargetID.isEmpty ? nil : translationTargetID, forKey: Key.translationTarget)
        }
    }

    /// Languages this profile translates without asking, as `TranslationLanguage.key`s.
    var alwaysTranslatedLanguages: Set<String> = [] {
        didSet {
            guard alwaysTranslatedLanguages != oldValue else { return }
            write(alwaysTranslatedLanguages.sorted(), forKey: Key.alwaysTranslate)
        }
    }

    func hideFrequentSite(host: String) {
        hiddenFrequentHosts.insert(host.lowercased())
    }

    func restoreHiddenFrequentSites() {
        hiddenFrequentHosts = []
    }

    func moveStartPageSections(from source: IndexSet, to destination: Int) {
        let moved = source.map { startPageOrder[$0] }
        var order = startPageOrder
        for index in source.sorted(by: >) {
            order.remove(at: index)
        }
        let insertion = destination - source.count(where: { $0 < destination })
        order.insert(contentsOf: moved, at: min(max(insertion, 0), order.count))
        startPageOrder = order
    }

    private static func resolveOrder(_ stored: [String]?) -> [StartPageSection] {
        completeOrder(stored?.compactMap(StartPageSection.init(rawValue:)) ?? [])
    }

    /// `known` without repeats, then each case it lacks, placed before the next case that is present.
    static func completeOrder<Section: CaseIterable & Hashable>(_ known: [Section]) -> [Section] {
        var order: [Section] = []
        for section in known where !order.contains(section) {
            order.append(section)
        }
        for section in Section.allCases where !order.contains(section) {
            let following = Section.allCases
                .drop { $0 != section }
                .dropFirst()
                .first { order.contains($0) }
            if let following, let index = order.firstIndex(of: following) {
                order.insert(section, at: index)
            } else {
                order.append(section)
            }
        }
        return order
    }

    // MARK: - Init

    init(
        defaults: UserDefaults = .standard,
        sessionDefaults: UserDefaults? = nil,
        appliesAppearanceGlobally: Bool = false,
        application: BrowserSettings? = nil
    ) {
        let session = sessionDefaults ?? defaults
        self.appDefaults = defaults
        self.sessionDefaults = session
        self.appliesAppearanceGlobally = appliesAppearanceGlobally
        self.applicationSettings = application
        // Reading the defaults now must see every theme choice that another settings object has not written yet.
        BrowserSettings.flushAllPendingWrites()
        _ = BrowserSettings.flushObservers
        func pick(_ key: String) -> UserDefaults {
            Self.sessionKeySet.contains(key) ? session : defaults
        }
        func string(_ key: String) -> String? {
            pick(key).string(forKey: key)
        }
        func bool(_ key: String) -> Bool {
            pick(key).bool(forKey: key)
        }
        func object(_ key: String) -> Any? {
            pick(key).object(forKey: key)
        }
        func double(_ key: String) -> Double {
            pick(key).double(forKey: key)
        }
        func finiteNumber(_ key: String) -> Double? {
            guard let value = object(key) as? NSNumber, value.doubleValue.isFinite else {
                return nil
            }
            return value.doubleValue
        }
        func stringArray(_ key: String) -> [String]? {
            pick(key).stringArray(forKey: key)
        }

        if application == nil {
            // Read before anything writes the website tint: a fresh install is told apart by having no old key.
            let themes = Self.loadThemeSettings(from: defaults)
            storedColorMode = themes.colorMode
            storedThemeID = themes.themeID
            storedUserThemes = Self.normalized(themes.userThemes)
            storedThemeAdjustments = themes.adjustments.mapValues { $0.bounded() }
            storedDockIcon = string(Key.dockIcon).flatMap(DockIconChoice.init(rawValue:)) ?? .standard
            let legacyLoomStyle = string(Key.loomStyle)
            if let storedWebsiteTint = object(Key.websiteTint) as? Bool {
                storedMatchesWebsiteColor = storedWebsiteTint
            } else if legacyLoomStyle == "websiteTint" {
                storedMatchesWebsiteColor = true
            } else if legacyLoomStyle == nil {
                storedMatchesWebsiteColor = object(Key.websiteColor) as? Bool ?? true
            } else {
                storedMatchesWebsiteColor = false
            }
            storedSidebarFontFamily = string(Key.sidebarFontFamily) ?? ""
            storedSidebarFontSize = min(max(finiteNumber(Key.sidebarFontSize) ?? 12, 10), 20)
            storedSidebarFontWeight = string(Key.sidebarFontWeight)
                .flatMap(SidebarFontWeight.init(rawValue:)) ?? .medium
            storedSidebarRowSpacing = min(max(finiteNumber(Key.sidebarRowSpacing) ?? 1, 0), 8)
            storedSidebarFolderTint = min(max(finiteNumber(Key.sidebarFolderTint) ?? 0.35, 0), 1)
            defaults.removeObject(forKey: "appearance.sidebar.directRemoveUnloadedTabs")

            storedShowsMediaPlayer = object(Key.mediaPlayer) as? Bool ?? true
            storedShowsLyrics = object(Key.lyrics) as? Bool ?? true
            storedRefractsTabColor = object(Key.tabColorRefraction) as? Bool ?? true
            storedSleepsInactiveTabs = object(Key.sleepsInactiveTabs) as? Bool ?? false
            storedSleepAfterMinutes = Self.clampedSleepMinutes(finiteNumber(Key.sleepAfterMinutes) ?? 0)
            storedArchiveTabsAfter = string(Key.archiveTabsAfter).flatMap(TabArchiveDelay.init(rawValue:)) ?? .never
            storedShowsLinkPreview = object(Key.linkPreview) as? Bool ?? true
            storedPeeksAtLinks = object(Key.linkPeek) as? Bool ?? true
            storedAutomaticPictureInPicture = object(Key.automaticPiP) as? Bool ?? false
            storedShowsVideoInPlayer = object(Key.videoInPlayer) as? Bool ?? false
            storedUpdateChannel = string(Key.updateChannel)
                .flatMap(UpdateChannel.init(rawValue:)) ?? .release
            let storedZoom = double(Key.pageZoom)
            storedPageZoom = storedZoom > 0 ? storedZoom : 1

            let storedFolder = string(Key.downloadFolder)
            storedDownloadFolder = storedFolder.map { URL(filePath: $0, directoryHint: .isDirectory) }
                ?? Self.defaultDownloadFolder
            storedAsksWhereToSave = bool(Key.askWhereToSave)
            storedDownloadRetention = string(Key.downloadRetention)
                .flatMap(DownloadRetention.init(rawValue:)) ?? .manually
            storedUserAgentMode = string(Key.userAgent)
                .flatMap(UserAgentMode.init(rawValue:)) ?? .safari
            storedCustomUserAgent = string(Key.customUserAgent) ?? ""
            storedWebInspectorEnabled = object(Key.webInspector) as? Bool ?? true
            storedCommandPaletteOrder = Self.completeOrder(
                (stringArray(Key.commandPaletteOrder) ?? []).compactMap(CommandPaletteSection.init(rawValue:))
            )
        }

        fillsPasswords = object(Key.passwordAutofill) as? Bool ?? true
        // Credential Manager is the only password store. The provider choice and the extension choice that went with the old
        // Passwords provider are per-profile values nothing reads any more.
        for key in ["autofill.passwordProvider", "autofill.passwordExtension"] {
            session.removeObject(forKey: key)
        }
        fillsContacts = object(Key.contactAutofill) as? Bool ?? true
        fillsPaymentCards = object(Key.paymentCardAutofill) as? Bool ?? true
        recordsInputHistory = object(Key.inputHistory) as? Bool ?? false
        inputHistoryRetention = string(Key.inputHistoryRetention).flatMap(InputHistoryRetention.init(rawValue:)) ?? .standard
        inputHistoryExcludedSites = stringArray(Key.inputHistoryExcludedSites) ?? []

        searchEngineID = string(Key.searchEngine) ?? SearchEngine.duckDuckGo.id
        customSearchName = string(Key.customSearchName) ?? ""
        customSearchTemplate = string(Key.customSearchTemplate) ?? ""
        showsSearchSuggestions = object(Key.suggestions) as? Bool ?? true
        agentOnlyInput = bool(Key.agentOnlyInput)

        historyRetention = string(Key.historyRetention)
            .flatMap(HistoryRetention.init(rawValue:)) ?? .forever
        clearsDataOnQuit = bool(Key.clearOnQuit)
        allowsCertificateExceptions = bool(Key.certificateExceptions)

        javaScriptEnabled = object(Key.javaScript) as? Bool ?? true
        blocksPopups = object(Key.blockPopups) as? Bool ?? true
        blocksTrackers = object(Key.blockTrackers) as? Bool ?? true
        autoplay = string(Key.autoplay)
            .flatMap(AutoplayPolicy.init(rawValue:)) ?? .allow

        startPageOrder = Self.resolveOrder(stringArray(Key.startPageOrder))
        hiddenStartPageSections = Set(
            (stringArray(Key.startPageHidden) ?? [])
                .compactMap(StartPageSection.init(rawValue:))
        )
        hiddenFrequentHosts = Set(stringArray(Key.startPageHiddenSites) ?? [])
        translationTargetID = string(Key.translationTarget) ?? ""
        alwaysTranslatedLanguages = Set(stringArray(Key.alwaysTranslate) ?? [])

        if application == nil {
            if object(Key.websiteTint) == nil {
                write(matchesWebsiteColor, forKey: Key.websiteTint)
            }
            refreshTheme()
        }
    }

    isolated deinit {
        flushPendingWrites()
    }

    // MARK: - Applying

    var forcesDarkAppearance = false {
        didSet {
            guard forcesDarkAppearance != oldValue else { return }
            applyAppearance()
        }
    }

    func applyAppearance() {
        guard appliesAppearanceGlobally else { return }
        NSApp.appearance = forcesDarkAppearance
            ? NSAppearance(named: .darkAqua)
            : colorMode.nsAppearance
    }

    func resetToDefaults() {
        cancelThemePreview()
        fillsPasswords = true
        fillsContacts = true
        fillsPaymentCards = true
        recordsInputHistory = false
        inputHistoryRetention = .standard
        inputHistoryExcludedSites = []
        // Saved themes stay: deleting them would lose the person's work.
        colorMode = .system
        themeID = ThemeCatalog.defaultID
        themeAdjustments = [:]
        dockIcon = .standard
        matchesWebsiteColor = true
        sidebarFontFamily = ""
        sidebarFontSize = 12
        sidebarFontWeight = .medium
        sidebarRowSpacing = 1
        sidebarFolderTint = 0.35
        refractsTabColor = true
        pageZoom = 1
        searchEngineID = SearchEngine.duckDuckGo.id
        customSearchName = ""
        customSearchTemplate = ""
        showsSearchSuggestions = true
        agentOnlyInput = false
        historyRetention = .forever
        clearsDataOnQuit = false
        allowsCertificateExceptions = false
        javaScriptEnabled = true
        blocksPopups = true
        blocksTrackers = true
        autoplay = .allow
        downloadFolder = Self.defaultDownloadFolder
        asksWhereToSave = false
        userAgentMode = .safari
        customUserAgent = ""
        webInspectorEnabled = true
        archiveTabsAfter = .never
        commandPaletteOrder = CommandPaletteSection.allCases
        startPageOrder = StartPageSection.allCases
        hiddenStartPageSections = []
        hiddenFrequentHosts = []
        translationTargetID = ""
        alwaysTranslatedLanguages = []
        onWebPreferencesChanged?()
    }
}
