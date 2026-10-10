// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

/// Account, passkey and verification-code management for one profile's vault. Reached from `AutofillSettings`
/// as its own entry, separate from the legacy Passwords page.
struct CredentialSettings: View {
    @State private var model: CredentialSettingsModel
    @State private var anchor = CredentialWindowAnchor()
    @State private var showsCreateWarning = false
    @State private var work: Task<Void, Never>?
    @State private var exportContext: CredentialExportContext?

    init(profile: Profile) {
        _model = State(initialValue: CredentialSettingsModel(profile: profile))
    }

    var body: some View {
        SettingsPageHeader(title: "Credentials")
        Group {
            if !model.isAvailable {
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
        .background(CredentialWindowAnchorView(anchor: anchor))
        .task(id: model.authorizationEpoch) { await model.load() }
        .onDisappear {
            work?.cancel()
            showsCreateWarning = false
            exportContext = nil
            model.cancelImport()
            model.close()
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
            CredentialExportSheet(model: model, context: context) { selection in
                withWindow { window in
                    let outcome = await model.exportCredentials(
                        selection: selection, expectedRevision: context.revision, epoch: context.epoch, in: window
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
        .onChange(of: model.authorizationEpoch) { exportContext = nil }
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
            isPresented: Binding(get: { model.pendingUnlockRemoval != nil }, set: { if !$0 { model.cancelUnlockRemoval() } }),
            presenting: model.pendingUnlockRemoval
        ) { pending in
            Button("Remove Unlock Passkey", role: .destructive) {
                withWindow { window in await model.confirmUnlockRemoval(pending, in: window) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("""
                You’ll confirm with one of the remaining unlock passkeys. The passkey itself stays in your passkey \
                provider. Removing it does not change the vault’s encryption key. Someone with that passkey and an \
                older vault file can still decrypt later copies of this vault they obtain.
                """)
        }
        .confirmationDialog("Create Credential Vault?", isPresented: $showsCreateWarning) {
            Button("Create Vault") {
                withWindow { window in await model.createVault(in: window) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("""
                The vault is encrypted with your unlock passkeys. If you lose every unlock passkey, WSurf cannot \
                recover the vault or anything stored in it, and there is no recovery option. Removing an unlock \
                passkey does not change the vault’s encryption key. Someone with that passkey and an older vault \
                file can still decrypt later copies of this vault they obtain. Deleting the vault does not delete \
                backups.
                """)
        }
    }

    // MARK: Locked

    @ViewBuilder
    private var lockedContent: some View {
        SettingsCard {
            VStack(spacing: 12) {
                if model.isBusy {
                    Spinner(size: 22)
                    Text("Accessing credentials…").font(Theme.Font.row)
                } else {
                    Image(systemName: "lock")
                        .font(.system(size: 26))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                    Text("Credentials are locked").font(Theme.Font.row).fontWeight(.medium)
                    Text(lockedCaption)
                        .font(Theme.Font.label)
                        .fixedSize(horizontal: false, vertical: true)
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
                    if let export = model.lastExport {
                        let status = exportStatus(export)
                        Text(status.title).font(Theme.Font.label).fontWeight(.medium)
                        Text(status.note)
                            .font(Theme.Font.label)
                            .fixedSize(horizontal: false, vertical: true)
                        SettingsButton(title: "Dismiss Export Status") { model.dismissExportResult() }
                    }
                    if let error = model.error {
                        Text(verbatim: error)
                            .font(Theme.Font.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    switch model.vaultExists {
                    case .some(true):
                        SettingsButton(title: "Unlock Credentials", isProminent: true) {
                            withWindow { window in await model.unlock(in: window) }
                        }
                    case .some(false):
                        SettingsButton(title: "Create Credential Vault", isProminent: true) {
                            showsCreateWarning = true
                        }
                    case .none:
                        SettingsButton(title: "Try Again") { run { await model.load() } }
                    }
                }
            }
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.vertical, 24)
            .frame(maxWidth: .infinity, minHeight: 160)
        }
    }

    private var lockedCaption: LocalizedStringResource {
        switch model.vaultExists {
        case .some(true):
            "Unlock with a passkey to view and edit your credentials."
        case .some(false):
            "Create a vault protected by a passkey to store passwords, passkeys and verification codes."
        case .none:
            "WSurf is checking for your credential vault."
        }
    }

    /// Neutral and secret-free. The system reports no receipt, so neither case claims the other app accepted anything.
    private func exportStatus(
        _ outcome: CredentialExportOutcome
    ) -> (title: LocalizedStringResource, note: LocalizedStringResource, symbol: String) {
        if outcome == .transferred {
            return (
                "The system accepted the export",
                "WSurf can’t see whether the other app has received or imported anything.",
                "checkmark.circle"
            )
        }
        return (
            "The export may not have completed",
            "The system stopped after your selection was passed to it, so it may or may not have reached the other app. Check there before exporting again. WSurf didn’t retry.",
            "exclamationmark.triangle"
        )
    }

    // MARK: Unlocked

    @ViewBuilder
    private var unlockedContent: some View {
        if let token = model.pendingImportToken {
            SettingsSection(
                title: "Credentials waiting to import",
                symbol: "square.and.arrow.down",
                footnote: """
                    Another app is sending credentials to the profile “\(model.profile.name)”. Nothing is saved \
                    until you review and confirm. Dismiss declines them; to import them later, send them again \
                    from the other app.
                    """
            ) {
                DetailRow(title: "Credentials from another app") {
                    HStack(spacing: 8) {
                        Button("Review…") { run { await model.beginImport() } }
                        Button("Dismiss") { model.discardPendingImport(token: token) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(model.isBusy)
                }
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
        if let result = model.lastImport {
            SettingsSection(title: "Import complete", symbol: "checkmark.circle") {
                DetailRow(verbatimTitle: String(localized: "Added \(result.added), updated \(result.updated)")) {
                    Button("Dismiss") { model.dismissImportResult() }.buttonStyle(.bordered)
                }
            }
        }
        if let export = model.lastExport {
            let status = exportStatus(export)
            SettingsSection(title: "Last export", symbol: status.symbol, footnote: status.note) {
                DetailRow(title: status.title) {
                    Button("Dismiss") { model.dismissExportResult() }.buttonStyle(.bordered)
                }
            }
        }
        SettingsSection(
            title: "Saved credentials",
            symbol: "key",
            footnote: "Passwords, passkeys and verification codes stay hidden until you reveal or copy them.",
            accessory: {
                HStack(spacing: 10) {
                    ToolbarChip(symbol: "plus", label: "Add Credential") {
                        run { try await model.beginEditing(accountID: nil) }
                    }
                    .disabled(model.isBusy)
                    ToolbarChip(symbol: "square.and.arrow.up", label: "Export…") {
                        guard let epoch = model.authorizationEpoch else { return }
                        exportContext = CredentialExportContext(revision: model.revision, epoch: epoch, summaries: model.summaries)
                    }
                    .disabled(model.isBusy || model.summaries.isEmpty)
                    ToolbarChip(symbol: "lock", label: "Lock") { model.lock() }
                }
            },
            content: {
                if model.summaries.isEmpty {
                    SettingsEmptyState(symbol: "key", title: "No saved credentials", caption: "Add a login, passkey or verification code to see it here.")
                }
                ForEach(model.summaries) { summary in
                    CredentialRow(model: model, summary: summary, run: run, remove: { model.requestRemoval(accountID: summary.id) })
                }
                AutofillPageStatus(isBusy: model.isBusy, error: model.error, kind: .password)
            }
        )
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
    private func run(_ operation: @escaping () async throws -> Void) {
        let epoch = model.authorizationEpoch
        work?.cancel()
        work = Task {
            // A lock and re-unlock before this task starts must not hand the queued action the fresh authorization.
            guard model.authorizationEpoch == epoch else { return }
            await model.attempt { try await operation() }
        }
    }

    private func withWindow(_ operation: @escaping (NSWindow) async -> Void) {
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
        } label: {
            Image(systemName: "ellipsis.circle")
                .accessibilityLabel("More actions for \(summary.title)")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(!summary.hasPassword && !summary.hasTOTP && !summary.usernameIsConcealed)
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
                    TextField("Websites (one HTTPS address per line)", text: text(\.websites), axis: .vertical)
                        .lineLimit(1...4)
                    TextField("Other HTTPS origins (one per line)", text: text(\.extraOrigins), axis: .vertical)
                        .lineLimit(1...3)
                }
                .textFieldStyle(.roundedBorder)
                totp(draft)
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
                Text("Remove passkey #\(passkey.shortID) for \(passkey.rpID) from this credential? Save to apply this change.")
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

    @ViewBuilder
    private func passkeys(_ draft: CredentialDraft) -> some View {
        if !draft.passkeySummaries.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Passkeys").font(Theme.Font.rowTitle)
                ForEach(draft.passkeySummaries) { passkey in
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: "\(passkey.rpID) · \(passkey.userName) · #\(passkey.shortID)")
                            Text(verbatim: passkeyMetadata(passkey))
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove", role: .destructive) { pendingPasskeyRemoval = passkey }
                            .accessibilityLabel("Remove passkey #\(passkey.shortID) for \(passkey.rpID)")
                    }
                }
            }
        }
    }

    private func passkeyMetadata(_ passkey: PasskeySummary) -> String {
        let source: String
        switch passkey.source {
        case .some(.created):
            source = String(localized: "Created here")
        case .some(.imported):
            source = String(localized: "Imported")
        case nil:
            source = String(localized: "Source unknown")
        }
        let created = passkey.createdAt.map {
            String(localized: "Created \($0.formatted(date: .abbreviated, time: .shortened))")
        } ?? String(localized: "Creation date unknown")
        let signed = passkey.lastSignedAt.map {
            String(localized: "Last signed \($0.formatted(date: .abbreviated, time: .shortened))")
        } ?? String(localized: "No local signature recorded")
        return [source, created, signed].joined(separator: " · ")
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

// MARK: - Exchange

/// What the export sheet was opened for. The revision and epoch travel with the selection, so a lock, re-unlock or
/// later write makes the export fail instead of sending a different vault state than the user chose from.
private struct CredentialExportContext: Identifiable {
    let id = UUID()
    let revision: UInt64
    let epoch: UInt64
    let summaries: [CredentialSummary]
}

private struct CredentialExportSheet: View {
    let model: CredentialSettingsModel
    let context: CredentialExportContext
    let export: ([CredentialExportSelection]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selection: [UUID: CredentialExportSelection] = [:]

    private var chosen: [CredentialExportSelection] {
        context.summaries.compactMap { selection[$0.id] }.filter { $0.password || $0.totp || !$0.passkeyIDs.isEmpty }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Export Credentials").font(.headline)
            Text("""
                Choose what to send to another app. The system passes your selection to the app you pick next, and \
                that app can read it: any passwords, passkeys and verification code setups you select aren’t \
                encrypted by WSurf. WSurf doesn’t write a file, and your vault keeps its own copy.
                """)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(context.summaries) { summary in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: summary.title).font(Theme.Font.rowTitle)
                            if summary.hasLogin {
                                Toggle("Login", isOn: binding(summary.id, \.password))
                            }
                            ForEach(summary.passkeys) { passkey in
                                Toggle(isOn: passkeyBinding(summary.id, passkey.id)) {
                                    Text(verbatim: "\(String(localized: "Passkey")) · \(passkey.rpID) · \(passkey.userName)")
                                }
                            }
                            if summary.hasTOTP {
                                Toggle("Verification code setup", isOn: binding(summary.id, \.totp))
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 320)
            if let error = model.error {
                Text(verbatim: error).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { model.error = nil; dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Export…") { export(chosen) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(chosen.isEmpty || model.isBusy)
            }
        }
        .padding(24)
        .frame(width: 520)
    }

    private func update(_ accountID: UUID, _ change: (inout CredentialExportSelection) -> Void) {
        var current = selection[accountID]
            ?? CredentialExportSelection(accountID: accountID, password: false, passkeyIDs: [], totp: false)
        change(&current)
        selection[accountID] = current
    }

    private func binding(_ accountID: UUID, _ keyPath: WritableKeyPath<CredentialExportSelection, Bool>) -> Binding<Bool> {
        Binding(
            get: { selection[accountID]?[keyPath: keyPath] ?? false },
            set: { value in update(accountID) { $0[keyPath: keyPath] = value } }
        )
    }

    private func passkeyBinding(_ accountID: UUID, _ passkeyID: UUID) -> Binding<Bool> {
        Binding(
            get: { selection[accountID]?.passkeyIDs.contains(passkeyID) ?? false },
            set: { on in
                update(accountID) {
                    if on {
                        $0.passkeyIDs.insert(passkeyID)
                    } else {
                        $0.passkeyIDs.remove(passkeyID)
                    }
                }
            }
        )
    }
}

private struct CredentialImportReviewSheet: View {
    let model: CredentialSettingsModel
    let run: (@escaping () async throws -> Void) -> Void

    var body: some View {
        if let review = model.importReview {
            VStack(alignment: .leading, spacing: 18) {
                Text("Review Import").font(.headline)
                Text("""
                    Importing into the profile “\(model.profile.name)”. Nothing is saved until you choose Import. \
                    Imported passwords, passkeys and verification codes are encrypted in that profile’s vault.
                    """)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(review.candidates) { candidate in candidateView(candidate) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 360)
                if let outcome = review.outcome {
                    Text("Adds \(outcome.added) and updates \(outcome.updated).").foregroundStyle(.secondary)
                } else {
                    Text("Choose what to do with each credential that already exists here.").foregroundStyle(.secondary)
                }
                if let error = model.error {
                    Text(verbatim: error).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button("Cancel", role: .cancel) { model.error = nil; model.cancelImport() }
                        .keyboardShortcut(.cancelAction)
                    Button("Import") { run { await model.commitImport() } }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!review.isResolved || (review.outcome.map { $0.added + $0.updated } ?? 0) == 0 || model.isBusy)
                }
            }
            .padding(24)
            .frame(width: 520)
        }
    }

    @ViewBuilder
    private func candidateView(_ candidate: CredentialImportReview.Candidate) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(verbatim: candidate.summary.title).font(Theme.Font.rowTitle)
            if !candidate.summary.origins.isEmpty {
                Text("The other app sent websites: \(candidate.summary.origins.joined(separator: ", "))")
                    .font(Theme.Font.label)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if candidate.needsManualAssociation {
                Text("The other app sent no website for this.")
                    .font(Theme.Font.label)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(candidate.records) { record in recordView(record) }
        }
    }

    private func recordView(_ record: CredentialImportReview.Record) -> some View {
        let targets = model.mergeTargets(for: record.incoming)
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: "\(kindLabel(record.kind)) · \(record.title)")
                    if let existing = record.existingTitle {
                        Text("Already saved as “\(existing)”").font(Theme.Font.label).foregroundStyle(.secondary)
                        if record.removesStoredPasswordOnReplace {
                            Text("Replace Saved removes the password saved for “\(existing)”. The other app’s login has none.")
                                .font(Theme.Font.label)
                                .foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Spacer(minLength: 8)
                Menu {
                    Button("Skip") { model.chooseImport(.skip, for: record.incoming) }
                    if record.isConflict {
                        Button("Replace Saved") { model.chooseImport(.replace, for: record.incoming) }
                    }
                    if record.canAddSeparately {
                        Button("Add Separately") { model.chooseImport(.addSeparately, for: record.incoming) }
                    }
                    if !targets.isEmpty {
                        Menu("Merge Into…") {
                            ForEach(targets) { target in
                                Button(mergeMenuTitle(target, kind: record.kind)) {
                                    model.chooseImport(.merge(into: target.accountID), for: record.incoming)
                                }
                            }
                        }
                    }
                } label: {
                    Text(choiceLabel(record))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            if let line = destinationLine(record) {
                Text(verbatim: line)
                    .font(Theme.Font.label)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A passkey keeps the website it was created for, so the target's websites don't describe it. Any other
    /// credential inherits them, and a target with none is said to have none rather than shown blank.
    private func mergeMenuTitle(_ target: CredentialImportReview.Target, kind: CredentialImportReview.Record.Kind) -> String {
        guard kind != .passkey else { return target.title }
        if target.allowedOrigins.isEmpty { return "\(target.title) — \(String(localized: "no approved website"))" }
        return "\(target.title) — \(target.allowedOrigins.joined(separator: ", "))"
    }

    /// Where the record will be saved and which websites it will work on, as the import itself will do it. A stored
    /// account keeps exactly its own websites; the other app's are only ever listed here to say they are not added.
    private func destinationLine(_ record: CredentialImportReview.Record) -> String? {
        guard let destination = record.destination else { return nil }
        let relyingParty = record.relyingParty ?? ""
        switch destination {
        case .skipped:
            return String(localized: "Won’t be imported.")
        case let .newAccount(origins):
            if record.kind == .passkey {
                return String(localized: "Saved as a new account. The passkey stays tied to \(relyingParty).")
            }
            if origins.isEmpty {
                return String(localized: "Saved as a new account with no approved website, so autofill won’t offer it until you add one.")
            }
            return String(localized: "Saved as a new account that works on \(origins.joined(separator: ", ")).")
        case let .existing(_, title, origins, ignored):
            if record.kind == .passkey {
                return String(localized: "Saved with “\(title)”. The passkey stays tied to \(relyingParty).")
            }
            var line = origins.isEmpty
                ? String(localized: "Saved into “\(title)”, which has no approved website, so autofill won’t offer it until you add one.")
                : String(localized: "Saved into “\(title)”, which works on \(origins.joined(separator: ", ")).")
            if !ignored.isEmpty {
                line += " " + String(localized: "The other app’s websites aren’t added: \(ignored.joined(separator: ", ")).")
            }
            return line
        }
    }

    private func kindLabel(_ kind: CredentialImportReview.Record.Kind) -> String {
        switch kind {
        case .password:
            String(localized: "Login")
        case .passkey:
            String(localized: "Passkey")
        case .totp:
            String(localized: "Verification code")
        }
    }

    private func choiceLabel(_ record: CredentialImportReview.Record) -> LocalizedStringResource {
        switch record.choice {
        case nil:
            record.isConflict ? "Choose…" : "Import"
        case .skip:
            "Skip"
        case .replace:
            "Replace Saved"
        case .addSeparately:
            "Add Separately"
        case .merge:
            "Merge"
        }
    }
}
