// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import Testing
import WebKit

@testable import WSurf
@testable import WSurfVault

/// Pick Credential…: where it is offered, what the list holds and in which order, the whole pick against real vaults (unlock, list,
/// fill, the offer to remember the website), and how a website is named and checked for imitation. The page flow runs in WebKit:
/// Chromium cannot load an HTTPS document from a fixture here (see `AutofillSaveScriptTests`); its page side is in
/// `CredentialPickerScriptTests`, with both engines.
@MainActor
struct CredentialPickerTests {
    static let site = "https://login.example.test"
    /// Another registrable domain: `.test` names are siblings within `example.test`.
    private static let other = "https://elsewhere.test"
    /// An hour's period, so a code read before and after a fill is almost always the same one.
    private static let generator = TOTPGenerator(
        secret: Data("12345678901234567890".utf8), algorithm: .sha1, period: 3600, digits: 6, issuer: nil, userName: nil
    )

    private func account(
        _ username: String, password: String? = "pw", origins: [String] = [Self.site], totp: TOTPGenerator? = nil,
        displayName: String? = nil
    ) -> CredentialAccount {
        CredentialAccount(
            id: UUID(), username: username, displayName: displayName, origins: origins, loginURLs: [], password: password, passkeys: [],
            totp: totp, exchangeAccountID: nil, exchangeItemID: nil
        )
    }

    // MARK: - The list

    @Test func theListHoldsLoginsAndCodesAndNothingSecret() throws {
        let ada = account("ada", password: "dummy-secret-1", totp: Self.generator, displayName: "Example")
        let codeOnly = account("", password: nil, origins: [Self.other], totp: Self.generator)
        var card = account("", password: nil, origins: [])
        card.secureItems = [SecureItemFixtures.card()]
        let rows = CredentialPicker.rows([ada, codeOnly, card], vaultID: UUID(), origin: Self.site, vault: nil)

        #expect(rows.map(\.accountID) == [ada.id, ada.id, codeOnly.id], "a card is not offered")
        #expect(rows.map(\.fill) == [.login, .code, .code])
        #expect(rows[0].title == "Example" && rows[0].detail == "ada · login.example.test" && rows[0].matchesSite)
        #expect(rows[2].title == "elsewhere.test" && rows[2].detail == "Verification code" && !rows[2].matchesSite)
        let code = try TOTP.code(Self.generator, at: Date.now.timeIntervalSince1970).value
        for row in rows {
            for text in [row.title, row.detail, row.searchKey] {
                #expect(!text.contains("dummy-secret-1") && !text.contains(code))
            }
        }
    }

