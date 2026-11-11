// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import SwiftUI

// MARK: - The status bar, behind a seam

/// The menu bar item as the controller uses it. The system's is `SystemPasswordsStatusItem`; a test makes its own, because a test host
/// must never put an item in the person's menu bar.
@MainActor
protocol PasswordsStatusItemHandle: AnyObject {
    var isVisible: Bool { get set }
    var behavior: NSStatusItem.Behavior { get set }
    /// The view the popover hangs from; nil where there is none (a test).
    var anchor: NSView? { get }
    func onClick(_ action: @escaping @MainActor () -> Void)
}

@MainActor
protocol PasswordsStatusBar {
    func makeItem() -> any PasswordsStatusItemHandle
}

struct SystemPasswordsStatusBar: PasswordsStatusBar {
    func makeItem() -> any PasswordsStatusItemHandle {
        SystemPasswordsStatusItem()
    }
}

/// The key in the menu bar: a template image, so the system draws it for the light, dark and tinted menu bars alike. Its look never
/// shows the lock state (the popover does).
@MainActor
final class SystemPasswordsStatusItem: NSObject, PasswordsStatusItemHandle {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private var click: (@MainActor () -> Void)?

    override init() {
        super.init()
        let name = String(localized: "Passwords")
        if let button = item.button {
            let image = NSImage(systemSymbolName: "key.fill", accessibilityDescription: name)
            image?.isTemplate = true
            button.image = image
            button.toolTip = name
            button.setAccessibilityLabel(name)
            button.setAccessibilityHelp(name)
            button.target = self
            button.action = #selector(clicked)
        }
    }

    var isVisible: Bool {
        get { item.isVisible }
        set { item.isVisible = newValue }
    }

    var behavior: NSStatusItem.Behavior {
        get { item.behavior }
        set { item.behavior = newValue }
    }

    var anchor: NSView? {
        item.button
    }

    func onClick(_ action: @escaping @MainActor () -> Void) {
        click = action
    }

    @objc private func clicked() {
        click?()
    }
}

// MARK: - Controller

/// The Passwords item in the menu bar and its popover: a second view onto the credentials model, in the WSurf process. It adds no
/// store, no copy of the vault and no secret path.
///
/// - It never unlocks. "Unlock…" opens the Passwords window, and the unlock (Touch ID, passkey) runs there, where it has a window to
///   anchor to. A transient popover is no place for a system sheet.
/// - Everything it copies goes through `CredentialSettingsModel.copy`: Touch ID on every password and code, `SecretClipboard`.
/// - It holds no model until the first open, and drops it, with the popover's content, when the popover closes: SwiftUI's
///   `onDisappear` does not reliably run for a popover, and it is what forgets an unlocked session.
/// - It is native and outside every tab, so no page, assistant or connected app can open or read it.
@MainActor
final class PasswordsStatusItem: NSObject, NSPopoverDelegate {
    static let shared = PasswordsStatusItem()
    static let popoverSize = NSSize(width: 340, height: 460)

    private let statusBar: any PasswordsStatusBar
    private let profiles: ProfileStore
    private let makeModel: @MainActor (Profile) -> CredentialSettingsModel
    /// The tab of the front browser window; nil with no window.
    private let frontTab: @MainActor () -> PasswordsMenuList.FrontTab?
    private let lockEverything: () -> Void
    private let openSettingsPage: @MainActor (Profile) -> Void

    private var isInstalled = false
    private(set) var handle: (any PasswordsStatusItemHandle)?
    private(set) var model: CredentialSettingsModel?
    private(set) var popover: NSPopover?
    /// The origin of the front tab when the popover opened; "Matching This Website" follows it.
    private(set) var frontOrigin: String?
    /// The copy in flight (its Touch ID prompt included). It belongs to this controller, not to the view: the system sheet may close
    /// the transient popover, and the copy still ends, or fails under its own checks, and only then is the model closed.
    private(set) var copyTask: Task<Void, Never>?

    /// The parameters are seams for tests, which must not touch the menu bar, open a vault or lock the real ones.
    init(
        statusBar: any PasswordsStatusBar = SystemPasswordsStatusBar(),
        profiles: ProfileStore = .shared,
        makeModel: @escaping @MainActor (Profile) -> CredentialSettingsModel = PasswordsStatusItem.makeSystemModel,
        frontTab: @escaping @MainActor () -> PasswordsMenuList.FrontTab? = PasswordsStatusItem.systemFrontTab,
        lockEverything: @escaping () -> Void = { CredentialManager.lockAll(reason: .manual) },
        openSettings: @escaping @MainActor (Profile) -> Void = PasswordsStatusItem.openSystemSettings
    ) {
        self.statusBar = statusBar
        self.profiles = profiles
        self.makeModel = makeModel
        self.frontTab = frontTab
        self.lockEverything = lockEverything
        openSettingsPage = openSettings
        super.init()
    }

    // MARK: Install

    /// Shows the item when the setting asks, and follows the setting from then on. Reads no model and no store: the first open builds them.
    func install(settings: BrowserSettings) {
        guard !isInstalled else { return }
        isInstalled = true
        setVisible(settings.showsPasswordsInMenuBar)
        settings.onPasswordsMenuBarChanged = { [weak self] visible in self?.setVisible(visible) }
    }

