// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Observation
import os
import WebKit
extension ExtensionManager {
    func action(for id: String, inWindow window: ExtensionWindowAdapter) -> WKWebExtension.Action? {
        guard owns(window), let context = contexts[id] else { return nil }
        let tab = window.browser?.activeTab.map { adapter(for: $0) }
        return context.action(for: tab)
    }

    func registerAnchor(_ view: NSView?, for id: String, inWindow window: ExtensionWindowAdapter) {
        guard owns(window), let browser = window.browser else { return }
        anchors[ObjectIdentifier(browser), default: [:]][id] = view
    }

    func registerOverflowAnchor(_ view: NSView?, inWindow window: ExtensionWindowAdapter) {
        guard owns(window), let browser = window.browser else { return }
        overflowAnchors[ObjectIdentifier(browser)] = view
    }

    func performAction(for id: String, inWindow window: ExtensionWindowAdapter) {
        guard owns(window), let context = contexts[id] else { return }
        let tab = window.browser?.activeTab.map { adapter(for: $0) }
        guard let action = context.action(for: tab) else { return }
        if let popover = presentedPopup, presentedPopupWindow === window,
           presentedPopupID == id, popover.isShown {
            popover.performClose(nil)
            return
        }
        if lastDismissedPopupID == id, Date().timeIntervalSince(lastPopupDismissal) < 0.3 {
            return
        }
        if action.presentsPopup {
            _ = present(action, for: id, in: window.browser)
        } else {
            context.performAction(for: tab)
        }
    }

    func contextMenu(for id: String, inWindow window: ExtensionWindowAdapter) -> NSMenu? {
        guard owns(window) else { return nil }
        return contextMenu(for: id, in: window.browser)
    }
}

enum StoreInstallState: Equatable {
    case idle
    case installing(id: String)
    case installed(id: String)
    case failed(id: String, message: String)
}

@MainActor
@Observable
final class ExtensionManager: NSObject, WKWebExtensionControllerDelegate {
    let controller: WKWebExtensionController

    private(set) var installed: [InstalledExtension] = [] {
        didSet { PasswordAutofill.shared.refreshPolicy() }
    }
    private(set) var systemExtensions: [InstalledExtension] = [] {
        didSet { PasswordAutofill.shared.refreshPolicy() }
    }
    private(set) var contexts: [String: WKWebExtensionContext] = [:]
    private var wakingBackgrounds: Set<String> = []
    private var loadFailures: [String: String] = [:]
    private(set) var actionRevision = 0
    var installState: StoreInstallState = .idle
    var updateChecks: [String: UpdateCheck] = [:]

    @ObservationIgnored private static var systemCatalogue: [SafariExtension]?
    @ObservationIgnored private static let liveManagers = NSHashTable<ExtensionManager>.weakObjects()

    /// The application owns window creation; the complete configuration includes all URLs and moved tabs.
    var onOpenWindow: ((WKWebExtension.WindowConfiguration) -> ExtensionWindowAdapter?)?

    private let library: ExtensionLibrary
    let profile: Profile?

    @ObservationIgnored var windows: [ObjectIdentifier: ExtensionWindowAdapter] = [:]
    @ObservationIgnored var windowOrder: [ObjectIdentifier] = []
    @ObservationIgnored weak var lastFocusedWindow: ExtensionWindowAdapter?
    @ObservationIgnored var hasStarted = false
    @ObservationIgnored private var isStopped = false
    @TaskLocal static var extensionCreatedForTesting: (@MainActor @Sendable () async -> Void)?

    @ObservationIgnored var tabAdapters: [UUID: ExtensionTabAdapter] = [:]
    @ObservationIgnored private var iconCache: [String: NSImage] = [:]
    @ObservationIgnored var anchors: [ObjectIdentifier: [String: NSView]] = [:]
    @ObservationIgnored var overflowAnchors: [ObjectIdentifier: NSView] = [:]

    @ObservationIgnored private var presentedPopup: NSPopover?
    @ObservationIgnored private var presentedPopupID: String?
    @ObservationIgnored weak var presentedPopupWindow: ExtensionWindowAdapter?
    @ObservationIgnored private var popupCloseObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var lastDismissedPopupID: String?
    @ObservationIgnored private var lastPopupDismissal = Date.distantPast
    @ObservationIgnored private var backgroundStarts: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let nativeMessaging = NativeMessagingService()
    private(set) var appsOutOfReach: Set<String> = []

