// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import Testing

@testable import WSurf
@testable import WSurfVault

/// A status bar that makes items of its own: a test host must never put an item in the person's menu bar.
@MainActor
private final class FakeStatusBar: PasswordsStatusBar {
    final class Item: PasswordsStatusItemHandle {
        var isVisible = false
        var behavior: NSStatusItem.Behavior = []
        let anchor: NSView? = nil
        private var click: (@MainActor () -> Void)?

        func onClick(_ action: @escaping @MainActor () -> Void) {
            click = action
        }

        func press() {
            click?()
        }
    }

    private(set) var items: [Item] = []

    func makeItem() -> any PasswordsStatusItemHandle {
        let item = Item()
        items.append(item)
        return item
    }
}

/// Holds a Touch ID prompt open until the test lets it answer.
@MainActor
private final class Prompt {
    private(set) var calls = 0
    var failure: (any Error)?
    private var waiting: CheckedContinuation<Void, Never>?
    var holds = false

    var isWaiting: Bool {
        waiting != nil
    }

    func verify() async throws {
        calls += 1
        if holds {
            await withCheckedContinuation { waiting = $0 }
        }
        if let failure {
            throw failure
        }
    }

    func answer() {
        waiting?.resume()
        waiting = nil
    }
}

/// The menu bar item and its popover, over fakes: no status item, no real vault of a person, no system prompt. Every case that opens a
/// vault runs on a fixture profile and a private pasteboard.
@MainActor
@Suite(.serialized)
struct PasswordsStatusItemTests {
    private static let concealed = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    private final class Rig {
        let bar = FakeStatusBar()
        let prompt = Prompt()
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("io.wsagency.wsurf.tests.\(UUID().uuidString)"))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("profiles-\(UUID()).json")
        let catalog: ProfileStore
        let selection: ProfileStore
        let clock = TestClock()
        /// The model the status item gets, and the profiles it asked for.
        var model: CredentialSettingsModel?
        private(set) var requested: [UUID] = []
        var openedWebsites: [URL] = []
        var controller: PasswordsStatusItem!

        init() {
            catalog = ProfileStore(file: file)
            selection = ProfileStore.selection(profile: .original(), catalog: catalog)
            controller = PasswordsStatusItem(
                statusBar: bar, profiles: { [selection] in selection },
                makeModel: { [unowned self] profile in
                    requested.append(profile.id)
                    let made = model ?? CredentialSettingsModel(profile: .privateBrowsing(), verifyUser: { _ in })
                    made.websiteOpener = { [unowned self] in openedWebsites.append($0) }
                    return made
                },
                frontTab: { nil }, openSettings: { _ in }
            )
        }

        func tearDown() {
            controller.closePopover()
            pasteboard.releaseGlobally()
            try? FileManager.default.removeItem(at: file)
        }

        var text: String? {
            pasteboard.string(forType: .string)
        }

        var isConcealed: Bool {
            pasteboard.types?.contains(PasswordsStatusItemTests.concealed) == true
        }

