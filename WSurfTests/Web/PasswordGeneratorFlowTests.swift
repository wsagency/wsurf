// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import Testing
import WebKit

@testable import WSurf
@testable import WSurfVault

/// Generate Password… end to end in WebKit against real fixture vaults (plan tests F1-F8 and I2): the page gets nothing before Use
/// Password, opening reads candidates only, Use Password writes exactly one new login before the fill, and every step refuses a
/// private window, a lock or an agent. The sheet is answered through `PasswordGeneratorFlow.answersForTesting`, which sees the
/// proposal before Use Password. Test-only in-memory unlock keys and synthetic passwords; nothing here touches a real vault or the
/// Keychain. Chromium cannot load an HTTPS document from a fixture here (see `AutofillSaveScriptTests`), and the flow refuses an
/// insecure page; its page side is in `PasswordGeneratorScriptTests`, with both engines.
@MainActor
struct PasswordGeneratorFlowTests {
    static let site = "https://login.example.test"
    private static let host = "login.example.test"

    private final class Flow {
        let page: BrowserPage
        let window: NSWindow
        let session = AutofillSaveSession()
        let profile: Profile
        var proposals: [PasswordGeneratorFlow.Proposal] = []

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
            PasswordGeneratorFlow.answersForTesting[profile.id] = nil
            PasswordGeneratorFlow.savedForTesting[profile.id] = nil
            CredentialManager.readAuditsForTesting[profile.id] = nil
            window.contentView = nil
            window.close()
            await page.close()
        }

        /// `html` as the page at the test site, with a main-world observer of the page's own events, mutations and password values
        /// (`window.seen`). A string under an https base URL has that origin but no TLS behind it, so the secure flag is set here.
        func load(_ html: String) async throws {
            let cancel = "<script>document.addEventListener('contextmenu', event => event.preventDefault());</script>"
            page.loadHTMLString("<!doctype html>" + cancel + html + PasswordGeneratorFlowTests.observer, baseURL: URL(string: PasswordGeneratorFlowTests.site + "/"))
            try #require(await waitUntil { !self.page.isLoading && self.page.url?.host() == PasswordGeneratorFlowTests.host })
            try #require(await waitUntil { PasswordAutofill.shared.frames[ObjectIdentifier(self.page)]?.isEmpty == false })
            try #require(await waitUntil { AutofillSaveCoordinator.shared.frames[ObjectIdentifier(self.page)] != nil })
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
            // The page's own reactions to the click (a focus) are done before the observer starts over.
            try await Task.sleep(for: .milliseconds(100))
            _ = try await page.evaluateJavaScript("window.seen = []; 0")
            return try #require(found)
        }

        /// The whole flow for `target`, with `answer` standing in for the person at the sheet.
        func generate(
            _ target: CredentialPicker.Target, allowed: @escaping @MainActor @Sendable () -> Bool = { true },
            answer: @escaping @MainActor (PasswordGeneratorFlow.Proposal) async -> PasswordGeneratorFlow.Answer?
        ) async -> PasswordGeneratorFlow.Outcome {
            PasswordGeneratorFlow.answersForTesting[profile.id] = { [weak self] proposal in
                self?.proposals.append(proposal)
                return await answer(proposal)
            }
            defer { PasswordGeneratorFlow.answersForTesting[profile.id] = nil }
            return await PasswordGeneratorFlow.shared.run(target, in: page, window: window, allowed: allowed)
        }

        func values(_ ids: [String]) async throws -> [String] {
            var result: [String] = []
            for id in ids {
                result.append(try await page.evaluateJavaScript("document.getElementById('\(id)').value") as? String ?? "?")
            }
            return result
        }

