// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import WSurfVault

/// "Pick Credential…" in a page's context menu, for when the automatic offer does not open: the person picks a saved login or
/// verification code from the unlocked vaults and it fills the field they right-clicked.
///
/// - The field is the one the frame's own script saw a trusted contextmenu event on (`noteContext`), in the frame the engine says
///   the event came from. The fill goes to that frame only, to that field and its partner only (`__wsurfPasswords.pickFill`).
/// - The picker lists titles and websites only. A secret is read after the choice, under the unlock and revision it was listed
///   under, and the code or password is made at the engine's dispatch boundary, as `AutofillSuggestions` does.
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

    /// Tests answer the picker without a sheet, keyed by profile like `VaultChoicePrompt.answersForTesting`.
    static var answersForTesting: [UUID: @MainActor ([Row]) async -> Answer?] = [:]

    private var targets: [ObjectIdentifier: Target] = [:]
    /// Pages whose pick is under way: a second menu command for the same page waits for the first to end.
    private var picking: Set<ObjectIdentifier> = []

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

    /// A trusted right-click as the frame's script reported it: an editable text field with a fresh token, or nothing (which
    /// forgets the page's earlier one, so a menu never fills a field from an older right-click).
    func noteContext(_ message: BrowserScriptMessage) {
        let page = message.page
        targets = targets.filter { $0.value.page != nil }
        let frame = message.frameInfo
        guard let body = message.body as? [String: Any],
              let token = body["token"] as? String, UUID(uuidString: token) != nil,
              let documentID = body["documentID"] as? String, UUID(uuidString: documentID) != nil,
              let field = (body["field"] as? String).flatMap(Field.init(rawValue:)),
              let raw = body["url"] as? String, let frameURL = URL(string: raw),
              let origin = CredentialAccountSelection.origin(for: frameURL), frame.autofillOrigin(reportedURL: frameURL) == origin else {
            targets[ObjectIdentifier(page)] = nil
            return
        }
        targets[ObjectIdentifier(page)] = Target(
            page: page, context: page.context, frame: frame, token: token, documentID: documentID, frameURL: frameURL, origin: origin,
            field: field, received: .now
        )
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

    /// Chromium names the right-clicked frame by its own id, which need not be the DevTools id the script's frame carries. The URL
    /// then names it only while no other live frame of the page, cross-site frames included, has that URL, the rule of
    /// `ChromiumPage.frame(id:requestURL:isMainFrame:)`.
    private static func isNamedFrame(_ target: Target, by menu: Menu, in page: BrowserPage) async -> Bool {
        guard let named = menu.chromiumFrame, target.frame.chromiumID != named.id else { return true }
        guard let chromium = page.chromium, let live = try? await chromium.devTools.framesIncludingCrossSiteFrames() else { return false }
        return live.filter { $0.isMainFrame == named.isMain && $0.request.url == named.url }.count == 1
    }

    /// Unlock if every vault is locked, list, let the person choose, fill. Every suspension is followed by the same check: the page,
    /// its window, its profile and the right-click are still the ones it started from, and the policy still offers the picker.
    func run(
        _ target: Target, in page: BrowserPage, window: NSWindow, allowed: @escaping @MainActor @Sendable () -> Bool
    ) async -> Outcome {
        let context = target.context, profile = context.profile, key = ObjectIdentifier(page), token = target.token
        let isCurrent: @MainActor @Sendable () -> Bool = { [weak self, weak page, weak window] in
            guard let self, let page, let window else { return false }
            return page.context === context && self.targets[key]?.token == token && page.window === window
                && Self.isOffered(in: page, allowedByTab: allowed())
        }
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
            case nil:
                return .nothing
            }
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

    /// Every unlocked vault of the profile, in ordinal order, each under its own unlock. A locked vault is never read. A profile with
    /// no vault (or a store that cannot be read) lists nothing, and the sheet says so.
    private func read(for target: Target) async -> Reading? {
        let profile = target.context.profile
        guard !profile.isPrivate else { return nil }
        let listing = (try? await CredentialManager.store(for: profile).listing()) ?? []
        let unlocked = CredentialManager.unlockedManagers(for: profile)
        let lastUsed = target.context.autofillLastUsed
        var reading = Reading()
        for vault in listing.sorted(by: { $0.ordinal < $1.ordinal }) {
            guard let manager = unlocked.first(where: { $0.vaultID == vault.vaultID }), let epoch = manager.authorizationEpoch,
                  let snapshot = try? await manager.snapshot(), manager.authorizationEpoch == epoch else {
                reading.hasLockedVault = true
                continue
            }
            reading.grants[vault.vaultID] = (epoch, snapshot.revision)
            var used: [UUID: Date] = [:]
            for account in snapshot.accounts where account.origins.contains(target.origin) {
                used[account.id] = lastUsed.date(vault: vault.vaultID, account: account.id, origin: target.origin)
            }
            reading.rows += Self.rows(
                snapshot.accounts, vaultID: vault.vaultID, origin: target.origin, vault: listing.count > 1 ? vault.label : nil, used: used
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
            rows: reading.rows, host: host, canUnlock: reading.hasLockedVault, profileID: target.context.profile.id, in: window
        )
    }

    /// The chosen credential is read again under the unlock and revision it was listed under, and delivered into the right-clicked
    /// field's frame only. The password, username or fresh code exists only in the closure the engine runs at its dispatch boundary.
    private func fill(
        _ id: UUID, reading: Reading, target: Target, in page: BrowserPage, isCurrent: @escaping @MainActor @Sendable () -> Bool
    ) async -> Outcome {
        let context = target.context
        guard let row = reading.rows.first(where: { $0.id == id }), let grant = reading.grants[row.vaultID],
              let manager = Self.manager(of: context, vaultID: row.vaultID, epoch: grant.epoch),
              let generation = manager.stableGeneration, let snapshot = try? await manager.snapshot() else { return .failed(.noField) }
        guard isCurrent() else { return .nothing }
        guard manager.authorizationEpoch == grant.epoch, manager.stableGeneration == generation, snapshot.revision == grant.revision,
              let account = snapshot.accounts.first(where: { $0.id == row.accountID }) else { return .failed(.noField) }
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
                guard let generator = account.totp, let code = try? TOTP.code(generator, at: Date.now.timeIntervalSince1970).value else {
                    throw ContactAutofillError.noField
                }
                fields = ["code": code]
            case .login:
                fields = ["username": account.username]
                if let password = account.password {
                    fields["password"] = password
                }
            }
            return ["token": token, "url": url, "documentID": documentID, "fields": fields]
        }
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
        guard isCurrent() else { return .filled(count) }
        let session = AutofillSaveCoordinator.shared.session(for: page)
        if account.origins.contains(target.origin) {
            target.context.autofillLastUsed.record(vault: vaultID, account: account.id, origin: target.origin)
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

    private static func manager(of context: BrowserProfileContext, vaultID: UUID, epoch: UInt64) -> CredentialManager? {
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
            String(localized: "Right-click the field and choose Pick Credential… to try again.")
        }
        await alert.beginSheetModal(for: window)
    }

    // MARK: - The list (pure)

    /// A login row for every credential with a username or a password, a code row for every one with a verification code. Cards,
    /// addresses and identities are not offered here. `used` dates only a credential saved for `origin`.
    nonisolated static func rows(
        _ accounts: [CredentialAccount], vaultID: UUID, origin: String, vault: String?, used: [UUID: Date] = [:]
    ) -> [Row] {
        accounts.flatMap { account -> [Row] in
            let summary = CredentialSummary(account)
            let matches = account.origins.contains(origin) || CredentialAccountSelection.isSibling(account, of: origin)
            let website = account.origins.lazy.compactMap(WebsiteLookalike.displayHost(of:)).first
            func row(_ fill: Row.Fill, _ first: String?) -> Row {
                let parts = [first, website, vault].compactMap { $0 }.filter { !$0.isEmpty && $0 != summary.title }
                return Row(
                    id: UUID(), vaultID: vaultID, accountID: account.id, fill: fill, title: summary.title,
                    detail: parts.joined(separator: " · "), matchesSite: matches, searchKey: summary.searchKey,
                    lastUsed: account.origins.contains(origin) ? used[account.id] : nil
                )
            }
            var rows: [Row] = []
            if account.password != nil || !account.username.isEmpty {
                rows.append(row(.login, summary.username))
            }
            if account.totp != nil {
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
