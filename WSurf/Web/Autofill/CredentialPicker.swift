// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import WSurfVault

/// "Pick Credential…" in a page's context menu, for when the automatic offer does not open: the person picks a saved login or
/// verification code from the unlocked vaults and it fills the field they right-clicked.
///
/// - The field is the one the frame's own script saw a trusted contextmenu event on (`noteContext`), in the frame the engine says
///   the event came from. The fill goes to that frame only, to that field and its partner only (`__wsurfPasswords.pickFill`).
/// - The picker lists titles and websites only, from the vault's candidates, which hold no secret. The chosen credential's one secret
///   is read after the choice, under the unlock and revision it was listed under, and the code or password is made at the engine's
///   dispatch boundary, as `AutofillSuggestions` does.
/// - It is never offered in a private window, while password autofill is off, on a page that is not a secure HTTPS page, or in a tab
///   an agent or a connected app controls (`isOffered`, checked again before every step).
/// - A credential used on a website it is not saved for is offered that website afterwards (`AutofillSaveSession.offerWebsite`,
///   `manual`): nothing is stored unless the person accepts.
@MainActor
final class CredentialPicker {
    static let shared = CredentialPicker()

    /// The field the person last right-clicked in a page, as the script of the frame that got the trusted contextmenu event reported
    /// it. The frame and its origin are the engine's word, never the page's.
    struct Target {
        weak var page: BrowserPage?
        let context: BrowserProfileContext
        let frame: BrowserFrame
        let token: String
        let documentID: String
        let frameURL: URL
        /// The frame's origin: what "this website" means for the list, the fill and the website a credential may be given.
        let origin: String
        let field: Field
        let received: ContinuousClock.Instant
    }

    /// What the right-clicked field looks like: only the order of the list depends on it.
    nonisolated enum Field: String, Sendable {
        case password, code, text
    }

    /// The context menu that offered the item: when it opened and, in Chromium, the frame the engine says was right-clicked.
    nonisolated struct Menu: Sendable {
        let opened: ContinuousClock.Instant
        var chromiumFrame: ChromiumFrame?
    }

    nonisolated struct ChromiumFrame: Sendable {
        let id: String
        let url: URL?
        let isMain: Bool
    }

    /// One choice of the picker: identity and labels, never a password, seed or code.
    nonisolated struct Row: Identifiable, Equatable, Sendable {
        nonisolated enum Fill: Sendable {
            case login, code
        }

        let id: UUID
        let vaultID: UUID
        let accountID: UUID
        let fill: Fill
        let title: String
        let detail: String
        /// Saved for this website or a sibling of it (`CredentialAccountSelection.isSibling`).
        let matchesSite: Bool
        let searchKey: String
        /// When it was last used on this website (`AutofillLastUsed`); only a credential saved for this website has one.
        var lastUsed: Date?
    }

    enum Answer: Equatable {
        case row(UUID), unlock
        /// A code the person picked from macOS's own list in the sheet's native field (Messages or Mail), or typed there. It fills the
        /// right-clicked field, or its split boxes, the way a vault code does, and is kept nowhere.
        case code(String)
    }

    enum Failure: Equatable {
        /// The field, the page or the vault changed, or the page took nothing.
        case noField
        /// The password or code would have gone to a form that sends it to another website: nothing was filled.
        case unsafeForm
    }

    enum Outcome: Equatable {
        case filled(Int), nothing, failed(Failure)
    }

    /// The vaults' choices as one list, with the unlock and revision each vault was read under.
    struct Reading {
        var rows: [Row] = []
        var grants: [UUID: (epoch: UInt64, revision: UInt64)] = [:]
        var hasLockedVault = false
    }

    static let menuItemIdentifier = NSUserInterfaceItemIdentifier("WSurfPickCredential")