    init(
        profile: Profile? = nil,
        dataStore: WKWebsiteDataStore? = nil,
        library: ExtensionLibrary? = nil
    ) {
        self.profile = profile
        self.library = library ?? ExtensionLibrary(profile: profile ?? .original())
        controller = WKWebExtensionController(
            configuration: Self.controllerConfiguration(for: profile, dataStore: dataStore)
        )
        super.init()
        Self.liveManagers.add(self)
        controller.delegate = self
        nativeMessaging.geckoID = { [weak self] id in
            guard let self else { return nil }
            return NativeMessagingManifest.geckoID(inPackage: self.library.packageURL(for: id))
        }
    }

    func didUnregister(key identifier: ObjectIdentifier, window: ExtensionWindowAdapter) {
        anchors[identifier] = nil
        overflowAnchors[identifier] = nil
        if presentedPopupWindow === window {
            presentedPopup?.performClose(nil)
            presentedPopup = nil
            presentedPopupID = nil
            presentedPopupWindow = nil
        }
    }

    func wakeBackgrounds(for url: URL) {
        guard !isStopped else { return }
        for (id, context) in contexts {
            let webExtension = context.webExtension
            guard webExtension.hasBackgroundContent, !webExtension.hasPersistentBackgroundContent,
                  !wakingBackgrounds.contains(id),
                  webExtension.allRequestedMatchPatterns.contains(where: { $0.matches(url) })
            else { continue }
            wakingBackgrounds.insert(id)
            Task { [weak self] in
                guard let self, !isStopped, contexts[id] === context else { return }
                try? await context.loadBackgroundContent()
                guard contexts[id] === context else { return }
                wakingBackgrounds.remove(id)
            }
        }
    }

    // MARK: - Lifecycle

    enum Storage: Equatable {
        case shared
        case persistent(UUID)
        case ephemeral
    }

    static func storageIdentifier(for profile: Profile?) -> Storage {
        guard let profile else { return .shared }
        if profile.isPrivate {
            return .ephemeral
        }
        return profile.isOriginal ? .shared : .persistent(profile.id)
    }

    static func eraseData(for profile: Profile) async {
        guard !profile.isOriginal, !profile.isPrivate else { return }
        let library = ExtensionLibrary(profile: profile)
        library.load()
        let ids = library.records.map(\.id)
        library.forgetThisProfile()
        guard !ids.isEmpty else { return }

        let controller = WKWebExtensionController(configuration: controllerConfiguration(for: profile))
        let types: Set<WKWebExtension.DataType> = [.local, .session, .synchronized]
        var cleared = 0
        for id in ids {
            guard let webExtension = try? await WKWebExtension(
                resourceBaseURL: library.packageURL(for: id)
            ) else { continue }
            let context = WKWebExtensionContext(for: webExtension)
            context.uniqueIdentifier = id
            guard let record = await controller.dataRecord(ofTypes: types, for: context) else { continue }
            await controller.removeData(ofTypes: types, from: [record])
            cleared += 1
        }
        Pipeline.log.notice("ext: cleared \(cleared, privacy: .public) stores for a removed profile")
    }

    private static func controllerConfiguration(
        for profile: Profile?,
        dataStore: WKWebsiteDataStore? = nil
    ) -> WKWebExtensionController.Configuration {
        let configuration: WKWebExtensionController.Configuration
        switch storageIdentifier(for: profile) {
        case .shared:
            configuration = .default()
        case .persistent(let identifier):
            configuration = .init(identifier: identifier)
        case .ephemeral:
            configuration = .nonPersistent()
        }
        let controllerDataStore = dataStore ?? configuration.webViewConfiguration.websiteDataStore
        // Use the browser's app-lifetime pool; short-lived extension pools can die inside IPC callbacks.
        configuration.webViewConfiguration = WebViewPool.makeConfiguration()
        configuration.webViewConfiguration.websiteDataStore = controllerDataStore
        configuration.webViewConfiguration.applicationNameForUserAgent = WebViewPool.safariApplicationName
        return configuration
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        for window in windowAdapters {
            if let browser = window.browser {
                unregister(browser: browser)
            }
        }
        for task in backgroundStarts.values {
            task.cancel()
        }
        backgroundStarts.removeAll()
        wakingBackgrounds.removeAll()
        for id in Array(contexts.keys) {
            unload(id: id)
        }
        appsOutOfReach = []
        loadFailures.removeAll()
        anchors = [:]
        overflowAnchors = [:]
        presentedPopup?.performClose(nil)
        presentedPopup = nil
        presentedPopupID = nil
        presentedPopupWindow = nil
        controller.delegate = nil
        onOpenWindow = nil
        hasStarted = false
    }