    /// The item is created when first shown, and only hidden after that. It never offers removal by ⌘-drag, which would leave the
    /// switch in Settings saying on with no icon.
    func setVisible(_ visible: Bool) {
        guard isInstalled else { return }
        if visible {
            item().isVisible = true
        } else {
            handle?.isVisible = false
            closePopover()
        }
    }

    private func item() -> any PasswordsStatusItemHandle {
        if let handle {
            return handle
        }
        let made = statusBar.makeItem()
        made.behavior = []
        made.onClick { [weak self] in self?.toggle() }
        handle = made
        return made
    }

    // MARK: Popover

    var isOpen: Bool {
        popover != nil
    }

    func toggle() {
        if isOpen {
            closePopover()
        } else {
            open()
        }
    }

    /// Binds to the profile shown now (a profile switch locked the one left, so nothing stale is offered), builds the content fresh and
    /// shows the popover. A copy still in flight from the last open keeps its model.
    func open() {
        guard popover == nil else { return }
        let profile = profile
        if model?.profile.id != profile.id {
            model = makeModel(profile)
        }
        guard let model else { return }
        frontOrigin = PasswordsMenuList.origin(of: frontTab(), shown: profile.id)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = Self.popoverSize
        popover.contentViewController = NSHostingController(rootView: PasswordsMenuView(model: model, origin: frontOrigin, actions: self))
        self.popover = popover
        if let anchor = handle?.anchor {
            // The search field takes the keyboard only in the active app.
            NSApp.activate()
            popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        }
    }

    func closePopover() {
        if let popover, popover.isShown {
            popover.performClose(nil)
        } else {
            finishClose()
        }
    }

    func popoverDidClose(_ notification: Notification) {
        finishClose()
    }

    /// The popover's content is dropped now; the model is closed now, or when the copy in flight ends.
    private func finishClose() {
        popover?.contentViewController = nil
        popover = nil
        releaseModelUnlessCopying()
    }

    private func releaseModelUnlessCopying() {
        guard copyTask == nil else { return }
        model?.close()
        model = nil
    }

    /// The profile the popover shows: never a private one, which keeps no vault.
    var profile: Profile {
        profiles.isPrivate ? profiles.profileToReturnTo : profiles.current
    }

    // MARK: Actions

    /// Copies one part of a stored credential through the model, which asks for Touch ID before a password or a code and puts a secret
    /// on the clipboard only through `SecretClipboard`. A second copy waits for the first one's prompt.
    func copy(_ part: CredentialCopyPart, of id: UUID) {
        guard copyTask == nil, let model else { return }
        copyTask = Task { [weak self] in
            await model.attempt { try await model.copy(part, of: .stored(id)) }
            self?.copyEnded()
        }
    }

    private func copyEnded() {
        copyTask = nil
        if popover == nil {
            releaseModelUnlessCopying()
        }
    }

    func perform(_ action: PasswordsMenuAction, on summary: CredentialSummary) {
        switch action {
        case .copyUsername:
            copy(.username, of: summary.id)
        case .copyPassword:
            copy(.password, of: summary.id)
        case .copyCode:
            copy(.code, of: summary.id)
        case .openWebsite:
            if model?.openWebsite(summary.website) == true {
                closePopover()
            }
        }
    }

    /// Opens the Passwords window, where the unlock runs. The popover itself never unlocks.
    func unlock() {
        openPasswords()
    }

    func openPasswords() {
        PasswordsWindow.shared.show()
        closePopover()
    }

    /// Locks every vault of every profile and Input History (`CredentialManager.lockAll`), and so empties this popover and the window.
    func lockNow() {
        lockEverything()
    }

    func openSettings() {
        closePopover()
        openSettingsPage(profile)
    }

    func quit() {
        NSApp.terminate(nil)
    }

    // MARK: The system's seams

    static func makeSystemModel(for profile: Profile) -> CredentialSettingsModel {
        let model = CredentialSettingsModel(profile: profile)
        model.websiteOpener = { url in
            let target = PasswordsWindowContent.linkTarget(in: BrowserApplication.shared, for: profile)
            target.browser.newTab(url: url, activate: true, after: target.browser.activeTab)
            target.showBrowser()
        }
        return model
    }

    /// The active tab of the front browser window (not a micro window, which holds one page).
    static func systemFrontTab() -> PasswordsMenuList.FrontTab? {
        guard let window = BrowserApplication.shared.activeCoordinator, !window.isClosed, !window.isMicro else { return nil }
        return PasswordsMenuList.FrontTab(
            url: window.browser.activeTab.flatMap { URL(string: $0.urlString) },
            profileID: window.profiles.current.id,
            isPrivate: window.profiles.isPrivate
        )
    }

    /// A Settings tab needs a browser window: the external-link window of the profile, else a new one. Never a private one.
    static func openSystemSettings(for profile: Profile) {
        let app = BrowserApplication.shared
        (app.externalLinkTarget(for: profile) ?? app.newWindow(profile: profile)).openSettings()
    }
}