    /// Why an editable field's menu shows Pick Credential… disabled instead of leaving it out: the two reasons a person can see and
    /// act on. A private window and turned-off password filling show no item, as before. It only explains. The item is never usable
    /// then: `isOffered` is the one gate, and a refusal always implies it fails.
    nonisolated enum Refusal: CaseIterable, Sendable {
        case agentControl, insecurePage

        /// The menu title, the same in both engines (a Chromium menu item has no subtitle).
        var menuTitle: String {
            switch self {
            case .agentControl:
                String(localized: "Pick Credential… (An AI App Is Using This Tab)")
            case .insecurePage:
                String(localized: "Pick Credential… (Page Isn’t Fully Secure)")
            }
        }
    }

    /// Tests answer the picker without a sheet, keyed by profile like `VaultChoicePrompt.answersForTesting`.
    static var answersForTesting: [UUID: @MainActor ([Row]) async -> Answer?] = [:]

    private var targets: [ObjectIdentifier: Target] = [:]
    /// Pages whose pick, or generated password (`PasswordGeneratorFlow`), is under way: they share the right-click, so a second menu
    /// command for the same page is refused until the first ends.
    var picking: Set<ObjectIdentifier> = []

    private init() {}

    // MARK: - Where it is offered

    /// Whether a page may offer Pick Credential… now, before anything is read: the tab's own policy (`allowedByTab`: no agent or
    /// connected app controls it, it is no internal page), never a private window, only while password autofill is on, and only on a
    /// secure HTTPS page shown in a window.
    static func isOffered(in page: BrowserPage, allowedByTab: Bool) -> Bool {
        let context = page.context
        return allowedByTab && !context.profile.isPrivate && AutofillSaveCoordinator.shared.isEnabled(.password, context: context)
            && page.url.flatMap(SavedPassword.origin(for:)) != nil && page.hasOnlySecureContent && page.window != nil
            && !page.isHiddenOrHasHiddenAncestor
    }

    /// The reason to show the item disabled, for a page where `isOffered` is false: nil where the item is left out (an internal or
    /// closed tab, no window, a page that is not HTTPS, a private window, password filling off, a locked screen or an inactive
    /// session: the last four by the same check `isOffered` makes). `agentControlled` is the tab's (`isAgentControlled`).
    static func refusal(in page: BrowserPage, agentControlled: Bool) -> Refusal? {
        // A page that is not HTTPS stays without the item whatever else holds, so no reason is the real one.
        guard page.url.flatMap(SavedPassword.origin(for:)) != nil else { return nil }
        let context = page.context
        // Private windows, turned-off password filling, a locked screen and an inactive session have no item, whatever else holds.
        guard AutofillSaveCoordinator.shared.isEnabled(.password, context: context) else { return nil }
        if agentControlled {
            return .agentControl
        }
        return page.hasOnlySecureContent ? nil : .insecurePage
    }

    /// A trusted right-click as the frame's script reported it: an editable text field with a fresh token, or nothing (which
    /// forgets the page's earlier one, so a menu never fills a field from an older right-click).
    func noteContext(_ message: BrowserScriptMessage) {
        note(message.body, in: message.page, frame: message.frameInfo)
    }

    /// What `noteContext` and `pickFocused` share: the script's report, taken in the frame the engine says sent it.
    @discardableResult
    private func note(_ report: Any?, in page: BrowserPage, frame: BrowserFrame) -> Bool {
        targets = targets.filter { $0.value.page != nil }
        guard let body = report as? [String: Any],
              let token = body["token"] as? String, UUID(uuidString: token) != nil,
              let documentID = body["documentID"] as? String, UUID(uuidString: documentID) != nil,
              let field = (body["field"] as? String).flatMap(Field.init(rawValue:)),
              let raw = body["url"] as? String, let frameURL = URL(string: raw),
              let origin = CredentialAccountSelection.origin(for: frameURL), frame.autofillOrigin(reportedURL: frameURL) == origin else {
            targets[ObjectIdentifier(page)] = nil
            return false
        }
        targets[ObjectIdentifier(page)] = Target(
            page: page, context: page.context, frame: frame, token: token, documentID: documentID, frameURL: frameURL, origin: origin,
            field: field, received: .now
        )
        return true
    }