    func start() async {
        guard !isStopped, !Task.isCancelled else { return }
        library.load()
        installed = library.records
        await discoverSystemExtensions()
        guard !isStopped, !Task.isCancelled else { return }

        if !hasStarted {
            hasStarted = true
            for window in windowAdapters {
                controller.didOpenWindow(window)
            }
            if let focused = preferredWindowAdapter {
                controller.didFocusWindow(focused)
            }
        }

        for record in installed + systemExtensions where record.enabled {
            await load(record)
        }
    }

    func discoverSystemExtensions() async {
        guard !isStopped, !Task.isCancelled else { return }
        let found: [SafariExtension]
        if let known = Self.systemCatalogue {
            found = known
        } else {
            found = await Task.detached(priority: .utility) {
                SafariExtensionCatalog.installed()
            }.value
            Self.systemCatalogue = found
        }
        guard !isStopped, !Task.isCancelled else { return }
        systemExtensions = found.map { extensionBundle in
            let placement = library.placement(for: extensionBundle.id)
            return InstalledExtension(
                id: extensionBundle.id,
                displayName: extensionBundle.displayName,
                version: extensionBundle.version,
                enabled: placement.enabled,
                installedAt: Date(timeIntervalSinceReferenceDate: 0),
                isPinned: placement.isPinned,
                toolbarOrder: placement.toolbarOrder,
                bundlePath: extensionBundle.bundlePath
            )
        }
        Pipeline.log.notice("ext: found \(found.count, privacy: .public) Safari extensions on this Mac")
    }

    private func record(for id: String) -> InstalledExtension? {
        installed.first { $0.id == id } ?? systemExtensions.first { $0.id == id }
    }

    private func load(_ record: InstalledExtension) async {
        guard !isStopped, !Task.isCancelled, contexts[record.id] == nil else { return }
        loadFailures[record.id] = nil
        let state = Pipeline.signposter.beginInterval("ext.load")
        defer { Pipeline.signposter.endInterval("ext.load", state) }
        let started = ContinuousClock.now
        do {
            let webExtension: WKWebExtension
            if let path = record.bundlePath, let bundle = Bundle(path: path) {
                webExtension = try await WKWebExtension(appExtensionBundle: bundle)
            } else {
                let package = library.packageURL(for: record.id)
                guard ExtensionShims.prepareApplePasswordsPersistent(at: package) != .failed else {
                    throw NSError(
                        domain: WKWebExtensionContext.errorDomain,
                        code: WKWebExtensionContext.Error.unknown.rawValue,
                        userInfo: [
                            NSLocalizedDescriptionKey:
                                "Apple Passwords is not a supported Chrome 3.4.0 package for persistent background support.",
                        ]
                    )
                }
                ExtensionShims.ensureApplied(at: package)
                ExtensionShims.ensureGapsApplied(at: package)
                ExtensionExternalConnect.ensureRelayApplied(at: package)
                ExtensionPageAssets.ensureReporterApplied(at: package)
                webExtension = try await WKWebExtension(resourceBaseURL: package)
            }
            await Self.extensionCreatedForTesting?()
            guard !isStopped, !Task.isCancelled, contexts[record.id] == nil,
                  self.record(for: record.id)?.enabled == true else { return }
            if let icon = webExtension.icon(for: CGSize(width: 32, height: 32)) {
                iconCache[record.id] = icon
            }
            let context = WKWebExtensionContext(for: webExtension)
            // Set the identifier before the load. WebKit keys the extension's
            // persistent storage on it.
            context.uniqueIdentifier = record.id
            if let base = URL(string: "webkit-extension://\(record.id)/") {
                context.baseURL = base
            }
            #if DEBUG
            context.isInspectable = true
            #endif

            for permission in webExtension.requestedPermissions {
                context.setPermissionStatus(.grantedExplicitly, for: permission)
            }
            for pattern in webExtension.allRequestedMatchPatterns {
                context.setPermissionStatus(.grantedExplicitly, for: pattern)
            }

            try controller.load(context)
            contexts[record.id] = context
            if !record.isSystem {
                library.updateMetadata(
                    id: record.id,
                    name: webExtension.displayName,
                    version: webExtension.version
                )
                installed = library.records
            }

            let name = webExtension.displayName ?? record.displayName
            let ms = (ContinuousClock.now - started).milliseconds
            Pipeline.log.notice("ext: \(name, privacy: .public) [\(record.id, privacy: .public)] loaded in \(ms)ms")

            if webExtension.hasBackgroundContent {
                startBackgroundContent(of: context, id: record.id, name: name)
            }
            logErrors(of: context, id: record.id)
        } catch {
            guard !isStopped, !Task.isCancelled else { return }
            loadFailures[record.id] = error.localizedDescription
            Self.logFailure(error, id: record.id, name: record.displayName, operation: "loading")
        }
    }

