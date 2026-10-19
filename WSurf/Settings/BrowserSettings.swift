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

    enum Key {
        /// The settings from before themes. The migration reads them once; nothing writes or removes them, so an
        /// older build still finds them.
        static let appearance = "appearance.mode"
        static let websiteTint = "appearance.websiteTint"
        static let websiteColor = "appearance.websiteColor"
        static let loomStyle = "appearance.loomStyle"
        static let transparency = "appearance.transparency"
        static let sidebarFontFamily = "appearance.sidebar.fontFamily"
        static let sidebarFontSize = "appearance.sidebar.fontSize"
        static let sidebarFontWeight = "appearance.sidebar.fontWeight"
        static let sidebarRowSpacing = "appearance.sidebar.rowSpacing"
        static let sidebarFolderTint = "appearance.sidebar.folderTint"
        static let sidebarTextStyles = "appearance.sidebar.textStyles"
        static let themeCustomizations = "appearance.themeCustomizations"
        static let themePreset = "appearance.themePreset"
        static let colorMode = "appearance.colorMode"
        static let themeID = "appearance.themeID"
        static let userThemes = "appearance.themes.user"
        static let themeAdjustments = "appearance.themes.adjustments"
        static let themesVersion = "appearance.themes.version"
        static let sleepsInactiveTabs = "tabs.sleep"
        static let sleepAfterMinutes = "tabs.sleepAfterMinutes"
        static let pageZoom = "content.defaultZoom"
        static let linkPreview = "content.linkPreview"
        static let linkPeek = "content.linkPeek"
        static let searchEngine = "search.engine"
        static let customSearchName = "search.custom.name"
        static let customSearchTemplate = "search.custom.template"
        static let suggestions = "search.suggestions"
        static let agentOnlyInput = "search.agentOnly"
        static let historyRetention = "privacy.historyRetention"
        static let clearOnQuit = "privacy.clearOnQuit"
        static let certificateExceptions = "privacy.certificateExceptions"
        static let javaScript = "content.javaScript"
        static let blockPopups = "content.blockPopups"
        static let blockTrackers = "content.blockTrackers"
        static let autoplay = "content.autoplay"
        static let mediaPlayer = "media.player"
        static let lyrics = "media.lyrics"
        static let tabColorRefraction = "appearance.tabColorRefraction"
        static let automaticPiP = "media.automaticPiP"
        static let videoInPlayer = "experiments.videoInPlayer"
        static let passwordAutofill = "autofill.passwords"
        static let contactAutofill = "autofill.contacts"
        static let paymentCardAutofill = "privacy.paymentCardAutofill"
        static let downloadFolder = "downloads.folder"
        static let askWhereToSave = "downloads.ask"
        static let downloadRetention = "downloads.retention"
        static let userAgent = "advanced.userAgent"
        static let customUserAgent = "advanced.userAgent.custom"
        static let webInspector = "advanced.webInspector"
        static let updateChannel = "updates.channel"
        static let startPageOrder = "startPage.order"
        static let startPageHidden = "startPage.hidden"
        static let startPageHiddenSites = "startPage.hiddenSites"
        static let commandPaletteOrder = "palette.order"
    }

    static let sessionKeys: [String] = [
        Key.searchEngine, Key.customSearchName, Key.customSearchTemplate,
        Key.suggestions, Key.agentOnlyInput,
        Key.historyRetention, Key.clearOnQuit, Key.certificateExceptions,
        Key.paymentCardAutofill, Key.contactAutofill, Key.passwordAutofill,
        Key.javaScript, Key.blockPopups, Key.blockTrackers, Key.autoplay,
        Key.startPageOrder, Key.startPageHidden, Key.startPageHiddenSites,
    ]

    private static let sessionKeySet = Set(sessionKeys)

    @ObservationIgnored private let appDefaults: UserDefaults
    @ObservationIgnored private let sessionDefaults: UserDefaults
    @ObservationIgnored private let appliesAppearanceGlobally: Bool
    @ObservationIgnored private var applicationSettings: BrowserSettings?
    var globalSettings: BrowserSettings {
        applicationSettings ?? self
    }
    @ObservationIgnored var storedColorMode: AppearanceMode?
    @ObservationIgnored var storedThemeID: String?
    @ObservationIgnored var storedUserThemes: [ThemeDefinition]?
    @ObservationIgnored var storedThemeAdjustments: [String: ThemeAdjustment]?
    /// The resolved colors of the selected theme, rebuilt after the theme, a saved theme or an adjustment changes.
    @ObservationIgnored var themeCache: ResolvedTheme?
    @ObservationIgnored private var storedSidebarFontFamily: String?
    @ObservationIgnored private var storedSidebarFontSize: Double?
    @ObservationIgnored private var storedSidebarFontWeight: SidebarFontWeight?
    @ObservationIgnored private var storedSidebarRowSpacing: Double?
    @ObservationIgnored private var storedSidebarFolderTint: Double?
    @ObservationIgnored private var storedMatchesWebsiteColor: Bool?
    @ObservationIgnored private var storedUpdateChannel: UpdateChannel?
    @ObservationIgnored private var storedPageZoom: Double?
    @ObservationIgnored private var storedShowsMediaPlayer: Bool?
    @ObservationIgnored private var storedShowsLyrics: Bool?
    @ObservationIgnored private var storedSleepsInactiveTabs: Bool?
    @ObservationIgnored var storedSleepAfterMinutes: Int?
    @ObservationIgnored private var storedShowsLinkPreview: Bool?
    @ObservationIgnored private var storedPeeksAtLinks: Bool?
    @ObservationIgnored private var storedRefractsTabColor: Bool?
    @ObservationIgnored private var storedAutomaticPictureInPicture: Bool?
    @ObservationIgnored private var storedShowsVideoInPlayer: Bool?
    @ObservationIgnored private var storedDownloadFolder: URL?
    @ObservationIgnored private var storedAsksWhereToSave: Bool?
    @ObservationIgnored private var storedDownloadRetention: DownloadRetention?
    @ObservationIgnored private var storedUserAgentMode: UserAgentMode?
    @ObservationIgnored private var storedCustomUserAgent: String?
    @ObservationIgnored private var storedWebInspectorEnabled: Bool?
    @ObservationIgnored var storedCommandPaletteOrder: [CommandPaletteSection]?

    @ObservationIgnored var onWebPreferencesChanged: (() -> Void)?
    @ObservationIgnored var onContentBlockingChanged: (() -> Void)?
    @ObservationIgnored var onUpdateChannelChanged: ((UpdateChannel) -> Void)?
    @ObservationIgnored var onLyricsChanged: ((Bool) -> Void)?
    @ObservationIgnored var onSleepPolicyChanged: (() -> Void)?
    @ObservationIgnored var onMediaPlayerChanged: ((Bool) -> Void)?
    @ObservationIgnored var onAutomaticPictureInPictureChanged: ((Bool) -> Void)?
    @ObservationIgnored var onVideoInPlayerChanged: ((Bool) -> Void)?
    @ObservationIgnored private var sidebarFontCache: Font?
    @ObservationIgnored private var sidebarEmphasizedFontCache: Font?
    @ObservationIgnored private var sidebarLineHeightCache: CGFloat = 0
    @ObservationIgnored private var sidebarTitleMidlineCache: CGFloat = 0

    private func store(for key: String) -> UserDefaults {
        Self.sessionKeySet.contains(key) ? sessionDefaults : appDefaults
    }

    private func write(_ value: Any?, forKey key: String) {
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
                write(encoded, forKey: key)
            }
            didChange(self)
        }
    }

    // MARK: - Appearance

    var sidebarFontFamily: String {
        get { globalValue(\.sidebarFontFamily, storage: storedSidebarFontFamily) }
        set {
            setGlobal(\BrowserSettings.sidebarFontFamily, storage: \BrowserSettings.storedSidebarFontFamily, value: newValue, key: Key.sidebarFontFamily, didChange: {
                $0.sidebarFontCache = nil
                $0.sidebarEmphasizedFontCache = nil
            })
        }
    }

    var sidebarFontSize: Double {
        get { globalValue(\.sidebarFontSize, storage: storedSidebarFontSize) }
        set {
            let value = newValue.isFinite ? min(max(newValue, 10), 20) : 12
            setGlobal(\BrowserSettings.sidebarFontSize, storage: \BrowserSettings.storedSidebarFontSize, value: value, key: Key.sidebarFontSize, didChange: {
                $0.sidebarFontCache = nil
                $0.sidebarEmphasizedFontCache = nil
            })
        }
    }

    var sidebarFontWeight: SidebarFontWeight {
        get { globalValue(\.sidebarFontWeight, storage: storedSidebarFontWeight) }
        set {
            setGlobal(\BrowserSettings.sidebarFontWeight, storage: \BrowserSettings.storedSidebarFontWeight, value: newValue, key: Key.sidebarFontWeight, encode: { $0.rawValue }) {
                $0.sidebarFontCache = nil
                $0.sidebarEmphasizedFontCache = nil
            }
        }
    }

    var sidebarRowSpacing: Double {
        get { globalValue(\.sidebarRowSpacing, storage: storedSidebarRowSpacing) }
        set {
            let value = newValue.isFinite ? min(max(newValue, 0), 8) : 1
            setGlobal(\BrowserSettings.sidebarRowSpacing, storage: \BrowserSettings.storedSidebarRowSpacing, value: value, key: Key.sidebarRowSpacing)
        }
    }

    var sidebarFolderTint: Double {
        get { globalValue(\.sidebarFolderTint, storage: storedSidebarFolderTint) }
        set {
            let value = newValue.isFinite ? min(max(newValue, 0), 1) : 0.35
            setGlobal(\BrowserSettings.sidebarFolderTint, storage: \BrowserSettings.storedSidebarFolderTint, value: value, key: Key.sidebarFolderTint)
        }
    }

    var sidebarFont: Font {
        let settings = globalSettings
        let family = sidebarFontFamily
        let size = CGFloat(sidebarFontSize)
        let weight = sidebarFontWeight
        if let font = settings.sidebarFontCache {
            return font
        }

        let native = Self.nativeSidebarFont(family: family, size: size, weight: weight)
        let resolved = Font(native)
        settings.sidebarFontCache = resolved
        settings.sidebarLineHeightCache = (native.ascender - native.descender + native.leading).rounded(.up)
        settings.sidebarTitleMidlineCache = native.capHeight > 0 && native.xHeight > 0
            ? (native.capHeight + native.xHeight) / 4
            : (native.ascender + native.descender) / 2
        return resolved
    }

    /// The sidebar font one step heavier, for the title of a new tab. The metrics match, so rows keep their height.
    var sidebarEmphasizedFont: Font {
        let settings = globalSettings
        let (family, size, weight) = (sidebarFontFamily, CGFloat(sidebarFontSize), sidebarFontWeight.emphasized)
        if let font = settings.sidebarEmphasizedFontCache {
            return font
        }
        let resolved = Font(Self.nativeSidebarFont(family: family, size: size, weight: weight))
        settings.sidebarEmphasizedFontCache = resolved
        return resolved
    }

    var sidebarLineHeight: CGFloat {
        _ = sidebarFont
        return globalSettings.sidebarLineHeightCache
    }

    /// How far above the baseline the middle of the sidebar's text sits: halfway between the middle of a capital
    /// and the middle of a lowercase letter, which is where the weight of a title is.
    var sidebarTitleMidline: CGFloat {
        _ = sidebarFont
        return globalSettings.sidebarTitleMidlineCache
    }

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

    // MARK: - Media

    var showsMediaPlayer: Bool {
        get { globalValue(\.showsMediaPlayer, storage: storedShowsMediaPlayer) }
        set { setGlobal(\BrowserSettings.showsMediaPlayer, storage: \BrowserSettings.storedShowsMediaPlayer, value: newValue, key: Key.mediaPlayer, didChange: { $0.onMediaPlayerChanged?(newValue) }) }
    }

    var showsLyrics: Bool {
        get { globalValue(\.showsLyrics, storage: storedShowsLyrics) }
        set { setGlobal(\BrowserSettings.showsLyrics, storage: \BrowserSettings.storedShowsLyrics, value: newValue, key: Key.lyrics, didChange: { $0.onLyricsChanged?(newValue) }) }
    }

    var sleepsInactiveTabs: Bool {
        get { globalValue(\.sleepsInactiveTabs, storage: storedSleepsInactiveTabs) }
        set {
            setGlobal(\BrowserSettings.sleepsInactiveTabs, storage: \BrowserSettings.storedSleepsInactiveTabs, value: newValue, key: Key.sleepsInactiveTabs, didChange: {
                $0.onSleepPolicyChanged?()
            })
        }
    }

    var showsLinkPreview: Bool {
        get { globalValue(\.showsLinkPreview, storage: storedShowsLinkPreview) }
        set { setGlobal(\BrowserSettings.showsLinkPreview, storage: \BrowserSettings.storedShowsLinkPreview, value: newValue, key: Key.linkPreview) }
    }

    var peeksAtLinks: Bool {
        get { globalValue(\.peeksAtLinks, storage: storedPeeksAtLinks) }
        set { setGlobal(\BrowserSettings.peeksAtLinks, storage: \BrowserSettings.storedPeeksAtLinks, value: newValue, key: Key.linkPeek) }
    }

    var refractsTabColor: Bool {
        get { globalValue(\.refractsTabColor, storage: storedRefractsTabColor) }
        set { setGlobal(\BrowserSettings.refractsTabColor, storage: \BrowserSettings.storedRefractsTabColor, value: newValue, key: Key.tabColorRefraction) }
    }

    var automaticPictureInPicture: Bool {
        get { globalValue(\.automaticPictureInPicture, storage: storedAutomaticPictureInPicture) }
        set {
            setGlobal(\BrowserSettings.automaticPictureInPicture, storage: \BrowserSettings.storedAutomaticPictureInPicture, value: newValue, key: Key.automaticPiP, didChange: {
                $0.onAutomaticPictureInPictureChanged?(newValue)
            })
        }
    }

    var showsVideoInPlayer: Bool {
        get { globalValue(\.showsVideoInPlayer, storage: storedShowsVideoInPlayer) }
        set {
            setGlobal(\BrowserSettings.showsVideoInPlayer, storage: \BrowserSettings.storedShowsVideoInPlayer, value: newValue, key: Key.videoInPlayer, didChange: { settings in
                if settings.showsVideoInPlayer {
                    settings.automaticPictureInPicture = false
                }
                settings.onVideoInPlayerChanged?(settings.showsVideoInPlayer)
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

    // MARK: - Downloads

    var downloadFolder: URL {
        get { globalValue(\.downloadFolder, storage: storedDownloadFolder) }
        set { setGlobal(\BrowserSettings.downloadFolder, storage: \BrowserSettings.storedDownloadFolder, value: newValue, key: Key.downloadFolder, encode: { $0.path(percentEncoded: false) }) }
    }

    var asksWhereToSave: Bool {
        get { globalValue(\.asksWhereToSave, storage: storedAsksWhereToSave) }
        set { setGlobal(\BrowserSettings.asksWhereToSave, storage: \BrowserSettings.storedAsksWhereToSave, value: newValue, key: Key.askWhereToSave) }
    }

    var downloadRetention: DownloadRetention {
        get { globalValue(\.downloadRetention, storage: storedDownloadRetention) }
        set { setGlobal(\BrowserSettings.downloadRetention, storage: \BrowserSettings.storedDownloadRetention, value: newValue, key: Key.downloadRetention, encode: { $0.rawValue }) }
    }

    static var defaultDownloadFolder: URL {
        FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
    }

    // MARK: - Advanced

    var userAgentMode: UserAgentMode {
        get { globalValue(\.userAgentMode, storage: storedUserAgentMode) }
        set {
            setGlobal(\BrowserSettings.userAgentMode, storage: \BrowserSettings.storedUserAgentMode, value: newValue, key: Key.userAgent, encode: { $0.rawValue }) {
                $0.onWebPreferencesChanged?()
            }
        }
    }

    var customUserAgent: String {
        get { globalValue(\.customUserAgent, storage: storedCustomUserAgent) }
        set {
            setGlobal(\BrowserSettings.customUserAgent, storage: \BrowserSettings.storedCustomUserAgent, value: newValue, key: Key.customUserAgent, didChange: { settings in
                if settings.userAgentMode == .custom {
                    settings.onWebPreferencesChanged?()
                }
            })
        }
    }

    var userAgentString: String? {
        switch userAgentMode {
        case .safari:
            WebViewPool.safariUserAgent
        case .wsurf:
            "\(WebViewPool.safariUserAgent) WSurf/\(UpdateFeed.currentVersion)"
        case .custom:
            customUserAgent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? WebViewPool.safariUserAgent
                : customUserAgent
        }
    }

    var webInspectorEnabled: Bool {
        get { globalValue(\.webInspectorEnabled, storage: storedWebInspectorEnabled) }
        set {
            setGlobal(\BrowserSettings.webInspectorEnabled, storage: \BrowserSettings.storedWebInspectorEnabled, value: newValue, key: Key.webInspector, didChange: {
                $0.onWebPreferencesChanged?()
            })
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

        if application == nil, object(Key.websiteTint) == nil {
            write(matchesWebsiteColor, forKey: Key.websiteTint)
        }
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
        fillsPasswords = true
        fillsContacts = true
        fillsPaymentCards = true
        // Saved themes stay: deleting them would lose the person's work.
        colorMode = .system
        themeID = ThemeCatalog.defaultID
        themeAdjustments = [:]
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
        commandPaletteOrder = CommandPaletteSection.allCases
        startPageOrder = StartPageSection.allCases
        hiddenStartPageSections = []
        hiddenFrequentHosts = []
        onWebPreferencesChanged?()
    }
}