    /// The right-click that belongs to `menu`: the page's latest, reported around the time the menu opened, and in Chromium from the
    /// frame the engine named.
    func target(for page: BrowserPage, menu: Menu) -> Target? {
        guard let target = targets[ObjectIdentifier(page)], target.page === page, target.context === page.context,
              target.received >= menu.opened.advanced(by: .seconds(-2)) else { return nil }
        if let frame = menu.chromiumFrame {
            guard target.frame.isMainFrame == frame.isMain, target.frame.chromiumID == frame.id || target.frameURL == frame.url else {
                return nil
            }
        }
        return target
    }

    // MARK: - Picking

    /// The menu item: the picker for the right-clicked field. `allowed` is the tab's policy, asked again before every step.
    func pick(in page: BrowserPage, menu: Menu, allowed: @escaping @MainActor @Sendable () -> Bool) {
        let key = ObjectIdentifier(page)
        guard !picking.contains(key), let target = target(for: page, menu: menu), let window = page.window,
              Self.isOffered(in: page, allowedByTab: allowed()) else {
            NSSound.beep()
            return
        }
        picking.insert(key)
        Task { [weak self, weak page] in
            guard let self, let page else { return }
            guard await Self.isNamedFrame(target, by: menu, in: page) else {
                self.picking.remove(key)
                NSSound.beep()
                return
            }
            let outcome = await self.run(target, in: page, window: window, allowed: allowed)
            self.picking.remove(key)
            if case .failed(let failure) = outcome, page.window === window {
                await Self.report(failure, in: window)
            }
        }
    }

    /// Edit ▸ Pick Credential…, for a site that cancels or replaces the context menu: the picker for the field that has focus. The
    /// focused frame's script reports that field as it reports a right-click (`note`), then `pick` runs, which is the menu item's
    /// whole path with every gate: the same `isOffered` first, again before each step, the same target check and the same flow.
    func pickFocused(in page: BrowserPage, allowed: @escaping @MainActor @Sendable () -> Bool) {
        // Not while a pick or a generated password is under way for the page: noting the focused field would replace the right-click
        // that flow runs from, and cancel it.
        guard !picking.contains(ObjectIdentifier(page)), Self.isOffered(in: page, allowedByTab: allowed()) else {
            NSSound.beep()
            return
        }
        Task { [weak self, weak page] in
            guard let self, let page, await self.noteFocusedField(in: page) else {
                NSSound.beep()
                return
            }
            // Opened now, after the frames answered, so a slow frame cannot use up the two seconds `target(for:menu:)` allows.
            self.pick(in: page, menu: Menu(opened: .now), allowed: allowed)
        }
    }

    /// The frame whose document has focus, main frame first, reports its focused field; the engine names the frame, never the page.
    /// A frame that has not answered within a second ends the command, so a busy frame cannot hold the page or stall the menu.
    func noteFocusedField(in page: BrowserPage) async -> Bool {
        let frames = (PasswordAutofill.shared.frames[ObjectIdentifier(page)] ?? [:]).sorted { $0.value.isMainFrame && !$1.value.isMainFrame }
        for (documentID, frame) in frames {
            // The answer waits in a box that an answer after the ceiling fills for nobody.
            let box = FocusReport()
            let answered = await PageReply<Bool>.awaiting(within: Self.focusedFieldCeiling) { gate in
                Task {
                    box.report = try? await page.callAsyncJavaScript(
                        "if (globalThis.__wsurfAutofillForms?.documentID !== documentID) return null; return globalThis.__wsurfPasswords?.focusedContext() ?? null;",
                        arguments: ["documentID": documentID], in: frame, contentWorld: PasswordAutofill.world
                    )
                    gate.finish(true)
                }
            }
            guard answered == true else { return false }
            if let report = box.report, report is [String: Any] {
                return note(report, in: page, frame: frame)
            }
        }
        return false
    }