    @Test func thisWebsiteComesFirstAndACodeFieldListsCodesFirst() {
        let here = account("here", totp: Self.generator)
        let sibling = account("sibling", origins: ["https://www.example.test"])
        let elsewhere = account("elsewhere", origins: [Self.other], totp: Self.generator)
        let rows = CredentialPicker.rows([elsewhere, sibling, here], vaultID: UUID(), origin: Self.site, vault: nil)

        let forText = CredentialPicker.ordered(rows, for: .text)
        #expect(forText.map { "\($0.title)/\($0.fill)" } == [
            "login.example.test/login", "www.example.test/login", "login.example.test/code", "elsewhere.test/login",
            "elsewhere.test/code",
        ])
        let forCode = CredentialPicker.ordered(rows, for: .code)
        #expect(forCode.map { "\($0.title)/\($0.fill)" } == [
            "login.example.test/code", "login.example.test/login", "www.example.test/login", "elsewhere.test/code",
            "elsewhere.test/login",
        ])
    }

    @Test func theCredentialUsedLastOnThisWebsiteComesFirstInTheFormTheFieldPrefers() {
        let ada = account("ada", displayName: "Ada"), bob = account("bob", totp: Self.generator, displayName: "Bob")
        let away = account("away", origins: [Self.other], displayName: "Away")
        let at = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let used = [bob.id: at, away.id: at.addingTimeInterval(60)]
        let rows = CredentialPicker.rows([away, bob, ada], vaultID: UUID(), origin: Self.site, vault: nil, used: used)

        #expect(rows.first { $0.accountID == away.id }?.lastUsed == nil, "a date for another website is never this website's")
        #expect(CredentialPicker.ordered(rows, for: .text).map { "\($0.title)/\($0.fill)" } == [
            "Bob/login", "Ada/login", "Bob/code", "Away/login",
        ])
        #expect(CredentialPicker.ordered(rows, for: .code).map { "\($0.title)/\($0.fill)" } == [
            "Bob/code", "Ada/login", "Bob/login", "Away/login",
        ])
    }

    @Test func searchingMatchesTitleUsernameAndWebsiteNeverTheSecret() {
        let rows = CredentialPicker.rows(
            [account("Ada", password: "hunter2"), account("grace", origins: [Self.other])], vaultID: UUID(), origin: Self.site, vault: nil
        )
        #expect(CredentialPicker.filter(rows, query: "").count == 2)
        #expect(CredentialPicker.filter(rows, query: " ADA ").map(\.detail) == ["Ada"], "the website is the title already")
        #expect(CredentialPicker.filter(rows, query: "elsewhere").count == 1)
        #expect(CredentialPicker.filter(rows, query: "hunter2").isEmpty)
    }

    // MARK: - Where it is offered

    private func page(profile: Profile, url: String = Self.site + "/", inWindow: Bool = true) -> (BrowserPage, NSWindow?) {
        let configuration = WebViewPool.makeConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let page = BrowserPage(webKit: WKWebView(frame: .zero, configuration: configuration), context: BrowserProfileContext(profile: profile))
        page.url = URL(string: url)
        page.hasOnlySecureContent = true
        guard inWindow else { return (page, nil) }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = page
        return (page, window)
    }

    @Test(.boundedWebViews) func itIsOfferedOnlyOnASecurePageOfAnOrdinaryProfileThatTheTabAllows() async throws {
        try await VaultManagerFixture.with(vaults: []) { profile, _, _ in
            let (good, window) = page(profile: profile)
            #expect(CredentialPicker.isOffered(in: good, allowedByTab: true))
            #expect(!CredentialPicker.isOffered(in: good, allowedByTab: false), "an agent's or connected app's tab, an internal page")
            good.hasOnlySecureContent = false
            #expect(!CredentialPicker.isOffered(in: good, allowedByTab: true), "mixed content")
            window?.contentView = nil
            window?.close()
            await good.close()

            let (plain, plainWindow) = page(profile: profile, url: "http://login.example.test/")
            #expect(!CredentialPicker.isOffered(in: plain, allowedByTab: true))
            plainWindow?.contentView = nil
            plainWindow?.close()
            await plain.close()

            let (loose, _) = page(profile: profile, inWindow: false)
            #expect(!CredentialPicker.isOffered(in: loose, allowedByTab: true), "no window")
            await loose.close()
        }
        let privateProfile = Profile.privateBrowsing()
        let (privatePage, privateWindow) = page(profile: privateProfile)
        #expect(!CredentialPicker.isOffered(in: privatePage, allowedByTab: true), "never in a private window")
        privateWindow?.contentView = nil
        privateWindow?.close()
        await privatePage.close()
        await privatePage.context.endPrivateSession()
    }

    @Test func theTabAllowsItOnlyWhileNoAgentOrConnectedAppHoldsIt() {
        let tab = BrowserTab()
        #expect(tab.allowsCredentialPicker)
        tab.processState.setAgentWorking(true)
        #expect(!tab.allowsCredentialPicker)
        tab.processState.setAgentWorking(false)
        tab.processState.isExternalAutomationWorking = true
        #expect(!tab.allowsCredentialPicker)
        tab.processState.isExternalAutomationWorking = false
        let connection = UUID()
        tab.processState.setExternalController(connection, holds: true)
        #expect(!tab.allowsCredentialPicker, "a tab a connected app holds")
        tab.processState.setExternalController(connection, holds: false)
        #expect(tab.allowsCredentialPicker)
        #expect(!BrowserTab(privately: true).allowsCredentialPicker)
    }

    private func menu(_ identifiers: [String]) -> NSMenu {
        let menu = NSMenu()
        for identifier in identifiers {
            let item = NSMenuItem(title: identifier, action: nil, keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier(identifier)
            menu.addItem(item)
        }
        return menu
    }

    @Test(.boundedWebViews) func theWebKitMenuOffersItAtTheTopOfAnEditableFieldOnlyWhileTheTabDoes() throws {
        let view = TabWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: WebViewPool.makeConfiguration())
        let event = try #require(NSEvent.mouseEvent(
            with: .rightMouseDown, location: NSPoint(x: 10, y: 10), modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
            eventNumber: 0, clickCount: 1, pressure: 1
        ))
        var offered = true
        var picked: [CredentialPicker.Menu] = []
        view.canPickCredential = { offered }
        view.onPickCredential = { picked.append($0) }
        let editable = ["WKMenuItemIdentifierCopy", "WKMenuItemIdentifierPaste", "WKMenuItemIdentifierSpellingMenu"]

        let field = menu(editable)
        view.willOpenMenu(field, with: event)
        #expect(field.items.first?.identifier == CredentialPicker.menuItemIdentifier && field.items[1].isSeparatorItem)
        let item = try #require(field.items.first)
        _ = (item.target as? NSObject)?.perform(item.action)
        #expect(picked.count == 1)

        let text = menu(["WKMenuItemIdentifierCopy", "WKMenuItemIdentifierLookUp"])
        view.willOpenMenu(text, with: event)
        #expect(!text.items.contains { $0.identifier == CredentialPicker.menuItemIdentifier }, "not on text that cannot be edited")

        offered = false
        let refused = menu(editable)
        view.willOpenMenu(refused, with: event)
        #expect(!refused.items.contains { $0.identifier == CredentialPicker.menuItemIdentifier }, "not while the policy refuses")
    }

    // MARK: - Picking against real vaults (WebKit)

    private final class Flow {
        let page: BrowserPage
        let window: NSWindow
        let session = AutofillSaveSession()
        let profile: Profile
        var offered: [[CredentialPicker.Row]] = []

        init(profile: Profile) {
            self.profile = profile
            let configuration = interactiveWebViewConfiguration()
            configuration.websiteDataStore = .nonPersistent()
            page = BrowserPage(
                webKit: WKWebView(frame: NSRect(x: 0, y: 0, width: 700, height: 500), configuration: configuration),
                context: BrowserProfileContext(profile: profile)
            )
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 500), styleMask: .borderless, backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = page
            window.orderBack(nil)
            PasswordAutofill.shared.install(in: page)
            AutofillSaveCoordinator.shared.install(in: page, session: session)
        }

        func close() async {
            CredentialPicker.answersForTesting[profile.id] = nil
            window.contentView = nil
            window.close()
            await page.close()
        }

        /// `html` as the page at the test site. A string under an https base URL has that origin but no TLS behind it, so the page's
        /// secure flag is set as a real https load would set it.
        func load(_ html: String) async throws {
            let cancel = "<script>document.addEventListener('contextmenu', event => event.preventDefault());</script>"
            page.loadHTMLString("<!doctype html>" + cancel + html, baseURL: URL(string: CredentialPickerTests.site + "/"))
            try #require(await waitUntil { !self.page.isLoading && self.page.url?.host() == "login.example.test" })
            try #require(await waitUntil { PasswordAutofill.shared.frames[ObjectIdentifier(self.page)]?.isEmpty == false })
            try #require(await waitUntil { AutofillSaveCoordinator.shared.frames[ObjectIdentifier(self.page)] != nil })
            // The value the policy sends this profile, sent here so the first right-click never races it.
            _ = try await page.callAsyncJavaScript(
                "globalThis.__wsurfPasswords.setEnabled(true);", arguments: [:], in: nil, contentWorld: PasswordAutofill.world
            )
            page.hasOnlySecureContent = true
        }

        func rightClick(_ id: String) async throws -> CredentialPicker.Target {
            let before = CredentialPicker.shared.target(for: page, menu: .init(opened: .now))?.token
            try await PageRightClick.send(at: try await PageRightClick.center(of: id, in: page), in: page, window: window)
            var found: CredentialPicker.Target?
            try #require(await waitUntil {
                found = CredentialPicker.shared.target(for: self.page, menu: .init(opened: .now))
                return found != nil && found?.token != before
            }, "the right-click on \(id) was recorded")
            return try #require(found)
        }

        /// The whole pick for `target`, with `choose` standing in for the person at the sheet.
        func pick(
            _ target: CredentialPicker.Target, allowed: @escaping @MainActor @Sendable () -> Bool = { true },
            choose: @escaping @MainActor ([CredentialPicker.Row]) async -> CredentialPicker.Answer?
        ) async -> CredentialPicker.Outcome {
            CredentialPicker.answersForTesting[profile.id] = { [weak self] rows in
                self?.offered.append(rows)
                return await choose(rows)
            }
            defer { CredentialPicker.answersForTesting[profile.id] = nil }
            return await CredentialPicker.shared.run(target, in: page, window: window, allowed: allowed)
        }

        func value(_ id: String) async throws -> String? {
            try await page.evaluateJavaScript("document.getElementById('\(id)').value") as? String
        }

        func values(_ ids: [String]) async throws -> [String] {
            var result: [String] = []
            for id in ids {
                result.append(try await value(id) ?? "?")
            }
            return result
        }
    }

    private func withFlow(
        passkeys: VaultPasskeys = VaultPasskeys(), vaults: [VaultState] = [.unlocked],
        _ body: (Flow, [FixtureVault]) async throws -> Void
    ) async throws {
        try await VaultManagerFixture.with(passkeys: passkeys, vaults: vaults) { profile, _, vaults in
            let flow = Flow(profile: profile)
            do {
                try await body(flow, vaults)
            } catch {
                await flow.close()
                throw error
            }
            await flow.close()
        }
    }

    private static let login = #"""
        <form id="a"><input id="au" autocomplete="username"><input id="ap" type="password"></form>
        <form id="b"><input id="bu" name="login"><input id="bp" type="password"></form>
        <div><input id="pin" name="pin" inputmode="numeric" maxlength="6"><button>Verify</button></div>
        <form action="https://collector.example/take"><input id="xu"><input id="xp" type="password"></form>
        """#

    /// The person chose a login and the fill is under way when the assistant or a connected app takes the tab: nothing is filled.
    /// Once it lets go, the same pick fills.
    @Test(.boundedWebViews, arguments: ["assistant", "connected app call", "connected app holds"])
    func aPickUnderWayIsRefusedWhenAnAgentTakesTheTab(controller: String) async throws {
        try await withFlow { flow, vaults in
            let ada = account("ada")
            try await VaultManagerFixture.save([ada], in: vaults[0])
            try await flow.load(Self.login)
            let tab = BrowserTab(opensBlank: false, context: flow.page.context)
            let connection = UUID()
            let control: @MainActor (Bool) -> Void = { on in
                switch controller {
                case "assistant":
                    tab.setAgentWorking(on)
                case "connected app call":
                    tab.setExternalAutomationWorking(on)
                default:
                    tab.processState.setExternalController(connection, holds: on)
                }
            }
            let allowed: @MainActor @Sendable () -> Bool = { tab.allowsCredentialPicker }
            let refused = await flow.pick(try await flow.rightClick("au"), allowed: allowed) { rows in
                control(true)
                return rows.first { $0.accountID == ada.id && $0.fill == .login }.map { .row($0.id) }
            }
            #expect(refused == .nothing)
            #expect(try await flow.values(["au", "ap"]) == ["", ""])

            control(false)
            let filled = await flow.pick(try await flow.rightClick("au"), allowed: allowed) { rows in
                rows.first { $0.accountID == ada.id && $0.fill == .login }.map { .row($0.id) }
            }
            #expect(filled == .filled(2))
        }
    }

    @Test(.boundedWebViews) func aLockedVaultIsUnlockedFirstAndNothingIsFilledWhenThePersonCancels() async throws {
        let passkeys = VaultPasskeys()
        try await withFlow(passkeys: passkeys) { flow, vaults in
            let ada = account("ada")
            try await VaultManagerFixture.save([ada], in: vaults[0])
            vaults[0].manager.lock(reason: .manual)
            try await flow.load(Self.login)
            let target = try await flow.rightClick("au")
            let before = passkeys.assertions.count

            let outcome = await flow.pick(target) { _ in nil }

            #expect(outcome == .nothing)
            #expect(passkeys.assertions.count == before + 1, "the ordinary unlock, once")
            #expect(vaults[0].manager.isUnlocked)
            #expect(flow.offered.first?.map(\.accountID) == [ada.id], "the list was read after the unlock")
            #expect(try await flow.values(["au", "ap"]) == ["", ""])
        }
    }

    @Test(.boundedWebViews) func theChosenLoginFillsTheRightClickedFormAloneAndAMatchOffersNothingToRemember() async throws {
        try await withFlow { flow, vaults in
            let ada = account("ada", password: "dummy-secret-1"), grace = account("grace", origins: [Self.other])
            try await VaultManagerFixture.save([grace, ada], in: vaults[0])
            try await flow.load(Self.login)
            let target = try await flow.rightClick("bu")
            #expect(target.origin == Self.site && target.field == .text && target.frame.isMainFrame)

            let outcome = await flow.pick(target) { rows in
                rows.first { $0.accountID == ada.id && $0.fill == .login }.map { .row($0.id) }
            }

            #expect(outcome == .filled(2))
            #expect(flow.offered.first?.first?.accountID == ada.id, "this website's credential is listed first")
            #expect(try await flow.values(["bu", "bp"]) == ["ada", "dummy-secret-1"])
            #expect(try await flow.values(["au", "ap", "xu", "xp"]) == ["", "", "", ""])
            #expect(flow.session.websiteOffer == nil, "saved for this website: nothing to remember")
        }
    }

    /// A pick is a use: the credential picked on this website is listed first the next time. One picked here that is saved for another
    /// website is not recorded and does not move.
    @Test(.boundedWebViews) func theCredentialLastPickedHereIsListedFirstNextTime() async throws {
        try await withFlow { flow, vaults in
            let ada = account("ada", displayName: "Ada"), bob = account("bob", displayName: "Bob")
            let grace = account("grace", origins: [Self.other], displayName: "Grace")
            try await VaultManagerFixture.save([grace, bob, ada], in: vaults[0])
            try await flow.load(Self.login)

            let lastUsed = flow.page.context.autofillLastUsed, key = try await vaults[0].manager.importMemoryKey()
            let first = try await flow.rightClick("bu")
            #expect(await flow.pick(first) { rows in rows.first { $0.accountID == bob.id }.map { .row($0.id) } } == .filled(2))
            #expect(flow.offered.last?.map(\.accountID) == [ada.id, bob.id, grace.id], "before any use, the order it always had")
            #expect(await waitUntil { lastUsed.date(key, account: bob.id, origin: Self.site) != nil }, "recorded with the vault's key")

            let second = try await flow.rightClick("au")
            #expect(await flow.pick(second) { rows in rows.first { $0.accountID == grace.id }.map { .row($0.id) } } == .filled(2))
            #expect(flow.offered.last?.map(\.accountID) == [bob.id, ada.id, grace.id], "bob was used here last")

            let third = try await flow.rightClick("bu")
            #expect(await flow.pick(third) { _ in nil } == .nothing)
            #expect(flow.offered.last?.map(\.accountID) == [bob.id, ada.id, grace.id], "grace is not saved for this website")
            #expect(lastUsed.date(key, account: grace.id, origin: Self.site) == nil)
        }
    }

    @Test(.boundedWebViews) func aVerificationCodeFillsAFieldNothingCallsACode() async throws {
        try await withFlow { flow, vaults in
            let codes = account("ada", password: nil, origins: [Self.other], totp: Self.generator)
            try await VaultManagerFixture.save([codes], in: vaults[0])
            try await flow.load(Self.login)
            let target = try await flow.rightClick("pin")
            #expect(target.field == .code)
            let earlier = try TOTP.code(Self.generator, at: Date.now.timeIntervalSince1970).value

            let outcome = await flow.pick(target) { rows in rows.first { $0.fill == .code }.map { .row($0.id) } }

            let later = try TOTP.code(Self.generator, at: Date.now.timeIntervalSince1970).value
            #expect(outcome == .filled(1))
            let filled = try await flow.value("pin")
            #expect(filled == earlier || filled == later)
            #expect(flow.offered.first?.first?.fill == .code, "a code field lists codes first")
            #expect(flow.session.websiteOffer?.isManual == true, "a code used on another website is offered that website too")
        }
    }

    // MARK: - A code from Messages or Mail (the sheet's native field; the sheet itself is answered by the test)

    private static let boxes = #"""
        <div><input id="d1" maxlength="1"><input id="d2" maxlength="1"><input id="d3" maxlength="1">
        <input id="d4" maxlength="1"><input id="d5" maxlength="1"><input id="d6" maxlength="1"><button>Verify</button></div>
        """#

    @Test func theSheetOffersTheNativeCodeFieldOnlyForACodeField() {
        #expect(CredentialPicker.offersMessagesCode(for: .code))
        #expect(!CredentialPicker.offersMessagesCode(for: .password) && !CredentialPicker.offersMessagesCode(for: .text))
    }

    @Test(.boundedWebViews) func aCodeFromMessagesFillsTheRightClickedCodeFieldAndNothingIsKept() async throws {
        try await withFlow { flow, vaults in
            try await flow.load(Self.login)
            let target = try await flow.rightClick("pin")
            #expect(target.field == .code)
            let changes = NSPasteboard.general.changeCount
            let revision = try await vaults[0].manager.snapshot().revision

            let outcome = await flow.pick(target) { _ in .code("482913") }

            #expect(outcome == .filled(1))
            #expect(try await flow.values(["pin", "au", "ap", "bu", "bp", "xu", "xp"]) == ["482913", "", "", "", "", "", ""])
            #expect(flow.session.websiteOffer == nil, "no credential was used: nothing is offered for saving")
            #expect(try await vaults[0].manager.snapshot().revision == revision, "nothing was written to the vault")
            #expect(NSPasteboard.general.changeCount == changes, "nothing was put on the pasteboard")
            #expect(await flow.pick(target) { _ in .code("111111") } == .nothing, "a right-click fills once")
            #expect(try await flow.value("pin") == "482913")
        }
    }

    @Test(.boundedWebViews) func aCodeFromMessagesFillsASplitCodeBoxByBoxFromTheFirstWhicheverWasRightClicked() async throws {
        try await withFlow { flow, _ in
            try await flow.load(Self.login + Self.boxes)
            let target = try await flow.rightClick("d3")
            #expect(target.field == .code)

            let short = await flow.pick(target) { _ in .code("1234") }
            #expect(short == .failed(.noField), "six boxes are not a four-digit code's")
            #expect(try await flow.values(["d1", "d2", "d3", "d4", "d5", "d6"]) == ["", "", "", "", "", ""])

            let again = try await flow.rightClick("d5")
            let outcome = await flow.pick(again) { _ in .code("246813") }
            #expect(outcome == .filled(6), "\(outcome)")
            #expect(try await flow.values(["d1", "d2", "d3", "d4", "d5", "d6", "pin"]) == ["2", "4", "6", "8", "1", "3", ""])
        }
    }

    @Test(.boundedWebViews) func aCodeFromMessagesIsNeverFilledIntoAFormThatSendsItElsewhere() async throws {
        try await withFlow { flow, _ in
            try await flow.load(Self.login)
            let target = try await flow.rightClick("xu")

            #expect(await flow.pick(target) { _ in .code("482913") } == .failed(.unsafeForm))

            #expect(try await flow.values(["xu", "xp", "pin"]) == ["", "", ""])
        }
    }

    @Test(.boundedWebViews) func aCodeFromMessagesForAPageThatChangedWhileTheSheetWasOpenFillsNothing() async throws {
        try await withFlow { flow, _ in
            try await flow.load(Self.login)
            let target = try await flow.rightClick("pin")
            @MainActor func documentID() async -> String? {
                try? await flow.page.callAsyncJavaScript(
                    "return globalThis.__wsurfAutofillForms?.documentID ?? null;", arguments: [:], in: nil, contentWorld: PasswordAutofill.world
                ) as? String
            }
            let old = await documentID()

            let outcome = await flow.pick(target) { _ in
                // The page moves on to a new document while the sheet is open.
                flow.page.loadHTMLString("<!doctype html>" + Self.login, baseURL: URL(string: Self.site + "/next"))
                _ = await waitUntil { await documentID().map { $0 != old } == true }
                return .code("482913")
            }

            #expect(outcome == .failed(.noField))
            #expect(try await flow.values(["pin"]) == [""])
        }
    }

    @Test(.boundedWebViews) func usedElsewhereItIsOfferedThisWebsiteAndAcceptingAddsExactlyThatOneChange() async throws {
        try await withFlow { flow, vaults in
            let grace = account("grace", password: "dummy-secret-2", origins: [Self.other]), bob = account("bob")
            try await VaultManagerFixture.save([grace, bob], in: vaults[0])
            let storedBob = try await vaults[0].manager.snapshot().accounts.first { $0.id == bob.id }
            try await flow.load(Self.login)
            let target = try await flow.rightClick("au")

            #expect(await flow.pick(target) { rows in rows.first { $0.accountID == grace.id }.map { .row($0.id) } } == .filled(2))

            let offer = try #require(flow.session.websiteOffer)
            #expect(offer.isManual && offer.lookalike == nil && offer.host == "login.example.test" && offer.accountID == grace.id)
            #expect(try await vaults[0].manager.revisionPage(accountID: grace.id, after: nil).items.isEmpty, "offering writes nothing")

            await flow.session.addWebsite(offer)

            #expect(flow.session.websiteOffer == nil && flow.session.error == nil)
            let accounts = try await vaults[0].manager.snapshot().accounts
            let saved = try #require(accounts.first { $0.id == grace.id })
            #expect(saved.origins == [Self.other, Self.site], "the page's origin, normalized, and nothing else")
            #expect(saved.username == grace.username && saved.password == grace.password && saved.importTrace == nil)
            #expect(accounts.first { $0.id == bob.id } == storedBob)
            let history = try await vaults[0].manager.revisionPage(accountID: grace.id, after: nil).items
            #expect(history.count == 1 && history.first?.subject == .metadata, "one change in History")
            #expect(history.first?.cause == CredentialChangeCause.addWebsite)
            // The automatic offer now knows it here.
            let rows = CredentialAccountSelection.suggestions(accounts, origin: Self.site, pageURL: nil, entered: nil, field: .password)
            #expect(rows.map(\.id).contains(grace.id))
        }
    }

    @Test(.boundedWebViews) func decliningStoresNothingAndASubmitOfThatLoginMakesNoCopy() async throws {
        try await withFlow { flow, vaults in
            let grace = account("grace", password: "dummy-secret-2", origins: [Self.other])
            try await VaultManagerFixture.save([grace], in: vaults[0])
            try await flow.load(Self.login)
            let target = try await flow.rightClick("au")
            #expect(await flow.pick(target) { rows in rows.first.map { .row($0.id) } } == .filled(2))
            let revision = try await vaults[0].manager.snapshot().revision

            // Submitting what was filled keeps the offer to remember the website instead of offering a copy of the login.
            await flow.session.offer(.password(try SavedPassword(website: Self.site, username: "grace", password: "dummy-secret-2")), origin: Self.site)
            #expect(flow.session.current == nil && flow.session.websiteOffer?.accountID == grace.id)

            flow.session.dismissWebsite(try #require(flow.session.websiteOffer))

            #expect(flow.session.websiteOffer == nil)
            #expect(try await vaults[0].manager.snapshot().revision == revision, "nothing is stored")
            #expect(try await vaults[0].manager.snapshot().accounts.first?.origins == [Self.other])
        }
    }

    @Test(.boundedWebViews) func aVaultThatChangesWhileThePickerIsOpenFillsNothing() async throws {
        try await withFlow { flow, vaults in
            let ada = account("ada")
            try await VaultManagerFixture.save([ada], in: vaults[0])
            try await flow.load(Self.login)
            let target = try await flow.rightClick("au")

            let outcome = await flow.pick(target) { rows in
                _ = try? await VaultManagerFixture.save([ada, self.account("someone")], in: vaults[0])
                return rows.first.map { .row($0.id) }
            }

            #expect(outcome == .failed(.noField))
            #expect(try await flow.values(["au", "ap"]) == ["", ""])
        }
    }

    @Test(.boundedWebViews) func aPasswordIsNotFilledIntoAFormThatSendsItElsewhere() async throws {
        try await withFlow { flow, vaults in
            let ada = account("ada")
            try await VaultManagerFixture.save([ada], in: vaults[0])
            try await flow.load(Self.login)
            let target = try await flow.rightClick("xu")

            #expect(await flow.pick(target) { rows in rows.first.map { .row($0.id) } } == .failed(.unsafeForm))
            #expect(try await flow.values(["xu", "xp"]) == ["", ""])
        }
    }

    @Test(.boundedWebViews) func anOldRightClickDoesNotBelongToALaterMenu() async throws {
        try await withFlow { flow, _ in
            try await flow.load(Self.login)
            _ = try await flow.rightClick("au")

            #expect(CredentialPicker.shared.target(for: flow.page, menu: .init(opened: .now.advanced(by: .seconds(3)))) == nil)
            let elsewhere = CredentialPicker.Menu(opened: .now, chromiumFrame: .init(id: "other", url: URL(string: Self.other), isMain: false))
            #expect(CredentialPicker.shared.target(for: flow.page, menu: elsewhere) == nil, "not another frame's menu")
        }
    }

    // MARK: - Naming a website, and imitations

    @Test func aWebsiteIsNamedAsTheAddressBarDrawsIt() {
        #expect(WebsiteLookalike.displayHost(of: "https://login.example.test") == "login.example.test")
        #expect(WebsiteLookalike.displayHost(of: "https://xn--bcher-kva.de") == "xn--bcher-kva.de", "punycode, not the letters")
        #expect(WebsiteLookalike.displayHost(of: URL(string: "https://bücher.de")?.absoluteString ?? "") == "xn--bcher-kva.de")
        #expect(WebsiteLookalike.displayHost(of: "https://user:pw@bank.example@evil.example/") == "evil.example", "no sign-in details")
        #expect(WebsiteLookalike.displayHost(of: "https://example.test:8443") == "example.test:8443")
        #expect(WebsiteLookalike.displayHost(of: "http://example.test") == nil)
    }

    @Test func anImitationOfACredentialsWebsiteIsNamed() {
        let paypal = ["https://paypal.com"]
        #expect(WebsiteLookalike.imitated(by: "https://xn--pypal-4ve.com", among: paypal) == "paypal.com", "a Cyrillic а")
        #expect(WebsiteLookalike.imitated(by: "https://paypa1.com", among: paypal) == "paypal.com")
        #expect(WebsiteLookalike.imitated(by: "https://www.paypal-login.com", among: paypal) == nil, "not one letter away")
        #expect(WebsiteLookalike.imitated(by: "https://xn--bcher-kva.de", among: ["https://bucher.de"]) == "bucher.de")
        #expect(WebsiteLookalike.imitated(by: "https://arnazon.com", among: ["https://shop.example.com", "https://amazon.com"]) == "amazon.com")
        #expect(WebsiteLookalike.imitated(by: "https://login.paypal.com", among: paypal) == nil, "the same site")
        #expect(WebsiteLookalike.imitated(by: "https://example.org", among: paypal) == nil)
        #expect(WebsiteLookalike.imitated(by: "https://x.com", among: ["https://y.com"]) == nil, "too short to tell")
        #expect(WebsiteLookalike.distance(Array("kitten"), Array("sitting")) == 3)
    }

    @Test func aHandPickedCredentialMayTakeAnyNormalizedWebsiteWithRoom() throws {
        let grace = account("grace", origins: [Self.other])
        #expect(!CredentialAccountSelection.canAddWebsite(Self.site, to: grace), "not a sibling")
        #expect(CredentialAccountSelection.canAddWebsite(Self.site, to: grace, anySite: true))
        #expect(!CredentialAccountSelection.canAddWebsite(Self.other, to: grace, anySite: true), "already there")
        #expect(!CredentialAccountSelection.canAddWebsite("https://Login.Example.test/", to: grace, anySite: true), "not normalized")
        #expect(!CredentialAccountSelection.canAddWebsite("http://login.example.test", to: grace, anySite: true))
        let full = account("full", origins: (0..<CredentialAccount.websiteLimit).map { "https://site\($0).example.test" })
        #expect(!CredentialAccountSelection.canAddWebsite(Self.site, to: full, anySite: true))
        let added = try CredentialAccountSelection.addingWebsite(Self.site, to: grace.id, in: [grace], anySite: true)
        #expect(added.first?.origins == [Self.other, Self.site])
    }

    /// A page that imitates the credential's website gets the offer with a warning; a punycode page is named in punycode.
    @Test(.boundedWebViews) func anImitatingPageIsWarnedAboutAndNamedInPunycode() async throws {
        try await VaultManagerFixture.with(vaults: [.unlocked]) { profile, _, vaults in
            let paypal = account("ada", origins: ["https://paypal.com"])
            try await VaultManagerFixture.save([paypal], in: vaults[0])
            let epoch = try #require(vaults[0].manager.authorizationEpoch)
            for (page, host) in [("https://paypa1.com", "paypa1.com"), ("https://xn--pypal-4ve.com", "xn--pypal-4ve.com")] {
                let (view, window) = self.page(profile: profile, url: page + "/login")
                let session = AutofillSaveSession()
                AutofillSaveCoordinator.shared.install(in: view, session: session)
                session.liveness = { _, _, _ in true }

                await session.offerWebsite(accountID: paypal.id, epoch: epoch, origin: page, documentID: "", manual: true)

                let offer = try #require(session.websiteOffer)
                #expect(offer.host == host && offer.lookalike == "paypal.com" && offer.isManual)
                window?.contentView = nil
                window?.close()
                await view.close()
            }
        }
    }
}
