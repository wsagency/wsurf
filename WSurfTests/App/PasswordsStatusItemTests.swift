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

        init(lockEverything: @escaping () -> Void = { CredentialManager.lockAll(reason: .manual) }) {
            catalog = ProfileStore(file: file)
            selection = ProfileStore.selection(profile: .original(), catalog: catalog)
            controller = PasswordsStatusItem(
                statusBar: bar, profiles: selection,
                makeModel: { [unowned self] profile in
                    requested.append(profile.id)
                    let made = model ?? CredentialSettingsModel(profile: .privateBrowsing(), verifyUser: { _ in })
                    made.websiteOpener = { [unowned self] in openedWebsites.append($0) }
                    return made
                },
                frontTab: { nil }, lockEverything: lockEverything, openSettings: { _ in }
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

            rig.controller.unlock()

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

    @Test func copyingAPasswordAsksEveryTimeAndAFailedAskLeavesTheClipboardAlone() async throws {
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

    @Test func copyingAVerificationCodeAsksEveryTimeAndAFailedAskLeavesTheClipboardAlone() async throws {
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

    @Test func lockNowAsksTheLockOnceAndNothingElse() {
        var locks = 0
        let rig = Rig(lockEverything: { locks += 1 })
        defer { rig.tearDown() }

        rig.controller.lockNow()

        #expect(locks == 1)
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