    /// How long a frame has to name its focused field (Edit ▸ Pick Credential…).
    static let focusedFieldCeiling: Duration = .seconds(1)

    @MainActor private final class FocusReport {
        var report: Any?
    }

    /// Chromium names the right-clicked frame by its own id, which need not be the DevTools id the script's frame carries. The URL
    /// then names it only while no other live frame of the page, cross-site frames included, has that URL, the rule of
    /// `ChromiumPage.frame(id:requestURL:isMainFrame:)`.
    static func isNamedFrame(_ target: Target, by menu: Menu, in page: BrowserPage) async -> Bool {
        guard let named = menu.chromiumFrame, target.frame.chromiumID != named.id else { return true }
        guard let chromium = page.chromium, let live = try? await chromium.devTools.framesIncludingCrossSiteFrames() else { return false }
        return live.filter { $0.isMainFrame == named.isMain && $0.request.url == named.url }.count == 1
    }

    /// Unlock if every vault is locked, list, let the person choose, fill. Every suspension is followed by the same check: the page,
    /// its window, its profile and the right-click are still the ones it started from, and the policy still offers the picker.
    func run(
        _ target: Target, in page: BrowserPage, window: NSWindow, allowed: @escaping @MainActor @Sendable () -> Bool
    ) async -> Outcome {
        let profile = target.context.profile
        let isCurrent = currentCheck(for: target, in: page, window: window, allowed: allowed)
        guard isCurrent(), await field(of: target, in: page) != nil, isCurrent() else { return .nothing }
        var unlocking = await AutofillSuggestions.allVaultsLocked(of: profile)
        while true {
            if unlocking {
                guard await AutofillSuggestions.shared.unlockVault(of: profile, in: window, while: isCurrent), isCurrent() else {
                    return .nothing
                }
            }
            guard isCurrent(), let reading = await read(for: target), isCurrent() else { return .nothing }
            switch await choose(reading, target: target, in: window) {
            case .row(let id)?:
                guard isCurrent() else { return .nothing }
                return await fill(id, reading: reading, target: target, in: page, isCurrent: isCurrent)
            case .unlock?:
                unlocking = true
            case .code(let code)?:
                guard isCurrent() else { return .nothing }
                return await fill(code: code, target: target, in: page, isCurrent: isCurrent)
            case nil:
                return .nothing
            }
        }
    }

    /// The check made after every suspension of a flow that started from `target`: the page, its window, its profile and the
    /// right-click are still the ones it started from, and the policy still offers the item (`allowed` is the tab's, asked again).
    func currentCheck(
        for target: Target, in page: BrowserPage, window: NSWindow, allowed: @escaping @MainActor @Sendable () -> Bool
    ) -> @MainActor @Sendable () -> Bool {
        let context = target.context, key = ObjectIdentifier(page), token = target.token
        return { [weak self, weak page, weak window] in
            guard let self, let page, let window else { return false }
            return page.context === context && self.targets[key]?.token == token && page.window === window
                && Self.isOffered(in: page, allowedByTab: allowed())
        }
    }

    /// The field the target names, if the frame's document still has it as it was right-clicked.
    private func field(of target: Target, in page: BrowserPage) async -> Field? {
        if let chromium = page.chromium, (try? await chromium.isLive(frame: target.frame)) != true {
            return nil
        }
        let answer = try? await page.callAsyncJavaScript(
            "if (globalThis.__wsurfAutofillForms?.documentID !== documentID) return null; return globalThis.__wsurfPasswords?.pickTarget(token, url) ?? null;",
            arguments: ["documentID": target.documentID, "token": target.token, "url": target.frameURL.absoluteString],
            in: target.frame, contentWorld: PasswordAutofill.world
        )
        return (answer as? String).flatMap(Field.init(rawValue:))
    }