        func sentinel() -> String {
            pasteboard.clearContents()
            pasteboard.setString("sentinel-not-a-secret", forType: .string)
            return "sentinel-not-a-secret"
        }
    }

    /// A rig over a fixture vault that holds `accounts` and is unlocked and read, with a model whose Touch ID is the rig's prompt.
    private func withVault(
        unlocked: Bool = true, accounts: [CredentialAccount] = [], _ body: (Rig, FixtureVault) async throws -> Void
    ) async throws {
        try await VaultManagerFixture.with(vaults: [.locked]) { profile, _, vaults in
            let vault = try #require(vaults.first)
            let rig = Rig()
            defer { rig.tearDown() }
            rig.model = CredentialSettingsModel(
                profile: profile, pasteboard: rig.pasteboard, manager: vault.manager,
                verifyUser: { _ in try await rig.prompt.verify() }, clock: rig.clock
            )
            if unlocked {
                try await VaultManagerFixture.unlock(vault)
                try await VaultManagerFixture.save(accounts, in: vault)
            }
            await rig.model?.load()
            try await body(rig, vault)
        }
    }

    private func login(_ password: String = "pw-secret", displayName: String? = nil) -> CredentialAccount {
        var account = VaultFixtures.account(password: password)
        account.displayName = displayName
        return account
    }

    /// Settings of their own over a throwaway defaults suite, so no test reads or writes the app's.
    private func withSettings(_ body: (BrowserSettings) throws -> Void) throws {
        let name = AppDatabase.defaultsSuite("PasswordsStatusItemTests-\(UUID().uuidString)")
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        try body(BrowserSettings(defaults: defaults, appliesAppearanceGlobally: false))
    }

    /// Lets the copy in flight end, as the status item's own task does.
    private func finishCopy(_ rig: Rig) async {
        await rig.controller.copyTask?.value
    }

    private func waitUntilAsking(_ prompt: Prompt) async throws {
        for _ in 0..<500 where !prompt.isWaiting {
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(prompt.isWaiting, "the Touch ID prompt never opened")
    }

    // MARK: Install

    @Test func installingMakesNoModelAndReadsNoVault() throws {
        let rig = Rig()
        defer { rig.tearDown() }
        try withSettings { settings in
            rig.controller.install(settings: settings)

            #expect(rig.requested.isEmpty && rig.controller.model == nil && !rig.controller.isOpen, "no model, no store, until the first open")
            #expect(rig.bar.items.count == 1)
            #expect(rig.bar.items.first?.isVisible == true)
            // A second install changes nothing.
            rig.controller.install(settings: settings)
            #expect(rig.bar.items.count == 1)
        }
    }

    @Test func theSettingShowsAndHidesTheItemAndTheItemNeverOffersRemoval() throws {
        let rig = Rig()
        defer { rig.tearDown() }
        try withSettings { settings in
            settings.showsPasswordsInMenuBar = false

            rig.controller.install(settings: settings)
            #expect(rig.bar.items.isEmpty, "off at launch: no item is made")

            settings.showsPasswordsInMenuBar = true
            let item = try #require(rig.bar.items.first)
            #expect(item.isVisible)
            #expect(!item.behavior.contains(.removalAllowed), "⌘-drag cannot leave the switch on with no icon")

            settings.showsPasswordsInMenuBar = false
            #expect(!item.isVisible)
            settings.showsPasswordsInMenuBar = true
            #expect(item.isVisible)
            #expect(rig.bar.items.count == 1, "the one item is hidden and shown, not made again")
            #expect(!item.behavior.contains(.removalAllowed))
        }
    }

    @Test func hidingTheItemClosesItsPopover() throws {
        let rig = Rig()
        defer { rig.tearDown() }
        try withSettings { settings in
            rig.controller.install(settings: settings)
            rig.controller.open()
            #expect(rig.controller.isOpen)

            settings.showsPasswordsInMenuBar = false

            #expect(!rig.controller.isOpen && rig.controller.model == nil)
        }
    }

    @Test func aClickOnTheItemOpensAndClosesThePopover() throws {
        let rig = Rig()
        defer { rig.tearDown() }
        try withSettings { settings in
            rig.controller.install(settings: settings)
            let item = try #require(rig.bar.items.first)

            item.press()
            #expect(rig.controller.isOpen && rig.controller.model != nil)
            item.press()
            #expect(!rig.controller.isOpen && rig.controller.model == nil)
        }
    }

    // MARK: Locked

    /// The rule of the popover: while the vault is locked nothing of it is listed, and a lock empties a list already read.
    @Test func whileLockedNothingOfTheVaultIsListed() async throws {
        try await withVault(unlocked: false) { rig, _ in
            let model = try #require(rig.model)
            let content = PasswordsMenuContent(model: model, origin: nil)

            #expect(model.menuPhase == .locked)
            #expect(model.menuSections(query: "", origin: nil) == nil)
            #expect(model.summaries.isEmpty)
            content.refresh()
            #expect(content.sections == nil && content.rows.isEmpty && content.selected == nil)
        }
        try await withVault(accounts: [login(displayName: "Work"), login(displayName: "Home")]) { rig, vault in
            let model = try #require(rig.model)
            let content = PasswordsMenuContent(model: model, origin: nil)
            content.refresh()
            #expect(model.menuPhase == .content)
            #expect(content.rows.count == 2 && content.selection != nil)

            // A lock empties the list at once, before any refresh: the copy the popover read does not outlive the unlock.
            vault.manager.lock(reason: .manual)
            #expect(model.menuPhase == .locked)
            #expect(content.sections == nil && content.rows.isEmpty && content.selected == nil)

            // An unlock is a new epoch: the old copy is not shown again before the list is read under the new one.
            try await VaultManagerFixture.unlock(vault)
            #expect(content.sections == nil)
            await model.load()
            content.refresh()
            #expect(content.rows.count == 2)
        }
    }

    @Test func theLockedPopoverUnlocksNothingItOpensThePasswordsWindow() async throws {
        try await withVault(unlocked: false) { rig, vault in
            let window = PasswordsWindowRig()
            let previous = PasswordsWindow.shared
            PasswordsWindow.shared = window.controller
            defer {
                PasswordsWindow.shared = previous
                window.tearDown()
            }
            rig.controller.open()
            #expect(rig.controller.model?.menuPhase == .locked)
            #expect(window.builtProfileIDs.isEmpty)

            rig.controller.openPasswords()

            #expect(window.builtProfileIDs.count == 1 && window.controller.window?.isVisible == true, "the unlock runs in the window")
            #expect(!rig.controller.isOpen, "the popover closes")
            #expect(!vault.manager.isUnlocked, "the popover itself unlocked nothing")
            #expect(rig.prompt.calls == 0)
        }
    }

    @Test func aPrivateProfileHasNoVaultToShow() {
        let rig = Rig()
        defer { rig.tearDown() }
        let work = rig.catalog.add(name: "Work")
        rig.selection.markCurrent(work)
        rig.selection.markCurrent(.privateBrowsing())

        rig.controller.open()

        #expect(rig.controller.profile.id == work.id, "private browsing shows the profile to return to")
        #expect(rig.requested == [work.id], "the popover bound to that profile, not to the private one")
        // A private profile keeps no vault: the model the rig falls back to is one, and it lists nothing.
        #expect(rig.controller.model?.menuPhase == .unavailable)
        #expect(rig.controller.model?.menuSections(query: "", origin: nil) == nil)
    }

    // MARK: Copy

    @Test func copyingAPasswordAsksUnderTheRigsModelAndAFailedAskLeavesTheClipboardAlone() async throws {
        let account = login("pw-secret")
        try await withVault(accounts: [account]) { rig, _ in
            let model = try #require(rig.model)
            rig.controller.open()
            let summary = try #require(model.summaries.first { $0.id == account.id })

            rig.controller.perform(.copyPassword, on: summary)
            await finishCopy(rig)
            #expect(rig.prompt.calls == 1)
            #expect(rig.text == "pw-secret" && rig.isConcealed, "a secret leaves only through SecretClipboard")

            rig.controller.perform(.copyPassword, on: summary)
            await finishCopy(rig)
            #expect(rig.prompt.calls == 2, "Touch ID on every copy, not once per open")

            let sentinel = rig.sentinel()
            rig.prompt.failure = WebsiteAuthenticatorError.notAllowed
            rig.controller.perform(.copyPassword, on: summary)
            await finishCopy(rig)
            #expect(rig.prompt.calls == 3)
            #expect(rig.text == sentinel, "a refused prompt copies nothing")
            #expect(model.error != nil)
        }
    }

    @Test func copyingAVerificationCodeAsksUnderTheRigsModelAndAFailedAskLeavesTheClipboardAlone() async throws {
        var account = login()
        account.totp = TOTPGenerator(
            secret: Data("12345678901234567890".utf8), algorithm: .sha1, period: 30, digits: 8, issuer: "Example", userName: "ada"
        )
        try await withVault(accounts: [account]) { rig, _ in
            let model = try #require(rig.model)
            rig.controller.open()
            let summary = try #require(model.summaries.first { $0.id == account.id })
            #expect(summary.hasTOTP)

            rig.controller.perform(.copyCode, on: summary)
            await finishCopy(rig)
            #expect(rig.prompt.calls == 1)
            #expect(rig.text?.count == 8 && rig.text?.allSatisfy(\.isNumber) == true && rig.isConcealed, "a code is a secret too")

            rig.controller.perform(.copyCode, on: summary)
            await finishCopy(rig)
            #expect(rig.prompt.calls == 2, "Touch ID on every code, not once per open")

            let sentinel = rig.sentinel()
            rig.prompt.failure = WebsiteAuthenticatorError.notAllowed
            rig.controller.perform(.copyCode, on: summary)
            await finishCopy(rig)
            #expect(rig.prompt.calls == 3)
            #expect(rig.text == sentinel, "a refused prompt copies no code")
        }
    }

    @Test func aUsernameCopiesWithoutAPrompt() async throws {
        let account = login()
        try await withVault(accounts: [account]) { rig, _ in
            let model = try #require(rig.model)
            rig.controller.open()
            let summary = try #require(model.summaries.first)

            rig.controller.perform(.copyUsername, on: summary)
            await finishCopy(rig)

            #expect(rig.text == "ada" && rig.prompt.calls == 0)
        }
    }

    /// What the owner asked for: a login needs two copies, and one confirmation covers both. The popover's real model shares the
    /// process-wide window with the Passwords window's (`CopyGrace.shared`); here the rig's model has one of its own on the rig's clock.
    @Test func oneConfirmationCoversTheNextCopiesOfThePopoverForThirtySeconds() async throws {
        var account = login("pw-secret")
        account.totp = TOTPGenerator(
            secret: Data("12345678901234567890".utf8), algorithm: .sha1, period: 30, digits: 8, issuer: "Example", userName: "ada"
        )
        try await withVault(accounts: [account]) { rig, _ in
            let model = try #require(rig.model)
            model.copyGrace = CopyGrace(now: { rig.clock.now })
            rig.controller.open()
            let summary = try #require(model.summaries.first)

            rig.controller.perform(.copyPassword, on: summary)
            await finishCopy(rig)
            rig.controller.perform(.copyUsername, on: summary)
            await finishCopy(rig)
            #expect(rig.text == "ada")
            rig.controller.perform(.copyCode, on: summary)
            await finishCopy(rig)
            #expect(rig.text?.count == 8 && rig.isConcealed, "a code is still a concealed secret")
            #expect(rig.prompt.calls == 1, "one prompt for the password, the username and the code")

            rig.clock.advance(by: .seconds(31))
            rig.controller.perform(.copyPassword, on: summary)
            await finishCopy(rig)
            #expect(rig.prompt.calls == 2 && rig.text == "pw-secret", "31 s later it asks again")
        }
    }

    @Test func theModelsOfThePopoverAndTheWindowShareTheProcessWideWindow() {
        #expect(PasswordsStatusItem.makeSystemModel(for: .privateBrowsing()).copyGrace === CopyGrace.shared)
    }

    @Test func aLockWhileThePromptIsUpCopiesNothing() async throws {
        let account = login("late-secret")
        try await withVault(accounts: [account]) { rig, vault in
            let model = try #require(rig.model)
            rig.controller.open()
            let summary = try #require(model.summaries.first)
            let sentinel = rig.sentinel()
            rig.prompt.holds = true

            rig.controller.perform(.copyPassword, on: summary)
            try await waitUntilAsking(rig.prompt)
            vault.manager.lock(reason: .manual)
            rig.prompt.answer()
            await finishCopy(rig)

            #expect(rig.text == sentinel, "the answer was given under an unlock that is gone")
            #expect(!rig.isConcealed)
        }
    }

    // MARK: Search focus

    /// The popover's content in a window of its own (a test has no status item to hang the popover from), so the focus the
    /// controller asks for lands on a real field.
    private func host(_ rig: Rig) throws -> NSWindow {
        let popover = try #require(rig.controller.popover)
        let view = try #require(popover.contentViewController?.view)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: PasswordsStatusItem.popoverSize), styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentView = view
        window.orderFrontRegardless()
        view.layoutSubtreeIfNeeded()
        return window
    }

    private func searchEditor(in window: NSWindow) -> NSText? {
        PasswordsStatusItem.searchField(in: window.contentView)?.currentEditor()
    }

    /// Opening the popover puts the keyboard in the search field with no click, so typing filters at once.
    @Test func openingThePopoverFocusesTheSearchFieldAndTypingReachesIt() async throws {
        try await withVault(accounts: [login(displayName: "Work"), login(displayName: "Home")]) { rig, _ in
            rig.controller.open()
            let window = try host(rig)
            defer { window.close() }

            #expect(await waitUntil { window.firstResponder != nil && window.firstResponder === searchEditor(in: window) })
            let editor = try #require(searchEditor(in: window) as? NSTextView)
            editor.insertText("wor", replacementRange: NSRange(location: 0, length: 0))
            #expect(PasswordsStatusItem.searchField(in: window.contentView)?.stringValue == "wor", "typing lands in the field")
        }
    }

    /// A vault that unlocks while the popover is up: the field appears then, and takes the keyboard.
    @Test func afterAnUnlockTheSearchFieldTakesTheFocus() async throws {
        try await withVault(unlocked: false, accounts: [login()]) { rig, vault in
            rig.controller.open()
            let window = try host(rig)
            defer { window.close() }
            #expect(rig.controller.model?.menuPhase == .locked)
            #expect(PasswordsStatusItem.searchField(in: window.contentView) == nil, "locked: no field")
            // The opening search for the field has given up by the time a slow unlock ends.
            rig.controller.focusTask?.cancel()

            try await VaultManagerFixture.unlock(vault)
            try await VaultManagerFixture.save([login()], in: vault)
            await rig.model?.load()

            #expect(await waitUntil { window.firstResponder != nil && window.firstResponder === searchEditor(in: window) })
        }
    }

    // MARK: Closing

    @Test func closingWithNoCopyInFlightForgetsTheSessionAndTheContent() async throws {
        try await withVault(accounts: [login()]) { rig, _ in
            let model = try #require(rig.model)
            rig.controller.open()
            let popover = try #require(rig.controller.popover)
            #expect(popover.contentViewController != nil && model.isLoaded)

            rig.controller.closePopover()

            #expect(popover.contentViewController == nil, "the content is dropped, not kept for the next open")
            #expect(rig.controller.popover == nil && rig.controller.model == nil)
            #expect(!model.isLoaded && model.summaries.isEmpty, "close() ran")
        }
    }

    @Test func closingWhileACopyIsInFlightWaitsForItBeforeClosingTheModel() async throws {
        let account = login("slow-secret")
        try await withVault(accounts: [account]) { rig, _ in
            let model = try #require(rig.model)
            rig.controller.open()
            let summary = try #require(model.summaries.first)
            rig.prompt.holds = true

            rig.controller.perform(.copyPassword, on: summary)
            try await waitUntilAsking(rig.prompt)
            // The system's sheet may close the transient popover.
            rig.controller.closePopover()
            #expect(rig.controller.popover == nil)
            #expect(rig.controller.model === model && model.isLoaded, "the model is kept until the copy ends")

            rig.prompt.answer()
            await finishCopy(rig)

            #expect(rig.text == "slow-secret" && rig.isConcealed, "the copy still completed")
            #expect(rig.controller.model == nil && !model.isLoaded, "and only then the model was closed")
        }
    }

    // MARK: Lock Now, profiles, websites

    @Test func returningToAnOpenBrowserProfileUsesItsLiveVaultInBothPasswordsSurfaces() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked]) { profile, passkeys, vaults in
            let rig = Rig()
            defer { rig.tearDown() }
            let catalog = rig.catalog
            _ = try #require(catalog.adopt(id: profile.id, name: "Personal fixture", symbol: "key", color: .blue))
            let work = catalog.add(name: "Work fixture")
            let app = BrowserApplication(notifications: NotificationCenter())
            @MainActor func browser(_ profile: Profile) -> AppCoordinator {
                let coordinator = AppCoordinator(
                    browser: BrowserModel(context: BrowserProfileContext.shared(for: profile), windowID: UUID(), database: .temporary()),
                    profiles: ProfileStore.selection(profile: profile, catalog: catalog)
                )
                app.register(coordinator)
                return coordinator
            }
            let first = browser(profile)
            let second = browser(work)
            defer {
                first.closeWindow()
                second.closeWindow()
            }
            first.showBrowser(activate: false)
            second.showBrowser(activate: false)
            try #require(first.nativeWindow?.isVisible == true && second.nativeWindow?.isVisible == true)
            let menu = PasswordsStatusItem(statusBar: rig.bar, profiles: { app.passwordsProfileStore(fallback: catalog) }, frontTab: { nil })
            defer { menu.closePopover() }
            var windowPage: CredentialSettingsModel?
            let passwords = PasswordsWindow(profiles: { app.passwordsProfileStore(fallback: catalog) }, autosaveName: nil) { profile in
                windowPage = CredentialSettingsModel(profile: profile)
                let controller = NSViewController()
                controller.view = NSView()
                return controller
            }
            defer { passwords.window?.close() }
            let epoch = try #require(vaults[0].manager.authorizationEpoch)
            let assertions = passkeys.assertions
            second.showBrowser()
            // A background test host can show its window without AppKit sending the key-window callback.
            if !second.isKeyWindow {
                second.windowDidBecomeKey()
            }
            menu.open()
            passwords.show()
            #expect(menu.model?.profile.id == work.id && passwords.boundProfileID == work.id)
            menu.closePopover()
            first.showBrowser()
            if !first.isKeyWindow {
                first.windowDidBecomeKey()
            }
            menu.open()
            passwords.show()
            try #require(menu.model?.profile.id == profile.id && passwords.boundProfileID == profile.id)
            passwords.window?.close()
            let pages = try [#require(menu.model), #require(windowPage)]
            for page in pages {
                await page.load()
                #expect(page.isLoaded && page.authorizationEpoch == epoch)
                page.close()
            }
            #expect(passkeys.assertions == assertions)
        }
    }

    @Test func lockNowLocksEveryVaultOfEveryProfile() async throws {
        try await VaultManagerFixture.exclusive {
            try await VaultManagerFixture.with(vaults: [.unlocked]) { _, _, first in
                try await VaultManagerFixture.with(vaults: [.unlocked]) { _, _, second in
                    let rig = Rig()
                    defer { rig.tearDown() }
                    #expect(first[0].manager.isUnlocked && second[0].manager.isUnlocked)

                    rig.controller.lockNow()

                    #expect(!first[0].manager.isUnlocked && !second[0].manager.isUnlocked)
                }
            }
        }
    }

    @Test func aLockedExplicitDefaultStaysSelectedWhenAnotherVaultIsAlreadyOpen() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked, .locked]) { profile, passkeys, vaults in
            let store = try CredentialManager.store(for: profile)
            await store.setDefaultVault(vaults[1].vaultID)
            let assertions = passkeys.assertions
            let epoch = try #require(vaults[0].manager.authorizationEpoch)
            let page = PasswordsStatusItem.makeSystemModel(for: profile)
            defer { page.close() }
            await page.load()
            #expect(page.selectedVaultID == vaults[1].vaultID && !page.isUnlocked && !page.isLoaded)
            #expect(vaults[0].manager.authorizationEpoch == epoch && passkeys.assertions == assertions)
        }
    }

    @Test func aProfileSwitchBetweenOpensBindsTheProfileShownNow() {
        let rig = Rig()
        defer { rig.tearDown() }
        let work = rig.catalog.add(name: "Work")
        rig.selection.markCurrent(.original())

        rig.controller.open()
        rig.controller.closePopover()
        rig.selection.markCurrent(work)
        rig.controller.open()
        rig.controller.closePopover()

        #expect(rig.requested == [Profile.original().id, work.id])
    }

    @Test func openWebsiteOpensTheCredentialsAddressAndClosesThePopover() async throws {
        let account = login()
        try await withVault(accounts: [account]) { rig, _ in
            let model = try #require(rig.model)
            rig.controller.open()
            let summary = try #require(model.summaries.first)

            rig.controller.perform(.openWebsite, on: summary)

            #expect(rig.openedWebsites == [URL(string: "https://example.test/login")!])
            #expect(!rig.controller.isOpen)
        }
    }
}