    private func startBackgroundContent(of context: WKWebExtensionContext, id: String, name: String) {
        backgroundStarts.removeValue(forKey: id)?.cancel()
        let watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled else { return }
            Pipeline.log.error("ext: \(name, privacy: .public) [\(id, privacy: .public)] background start timed out")
            self?.logErrors(of: context, id: id)
        }
        backgroundStarts[id] = Task { @MainActor [weak self] in
            defer { watchdog.cancel() }
            guard let self, !isStopped, !Task.isCancelled, contexts[id] === context else { return }
            do {
                try await context.loadBackgroundContent()
                guard !isStopped, !Task.isCancelled, contexts[id] === context else { return }
                Pipeline.log.notice("ext: \(name, privacy: .public) [\(id, privacy: .public)] background ready")
            } catch {
                guard !isStopped, !Task.isCancelled, contexts[id] === context else { return }
                Self.logFailure(error, id: id, name: name, operation: "starting background")
            }
            logErrors(of: context, id: id)
        }
    }

    private func refuseReachingApp(for context: WKWebExtensionContext) -> NSError {
        let id = context.uniqueIdentifier
        if appsOutOfReach.insert(id).inserted {
            Pipeline.log.notice("Extension runtime event")
        }
        return NSError(
            domain: WKWebExtensionContext.errorDomain,
            code: WKWebExtensionContext.Error.unknown.rawValue,
            userInfo: [NSLocalizedDescriptionKey: Self.appOutOfReachReason]
        )
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        sendMessage message: Any,
        toApplicationWithIdentifier applicationIdentifier: String?,
        for context: WKWebExtensionContext,
        replyHandler: @escaping (Any?, (any Error)?) -> Void
    ) {
        let handled = nativeMessaging.sendOnce(
            message: message,
            applicationIdentifier: applicationIdentifier,
            for: context,
            reply: replyHandler
        )
        guard !handled else { return }
        replyHandler(nil, refuseReachingApp(for: context))
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        connectUsing port: WKWebExtension.MessagePort,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        switch nativeMessaging.connect(port: port, for: context) {
        case .connected:
            completionHandler(nil)
        case .failed(let error):
            completionHandler(error)
        case .unavailable:
            completionHandler(refuseReachingApp(for: context))
        }
    }

    private func unload(id: String) {
        loadFailures[id] = nil
        backgroundStarts.removeValue(forKey: id)?.cancel()
        guard let context = contexts.removeValue(forKey: id) else { return }
        nativeMessaging.disconnect(for: context)
        do {
            try controller.unload(context)
        } catch {
            Pipeline.log.error("Extension unloading failed")
        }
    }

    private func logErrors(of context: WKWebExtensionContext, id: String) {
        let name = context.webExtension.displayName ?? record(for: id)?.displayName ?? id
        for error in context.errors {
            Self.logFailure(error, id: id, name: name, operation: "reported")
        }
    }

    private static func logFailure(_ error: any Error, id: String, name: String, operation: String) {
        let failure = error as NSError
        Pipeline.log.error("""
        ext: \(name, privacy: .public) [\(id, privacy: .public)] \(operation, privacy: .public): \
        \(failure.domain, privacy: .public) \(failure.code), \(failure.localizedDescription, privacy: .public)
        """)
    }

    func errorCount(for id: String) -> Int {
        errors(for: id).count
    }

    func errors(for id: String) -> [String] {
        var found = (contexts[id]?.errors ?? []).map(\.localizedDescription)
        if let failure = loadFailures[id] {
            found.append(failure)
        }
        if appsOutOfReach.contains(id) {
            found.append(Self.appOutOfReachReason)
        }
        return found
    }

    static let appOutOfReachReason = String(
        localized: "The extension’s companion app is unavailable. Features that require it won’t work."
    )

    func loadedIcon(for id: String, size: CGFloat) -> NSImage? {
        contexts[id]?.webExtension.icon(for: CGSize(width: size, height: size))
            ?? iconCache[id]
    }

    func icon(for id: String) async -> NSImage? {
        if let cached = iconCache[id] {
            return cached
        }

        if let icon = contexts[id]?.webExtension.icon(for: CGSize(width: 32, height: 32)) {
            iconCache[id] = icon
            return icon
        }

        guard let known = record(for: id) else { return nil }

        do {
            let webExtension: WKWebExtension
            if let path = known.bundlePath, let bundle = Bundle(path: path) {
                webExtension = try await WKWebExtension(appExtensionBundle: bundle)
            } else {
                webExtension = try await WKWebExtension(resourceBaseURL: library.packageURL(for: id))
            }
            let icon = webExtension.icon(for: CGSize(width: 32, height: 32))
            if let icon {
                iconCache[id] = icon
            }
            return icon
        } catch {
            Pipeline.log.error("Extension icon loading failed")
            return nil
        }
    }

    // MARK: - Install and manage

    func install(id: String, from store: ExtensionStore) async {
        installState = .installing(id: id)
        do {
            let package: Data
            switch store {
            case .chrome:
                package = try await ChromeWebStore.downloadPackage(id: id)
            case .firefox:
                package = try await FirefoxAddons.downloadPackage(slug: id)
            }
            try await library.unpack(package, id: id)
            guard try await confirm(package, id: id) else {
                library.discardPackage(id: id)
                installState = .idle
                return
            }
            library.recordInstall(id: id, source: store)
            installed = library.records
            guard let record = installed.first(where: { $0.id == id }) else {
                installState = .failed(
                    id: id,
                    message: String(localized: "This extension couldn’t be added to your library")
                )
                return
            }
            await load(record)
            guard contexts[id] != nil else {
                uninstall(id: id)
                installState = .failed(
                    id: id,
                    message: String(localized: "This extension isn’t supported by WebKit")
                )
                return
            }
            installState = .installed(id: id)
            Pipeline.log.notice("Extension installed")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            installState = .failed(id: id, message: message)
            Pipeline.log.error("Extension installation failed")
        }
    }

    func replacePackage(_ package: Data, id: String, name: String?, version: String) async throws {
        unload(id: id)
        try await library.unpack(package, id: id)
        library.updateMetadata(id: id, name: name, version: version)
        installed = library.records
        guard let refreshed = record(for: id), refreshed.enabled else { return }
        await load(refreshed)
    }

    func grantedPermissions(id: String) -> Set<String> {
        Set(contexts[id]?.webExtension.requestedPermissions.map(\.rawValue) ?? [])
    }

    func installedRecord(id: String) -> InstalledExtension? {
        record(for: id)
    }

    private func confirm(_ package: Data, id: String) async throws -> Bool {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("wsurf-ext-\(id).zip")
        try package.write(to: scratch, options: .atomic)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let webExtension = try await WKWebExtension(resourceBaseURL: scratch)
        let unpacked = library.packageURL(for: id)
        let accepted = Set(webExtension.requestedPermissions.map(\.rawValue))
        let unsupported = await Task.detached(priority: .userInitiated) {
            ExtensionCompatibility.report(forPackageAt: unpacked, accepting: accepted)
        }.value
        if !unsupported.isEmpty {
            Pipeline.log.notice("Extension requests unsupported capabilities")
        }
        return await ExtensionConsent.confirmInstall(
            name: webExtension.displayName ?? id,
            permissions: webExtension.requestedPermissions,
            matchPatterns: webExtension.allRequestedMatchPatterns,
            unsupported: unsupported,
            in: NSApp.keyWindow ?? NSApp.mainWindow
        )
    }

    func setEnabled(_ enabled: Bool, id: String) {
        library.setEnabled(enabled, id: id)
        installed = library.records
        applyPlacementsToSystemExtensions()
        if enabled {
            guard let record = record(for: id) else { return }
            Task { await load(record) }
        } else {
            unload(id: id)
        }
    }

    private func applyPlacementsToSystemExtensions() {
        systemExtensions = systemExtensions.map { record in
            var updated = record
            let placement = library.placement(for: record.id)
            updated.enabled = placement.enabled
            updated.isPinned = placement.isPinned
            updated.toolbarOrder = placement.toolbarOrder
            return updated
        }
    }

    func uninstall(id: String) {
        guard record(for: id)?.isSystem != true else { return }
        unload(id: id)
        library.uninstall(id: id)
        installed = library.records
        for key in windowOrder {
            anchors[key]?[id] = nil
        }
        iconCache[id] = nil
        Pipeline.log.notice("Extension uninstalled")
    }

    func isInstalled(_ id: String) -> Bool {
        installed.contains { $0.id == id }
    }

    // MARK: - Actions and popups

    func noteActionUpdate() {
        actionRevision += 1
    }

    var actionableExtensions: [InstalledExtension] {
        (installed + systemExtensions).filter { $0.enabled && contexts[$0.id] != nil }
    }

    var pinnedExtensions: [InstalledExtension] {
        actionableExtensions.filter(\.isPinned)
    }

    var unpinnedExtensions: [InstalledExtension] {
        actionableExtensions.filter { !$0.isPinned }
    }

    func setPinned(_ pinned: Bool, id: String) {
        library.setPinned(pinned, id: id)
        installed = library.records
        applyPlacementsToSystemExtensions()
        if !pinned {
            for key in windowOrder {
                anchors[key]?[id] = nil
            }
        }
    }

    func move(_ id: String, before anchor: String?) {
        library.move(id, before: anchor)
        installed = library.records
    }

    private func anchorView(for id: String, in browser: BrowserModel) -> NSView? {
        let key = ObjectIdentifier(browser)
        if let own = anchors[key]?[id], own.window != nil {
            return own
        }
        if let overflow = overflowAnchors[key], overflow.window != nil {
            return overflow
        }
        return nil
    }

    func performAction(for id: String, in browser: BrowserModel? = nil) {
        guard let window = registeredWindow(in: browser), let context = contexts[id] else { return }
        let tab = window.browser?.activeTab.map { adapter(for: $0) }
        guard let action = context.action(for: tab) else { return }

        if let popover = presentedPopup, presentedPopupWindow === window,
           presentedPopupID == id, popover.isShown {
            popover.performClose(nil)
            return
        }
        if lastDismissedPopupID == id, Date().timeIntervalSince(lastPopupDismissal) < 0.3 {
            return
        }
        if action.presentsPopup {
            _ = present(action, for: id, in: window.browser)
        } else {
            context.performAction(for: tab)
        }
    }

    @discardableResult
    func present(
        _ action: WKWebExtension.Action,
        for id: String,
        in browser: BrowserModel? = nil
    ) -> Bool {
        guard let window = registeredWindow(in: browser), let popover = action.popupPopover,
              let browser = window.browser, let anchor = anchorView(for: id, in: browser) else {
            return false
        }
        popover.behavior = .transient
        if let popupCloseObserver {
            NotificationCenter.default.removeObserver(popupCloseObserver)
        }
        popupCloseObserver = NotificationCenter.default.addObserver(
            forName: NSPopover.didCloseNotification,
            object: popover,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.presentedPopup === popover else { return }
                self.presentedPopup = nil
                self.presentedPopupID = nil
                self.presentedPopupWindow = nil
                self.lastDismissedPopupID = id
                self.lastPopupDismissal = Date()
            }
        }
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        clipPopup(popover)
        presentedPopup = popover
        presentedPopupID = id
        presentedPopupWindow = window
        action.hasUnreadBadgeText = false
        return true
    }

    private func clipPopup(_ popover: NSPopover) {
        guard let content = popover.contentViewController?.view,
              let frameView = content.window?.contentView?.superview
        else { return }

        guard let radius = Self.plateCornerRadius(of: frameView) else {
            Pipeline.log.notice("""
                ext: popup left unclipped - \
                \(String(describing: type(of: frameView)), privacy: .public) \
                bounds \(NSStringFromRect(frameView.bounds), privacy: .public) \
                reports no plausible corner \
                (layer \(frameView.layer?.cornerRadius ?? -1, privacy: .public))
                """)
            return
        }

        content.wantsLayer = true
        content.layer?.cornerRadius = radius
        content.layer?.cornerCurve = .continuous
        content.layer?.masksToBounds = true
        Pipeline.log.notice("ext: popup clipped to the plate's \(radius, privacy: .public)pt corner")
    }

    private static func plateCornerRadius(of frameView: NSView) -> CGFloat? {
        let limit = min(frameView.bounds.width, frameView.bounds.height) / 4
        guard limit > 1 else { return nil }

        for key in ["cornerRadius", "_cornerRadius"] {
            guard frameView.responds(to: NSSelectorFromString(key)),
                  let radius = frameView.value(forKey: key) as? CGFloat,
                  radius > 1, radius <= limit
            else { continue }
            return radius
        }
        if let radius = frameView.layer?.cornerRadius, radius > 1, radius <= limit {
            return radius
        }
        return nil
    }

    func contextMenu(for id: String, in browser: BrowserModel? = nil) -> NSMenu? {
        guard let window = registeredWindow(in: browser), let context = contexts[id],
              let owner = window.browser else { return nil }
        let tab = owner.activeTab.map { adapter(for: $0) }
        let menu = NSMenu()

        for item in context.action(for: tab)?.menuItems ?? [] {
            item.menu?.removeItem(item)
            menu.addItem(item)
        }
        if !menu.items.isEmpty {
            menu.addItem(.separator())
        }

        let known = record(for: id)
        let isPinned = known?.isPinned ?? true
        let pinTitle: LocalizedStringResource = isPinned ? "Hide Extension" : "Show Extension"
        menu.addItem(appMenuItem(title: String(localized: pinTitle), action: #selector(togglePinnedFromMenu(_:)), id: id, window: window))
        if context.optionsPageURL != nil {
            menu.addItem(appMenuItem(title: String(localized: "Extension Options"), action: #selector(openOptionsFromMenu(_:)), id: id, window: window))
        }
        menu.addItem(.separator())
        let title: LocalizedStringResource = known?.isSystem == true ? "Disable Extension" : "Remove Extension"
        let action: Selector = known?.isSystem == true ? #selector(disableFromMenu(_:)) : #selector(removeFromMenu(_:))
        menu.addItem(appMenuItem(title: String(localized: title), action: action, id: id, window: window))
        return menu
    }

    private func appMenuItem(
        title: String,
        action: Selector,
        id: String,
        window: ExtensionWindowAdapter
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = ExtensionMenuCommand(id: id, window: window)
        return item
    }

    @objc private func togglePinnedFromMenu(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? ExtensionMenuCommand,
              let window = command.window, owns(window),
              let record = record(for: command.id) else { return }
        setPinned(!record.isPinned, id: command.id)
    }

    @objc private func disableFromMenu(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? ExtensionMenuCommand,
              let window = command.window, owns(window) else { return }
        setEnabled(false, id: command.id)
    }

    @objc private func openOptionsFromMenu(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? ExtensionMenuCommand,
              let window = command.window, owns(window),
              let url = contexts[command.id]?.optionsPageURL else { return }
        _ = openTab(url, in: window.browser)
    }

    @objc private func removeFromMenu(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? ExtensionMenuCommand,
              let window = command.window, owns(window) else { return }
        confirmUninstall(id: command.id)
    }

    func hasOptionsPage(id: String) -> Bool {
        contexts[id]?.optionsPageURL != nil
    }

    func openOptionsPage(id: String, in browser: BrowserModel? = nil) {
        guard let window = registeredWindow(in: browser),
              let url = contexts[id]?.optionsPageURL else { return }
        _ = openTab(url, in: window.browser)
    }

    func confirmUninstall(id: String) {
        let name = installed.first { $0.id == id }?.displayName ?? id
        let alert = NSAlert()
        alert.messageText = String(localized: "Remove “\(name)”?")
        alert.informativeText = String(localized: "It is removed from every profile, along with its settings and data.")
        if let icon = loadedIcon(for: id, size: 64) {
            alert.icon = icon
        }
        alert.addButton(withTitle: String(localized: "Remove Extension"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        uninstall(id: id)
    }
}