    /// Every unlocked vault of the profile, in ordinal order, each under its own unlock, as candidates: no secret is read to list.
    /// A locked vault is never read. A profile with no vault (or a store that cannot be read) lists nothing, and the sheet says so.
    private func read(for target: Target) async -> Reading? {
        let profile = target.context.profile
        guard !profile.isPrivate else { return nil }
        let listing = (try? await CredentialManager.store(for: profile).listing()) ?? []
        let unlocked = CredentialManager.unlockedManagers(for: profile)
        let lastUsed = target.context.autofillLastUsed
        var reading = Reading()
        for vault in listing.sorted(by: { $0.ordinal < $1.ordinal }) {
            guard let manager = unlocked.first(where: { $0.vaultID == vault.vaultID }), let epoch = manager.authorizationEpoch,
                  let candidates = try? await manager.autofillCandidates(), manager.authorizationEpoch == epoch else {
                reading.hasLockedVault = true
                continue
            }
            reading.grants[vault.vaultID] = (epoch, candidates.revision)
            let uses = try? await manager.importMemoryKey()
            var used: [UUID: Date] = [:]
            for candidate in candidates.candidates where candidate.origins.contains(target.origin) {
                used[candidate.id] = lastUsed.date(uses, account: candidate.id, origin: target.origin)
            }
            reading.rows += Self.rows(
                candidates.candidates, vaultID: vault.vaultID, origin: target.origin, vault: listing.count > 1 ? vault.label : nil, used: used
            )
        }
        reading.rows = Self.ordered(reading.rows, for: target.field)
        return reading
    }

    private func choose(_ reading: Reading, target: Target, in window: NSWindow) async -> Answer? {
        if let answer = Self.answersForTesting[target.context.profile.id] {
            return await answer(reading.rows)
        }
        guard let host = WebsiteLookalike.displayHost(of: target.origin) else { return nil }
        return await CredentialPickerSheet.present(
            rows: reading.rows, host: host, canUnlock: reading.hasLockedVault, offersCode: Self.offersMessagesCode(for: target.field),
            profileID: target.context.profile.id, page: target.page, in: window
        )
    }

