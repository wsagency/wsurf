// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import AppKit
import Observation
import WebKit

/// Native windows own selection and running tasks; contexts own profile data.
@MainActor
@Observable
final class BrowserApplication {
    static let shared = BrowserApplication()

    private(set) var windows: [AppCoordinator] = []
    private(set) var activeWindowID: UUID?
    private(set) var isTerminating = false
    /// Mute WSurf is on: every tab of every window is silenced. What each tab's own mute was, to give back, is `mutedBefore`.
    /// Only `BrowserApplication+Audio` changes them.
    var isMuted = false
    @ObservationIgnored var mutedBefore: [UUID: Bool] = [:]
    private var privateSessionCleanups: [UUID: Task<Void, Never>] = [:]
    let updates = UpdateController()
    private var isReady = false
    /// The wait for an idle moment after launch, to start Chromium in a session that uses it (`ChromiumPrewarm`).
    @ObservationIgnored var chromiumPrewarm: ChromiumPrewarm?
    /// While a launch opens its saved windows (`beginLaunchRestore` to the end of `continueLaunchRestore`). A window opened then
    /// draws before its assistant and voices are built (`AppCoordinator.configureEngines`).
    @ObservationIgnored private(set) var isLaunching = false
    /// While a launch's restore opens a window: whether it is the first in the restore order (`isOpeningFirstWindow`).
    @ObservationIgnored private var launchOpensFirstWindow: Bool?
    /// The rest of a launch that a quit stopped; a quit that is called off goes on with it (`cancelTermination`).
    @ObservationIgnored private var interruptedLaunch: (() -> Void)?
    private var queuedURLs: [URL] = []
    private var usedProfiles: [UUID: BrowserProfileContext] = [:]
    private var focusOrder: [UUID] = []
    private let defaults: UserDefaults
    /// Whether this copy of the app owns the saved session: a second copy's windows say so in a notice. Only a test says otherwise.
    /// Only that notice reads it; what is saved still follows `AppDatabase.ownsSession`, so `true` in a test gives a first copy's
    /// windows, not a saved session.
    let ownsSession: Bool
    private static let lastWindowKey = "browser.lastFocusedWindow"
    /// Profile and window of the last regular window the user closed, kept until another regular window opens.
    static let closedAsLastKey = "browser.windowClosedAsLast"
    private var mainMenu: MainMenu?

