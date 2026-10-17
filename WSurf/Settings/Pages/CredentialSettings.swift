// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Account, passkey and verification-code management for one profile's vault. Reached from `AutofillSettings`.
struct CredentialSettings: View {
    @State var model: CredentialSettingsModel
    @State private var anchor = CredentialWindowAnchor()
    @State var showsCreateWarning = false
    @State var showsMigrationConfirmation = false
    @State var showsTrash = false
    @State private var work: Task<Void, Never>?
    @State private var exportContext: CredentialExportContext?

    init(profile: Profile) {
        _model = State(initialValue: CredentialSettingsModel(profile: profile))
    }

    var body: some View {
        // Kept by every state below. On the branching `Group` the modifier applied to each child of the current branch,
        // and the weak anchor kept whichever view updated last, which could be one already removed from the window.
        SettingsPageHeader(title: "Credentials")
            .background(CredentialWindowAnchorView(anchor: anchor))
        scratchWarnings
        Group {
            if let failClosed = model.failClosed {
                failClosedContent(failClosed)
            } else if !model.isAvailable {
                SettingsCard {
                    SettingsEmptyState(
                        symbol: "lock",
                        title: "Credentials are unavailable",
                        caption: "Private Browsing and removed profiles don’t keep a credential vault."
                    )
                }
            } else if model.isLoaded {
                unlockedContent
            } else {
                lockedContent
            }
        }
        .settingsAnchor("autofill.credentials")
        .task(id: model.authorizationEpoch) { await model.load() }
        .task { await model.legacy.refresh() }
        .onDisappear {
            work?.cancel()
            showsCreateWarning = false
            exportContext = nil
            model.cancelImport()
            model.close()
            model.legacy.endSession()
        }
        .sheet(isPresented: Binding(get: { model.draft != nil }, set: { if !$0 { model.cancelEditing() } })) {
            CredentialEditorSheet(model: model)
        }
        .sheet(
            isPresented: Binding(get: { model.importReview != nil }, set: { if !$0 { model.cancelImport() } })
        ) {
            CredentialImportReviewSheet(model: model, run: run)
        }
        .sheet(item: $exportContext) { context in
            CredentialExportSheet(model: model, csv: context.csv) { selection in
                if context.csv {
                    saveCSV(selection, epoch: context.epoch)
                    return
                }
                withWindow { window in
                    let outcome = await model.exportCredentials(
                        selection: selection, epoch: context.epoch, in: window
                    )
                    // Cancelled before any data was passed leaves the sheet for another try; every other result is
                    // reported on the page, so the sheet closes instead of inviting a second export.
                    if let outcome, outcome != .cancelled {
                        exportContext = nil
                    }
                }
            }
        }
        // The sheet's revision and epoch are only meaningful for the authorization it was opened under.
        .onChange(of: model.authorizationEpoch) {
            exportContext = nil
            showsTrash = false
            model.legacy.endSession()
        }
        .legacyRemovalDialog(model: model, run: run)
        .confirmationDialog(
            "Remove Credential?",
            isPresented: Binding(get: { model.pendingRemoval != nil }, set: { if !$0 { model.cancelRemoval() } }),
            presenting: model.pendingRemoval
        ) { pending in
            // The captured value carries the revision and epoch it was presented at; the model rejects a stale one.
            Button("Remove Credential", role: .destructive) {
                run { _ = try await model.confirmRemoval(pending) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { pending in
            Text("Remove “\(pending.summary.title)” and everything saved with it, including passkeys and verification codes?")
        }
        .confirmationDialog(
            "Remove Unlock Passkey?",
            isPresented: Binding(get: { model.pendingUnlockRemoval != nil && !model.isBusy }, set: { _ in }),
            presenting: model.pendingUnlockRemoval
        ) { pending in
            Button("Remove Unlock Passkey", role: .destructive) {
                withWindow { window in await model.confirmUnlockRemoval(pending, in: window) }
            }
            Button("Cancel", role: .cancel) { model.cancelUnlockRemoval() }
        } message: { pending in
            // The model words the request, so the confirmation and what it will do come from one place.
            Text(verbatim: pending.text)
        }
        .confirmationDialog("Upgrade This Vault?", isPresented: $showsMigrationConfirmation) {
            Button("Upgrade and Unlock") {
                withWindow { window in await model.unlock(in: window, confirmMigration: true) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("""
                This vault was saved by an older version of WSurf. Unlocking it upgrades it to a new format that every \
                other WSurf build, including older ones, cannot read. A copy from before the upgrade is kept next to \
                the vault, but it won’t include anything you change afterwards.
                """)
        }
        .sheet(isPresented: $showsCreateWarning) {
            CredentialNewVaultSheet(
                canUseNewPasskey: model.canCreateWithNewPasskey,
                existingPasskeys: model.existingPasskeys
            ) { name, choice in
                showsCreateWarning = false
                withWindow { window in await model.createVault(name: name, choice: choice, in: window) }
            } cancel: {
                showsCreateWarning = false
            }
        }
        .sheet(isPresented: Binding(get: { model.versionsAccountID != nil }, set: { if !$0 { model.closeVersions() } })) {
            CredentialVersionsSheet(model: model, run: run)
        }
    }

    // MARK: Locked

    @ViewBuilder
    private var lockedContent: some View {
        if model.vaults.count > 1 {
            vaultsSection
        }
        SettingsCard {
            VStack(spacing: 12) {
                if model.isBusy {
                    Spinner(size: 22)
                    if model.isVerifying {
                        Text("Verifying your credentials…").font(Theme.Font.row)
                        Text("WSurf is checking the vault before opening it. This can take a moment.")
                            .font(Theme.Font.label)
                            .fixedSize(horizontal: false, vertical: true)
                    } else {
                        Text("Accessing credentials…").font(Theme.Font.row)
                    }
                } else {
                    Image(systemName: "lock")
                        .font(.system(size: 26))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    Text("Credentials are locked").font(Theme.Font.row).fontWeight(.medium)
                    Text(lockedCaption)
                        .font(Theme.Font.label)
                        .fixedSize(horizontal: false, vertical: true)
                    legacyLockedHint
                    if let token = model.pendingImportToken {
                        Text("""
                            Unlock the profile “\(model.profile.name)” to review the credentials another app is \
                            sending to WSurf. Dismiss declines them; to import them later, send them again from the \
                            other app.
                            """)
                            .font(Theme.Font.label)
                            .fixedSize(horizontal: false, vertical: true)
                        SettingsButton(title: "Dismiss Incoming Credentials") { model.discardPendingImport(token: token) }
                    }
                    if model.hasUnconfirmedPasskeys {
                        Text("A passkey was saved here, but WSurf could not confirm that the website received it. Unlock to see which one.")
                            .font(Theme.Font.label)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let message = model.transferMessage {
                        Text(verbatim: message.text).font(Theme.Font.label).fontWeight(.medium).fixedSize(horizontal: false, vertical: true)
                        SettingsButton(title: "Dismiss") { model.dismissTransferMessage() }
                    }
                    if let error = model.error {
                        Text(verbatim: error)
                            .font(Theme.Font.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    lockedAction
                }
            }
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, minHeight: 160)
        }
        // The same entries as the unlocked page, visible but off, so it is clear why nothing can be imported or exported yet.
        SettingsSection(title: "Import & Export", symbol: "arrow.up.arrow.down", footnote: lockedTransferReason) {
            DetailRow(title: "Import passwords from a CSV file") {
                Button("Choose File…") {}.buttonStyle(.bordered).disabled(true)
            }
            RowSeparator()
            DetailRow(title: "Export to another app") {
                Button("Export…") {}.buttonStyle(.bordered).disabled(true)
            }
            RowSeparator()
            DetailRow(title: "Export passwords to a CSV file") {
                Button("Export to CSV…") {}.buttonStyle(.bordered).disabled(true)
            }
        }
    }

    /// Why the Import & Export entries are off while the vault is not open.
    var lockedTransferReason: LocalizedStringResource {
        switch model.vaultExists {
        case .some(true):
            "Unlock the vault to import or export credentials. Nothing is read or saved while it is locked."
        case .some(false):
            "Create a vault first: imports are saved into a vault, and there is nothing to export yet."
        case .none:
            "Import and export wait until WSurf knows whether a credential vault exists."
        }
    }

    var lockedCaption: LocalizedStringResource {
        switch model.vaultExists {
        case .some(true):
            model.needsMigrationConfirmation
                ? "This vault was saved by an older version of WSurf. Unlocking it upgrades it to the new format."
                : "Unlock with a passkey to view and edit your credentials."
        case .some(false):
            "Create a vault protected by a passkey to store passwords, passkeys and verification codes."
        case .none:
            model.error == nil
                ? "WSurf is checking for your credential vault."
                : "WSurf can’t tell whether a credential vault exists, so it won’t offer to create one. Nothing was changed."
        }
    }

    /// The one next step a transfer ending allows. The model decides which; this only draws it. `.exportAgain` means the
    /// other app has to send the import again (the message says so): it is not WSurf's own export, and WSurf has no button
    /// for it.
    @ViewBuilder
    private func nextStep(_ action: CredentialTransferMessage.Action) -> some View {
        switch action {
        case .none, .exportAgain:
            EmptyView()
        case .checkSavedCredentials:
            Button("Check Saved Credentials") {
                showsTrash = false
                model.dismissTransferMessage()
            }
        }
    }

    private func openExport(csv: Bool = false) {
        guard let epoch = model.authorizationEpoch else { return }
        exportContext = CredentialExportContext(epoch: epoch, csv: csv)
    }

    private func importCSV() {
        // The authorization the user was looking at; checked again after the panel, which can stay open past a lock.
        guard let epoch = model.authorizationEpoch else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.message = String(localized: "Choose a password CSV file, such as one exported from Passwords.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run { await model.beginCSVImport(from: url, epoch: epoch) }
    }

    /// The save panel runs only after the user clicked Choose File…, and the vault is read and the selection proved current
    /// only after it returns, so a change made while the panel was open writes nothing. The panel itself asks before replacing a file.
    private func saveCSV(_ selection: [CredentialExportSelection], epoch: UInt64) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = String(localized: "WSurf Passwords.csv")
        panel.message = String(localized: "The file will not be encrypted. Anyone who can open it can read the passwords in it.")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        work?.cancel()
        work = Task {
            guard model.authorizationEpoch == epoch else { return }
            await model.exportCSV(selection: selection, epoch: epoch, to: url)
            exportContext = nil
        }
    }

    private func resultCaption(_ result: CredentialImportOutcome.Result) -> String {
        let action: String = switch result.action {
        case .added:
            String(localized: "Added")
        case .updated:
            String(localized: "Updated")
        case .unchanged:
            String(localized: "Already saved")
        case .skipped:
            String(localized: "Skipped")
        }
        let parts = [action, result.kind.label, result.relyingParty].compactMap { $0 }
        return parts.joined(separator: " · ")
    }

    // MARK: Unlocked

    @ViewBuilder
    private var unlockedContent: some View {
        vaultsSection
        SettingsSection(
            title: "Import & Export",
            symbol: "arrow.up.arrow.down",
            footnote: """
                A CSV file holds passwords with their websites only, and isn’t encrypted: delete it once you have used it. \
                Passkeys and verification codes can only be moved with Export… and the system’s credential exchange.
                """
        ) {
            legacyImportRows
            if let token = model.pendingImportToken {
                DetailRow(
                    verbatimTitle: String(localized: "Credentials from another app"),
                    verbatimCaption: String(localized: """
                        Sent to the profile “\(model.profile.name)”. Nothing is saved until you review and confirm. \
                        Dismiss declines them; to import them later, send them again from the other app.
                        """)
                ) {
                    HStack(spacing: 8) {
                        Button("Review…") { run { await model.beginImport() } }
                        Button("Dismiss") { model.discardPendingImport(token: token) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isBusy)
                }
                RowSeparator()
            }
            DetailRow(title: "Import passwords from a CSV file") {
                Button("Choose File…") { importCSV() }
                    .buttonStyle(.bordered)
                    .disabled(model.isBusy)
            }
            RowSeparator()
            DetailRow(title: "Export to another app") {
                Button("Export…") { openExport() }
                    .buttonStyle(.bordered)
                    .disabled(model.isBusy || model.summaries.isEmpty)
            }
            RowSeparator()
            DetailRow(title: "Export passwords to a CSV file") {
                Button("Export to CSV…") { openExport(csv: true) }
                    .buttonStyle(.bordered)
                    .disabled(model.isBusy || model.summaries.filter(CredentialCSVExport.isExportable).isEmpty)
            }
        }
        if model.hasUnconfirmedPasskeys {
            SettingsSection(
                title: "Passkeys not confirmed with the website",
                symbol: "exclamationmark.triangle",
                footnote: """
                    These passkeys were saved here, but WSurf could not confirm that the website received them. \
                    Test sign-in on the website; remove any passkey that does not work. Dismiss only hides this \
                    notice.
                    """
            ) {
                ForEach(model.unconfirmedPasskeys) { item in
                    DetailRow(verbatimTitle: String(localized: "\(item.userName) on \(item.rpID)")) { EmptyView() }
                }
                DetailRow(title: "Notice") {
                    Button("Dismiss") { model.dismissUnconfirmedPasskeys() }.buttonStyle(.bordered)
                }
            }
        }
        // One ending for a transfer, from the model: its text, the one next step it allows, and (after a saved import) what
        // became of each credential. Dismissing it removes all of it; nothing here repeats it.
        if let message = model.transferMessage {
            SettingsSection(
                title: message.kind == .succeeded ? "Transfer finished" : "Transfer",
                symbol: message.kind == .succeeded ? "checkmark.circle" : "exclamationmark.triangle"
            ) {
                DetailRow(verbatimTitle: message.text) {
                    HStack(spacing: 8) {
                        nextStep(message.action)
                        Button("Dismiss") { model.dismissTransferMessage() }
                    }
                    .buttonStyle(.bordered)
                }
                if message.receipt != nil, let results = model.lastImport?.results {
                    ForEach(results) { result in
                        RowSeparator()
                        DetailRow(verbatimTitle: result.title, verbatimCaption: resultCaption(result)) { EmptyView() }
                    }
                }
            }
        }
        if showsTrash {
            trashSection
        } else {
            SettingsSection(
                title: "Saved credentials",
                symbol: "key",
                footnote: "Passwords, passkeys and verification codes stay hidden until you reveal or copy them.",
                accessory: {
                    HStack(spacing: 10) {
                        listSwitch
                        ToolbarChip(symbol: "plus", label: "Add Credential") {
                            run { try await model.beginEditing(accountID: nil) }
                        }
                        .disabled(model.isBusy)
                        ToolbarChip(symbol: "lock", label: "Lock") { model.lock() }
                    }
                },
                content: {
                    if model.summaries.isEmpty {
                        SettingsEmptyState(symbol: "key", title: "No saved credentials", caption: "Add a login, passkey or verification code to see it here.")
                    }
                    ForEach(model.summaries) { summary in
                        CredentialRow(
                            model: model, summary: summary, run: run,
                            remove: { model.requestRemoval(accountID: summary.id) },
                            versions: { run { try await model.loadVersions(accountID: summary.id) } }
                        )
                    }
                    AutofillPageStatus(isBusy: model.isBusy, error: model.error, kind: .password)
                }
            )
        }
        SettingsSection(
            title: "Unlock passkeys",
            symbol: "person.badge.key",
            footnote: "Any one of these passkeys unlocks the vault. Keep at least one.",
            accessory: {
                ToolbarChip(symbol: "plus", label: "Add Unlock Passkey") {
                    withWindow { window in await model.addUnlock(in: window) }
                }
                .disabled(model.isBusy)
            },
            content: {
                let unlocks = model.unlockCredentials
                ForEach(Array(unlocks.enumerated()), id: \.element.credentialID) { index, unlock in
                    DetailRow(verbatimTitle: String(localized: "Unlock passkey \(index + 1)")) {
                        Button("Remove…", role: .destructive) { model.requestUnlockRemoval(credentialID: unlock.credentialID) }
                            .buttonStyle(.bordered)
                            .disabled(unlocks.count < 2 || model.isBusy)
                            .accessibilityLabel("Remove unlock passkey \(index + 1)")
                    }
                    if index < unlocks.count - 1 {
                        RowSeparator()
                    }
                }
            }
        )
    }

    // MARK: Actions

    /// One cancellable UI task; leaving the page cancels it. A mutation that already committed still returns
    /// its receipt to the model, so cancellation only skips presentation.
    func run(_ operation: @escaping () async throws -> Void) {
        let epoch = model.authorizationEpoch
        work?.cancel()
        work = Task {
            // A lock and re-unlock before this task starts must not hand the queued action the fresh authorization.
            guard model.authorizationEpoch == epoch else { return }
            await model.attempt { try await operation() }
        }
    }

    func withWindow(_ operation: @escaping (NSWindow) async -> Void) {
        guard let window = anchor.window, window.isVisible else {
            model.error = String(localized: "Couldn’t find this window to show the passkey prompt. Bring it to the front and try again.")
            return
        }
        let epoch = model.authorizationEpoch
        work?.cancel()
        work = Task {
            guard model.authorizationEpoch == epoch else { return }
            await operation(window)
        }
    }
}

// MARK: - Row

private struct CredentialRow: View {
    let model: CredentialSettingsModel
    let summary: CredentialSummary
    let run: (@escaping () async throws -> Void) -> Void
    let remove: () -> Void
    let versions: () -> Void

    private var host: String {
        summary.origins.lazy.compactMap { URL(string: $0)?.host }.first ?? summary.title
    }

    /// Secret-free: a concealed username is described, never shown, until revealed.
    private var detail: String {
        var parts: [String] = []
        if summary.usernameIsConcealed {
            parts.append(String(localized: "Username hidden"))
        } else if let username = summary.username {
            parts.append(username)
        }
        if summary.hasPassword { parts.append(String(localized: "Password")) }
        if summary.passkeys.count == 1 {
            parts.append(String(localized: "Passkey"))
        } else if !summary.passkeys.isEmpty {
            parts.append(String(localized: "\(summary.passkeys.count) passkeys"))
        }
        if summary.hasTOTP { parts.append(String(localized: "Verification code")) }
        if summary.hasNotes { parts.append(String(localized: "Notes")) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SiteRow(host: host, summary: detail.isEmpty ? nil : detail) {
                HStack(spacing: 8) {
                    actions
                    Button("Edit…") { run { try await model.beginEditing(accountID: summary.id) } }
                        .disabled(model.isBusy)
                    Button("Remove", role: .destructive, action: remove)
                        .disabled(model.isBusy)
                }
                .buttonStyle(.bordered).fixedSize()
            }
            revealed
        }
    }

    private var actions: some View {
        Menu {
            if summary.hasPassword {
                Button("Copy Password") { run { try await model.copyPassword(accountID: summary.id) } }
                if model.revealedPassword?.accountID == summary.id {
                    Button("Hide Password") { model.hideSecrets() }
                } else {
                    Button("Show Password") { run { try await model.revealPassword(accountID: summary.id) } }
                }
            }
            if summary.usernameIsConcealed {
                if model.revealedUsername?.accountID == summary.id {
                    Button("Hide Username") { model.hideSecrets() }
                } else {
                    Button("Show Username") { run { try await model.revealUsername(accountID: summary.id) } }
                }
            }
            if summary.hasTOTP {
                Button("Copy Verification Code") { run { try await model.copyTOTP(accountID: summary.id) } }
                if model.shownTOTPAccountID == summary.id {
                    Button("Hide Verification Code") { model.hideSecrets() }
                } else {
                    Button("Show Verification Code") { run { try await model.showTOTP(accountID: summary.id) } }
                }
            }
            Button("Earlier Versions…", action: versions)
        } label: {
            Image(systemName: "ellipsis.circle")
                .accessibilityLabel("More actions for \(summary.title)")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    @ViewBuilder
    private var revealed: some View {
        if let username = model.revealedUsername, username.accountID == summary.id {
            revealedLine("Username", value: username.value)
        }
        if let password = model.revealedPassword, password.accountID == summary.id {
            revealedLine("Password", value: password.value)
        }
        if model.shownTOTPAccountID == summary.id {
            // Ticks only while this row shows a code, which only exists while the vault is unlocked.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if let code = model.totpCode(now: context.date.timeIntervalSince1970) {
                    HStack(spacing: 8) {
                        Text("Verification code").foregroundStyle(.secondary)
                        Text(verbatim: code.value)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .privacySensitive()
                        Spacer(minLength: 8)
                        Text("Expires in \(Int(code.remainingSeconds.rounded(.up))) s")
                            .foregroundStyle(.secondary)
                    }
                    .font(Theme.Font.label)
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }

    private func revealedLine(_ title: LocalizedStringResource, value: String) -> some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .privacySensitive()
            Spacer(minLength: 0)
        }
        .font(Theme.Font.label)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Editor

private struct CredentialEditorSheet: View {
    let model: CredentialSettingsModel
    @State private var totpInput = ""
    @State private var totpError: String?
    @State private var isSaving = false
    @State private var saving: Task<Void, Never>?
    @State private var pendingPasskeyRemoval: PasskeySummary?

    var body: some View {
        if let draft = model.draft {
            VStack(alignment: .leading, spacing: 18) {
                Group {
                    if draft.isNew { Text("Add Credential") } else { Text("Edit Credential") }
                }
                .font(.headline)
                Form {
                    TextField("Name", text: optionalText(\.displayName))
                    if draft.usernameIsConcealed {
                        ConcealedUsernameField(username: text(\.username))
                    } else {
                        TextField("Username or email", text: text(\.username))
                    }
                    AutofillPasswordField(password: optionalText(\.password))
                    Button("Generate Strong Password") {
                        do {
                            model.draft?.password = try SavedPassword.generate()
                        } catch {
                            model.error = String(localized: "Couldn’t generate a password.")
                        }
                    }
                    LabeledContent("Websites (one HTTPS address per line)") {
                        WebsiteListField(
                            kind: .websites, label: "Websites (one HTTPS address per line)", lineLimit: 1...4, text: text(\.websites)
                        )
                    }
                    LabeledContent("Other HTTPS origins (one per line)") {
                        WebsiteListField(
                            kind: .extraOrigins, label: "Other HTTPS origins (one per line)", lineLimit: 1...3, text: text(\.extraOrigins)
                        )
                    }
                }
                .textFieldStyle(.roundedBorder)
                totp(draft)
                notes(draft)
                passkeys(draft)
                if let error = model.error {
                    Text(verbatim: error).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { model.error = nil; model.cancelEditing() }
                        .keyboardShortcut(.cancelAction)
                    Button("Save") {
                        isSaving = true
                        saving = Task {
                            await model.attempt { _ = try await model.commitDraft() }
                            isSaving = false
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(isSaving)
                }
            }
            .padding(24)
            .frame(width: 520)
            .onDisappear { totpInput = ""; saving?.cancel() }
            .confirmationDialog(
                "Remove Passkey?",
                isPresented: Binding(
                    get: { pendingPasskeyRemoval != nil },
                    set: { if !$0 { pendingPasskeyRemoval = nil } }
                ),
                presenting: pendingPasskeyRemoval
            ) { passkey in
                Button("Remove Passkey", role: .destructive) {
                    model.draft?.removePasskey(passkey.id)
                    pendingPasskeyRemoval = nil
                }
                Button("Cancel", role: .cancel) { pendingPasskeyRemoval = nil }
            } message: { passkey in
                Text("""
                    Remove passkey \(passkey.id.uuidString) for \(passkey.rpID)?
                    Only this local copy is removed.
                    The website registration and any other exported copies remain. Save to apply.
                    """)
            }
        }
    }

    @ViewBuilder
    private func totp(_ draft: CredentialDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Verification code").font(Theme.Font.rowTitle)
            if let generator = draft.totp {
                HStack {
                    Text(verbatim: [generator.issuer, generator.userName].compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove Verification Code", role: .destructive) { model.draft?.removeTOTP() }
                }
            } else {
                HStack {
                    SecureField("Setup key or otpauth:// link", text: $totpInput).textFieldStyle(.roundedBorder)
                    Button("Set Up") {
                        do {
                            try model.draft?.setUpTOTP(totpInput)
                            totpInput = ""
                            totpError = nil
                        } catch {
                            totpError = String(localized: "Enter a valid setup key or otpauth:// link.")
                        }
                    }
                    .disabled(totpInput.isEmpty)
                }
                if let totpError {
                    Text(verbatim: totpError).foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Notes can hold secrets, so each one is hidden from screen sharing like the other secret fields.
    private func notes(_ draft: CredentialDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notes").font(Theme.Font.rowTitle)
            ForEach(draft.notes.indices, id: \.self) { index in
                HStack(alignment: .top, spacing: 8) {
                    TextEditor(text: noteText(index))
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(height: 80)
                        .background(Theme.Wash.faint, in: RoundedRectangle(cornerRadius: 8))
                        .privacySensitive()
                        .accessibilityLabel("Note \(index + 1)")
                    Button("Remove", role: .destructive) { model.draft?.removeNote(at: index) }
                        .accessibilityLabel("Remove note \(index + 1)")
                }
            }
            Button("Add Note") { model.draft?.addNote() }
        }
    }

    @ViewBuilder
    private func passkeys(_ draft: CredentialDraft) -> some View {
        if !draft.passkeySummaries.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Passkeys").font(Theme.Font.rowTitle)
                ForEach(draft.passkeySummaries) { passkey in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: "\(passkey.rpID) · \(passkey.userName) · \(passkey.id.uuidString)")
                            Text(verbatim: passkeyMetadata(passkey))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove", role: .destructive) { pendingPasskeyRemoval = passkey }
                            .accessibilityLabel("Remove passkey \(passkey.id.uuidString) for \(passkey.rpID)")
                    }
                }
            }
        }
    }

    private func passkeyMetadata(_ passkey: PasskeySummary) -> String {
        let source: String
        switch passkey.source {
        case .some(.created):
            source = String(localized: "Created in WSurf")
        case .some(.imported):
            source = String(localized: "Imported")
        case nil:
            source = String(localized: "Source unknown")
        }
        let created = passkey.createdAt.map { date in
            let timestamp = date.formatted(date: .abbreviated, time: .shortened)
            let relativeAge = date.formatted(.relative(presentation: .named))
            return String(localized: "Created \(timestamp) (\(relativeAge))")
        } ?? String(localized: "Creation date unknown")
        let signed = passkey.lastSignedAt.map {
            String(localized: "Last local signature \($0.formatted(date: .abbreviated, time: .shortened))")
        } ?? String(localized: "No local signature recorded")
        return [source, created, signed].joined(separator: " · ")
    }

    private func noteText(_ index: Int) -> Binding<String> {
        Binding(
            get: { model.draft.flatMap { $0.notes.indices.contains(index) ? $0.notes[index].text : nil } ?? "" },
            set: { text in
                guard model.draft?.notes.indices.contains(index) == true else { return }
                model.draft?.notes[index].text = text
            }
        )
    }

    private func text(_ keyPath: WritableKeyPath<CredentialDraft, String>) -> Binding<String> {
        Binding(get: { model.draft?[keyPath: keyPath] ?? "" }, set: { model.draft?[keyPath: keyPath] = $0 })
    }

    /// An emptied field means "absent", matching how the vault stores optional values.
    private func optionalText(_ keyPath: WritableKeyPath<CredentialDraft, String?>) -> Binding<String> {
        Binding(
            get: { model.draft?[keyPath: keyPath] ?? "" },
            set: { model.draft?[keyPath: keyPath] = $0.isEmpty ? nil : $0 }
        )
    }
}

private struct ConcealedUsernameField: View {
    @Binding var username: String
    @State private var isRevealed = false

    private var toggleLabel: LocalizedStringKey { isRevealed ? "Hide username" : "Show username" }

    var body: some View {
        LabeledContent("Username") {
            HStack(spacing: 6) {
                Group {
                    if isRevealed {
                        TextField("Username", text: $username).autocorrectionDisabled()
                    } else {
                        SecureField("Username", text: $username)
                    }
                }
                .labelsHidden()
                .privacySensitive()
                Button {
                    isRevealed.toggle()
                } label: {
                    Image(systemName: isRevealed ? "eye.slash" : "eye")
                        .frame(width: 24, height: 24)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityLabel(toggleLabel)
                .help(toggleLabel)
            }
        }
        .onDisappear { isRevealed = false }
    }
}

// MARK: - Window anchor

/// The exact window hosting this page, read when a native passkey prompt is requested.
@MainActor
private final class CredentialWindowAnchor {
    weak var view: NSView?
    var window: NSWindow? {
        view?.window
    }
}

private struct CredentialWindowAnchorView: NSViewRepresentable {
    let anchor: CredentialWindowAnchor

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        anchor.view = view
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        anchor.view = view
    }
}