    /// The chosen credential's one secret for the row (its password, or the source of its code) is read under the unlock and revision
    /// it was listed under (`autofillLogin`), and delivered into the right-clicked field's frame only. The password, username or fresh
    /// code exists only in the closure the engine runs at its dispatch boundary.
    private func fill(
        _ id: UUID, reading: Reading, target: Target, in page: BrowserPage, isCurrent: @escaping @MainActor @Sendable () -> Bool
    ) async -> Outcome {
        let context = target.context
        guard let row = reading.rows.first(where: { $0.id == id }), let grant = reading.grants[row.vaultID],
              let manager = Self.manager(of: context, vaultID: row.vaultID, epoch: grant.epoch),
              let generation = manager.stableGeneration else { return .failed(.noField) }
        let picked: AutofillLogin?
        do {
            picked = try await manager.autofillLogin(
                accountID: row.accountID, field: row.fill == .code ? .totp : .password, expectedRevision: grant.revision
            )
        } catch CredentialVaultError.staleRevision {
            // A write since the list, or the credential is gone: decided after the page is checked, as before.
            picked = nil
        } catch {
            return .failed(.noField)
        }
        guard isCurrent() else { return .nothing }
        guard manager.authorizationEpoch == grant.epoch, manager.stableGeneration == generation, let login = picked else {
            return .failed(.noField)
        }
        let account = login.candidate
        guard await field(of: target, in: page) != nil else { return isCurrent() ? .failed(.noField) : .nothing }
        guard isCurrent() else { return .nothing }
        let fill = row.fill, vaultID = row.vaultID, epoch = grant.epoch
        let token = target.token, url = target.frameURL.absoluteString, documentID = target.documentID
        let prepare: @MainActor @Sendable () throws -> [String: Any] = {
            guard isCurrent(), Self.manager(of: context, vaultID: vaultID, epoch: epoch) === manager,
                  manager.stableGeneration == generation else { throw ContactAutofillError.changedPage }
            var fields: [String: Any]
            switch fill {
            case .code:
                guard let code = login.code?.code(at: .now) else { throw ContactAutofillError.noField }
                fields = ["code": code]
            case .login:
                fields = ["username": account.username]
                if let password = login.password {
                    fields["password"] = password
                }
            }
            return ["token": token, "url": url, "documentID": documentID, "fields": fields]
        }
        let outcome = await deliver(prepare, target: target, in: page, isCurrent: isCurrent)
        guard case .filled(let count) = outcome else { return outcome }
        guard isCurrent() else { return .filled(count) }
        let session = AutofillSaveCoordinator.shared.session(for: page)
        if account.origins.contains(target.origin) {
            target.context.autofillLastUsed.record(account: account.id, origin: target.origin, in: manager)
            if fill == .login, !account.username.isEmpty {
                AutofillSaveCoordinator.shared.rememberFilledUsername(
                    account.username, origin: target.origin, documentID: target.documentID, in: page, accountID: account.id, epoch: epoch
                )
            }
        } else if let session {
            // Used where it is not saved: offer this website, and keep a submit of the same login from becoming a copy of it.
            if fill == .login {
                session.manualPick = .init(accountID: account.id, epoch: epoch, origin: target.origin, deadline: .now.advanced(by: .seconds(300)))
            }
            await session.offerWebsite(
                accountID: account.id, epoch: epoch, origin: target.origin, documentID: target.documentID, manual: true
            )
        }
        return .filled(count)
    }

    /// The picked code, into the right-clicked field (and its split boxes) only: it is checked as a vault code is, and nothing of it is
    /// recorded, offered for saving or kept.
    private func fill(
        code: String, target: Target, in page: BrowserPage, isCurrent: @escaping @MainActor @Sendable () -> Bool
    ) async -> Outcome {
        guard await field(of: target, in: page) != nil else { return isCurrent() ? .failed(.noField) : .nothing }
        guard isCurrent() else { return .nothing }
        nonisolated(unsafe) let fields: [String: Any] = ["code": code]
        let token = target.token, url = target.frameURL.absoluteString, documentID = target.documentID
        return await deliver({
            guard isCurrent() else { throw ContactAutofillError.changedPage }
            return ["token": token, "url": url, "documentID": documentID, "fields": fields]
        }, target: target, in: page, isCurrent: isCurrent)
    }

    /// `pickFill` in the right-clicked frame, with the arguments `prepare` makes at the engine's dispatch boundary.
    private func deliver(
        _ prepare: @escaping @MainActor @Sendable () throws -> [String: Any], target: Target, in page: BrowserPage,
        isCurrent: @escaping @MainActor @Sendable () -> Bool
    ) async -> Outcome {
        let answer: Any
        do {
            answer = try await page.callAsyncJavaScript(
                "if (globalThis.__wsurfAutofillForms?.documentID !== documentID) return 0; return globalThis.__wsurfPasswords?.pickFill(token, url, fields) ?? 0;",
                in: target.frame, contentWorld: PasswordAutofill.world, prepareArguments: prepare
            )
        } catch {
            return isCurrent() ? .failed(.noField) : .nothing
        }
        let count = (answer as? NSNumber)?.intValue ?? 0
        guard count > 0 else { return count < 0 ? .failed(.unsafeForm) : .failed(.noField) }
        return .filled(count)
    }