    init(defaults: UserDefaults? = nil, notifications: NotificationCenter = .default, ownsSession: Bool = AppDatabase.ownsSession) {
        self.ownsSession = ownsSession
        // Tests keep what they write to themselves instead of leaving it in the preferences of their bundle identifier.
        self.defaults = defaults ?? (AppDatabase.isRunningTests ? InMemoryUserDefaults(inheriting: .standard) : BrowserMCPServer.appDefaults)
        installSharedRouting()
        // AppKit closes every window right after posting this, on the main thread. Those closes come from the quit, not
        // from the user, so the flag must be set before the post returns: an observer queue would set it too late.
        _ = notifications.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.isTerminating = true }
        }
    }

    var activeCoordinator: AppCoordinator? {
        windows.first { !$0.isClosed && $0.isKeyWindow }
            ?? windows.first { !$0.isClosed && $0.windowID == activeWindowID }
            ?? windows.last { !$0.isClosed }
    }

    /// A micro window is never where an external link lands: it holds one page.
    var externalLinkTarget: AppCoordinator? {
        if let activeCoordinator, !activeCoordinator.profiles.isPrivate, !activeCoordinator.isMicro {
            return activeCoordinator
        }
        return focusOrder.reversed().compactMap { id in
            windows.first { !$0.isClosed && $0.windowID == id && !$0.profiles.isPrivate && !$0.isMicro }
        }.first ?? windows.last { !$0.isClosed && !$0.profiles.isPrivate && !$0.isMicro }
    }

    /// The external-link window when it shows `profile`, else the last regular window of that profile; nil with none, so a caller
    /// opens a new window of the profile instead of another profile's.
    func externalLinkTarget(for profile: Profile) -> AppCoordinator? {
        if let target = externalLinkTarget, target.profiles.current.id == profile.id {
            return target
        }
        return windows.last { !$0.isClosed && !$0.profiles.isPrivate && !$0.isMicro && $0.profiles.current.id == profile.id }
    }

    /// The window a connected app, the assistant's tools and shortcuts that open app pages work in: the active window, or
    /// while a micro window is active, the regular window used last. A private window that is active, micro or not, gives
    /// nothing, so a connected app keeps being refused while one is in front.
    var activeBrowsingCoordinator: AppCoordinator? {
        guard let active = activeCoordinator else { return nil }
        guard active.isMicro else { return active }
        guard !active.profiles.isPrivate else { return nil }
        return focusOrder.reversed().compactMap { id in
            windows.first { !$0.isClosed && $0.windowID == id && !$0.isMicro }
        }.first ?? windows.last { !$0.isClosed && !$0.isMicro }
    }

    /// The window a micro window's page moves to, and where pages it opens go: the regular window of the same profile used
    /// most recently, which is normally the one the page came from.
    func browsingWindow(for micro: AppCoordinator) -> AppCoordinator? {
        let recent = focusOrder.reversed().compactMap { id in windows.first { $0.windowID == id } }
        return (recent + windows.reversed()).first {
            !$0.isClosed && !$0.isMicro && !$0.isSwitchingProfile && $0.context === micro.context
        }
    }

    @ObservationIgnored lazy var mcpServer = BrowserMCPServer(
        defaults: BrowserMCPServer.appDefaults,
        target: { [weak self] in
            guard let coordinator = self?.activeBrowsingCoordinator,
                  !coordinator.isClosed, coordinator.nativeWindow != nil,
                  !coordinator.profiles.isPrivate, !coordinator.isSwitchingProfile
            else { return nil }
            return coordinator.browser
        },
        available: { [weak self] browser in
            self?.windows.contains {
                $0.browser === browser && !$0.isClosed && $0.nativeWindow != nil && !$0.isMicro
                    && !$0.profiles.isPrivate && !$0.isSwitchingProfile && !$0.agentTurns.isRunning
            } == true
        },
        developerTarget: { [weak self] profileID in self?.developerWindow(profileID: profileID)?.browser }
    )

    /// The regular window of the Developer profile a paired client with a standing grant works in: the one used most
    /// recently, or a new one shown behind other windows. Never a private window, and it never activates WSurf or takes focus.
    func developerWindow(profileID: UUID) -> AppCoordinator? {
        guard profileID != Profile.privateID,
              let profile = ProfileStore.shared.profiles.first(where: { $0.id == profileID }) else { return nil }
        let recent = ([activeCoordinator].compactMap { $0 } + focusOrder.reversed().compactMap { id in windows.first { $0.windowID == id } })
        if let existing = (recent + windows).first(where: {
            !$0.isClosed && $0.nativeWindow != nil && !$0.isMicro && !$0.profiles.isPrivate && !$0.isSwitchingProfile
                && $0.context.profile.id == profileID
        }) {
            return existing
        }
        // Opening a window marks its profile as the current one; an unattended run must not change which profile the
        // next launch or new window starts in.
        let catalog = ProfileStore.shared
        let previous = catalog.current
        let opened = newWindow(profile: profile, show: false)
        catalog.markCurrent(previous)
        return opened
    }

    func bootstrap() async {
        guard !isReady, !isLaunching else { return }
        OutputDucker.restoreAfterUncleanExit()
        BrowserSettings.application.applyAppearance()
        // macOS forgets a runtime Dock icon when the app quits, so the choice is applied again at every launch.
        BrowserSettings.application.applyDockIcon()
        let menu = MainMenu(application: self)
        mainMenu = menu
        menu.install()
        updates.setChannel(BrowserSettings.application.updateChannel)
        updates.start()
        let lastWindowID = defaults.string(forKey: Self.lastWindowKey).flatMap(UUID.init(uuidString:))
        let catalog = ProfileStore.shared
        InputHistory.shared.purgeAllProfilesAtLaunch(catalog.profiles)
        CloudSync.startIfAvailable(profiles: catalog.profiles)
        let restore = beginLaunchRestore(of: catalog.profiles, lastWindowID: lastWindowID, launchProfileID: catalog.launchProfileID)
        if restore.lead != nil {
            // The window in front draws before the others are built.
            await Task.yield()
        }
        finishLaunch(restore, lastWindowID: lastWindowID)
    }

    /// The rest of a launch once its windows are restored. A quit that began while they opened stops it before the next one; a
    /// quit that is called off goes on from there (`cancelTermination`).
    private func finishLaunch(_ restore: LaunchRestore, lastWindowID: UUID?) {
        guard continueLaunchRestore(restore) else {
            interruptedLaunch = { [weak self] in self?.finishLaunch(restore, lastWindowID: lastWindowID) }
            return
        }
        let catalog = ProfileStore.shared
        // A micro window alone is not a launch: the person still gets a window to browse in.
        if !windows.contains(where: { !$0.isMicro }) {
            newWindow(profile: catalog.current)
        }
        if let profileID = catalog.launchProfileID,
           let profile = catalog.profiles.first(where: { $0.id == profileID }) {
            let window = windows.last { $0.profiles.current.id == profileID && !$0.isMicro }
                ?? newWindow(profile: profile, show: false)
            window.showBrowser()
        } else if let lastWindowID, let window = windows.first(where: { $0.windowID == lastWindowID }) {
            window.showBrowser()
        } else if activeCoordinator?.isMicro == true, let window = windows.last(where: { !$0.isMicro }) {
            window.showBrowser()
        }
        CloudTabs.shared?.publishAll(force: true)
        isReady = true
        let queued = queuedURLs
        queuedURLs.removeAll()
        openFromAnotherApp(queued)
        if CredentialExchangeCoordinator.shared.pendingToken != nil {
            showCredentialExchange()
        }
        mcpServer.resume()
        // The front window has drawn. Chromium's framework is read into memory off the main thread, where Chromium was used.
        ChromiumRuntime.shared.prepareInBackground()
        armChromiumPrewarm()
        // Every regular profile's watches, whether or not a window of it is open. Each waits a minute before its first reading.
        for profile in catalog.profiles {
            BrowserProfileContext.shared(for: profile).pageWatches?.resume()
        }
        if let coordinator = activeCoordinator {
            Task { await coordinator.offerLegacyPasswordImport() }
        }
    }

    /// Opens the windows each profile had open when the app last ran. A profile with none gets back the window the user
    /// closed last, but only when that window was the last regular window open and nothing opened after it. A window closed
    /// while others stayed open is left to Reopen Last Closed Window.
    func restoreWindows(of profiles: [Profile], show: Bool = true) {
        for step in restoreSteps(of: profiles) {
            open(step, show: show)
        }
        relinkMicroPlaceholders()
    }

    // MARK: - Launch

    /// One window a launch brings back.
    enum RestoreStep {
        /// A window that was open when the app last quit.
        case saved(BrowserModel.SavedBrowserWindow, Profile)
        /// The regular window the person closed last. It opens only if its profile has no regular window open by its turn.
        case closedAsLast(BrowserModel.SavedBrowserWindow, Profile)

        var window: BrowserModel.SavedBrowserWindow {
            switch self {
            case .saved(let window, _), .closedAsLast(let window, _):
                window
            }
        }

        var profile: Profile {
            switch self {
            case .saved(_, let profile), .closedAsLast(_, let profile):
                profile
            }
        }

        var isSaved: Bool {
            if case .saved = self {
                return true
            }
            return false
        }
    }

    /// A launch's restore: the windows in the order `restoreWindows` opens them, which one `beginLaunchRestore` opened first, and
    /// how far `continueLaunchRestore` got.
    @MainActor
    final class LaunchRestore {
        let steps: [RestoreStep]
        /// The step of the window that ends up in front, opened before the others; nil when no restored window is (the launch
        /// profile has none), and then every window opens in order.
        let lead: Int?
        /// The first step that opens a window: onboarding, release notes and the default-browser check belong to that window.
        let first: Int?
        fileprivate(set) var next = 0
        fileprivate(set) var opened: [(step: Int, window: AppCoordinator)] = []

        fileprivate init(steps: [RestoreStep], lead: Int?, first: Int?) {
            self.steps = steps
            self.lead = lead
            self.first = first
        }

        var leadWindow: AppCoordinator? {
            opened.first { $0.step == lead }?.window
        }
    }

    /// The saved windows of `profiles` in the order a launch opens them: each profile's regular windows, used longest ago first,
    /// then the window it closed last, then its micro windows. Takes the record of the window closed last.
    private func restoreSteps(of profiles: [Profile]) -> [RestoreStep] {
        let closedAsLast = takeWindowClosedAsLast()
        var steps: [RestoreStep] = []
        for profile in profiles {
            let database = BrowserProfileContext.shared(for: profile).database
            let saved = BrowserModel.savedWindows(in: database).reversed()
            steps += saved.filter { $0.windowKind == .standard }.map { .saved($0, profile) }
            // Micro windows come after: one left open at quit must not hide that the regular window was closed last.
            if let closedAsLast, closedAsLast.profileID == profile.id,
               let window = BrowserModel.savedWindows(in: database, includeClosed: true)
                .first(where: { $0.id == closedAsLast.windowID && $0.closedAt != nil }) {
                steps.append(.closedAsLast(window, profile))
            }
            steps += saved.filter { $0.windowKind == .micro }.map { .saved($0, profile) }
        }
        return steps
    }

    @discardableResult
    private func open(_ step: RestoreStep, show: Bool) -> AppCoordinator? {
        if case .closedAsLast = step {
            let context = BrowserProfileContext.shared(for: step.profile)
            guard !windows.contains(where: { $0.context === context && !$0.isMicro }) else { return nil }
        }
        return openSavedWindow(step.window, of: step.profile, show: show)
    }

    /// Starts a launch's restore with the window that ends up in front, so that it draws before the others are built;
    /// `continueLaunchRestore` opens the others behind it, in the order `restoreWindows` opens them. The window in front is the
    /// one `bootstrap` brings forward: the launch profile's last regular window, else the window used last, else the last regular
    /// window. When the launch profile has no restored window nothing opens here, and the others open in order as before.
    func beginLaunchRestore(of profiles: [Profile], lastWindowID: UUID?, launchProfileID: UUID?, show: Bool = true) -> LaunchRestore {
        isLaunching = true
        let steps = restoreSteps(of: profiles)
        // Which steps open a window: the window closed last only for a profile with no regular window to restore. (A saved window
        // whose ID cannot be remapped opens nothing either; that takes a failed database write and is not foreseen here.)
        let opens = steps.map { step in
            step.isSaved || !steps.contains { $0.isSaved && $0.window.windowKind == .standard && $0.profile.id == step.profile.id }
        }
        let regular = steps.indices.filter { opens[$0] && steps[$0].window.windowKind == .standard }
        let lead: Int? = if let launchProfileID {
            regular.last { steps[$0].profile.id == launchProfileID }
        } else if let lastWindowID, let used = regular.first(where: { steps[$0].window.id == lastWindowID }) {
            used
        } else {
            regular.last
        }
        let restore = LaunchRestore(steps: steps, lead: lead, first: opens.firstIndex(of: true))
        if let lead, let window = openLaunchStep(lead, of: restore, show: show) {
            restore.opened.append((lead, window))
        }
        return restore
    }

    /// Opens the rest of a launch's windows in order, each behind the window in front and above those opened before it, as they
    /// stood when each came forward in turn; then `windows` and the focus order are what opening them one after another leaves.
    /// A quit that begins first stops it before the next window and it returns false; the rest waits in `restore`. The windows
    /// not opened keep their saved rows untouched, so the next launch brings them back.
    @discardableResult
    func continueLaunchRestore(_ restore: LaunchRestore, show: Bool = true) -> Bool {
        let lead = restore.leadWindow
        while restore.next < restore.steps.count {
            guard !isTerminating else {
                keepWindowClosedAsLast(of: restore)
                return false
            }
            let step = restore.next
            restore.next += 1
            guard step != restore.lead, let window = openLaunchStep(step, of: restore, show: show && lead == nil) else { continue }
            restore.opened.append((step, window))
            if show, let lead {
                window.nativeWindow?.order(.below, relativeTo: lead.nativeWindow?.windowNumber ?? 0)
                focus(window)
            }
        }
        relinkMicroPlaceholders()
        let ordered = restore.opened.sorted { $0.step < $1.step }.map(\.window)
        windows = ordered.filter { window in windows.contains { $0 === window } }
            + windows.filter { window in !ordered.contains { $0 === window } }
        if show, let lead {
            focus(lead)
        }
        isLaunching = false
        return true
    }

    private func openLaunchStep(_ step: Int, of restore: LaunchRestore, show: Bool) -> AppCoordinator? {
        launchOpensFirstWindow = step == restore.first
        defer { launchOpensFirstWindow = nil }
        return open(restore.steps[step], show: show)
    }

    /// A quit that stops a launch before the window closed last opened puts its record back, so the next launch brings it back.
    private func keepWindowClosedAsLast(of restore: LaunchRestore) {
        for case .closedAsLast(let window, let profile) in restore.steps[restore.next...] {
            let context = BrowserProfileContext.shared(for: profile)
            guard !windows.contains(where: { $0.context === context && !$0.isMicro }) else { continue }
            defaults.set([profile.id.uuidString, window.id.uuidString], forKey: Self.closedAsLastKey)
        }
    }

    /// Whether the window opening now is the first one, which onboarding, release notes and the default-browser check belong to.
    /// A launch opens the window in front before the others, so while it restores the restore order decides.
    var isOpeningFirstWindow: Bool {
        launchOpensFirstWindow ?? (windows.count == 1)
    }

    @discardableResult
    private func openSavedWindow(_ saved: BrowserModel.SavedBrowserWindow, of profile: Profile, show: Bool = true) -> AppCoordinator? {
        var id = saved.id
        if id == BrowserModel.legacyWindowID || windows.contains(where: { $0.windowID == id }) {
            let uniqueID = UUID()
            guard BrowserModel.remapSavedWindow(
                in: BrowserProfileContext.shared(for: profile).database, from: id, to: uniqueID
            ) else { return nil }
            id = uniqueID
        }
        return newWindow(profile: profile, windowID: id, restoring: true, show: show, kind: saved.windowKind)
    }

    private func takeWindowClosedAsLast() -> (profileID: UUID, windowID: UUID)? {
        defer { defaults.removeObject(forKey: Self.closedAsLastKey) }
        guard let ids = defaults.stringArray(forKey: Self.closedAsLastKey), ids.count == 2,
              let profileID = UUID(uuidString: ids[0]), let windowID = UUID(uuidString: ids[1])
        else { return nil }
        return (profileID, windowID)
    }

    @discardableResult
    func newWindow(
        profile: Profile? = nil,
        settingsOwner: Profile? = nil,
        windowID: UUID = UUID(),
        restoring: Bool = false,
        show: Bool = true,
        urls: [URL] = [],
        kind: WindowKind = .standard,
        joining shared: BrowserProfileContext? = nil
    ) -> AppCoordinator {
        let profile = shared?.profile ?? profile ?? activeCoordinator?.profiles.current ?? ProfileStore.shared.current
        let owner = settingsOwner ?? activeCoordinator.map {
            $0.profiles.isPrivate ? $0.profiles.profileToReturnTo : $0.profiles.current
        } ?? ProfileStore.shared.current
        // A window can join a private context that is already open, which a new private window never does: its page is
        // the same session, and a context of its own would be another cookie store.
        let context = shared ?? BrowserProfileContext.shared(for: profile, settingsOwner: owner)
        let browser = BrowserModel(context: context, windowID: windowID)
        // Before the coordinator exists: what it builds, and what restores from the saved row, depends on it.
        browser.windowKind = kind
        let selection = ProfileStore.selection(profile: profile)
        if profile.isPrivate {
            selection.markCurrent(owner)
            selection.markCurrent(profile)
        }
        let coordinator = AppCoordinator(browser: browser, profiles: selection)
        register(coordinator)
        coordinator.prepareBrowser(restoring: restoring, show: show, urls: urls)
        if show {
            focus(coordinator)
            LaunchSignpost.windowShown()
        }
        return coordinator
    }

    func register(_ coordinator: AppCoordinator) {
        guard !coordinator.isClosed, !windows.contains(where: { $0 === coordinator }) else { return }
        precondition(!windows.contains { $0.windowID == coordinator.windowID })
        coordinator.application = self
        windows.append(coordinator)
        if isMuted {
            coordinator.silenceSpeech(true)
        }
        if !coordinator.profiles.isPrivate, !coordinator.isMicro {
            defaults.removeObject(forKey: Self.closedAsLastKey)
        }
        remember(coordinator.context)
        configureExtensions(coordinator.extensions, profile: coordinator.profiles.current)
    }

    @discardableResult
    func ensureActiveWindow() -> AppCoordinator {
        activeCoordinator ?? newWindow(profile: ProfileStore.shared.current)
    }

    /// Brings a window to the front for a Dock click: a window to browse in, never only a micro window.
    func showBrowser() {
        (activeBrowsingCoordinator ?? windows.last { !$0.isClosed && !$0.isMicro }
            ?? newWindow(profile: ProfileStore.shared.current)).showBrowser()
    }

    /// Unloads the background tabs of every open window. Each window keeps its current tab.
    @discardableResult
    func freeMemory() -> Int {
        windows.filter { !$0.isClosed }.reduce(0) { $0 + $1.browser.freeMemory() }
    }

    func focus(_ coordinator: AppCoordinator) {
        guard !coordinator.isClosed, windows.contains(where: { $0 === coordinator }) else { return }
        activeWindowID = coordinator.windowID
        focusOrder.removeAll { $0 == coordinator.windowID }
        focusOrder.append(coordinator.windowID)
        if !coordinator.profiles.isPrivate, !coordinator.isMicro, !AppDatabase.isRunningTests {
            defaults.set(coordinator.windowID.uuidString, forKey: Self.lastWindowKey)
        }
        coordinator.extensions.focus(browser: coordinator.browser)
        for window in windows {
            window.activation.setSuspended(window !== coordinator)
        }
    }

    func didClose(_ coordinator: AppCoordinator) {
        guard !isTerminating else { return }
        mcpServer.disconnect(browser: coordinator.browser)
        coordinator.extensions.unregister(browser: coordinator.browser)
        windows.removeAll { $0 === coordinator }
        focusOrder.removeAll { $0 == coordinator.windowID }
        if activeWindowID == coordinator.windowID {
            activeWindowID = focusOrder.last ?? windows.last?.windowID
        }
        // A private window keeps nothing, so it neither counts as an open window nor leaves a window to bring back.
        // A micro window is neither: it is not the window to bring back, and one left open does not hide that the last
        // regular window closed.
        if !coordinator.profiles.isPrivate, !coordinator.isMicro,
           !windows.contains(where: { !$0.isClosed && !$0.profiles.isPrivate && !$0.isMicro }) {
            defaults.set([coordinator.context.profile.id.uuidString, coordinator.windowID.uuidString], forKey: Self.closedAsLastKey)
        }
    }

    func openFromAnotherApp(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        guard isReady else {
            queuedURLs.append(contentsOf: urls)
            return
        }
        let target = externalLinkTarget ?? newWindow(profile: ProfileStore.shared.current)
        target.openFromAnotherApp(urls)
    }

    /// The system delivers an import from another app as an activity that carries only a token. Queueing it fetches
    /// nothing: the credential page asks for the profile, the unlock and the review first, and the import is bound
    /// to the profile whose page the user reviews it from. Before bootstrap finishes the token waits in the
    /// exchange coordinator and `bootstrap` shows it. A token refused because another transfer is open is not dropped
    /// silently: the coordinator keeps its refusal and the credential page opens to show it; a token it ignores opens nothing.
    @discardableResult
    func receiveCredentialExchange(_ activity: NSUserActivity) -> Bool {
        let coordinator = CredentialExchangeCoordinator.shared
        let received = coordinator.receive(activity)
        if isReady, received != .ignored {
            showCredentialExchange()
        }
        return received == .accepted
    }

    /// Opens the credential page in the window external links go to: never a private window, which keeps no vault.
    private func showCredentialExchange() {
        (externalLinkTarget ?? newWindow(profile: ProfileStore.shared.current)).openSettings(.autofill)
    }

    var canReopenWindow: Bool {
        mostRecentlyClosedWindow() != nil
    }

    func reopenLastClosedWindow() {
        guard let (profile, saved) = mostRecentlyClosedWindow() else { return }
        openSavedWindow(saved, of: profile)
        relinkMicroPlaceholders()
    }

    private func mostRecentlyClosedWindow() -> (Profile, BrowserModel.SavedBrowserWindow)? {
        ProfileStore.shared.profiles.flatMap { profile in
            BrowserModel.savedWindows(in: BrowserProfileContext.shared(for: profile).database, includeClosed: true)
                .filter { $0.closedAt != nil }
                .map { (profile, $0) }
        }.max { ($0.1.closedAt ?? .distantPast) < ($1.1.closedAt ?? .distantPast) }
    }

    func coordinator(for page: BrowserPage) -> AppCoordinator? {
        windows.first { coordinator in
            !coordinator.isClosed && coordinator.context === page.context
                && (coordinator.browser.tabs.contains { $0.liveView === page }
                    || coordinator.peek.tab?.liveView === page)
        }
    }

    private func installSharedRouting() {
        GeolocationBridge.shared.tabResolver = { [weak self] page in
            self?.coordinator(for: page)?.browser.tabs.first { $0.liveView === page }
        }
        NotificationBridge.shared.tabResolver = GeolocationBridge.shared.tabResolver
        NotificationBridge.shared.openWatchedPage = { [weak self] url, profileID in
            self?.openWatchedPage(url, profileID: profileID)
        }
        TabWebView.refreshHoverShield = { [weak self] in
            self?.windows.forEach { $0.applyHoverShield() }
        }
        PageClickWatcher.shared.onClick = { [weak self] page, point in
            self?.coordinator(for: page)?.downloadFlights.noteClick(at: point)
        }
        AutofillSuggestions.shared.openSettings = { [weak self] in
            self?.ensureActiveWindow().openSettings(.autofill)
        }
        let settings = BrowserSettings.application
        settings.onWebPreferencesChanged = { [weak self] in
            self?.windows.forEach { $0.browser.applyWebSettings() }
        }
        settings.onUpdateChannelChanged = { [weak self] channel in
            self?.updates.setChannel(channel)
        }
        settings.onSleepPolicyChanged = { [weak self] in
            self?.windows.forEach { $0.applySleepTimer() }
        }
        settings.onLyricsChanged = { [weak self] enabled in
            self?.windows.forEach { $0.sidePanel.setAvailable(enabled, for: .lyrics) }
        }
        settings.onMediaPlayerChanged = { [weak self] enabled in
            self?.windows.forEach { $0.media.isEnabled = enabled }
        }
        settings.onAutomaticPictureInPictureChanged = { [weak self] _ in
            self?.windows.forEach { $0.applyPictureLending() }
        }
        settings.onVideoInPlayerChanged = { [weak self] _ in
            self?.windows.forEach { $0.applyPictureLending() }
        }
    }

    func prepareWebScripts(for coordinator: AppCoordinator) {
        remember(coordinator.context)
        coordinator.context.webViewPool.configurePage = { [weak self] page in
            page.installScript(MediaCenter.frameScriptSource, in: BrowserPage.servicesWorld, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            page.addScriptMessageHandler(name: MediaCenter.frameScriptHandlerName, in: BrowserPage.servicesWorld) { [weak self] message in
                guard let body = message.body as? String else { return }
                self?.coordinator(for: message.page)?.media.receiveScriptMessage(
                    body, from: message.page, isMainFrame: message.frameInfo.isMainFrame, frameID: message.frameInfo.chromiumID
                )
            }
            MediaCenter.watchFrames(of: page) { [weak self] in self?.coordinator(for: $0)?.media }
            GeolocationBridge.shared.install(in: page)
            NotificationBridge.shared.install(in: page)
        }
    }

    func prepareToTerminate() {
        isTerminating = true
        // Chromium must not start while the app quits.
        chromiumPrewarm?.cancel()
        // Every profile's vault, synchronously and before anything below can suspend. A cancelled termination leaves them
        // locked: unlocking again is one explicit user action, never an implicit one.
        CredentialManager.lockAll(reason: .termination)
        mcpServer.stop()
        // The trees are still whole here; `closeTabsForTermination` empties them later.
        CloudSync.shared?.prepareToTerminate()
        for coordinator in windows {
            coordinator.stopAgent()
            coordinator.voiceInput.cancel()
            coordinator.browser.saveBlocking()
            coordinator.conversationLog.saveBlocking()
        }
    }

    func cancelTermination() {
        isTerminating = false
        CloudSync.shared?.cancelTermination()
        if let resume = interruptedLaunch {
            // The quit came while launch was still opening windows: launch goes on, and resumes the server as it does.
            interruptedLaunch = nil
            resume()
        } else {
            mcpServer.resume()
        }
    }

    func endPrivateSession(_ context: BrowserProfileContext) {
        guard context.profile.isPrivate, privateSessionCleanups[context.contextID] == nil else { return }
        privateSessionCleanups[context.contextID] = Task { [weak self] in
            await context.endPrivateSession()
            self?.privateSessionCleanups[context.contextID] = nil
        }
    }

    func clearDataOnQuitIfNeeded() async throws {
        // Preflight all persistent contexts before deleting any data or closing private pages.
        for context in usedProfiles.values where context.settings.clearsDataOnQuit {
            try ChromiumRuntime.shared.preflightClearData(context: context, kinds: [.cookies, .cache], since: .distantPast)
        }
        for coordinator in windows where coordinator.profiles.isPrivate {
            coordinator.closePeekImmediately()
            coordinator.browser.closeAllTabs(saving: false)
            coordinator.conversationLog.clearAll()
            endPrivateSession(coordinator.context)
        }
        for cleanup in Array(privateSessionCleanups.values) {
            await cleanup.value
        }
        for context in usedProfiles.values where context.settings.clearsDataOnQuit {
            let tabs = windows.filter { $0.context === context }.flatMap { $0.browser.tabs }
            try await BrowsingData.clearEverything(
                history: context.history,
                tabs: tabs, context: context
            )
        }
    }

    var hasDataToClearOnQuit: Bool {
        !privateSessionCleanups.isEmpty || windows.contains { $0.profiles.isPrivate }
            || usedProfiles.values.contains { $0.settings.clearsDataOnQuit }
    }

    func closePagesForTermination() async {
        await closeTabsForTermination()
        await ChromiumRuntime.shared.shutdown()
    }

    func closeTabsForTermination() async {
        for coordinator in windows {
            coordinator.media.releaseControl()
            coordinator.media.unwatch()
            coordinator.closePeekImmediately()
            let tabs = coordinator.browser.tabs
            coordinator.browser.closeAllTabs(saving: false)
            for tab in tabs {
                await tab.waitForRetirement()
            }
        }
    }

    func finishTermination() {
        isTerminating = true
        for context in usedProfiles.values {
            context.downloads.clearOnQuitIfNeeded(context.settings.downloadRetention)
        }
    }

    private func remember(_ context: BrowserProfileContext) {
        if !context.profile.isPrivate {
            usedProfiles[context.profile.id] = context
        }
    }

    func forgetProfile(_ id: UUID) {
        usedProfiles[id] = nil
    }

    func configureExtensions(_ manager: ExtensionManager, profile: Profile) {
        manager.onOpenWindow = { [weak self, weak manager] configuration in
            guard let self, let manager else { return nil }
            return openExtensionWindow(
                for: manager, profile: profile, privately: configuration.shouldBePrivate,
                focused: configuration.shouldBeFocused, urls: configuration.tabURLs,
                tabs: configuration.tabs.compactMap { $0 as? ExtensionTabAdapter }
            )
        }
    }

    /// Opens the window an extension asked for. The window starts with a tab of its own, which the requested
    /// pages replace.
    func openExtensionWindow(
        for manager: ExtensionManager, profile: Profile, privately: Bool, focused: Bool,
        urls: [URL], tabs requested: [ExtensionTabAdapter]
    ) -> ExtensionWindowAdapter? {
        guard let source = windows.first(where: { !$0.isClosed && $0.extensions === manager }) else { return nil }
        let owner = source.profiles.isPrivate ? source.profiles.profileToReturnTo : profile
        let coordinator = newWindow(
            profile: privately ? .privateBrowsing() : owner, settingsOwner: owner, show: focused
        )
        // The profile's pins fill every new window. Closing one would remove it from all of them.
        let initialTabs = coordinator.browser.tabs.filter { $0.pinID == nil }
        var hasRequestedTab = !urls.isEmpty
        for url in urls.reversed() {
            coordinator.openNewTab(url: url)
        }
        for adapter in requested {
            guard let oldOwner = adapter.browser, let tab = adapter.tab else { continue }
            if coordinator.browser.adoptTab(tab, from: oldOwner) {
                hasRequestedTab = true
            }
        }
        if hasRequestedTab {
            for tab in initialTabs {
                coordinator.browser.close(tab, recordForReopening: false)
            }
        }
        return coordinator.extensions.adapter(for: coordinator.browser)
    }
}