        /// What the page's own main-world observer saw since the right-click.
        func seen() async throws -> [String] {
            let json = try await page.evaluateJavaScript("JSON.stringify(window.seen)") as? String ?? "null"
            return (try? JSONDecoder().decode([String].self, from: Data(json.utf8))) ?? ["unreadable: \(json)"]
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

    /// The page's own script, in the main world: every event of a field, every mutation and, every 10 ms, any password field whose
    /// value changed. Before Use Password it must see nothing.
    private static let observer = #"""
        <script>
        window.seen = [];
        for (const type of ['focus','focusin','keydown','beforeinput','input','keyup','change','blur','focusout']) {
          document.addEventListener(type, event => seen.push(type + ':' + (event.target?.id || '')), true);
        }
        new MutationObserver(records => { for (const r of records) seen.push('mutation:' + r.type + ':' + (r.attributeName || '')); })
          .observe(document, {subtree:true, childList:true, attributes:true, characterData:true});
        const values = new Map();
        setInterval(() => {
          for (const input of document.querySelectorAll('input[type=password]')) {
            if (input.value !== (values.get(input) ?? '')) { values.set(input, input.value); seen.push('value:' + input.id); }
          }
        }, 10);
        </script>
        """#

    private static let signUp = #"""
        <form id="signup"><input id="se" type="email" value="ada@example.test">
        <input id="sp" type="password" autocomplete="new-password"><input id="sc" type="password" autocomplete="new-password"></form>
        <form id="step"><input id="np" type="password" autocomplete="new-password"></form>
        <form id="login"><input id="lu" autocomplete="username"><input id="lp" type="password" autocomplete="current-password"></form>
        <p><input id="note" name="note"></p>
        """#

    private func login(_ username: String, origins: [String] = [Self.site], password: String = "Zt4$pL8@nR2w") -> CredentialAccount {
        CredentialAccount(
            id: UUID(), username: username, displayName: nil, origins: origins, loginURLs: [], password: password, passkeys: [],
            totp: nil, exchangeAccountID: nil, exchangeItemID: nil
        )
    }

    private func use(_ proposal: PasswordGeneratorFlow.Proposal) -> PasswordGeneratorFlow.Answer? {
        proposal.password.map { .use($0, vaultID: proposal.vaultID) }
    }

    // MARK: - F1: nothing reaches the page before Use Password

    /// While the sheet is open the page's own observer sees no event, no mutation and no value; after Use Password the field and its
    /// confirmation hold the password. After Cancel it never sees anything. Neither the tab's save session nor the right-click record
    /// holds the password.
    @Test(.boundedWebViews) func nothingReachesThePageBeforeUsePasswordAndNothingAfterCancel() async throws {
        try await withFlow { flow, _ in
            try await flow.load(Self.signUp)
            let target = try await flow.rightClick("sp")
            var whileOpen: [String]?
            let outcome = await flow.generate(target) { proposal in
                try? await Task.sleep(for: .milliseconds(150))
                whileOpen = try? await flow.seen()
                return self.use(proposal)
            }
            #expect(outcome == .filled(2))
            #expect(whileOpen == [], "the page saw nothing while the sheet was open")
            let password = try #require(flow.proposals.first?.password).revealed
            #expect(try await flow.values(["sp", "sc"]) == [password, password])
            #expect(try await flow.seen().contains("input:sp"), "the observer works: it saw the fill")
            var dumped = ""
            dump(flow.session, to: &dumped)
            dump(target, to: &dumped)
            dump(flow.proposals.first?.password, to: &dumped)
            #expect(!dumped.contains(password), "a dump holds no generated password")

            let cancelled = try await flow.rightClick("np")
            #expect(await flow.generate(cancelled) { _ in nil } == .nothing)
            try await Task.sleep(for: .milliseconds(150))
            #expect(try await flow.seen() == [], "after Cancel the page sees nothing")
            #expect(try await flow.values(["np"]) == [""])
        }
    }

    // MARK: - F2 and F3: what is read and what is written

    /// Opening reads candidates only, once per unlocked vault, and Use Password reads nothing more. The vault then holds exactly one
    /// new login: this website, its login page, the username the form shows and the password, and nothing else changed.
    @Test(.boundedWebViews) func openingReadsCandidatesOnlyAndUsePasswordWritesOneNewLogin() async throws {
        try await withFlow { flow, vaults in
            let grace = login("grace@example.test")
            try await VaultManagerFixture.save([grace], in: vaults[0])
            let before = try await vaults[0].manager.snapshot()
            try await flow.load(Self.signUp)
            let target = try await flow.rightClick("sp")
            let audit = VaultReadAudit()
            CredentialManager.readAuditsForTesting[flow.profile.id] = audit

            #expect(await flow.generate(target) { self.use($0) } == .filled(2))
            #expect(audit.reads == [.candidates], "candidates to open, nothing to save")
            CredentialManager.readAuditsForTesting[flow.profile.id] = nil

            let after = try await vaults[0].manager.snapshot()
            #expect(after.revision == before.revision + 1)
            #expect(after.accounts.filter { $0.id != grace.id }.count == 1)
            let saved = try #require(after.accounts.first { $0.id != grace.id })
            let loginPage = try #require(URL(string: Self.site + "/"))
            #expect(saved.username == "ada@example.test" && saved.origins == [Self.site] && saved.displayName == nil)
            #expect(saved.loginURLs == [loginPage])
            #expect(saved.password == flow.proposals.first?.password?.revealed)
            #expect(after.accounts.first { $0.id == grace.id } == before.accounts.first { $0.id == grace.id }, "the other login is untouched")
            let proposal = try #require(flow.proposals.first)
            #expect(proposal.host == Self.host && proposal.pageHost == nil && proposal.vaults.map(\.id) == [vaults[0].vaultID])
            #expect(proposal.format == .easyToType && proposal.password?.count == PasswordGenerator.defaultLength)
            #expect(proposal.field.hasConfirmation && proposal.field.username == "ada@example.test")
        }
    }

    // MARK: - F4: save, then fill

    /// A lock while the sheet is open saves and fills nothing.
    @Test(.boundedWebViews) func aLockWhileTheSheetIsOpenSavesAndFillsNothing() async throws {
        try await withFlow { flow, vaults in
            let before = try await vaults[0].manager.snapshot()
            try await flow.load(Self.signUp)
            let target = try await flow.rightClick("sp")
            let outcome = await flow.generate(target) { proposal in
                vaults[0].manager.lock(reason: .manual)
                return self.use(proposal)
            }
            #expect(outcome == .failed(.noField))
            #expect(try await flow.values(["sp", "sc"]) == ["", ""])
            try await VaultManagerFixture.unlock(vaults[0])
            #expect(try await vaults[0].manager.snapshot().revision == before.revision, "nothing was written")
        }
    }

    /// A page that changes after the save keeps the saved login, gets nothing, and the flow says so.
    @Test(.boundedWebViews) func aFillThatFailsAfterTheSaveKeepsTheLoginAndSaysSo() async throws {
        try await withFlow { flow, vaults in
            try await flow.load(Self.signUp)
            let target = try await flow.rightClick("sp")
            PasswordGeneratorFlow.savedForTesting[flow.profile.id] = {
                _ = try? await flow.page.evaluateJavaScript("document.getElementById('signup').remove(); 0")
            }
            let outcome = await flow.generate(target) { self.use($0) }
            #expect(outcome == .failed(.savedNotFilled(host: Self.host)))
            let saved = try await vaults[0].manager.snapshot().accounts
            #expect(saved.count == 1 && saved.first?.password == flow.proposals.first?.password?.revealed, "the login stays")
        }
    }

    // MARK: - F5: a private window

    /// In a private window nothing is offered: even a right-click recorded there runs nothing, reads nothing and writes nothing.
    @Test(.boundedWebViews) func aPrivateWindowReadsAndWritesNothing() async throws {
        let flow = Flow(profile: .privateBrowsing())
        do {
            try await flow.load(Self.signUp)
            #expect(!CredentialPicker.isOffered(in: flow.page, allowedByTab: true))
            // The policy turns the page's script off in a private window, so nothing reports a right-click there. Turned on again
            // here, after the policy landed, the right-click is recorded, and the flow still refuses it.
            try await Task.sleep(for: .milliseconds(300))
            _ = try await flow.page.callAsyncJavaScript(
                "globalThis.__wsurfPasswords.setEnabled(true);", arguments: [:], in: nil, contentWorld: PasswordAutofill.world
            )
            let target = try await flow.rightClick("sp")
            let audit = VaultReadAudit()
            CredentialManager.readAuditsForTesting[flow.profile.id] = audit
            #expect(await flow.generate(target) { self.use($0) } == .nothing)
            #expect(flow.proposals.isEmpty && audit.reads.isEmpty)
            #expect(try await flow.values(["sp", "sc"]) == ["", ""])
        } catch {
            await flow.close()
            await flow.page.context.endPrivateSession()
            throw error
        }
        await flow.close()
        await flow.page.context.endPrivateSession()
    }

    // MARK: - F6: agents

    /// An agent or a connected app that takes the tab at any step stops the flow: before anything is read, while the sheet is open,
    /// or after the save, where the login stays saved and the page gets nothing.
    @Test(.boundedWebViews, arguments: ["before", "sheet", "saved"])
    func anAgentThatTakesTheTabAtAnyStepGetsNothingFilled(step: String) async throws {
        try await withFlow { flow, vaults in
            try await flow.load(Self.signUp)
            let tab = BrowserTab(opensBlank: false, context: flow.page.context)
            let allowed: @MainActor @Sendable () -> Bool = { tab.allowsCredentialPicker }
            let target = try await flow.rightClick("sp")
            let audit = VaultReadAudit()
            CredentialManager.readAuditsForTesting[flow.profile.id] = audit
            if step == "before" {
                tab.setAgentWorking(true)
            }
            PasswordGeneratorFlow.savedForTesting[flow.profile.id] = {
                if step == "saved" {
                    tab.setAgentWorking(true)
                }
            }
            let outcome = await flow.generate(target, allowed: allowed) { proposal in
                if step == "sheet" {
                    tab.setAgentWorking(true)
                }
                return self.use(proposal)
            }
            #expect(try await flow.values(["sp", "sc"]) == ["", ""])
            CredentialManager.readAuditsForTesting[flow.profile.id] = nil
            let saved = try await vaults[0].manager.snapshot().accounts
            switch step {
            case "before":
                #expect(outcome == .nothing && audit.reads.isEmpty && flow.proposals.isEmpty && saved.isEmpty)
            case "sheet":
                #expect(outcome == .nothing && saved.isEmpty)
            default:
                #expect(outcome == .failed(.savedNotFilled(host: Self.host)) && saved.count == 1)
            }
            tab.setAgentWorking(false)
        }
    }

    /// The sheet of a page an agent takes closes as a Cancel; the sheet of another page, in another window of the same profile,
    /// stays until its own end.
    @Test(.boundedWebViews) func aDismissedPageLosesItsSheetAndAnotherPageKeepsItsOwn() async throws {
        @MainActor
        final class Answers {
            var first: String?
            var second: String?
        }
        try await withFlow { first, _ in
            let second = Flow(profile: first.profile)
            do {
                let field = PasswordGeneratorFlow.Field(kind: .new)
                let proposal = PasswordGeneratorFlow.Proposal(
                    host: Self.host, pageHost: nil, field: field, vaults: [], vaultID: UUID(), canUnlock: false, format: .easyToType,
                    password: PasswordGeneratorFlow.password(.easyToType, for: field)
                )
                let answers = Answers()
                let profileID = first.profile.id
                let (firstPage, firstWindow, secondPage, secondWindow) = (first.page, first.window, second.page, second.window)
                Task { @MainActor in
                    let answer = await PasswordGeneratorSheet.present(proposal, profileID: profileID, page: firstPage, in: firstWindow)
                    answers.first = answer == nil ? "cancel" : "answer"
                }
                Task { @MainActor in
                    let answer = await PasswordGeneratorSheet.present(proposal, profileID: profileID, page: secondPage, in: secondWindow)
                    answers.second = answer == nil ? "cancel" : "answer"
                }
                try #require(await waitUntil { first.window.attachedSheet != nil && second.window.attachedSheet != nil })

                CredentialPickerSheet.dismiss(page: first.page)
                #expect(await waitUntil { answers.first == "cancel" })
                #expect(first.window.attachedSheet == nil)
                try await Task.sleep(for: .milliseconds(100))
                #expect(second.window.attachedSheet != nil && answers.second == nil, "the other page's sheet stays")

                CredentialPickerSheet.dismiss(page: second.page)
                #expect(await waitUntil { answers.second == "cancel" })
            } catch {
                CredentialPickerSheet.dismiss(profileID: first.profile.id)
                await second.close()
                throw error
            }
            await second.close()
        }
    }

    /// L3: the real wiring. The tab hosts the page (`BrowserTab(adoptingPage:)`), the real sheet is open on its window, and an agent
    /// taking the tab (`processState.onControlChange`, then `agentControlChanged`, then `CredentialPickerSheet.dismiss(page: liveView)`)
    /// closes that sheet as a Cancel: nothing is saved or filled.
    @Test(.boundedWebViews) func anAgentTakingTheTabThatHostsThePageClosesItsRealSheet() async throws {
        try await withFlow { flow, vaults in
            try await flow.load(Self.signUp)
            let tab = BrowserTab(adoptingPage: flow.page, opensBlank: false, context: flow.page.context)
            try #require(tab.liveView === flow.page)
            let target = try await flow.rightClick("sp")
            let before = try await vaults[0].manager.snapshot()
            let (page, window) = (flow.page, flow.window)
            let run = Task { @MainActor in
                await PasswordGeneratorFlow.shared.run(target, in: page, window: window, allowed: { tab.allowsCredentialPicker })
            }
            do {
                try #require(await waitUntil { flow.window.attachedSheet != nil }, "the real sheet opened")
                tab.setAgentWorking(true)
                let closed = await waitUntil { flow.window.attachedSheet == nil }
                #expect(closed, "the agent's taking the tab closed the sheet")
                if !closed {
                    CredentialPickerSheet.dismiss(profileID: flow.profile.id)
                }
                #expect(await run.value == .nothing)
            } catch {
                CredentialPickerSheet.dismiss(profileID: flow.profile.id)
                _ = await run.value
                tab.setAgentWorking(false)
                throw error
            }
            tab.setAgentWorking(false)
            #expect(try await flow.values(["sp", "sc"]) == ["", ""])
            #expect(try await vaults[0].manager.snapshot().revision == before.revision, "nothing was saved")
        }
    }

    // MARK: - L1: page text in the sheet

    /// The username a form shows is page text. In the sheet's sentence it is one clean line: no line break, control, format (bidi
    /// override or isolate, zero-width) or separator character, so a page cannot lay out its own text in WSurf's.
    @Test func aPageSuppliedUsernameIsOneCleanLineInTheSheet() {
        let hostile = "ada\n\u{202E}WSurf saved this in vault Personal\u{2066}\r\u{2028}\u{2029}\u{7}\u{200B}\t."
        var field = PasswordGeneratorFlow.Field(kind: .new)
        field.username = hostile
        for hasConfirmation in [false, true] {
            field.hasConfirmation = hasConfirmation
            let text = PasswordGeneratorView.explanation(host: Self.host, field: field)
            let hidden: Set<Unicode.GeneralCategory> = [.control, .format, .lineSeparator, .paragraphSeparator]
            #expect(!text.unicodeScalars.contains { hidden.contains($0.properties.generalCategory) }, "\(text.debugDescription)")
            #expect(text.contains("adaWSurf saved this in vault Personal."))
        }
        #expect(PasswordGeneratorView.shownUsername("ada@example.test") == "ada@example.test", "an ordinary username is as it is")
    }

    /// A long username is cut, so the sentence stays short.
    @Test func aLongUsernameIsCutInTheSheet() {
        let shown = PasswordGeneratorView.shownUsername(String(repeating: "a", count: 500))
        #expect(shown == String(repeating: "a", count: PasswordGeneratorView.shownUsernameLimit) + "…")
        #expect(PasswordGeneratorView.shownUsername(String(repeating: "b", count: PasswordGeneratorView.shownUsernameLimit)).count == PasswordGeneratorView.shownUsernameLimit)
    }

    // MARK: - L2: what Use Password saves is what the sheet showed

    /// A page that changes the username, a length limit, the password rules or the confirmation while the sheet is open gets nothing
    /// saved or filled: at Use Password the field is read again and must equal what the sheet showed.
    @Test(.boundedWebViews, arguments: ["username", "maxlength", "rules", "confirmation"])
    func aFieldThatChangesWhileTheSheetIsOpenSavesAndFillsNothing(change: String) async throws {
        try await withFlow { flow, vaults in
            try await flow.load(Self.signUp)
            let target = try await flow.rightClick("sp")
            let before = try await vaults[0].manager.snapshot()
            let scripts = [
                "username": "document.getElementById('se').value = 'bob@example.test'; 0",
                "maxlength": "document.getElementById('sp').maxLength = 8; 0",
                "rules": "document.getElementById('sp').setAttribute('passwordrules', 'required: digit; minlength: 20'); 0",
                "confirmation": "document.getElementById('sc').remove(); 0",
            ]
            let script = try #require(scripts[change])
            let outcome = await flow.generate(target) { proposal in
                _ = try? await flow.page.evaluateJavaScript(script)
                return self.use(proposal)
            }
            #expect(outcome == .failed(.fieldChanged))
            #expect(try await flow.values(["sp"]) == [""])
            if change != "confirmation" {
                #expect(try await flow.values(["sc"]) == [""])
            }
            #expect(try await vaults[0].manager.snapshot().revision == before.revision, "nothing was saved")
        }
    }

    // MARK: - I1: a form that turned unsafe after the save

    /// A form that starts sending to another website after the save keeps the saved login and says so in its own words.
    @Test(.boundedWebViews) func aFormThatTurnsUnsafeAfterTheSaveSaysSo() async throws {
        try await withFlow { flow, vaults in
            try await flow.load(Self.signUp)
            let target = try await flow.rightClick("sp")
            PasswordGeneratorFlow.savedForTesting[flow.profile.id] = {
                _ = try? await flow.page.evaluateJavaScript(
                    "document.getElementById('signup').setAttribute('action', 'https://elsewhere.example/collect'); 0"
                )
            }
            let outcome = await flow.generate(target) { self.use($0) }
            #expect(outcome == .failed(.savedFormUnsafe(host: Self.host)))
            #expect(try await flow.values(["sp", "sc"]) == ["", ""])
            #expect(try await vaults[0].manager.snapshot().accounts.count == 1, "the login stays")
        }
    }

    // MARK: - F7: which vault

    /// The vault the sheet offers first: the one unlocked vault that holds this website, else the default vault. A vault the person
    /// chooses gets the login, and Unlock Other Vaults… unlocks before the sheet opens again.
    @Test(.boundedWebViews) func theSheetOffersTheHolderThenTheDefaultAndSavesWhereThePersonChooses() async throws {
        try await withFlow(vaults: [.unlocked, .unlocked]) { flow, vaults in
            try await flow.load(Self.signUp)
            let store = try CredentialManager.store(for: flow.profile)
            let defaultID = await store.defaultVaultID() ?? vaults[0].vaultID
            let other = try #require(vaults.first { $0.vaultID != defaultID })

            // Nothing holds this website: the default vault, and the person picks the other one.
            let signUp = try await flow.rightClick("sp")
            #expect(await flow.generate(signUp) { proposal in
                proposal.password.map { .use($0, vaultID: other.vaultID) }
            } == .filled(2))
            #expect(flow.proposals.last?.vaultID == defaultID && flow.proposals.last?.vaults.count == 2)
            #expect(try await other.manager.snapshot().accounts.count == 1, "saved where the person chose")

            // Now the other vault holds this website, and it is offered first.
            let next = try await flow.rightClick("np")
            #expect(await flow.generate(next) { _ in nil } == .nothing)
            #expect(flow.proposals.last?.vaultID == other.vaultID)
        }
    }

    @Test(.boundedWebViews) func unlockOtherVaultsUnlocksAndOpensTheSheetAgain() async throws {
        let passkeys = VaultPasskeys()
        try await withFlow(passkeys: passkeys, vaults: [.unlocked, .locked]) { flow, vaults in
            try await flow.load(Self.signUp)
            let target = try await flow.rightClick("sp")
            let before = passkeys.assertions.count
            var answered = 0
            let outcome = await flow.generate(target) { _ in
                answered += 1
                return answered == 1 ? .unlock : nil
            }
            #expect(outcome == .nothing)
            #expect(flow.proposals.first?.canUnlock == true && flow.proposals.first?.vaults.count == 1)
            #expect(passkeys.assertions.count == before + 1, "the ordinary unlock, once")
            #expect(flow.proposals.last?.vaults.count == 2 && flow.proposals.last?.canUnlock == false)
            let unlocked = vaults.map(\.manager.isUnlocked)
            #expect(unlocked == [true, true], "both vaults are unlocked")
        }
    }

    // MARK: - F8: an identifier-first sign-up

    /// A form with a password and no username saves the username an earlier step of this website asked for.
    @Test(.boundedWebViews) func anIdentifierFirstSignUpSavesTheUsernameOfTheEarlierStep() async throws {
        try await withFlow { flow, vaults in
            try await flow.load(Self.signUp)
            let target = try await flow.rightClick("np")
            flow.session.username = .init(origin: Self.site, value: "ada@example.test", documentID: "an earlier step", attemptID: UUID())
            #expect(await flow.generate(target) { self.use($0) } == .filled(1))
            #expect(flow.proposals.first?.field.username == "", "the form shows none")
            #expect(try await vaults[0].manager.snapshot().accounts.map(\.username) == ["ada@example.test"])
        }
    }

    // MARK: - Refusals

    /// A field that takes no password, and the current password of a change form, are refused before anything is read or made.
    @Test(.boundedWebViews) func theWrongFieldIsRefusedBeforeAnythingIsReadOrMade() async throws {
        try await withFlow { flow, vaults in
            try await flow.load(Self.signUp + #"<form id="change"><input id="cc" type="password" autocomplete="current-password"><input id="cn" type="password" autocomplete="new-password"></form>"#)
            let audit = VaultReadAudit()
            CredentialManager.readAuditsForTesting[flow.profile.id] = audit
            let email = try await flow.rightClick("se")
            #expect(await flow.generate(email) { self.use($0) } == .failed(.notPasswordField))
            let current = try await flow.rightClick("cc")
            #expect(await flow.generate(current) { self.use($0) } == .failed(.currentPasswordField))
            #expect(flow.proposals.isEmpty && audit.reads.isEmpty)
            CredentialManager.readAuditsForTesting[flow.profile.id] = nil
            #expect(try await vaults[0].manager.snapshot().accounts.isEmpty)
        }
    }

    /// A profile with no vault gets no password: one that cannot be saved is not offered.
    @Test(.boundedWebViews) func aProfileWithNoVaultGetsNoPassword() async throws {
        try await withFlow(vaults: []) { flow, _ in
            try await flow.load(Self.signUp)
            let target = try await flow.rightClick("sp")
            #expect(await flow.generate(target) { self.use($0) } == .failed(.noVault))
            #expect(flow.proposals.isEmpty)
            #expect(try await flow.values(["sp", "sc"]) == ["", ""])
        }
    }

    // MARK: - I2: Input History

    /// A generated fill is the script's own untrusted typing, which Input History never records: after the fill and the person's own
    /// typing in another field, Input History holds that typing only.
    @Test(.boundedWebViews) func aGeneratedFillNeverReachesInputHistory() async throws {
        final class Posts {
            var all: [(body: [String: Any], frame: BrowserFrame)] = []
        }
        let rig = InputHistoryCaptureRig(recording: true, formModel: true)
        let posts = Posts()
        rig.page.installScript(
            AutofillSuggestionScript.source + PasswordAutofillScript.clientSource, in: PasswordAutofill.world,
            injectionTime: .atDocumentStart, forMainFrameOnly: false
        )
        rig.page.addScriptMessageHandler(name: "wsurfPasswords", in: PasswordAutofill.world) { message in
            guard let body = message.body as? [String: Any] else { return }
            posts.all.append((body, message.frameInfo))
        }
        let window = NSWindow(contentRect: NSRect(x: 50, y: 50, width: 600, height: 400), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = rig.page
        window.orderBack(nil)
        defer {
            window.contentView = nil
            window.close()
        }
        do {
            rig.page.loadHTMLString(
                "<!doctype html><script>document.addEventListener('contextmenu', event => event.preventDefault());</script>"
                    + "<form onsubmit='return false'><input id='email' type='email' value='ada@example.test'>"
                    + "<input id='new' type='password' autocomplete='new-password'><input id='again' type='password' autocomplete='new-password'></form>"
                    + "<input id='note' name='note'>",
                baseURL: URL(string: "https://login.example/")
            )
            #expect(await PageSettle.untilIdle(rig.page, timeout: .seconds(20)))
            #expect(await waitUntil { rig.capture.documentCount(in: rig.page) >= 1 })
            try #require(await waitUntil { posts.all.contains { $0.body["action"] as? String == "ready" } })
            let main = try #require(posts.all.last { $0.body["action"] as? String == "ready" }?.frame)
            _ = try await rig.page.callAsyncJavaScript(
                "globalThis.__wsurfPasswords.setEnabled(true);", arguments: [:], in: main, contentWorld: PasswordAutofill.world
            )
            try #require(await waitUntil {
                try await rig.page.callAsyncJavaScript(
                    "return globalThis.__wsurfInputHistory?.__test.enabled();", arguments: [:], in: nil, contentWorld: AutofillPage.world
                ) as? Bool == true
            })

            let count = posts.all.count
            try await PageRightClick.send(at: try await PageRightClick.center(of: "new", in: rig.page), in: rig.page, window: window)
            try #require(await waitUntil { posts.all.dropFirst(count).contains { $0.body["action"] as? String == "context" } })
            let click = try #require(posts.all.last { $0.body["action"] as? String == "context" }?.body)
            let password = "hq4mzt-wnbcke-paXr9j"
            let answer = try await rig.page.callAsyncJavaScript(
                "return globalThis.__wsurfPasswords.generateFill(token, url, password);",
                arguments: ["token": click["token"] as? String ?? "", "url": click["url"] as? String ?? "", "password": password],
                in: main, contentWorld: PasswordAutofill.world
            ) as? [String: Any]
            #expect((answer?["count"] as? NSNumber)?.intValue == 2)

            // The person's own typing in another field is recorded, so the capture is working; the generated password is not.
            let hook = "const field = id => document.getElementById(id); return globalThis.__wsurfInputHistory.__test."
            _ = try await rig.page.callAsyncJavaScript(
                hook + "edit(field('note'), 'dummy-note-1')", arguments: [:], in: nil, contentWorld: AutofillPage.world
            )
            for call in ["blur(field('new'))", "blur(field('again'))", "blur(field('note'))", "leave()"] {
                _ = try await rig.page.callAsyncJavaScript(hook + call, arguments: [:], in: nil, contentWorld: AutofillPage.world)
            }
            #expect(try await waitUntil { try await rig.entries().count == 1 })
            let entries = try await rig.entries()
            #expect(entries.map(\.payload.value) == ["dummy-note-1"], "the generated password is not among what Input History kept")
        } catch {
            await rig.tearDown()
            throw error
        }
        await rig.tearDown()
    }
}