    /// The unlocked manager of `vaultID`, only under the unlock `epoch` a list or a sheet was made under.
    static func manager(of context: BrowserProfileContext, vaultID: UUID, epoch: UInt64) -> CredentialManager? {
        guard !context.profile.isPrivate else { return nil }
        return CredentialManager.unlockedManagers(for: context.profile).first { $0.vaultID == vaultID && $0.authorizationEpoch == epoch }
    }

    private static func report(_ failure: Failure, in window: NSWindow) async {
        let alert = NSAlert()
        alert.messageText = String(localized: "Couldn’t Fill Saved Details")
        alert.informativeText = switch failure {
        case .unsafeForm:
            String(localized: "This form sends what you type to another website, so nothing was filled.")
        case .noField:
            String(localized: "Click the field and choose Pick Credential… from the Edit menu or the field’s context menu to try again.")
        }
        await alert.beginSheetModal(for: window)
    }

    // MARK: - The list (pure)

    /// The sheet holds the native field for a code from Messages or Mail only for a field that looks like a code.
    nonisolated static func offersMessagesCode(for field: Field) -> Bool {
        field == .code
    }

    /// A login row for every credential with a username or a password, a code row for every one with a verification code. Cards,
    /// addresses and identities are not offered here. `used` dates only a credential saved for `origin`. Titles and search keys follow
    /// the Credential Manager's rule (`CredentialSummary.naming`), item titles included, from what a list may read of a credential.
    nonisolated static func rows(
        _ accounts: [some AutofillListable], vaultID: UUID, origin: String, vault: String?, used: [UUID: Date] = [:]
    ) -> [Row] {
        accounts.flatMap { account -> [Row] in
            let named = CredentialSummary.naming(account)
            let matches = account.origins.contains(origin) || CredentialAccountSelection.isSibling(account, of: origin)
            let website = account.origins.lazy.compactMap(WebsiteLookalike.displayHost(of:)).first
            func row(_ fill: Row.Fill, _ first: String?) -> Row {
                let parts = [first, website, vault].compactMap { $0 }.filter { !$0.isEmpty && $0 != named.title }
                return Row(
                    id: UUID(), vaultID: vaultID, accountID: account.id, fill: fill, title: named.title,
                    detail: parts.joined(separator: " · "), matchesSite: matches, searchKey: named.searchKey,
                    lastUsed: account.origins.contains(origin) ? used[account.id] : nil
                )
            }
            var rows: [Row] = []
            if account.hasPassword || !account.username.isEmpty {
                rows.append(row(.login, named.username))
            }
            if account.hasTOTP {
                rows.append(row(.code, String(localized: "Verification code")))
            }
            return rows
        }
    }

    /// This website's credentials first, then the others; within each, codes first for a code field and logins first otherwise; then
    /// by title. Above all of them, the code or login (as the field prefers) of the credential used last on this website.
    nonisolated static func ordered(_ rows: [Row], for field: Field) -> [Row] {
        let preferred: Row.Fill = field == .code ? .code : .login
        func rank(_ row: Row) -> Int {
            (row.matchesSite ? 0 : 2) + (row.fill == preferred ? 0 : 1)
        }
        let sorted = rows.enumerated().sorted { left, right in
            let (leftRank, rightRank) = (rank(left.element), rank(right.element))
            if leftRank != rightRank {
                return leftRank < rightRank
            }
            let order = left.element.title.localizedStandardCompare(right.element.title)
            return order == .orderedSame ? left.offset < right.offset : order == .orderedAscending
        }
        .map(\.element)
        return CredentialAccountSelection.lastUsedFirst(sorted) { $0.fill == preferred ? $0.lastUsed : nil }
    }

    /// The rows whose title, username (unless concealed) or website holds `query`, ignoring case and accents.
    nonisolated static func filter(_ rows: [Row], query: String) -> [Row] {
        let needle = CredentialSummary.folded(query.trimmingCharacters(in: .whitespacesAndNewlines))
        return needle.isEmpty ? rows : rows.filter { $0.searchKey.contains(needle) }
    }
}
