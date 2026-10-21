// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

// MARK: - Merge sheet

/// Reviews merging two or more credentials into one. It shows what the merge keeps and what it leaves out before anything is
/// written, and it writes nothing until the user confirms. Every value shown is a title, a username the credential does not conceal, a
/// website or a count; a password is shown only after "Show Password", through the same reveal as the list.
struct CredentialMergeSheet: View {
    let model: CredentialSettingsModel
    let ids: [UUID]
    /// Leaves the sheet; `true` when the merge was written.
    let close: (Bool) -> Void
    @State private var proposal: CredentialMergeProposal?
    @State private var message: String?
    @State private var isWorking = false
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Merge Credentials").font(.headline)
            if let proposal {
                ScrollView {
                    content(proposal)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 440)
            } else if message == nil {
                HStack(spacing: 8) {
                    Spinner(size: 16)
                    Text("Reading credentials…").foregroundStyle(.secondary)
                }
            }
            if let message {
                Text(verbatim: message).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { close(false) }
                    .keyboardShortcut(.cancelAction)
                Button("Merge…") { confirming = true }
                    .keyboardShortcut(.defaultAction)
                    .disabled(proposal == nil || isWorking)
            }
        }
        .padding(24)
        .frame(width: 580)
        .task { await reload() }
        .onDisappear { model.hideSecrets() }
        .confirmationDialog("Merge Credentials?", isPresented: $confirming, presenting: proposal) { proposal in
            Button("Merge") { merge(proposal) }
            Button("Cancel", role: .cancel) {}
        } message: { proposal in
            Text(verbatim: consequence(of: proposal))
        }
    }

    // MARK: Content

    @ViewBuilder
    private func content(_ proposal: CredentialMergeProposal) -> some View {
        let preview = proposal.preview
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Picker(
                    "Primary",
                    selection: Binding(get: { proposal.picks.survivor }, set: { id in Task { await reload(survivor: id) } })
                ) {
                    ForEach(preview.items) { item in
                        Text(verbatim: label(of: item)).tag(item.id)
                    }
                }
                .pickerStyle(.menu)
                Text("""
                    The primary credential’s name, username, password, verification code and notes win. The other passwords and \
                    codes stay in its History, and every passkey, note, item and website is kept.
                    """)
                    .font(Theme.Font.label)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            credentials(preview)
            websites(proposal)
            alsoKept(preview)
        }
    }

    private func credentials(_ preview: MergePreview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Credentials").font(Theme.Font.rowTitle)
            ForEach(preview.items) { item in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(verbatim: item.title).font(Theme.Font.row)
                        Spacer(minLength: 8)
                        if item.hasPassword {
                            passwordToggle(item)
                        }
                    }
                    Text(verbatim: detail(of: item)).font(Theme.Font.label).foregroundStyle(.secondary)
                    if let revealed = model.revealedPassword, revealed.accountID == item.id {
                        Text(verbatim: revealed.value)
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                            .privacySensitive()
                    }
                }
                .accessibilityElement(children: .contain)
            }
        }
    }

    private func passwordToggle(_ item: MergePreview.Item) -> some View {
        let isShown = model.revealedPassword?.accountID == item.id
        return Button(isShown ? "Hide Password" : "Show Password") {
            if isShown {
                model.hideSecrets()
            } else {
                Task {
                    do {
                        try await model.revealPassword(accountID: item.id)
                    } catch {
                        message = CredentialSettingsModel.mergeMessage(for: error)
                    }
                }
            }
        }
        .controlSize(.small)
        .accessibilityLabel(
            isShown ? String(localized: "Hide password of \(item.title)") : String(localized: "Show password of \(item.title)")
        )
    }

    private func websites(_ proposal: CredentialMergeProposal) -> some View {
        let preview = proposal.preview
        return VStack(alignment: .leading, spacing: 6) {
            Text("Websites").font(Theme.Font.rowTitle)
            Text("Before: \(hosts(preview.websitesBefore))").font(Theme.Font.label).foregroundStyle(.secondary)
            Text("After: \(hosts(preview.websitesAfter))").font(Theme.Font.label).foregroundStyle(.secondary)
            if !preview.otherSite.isEmpty {
                Text("Also fill on").font(Theme.Font.label).fontWeight(.medium).padding(.top, 4)
                ForEach(preview.otherSite, id: \.self) { origin in
                    Toggle(isOn: ticked(origin, in: proposal)) {
                        Text(verbatim: URL(string: origin)?.host ?? origin)
                    }
                }
                Text("These websites are on other sites. The merged password and verification code fill on one only if you tick it.")
                    .font(Theme.Font.label)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(preview.notKept, id: \.self) { host in
                Text("\(host) won’t be kept: the merged credential won’t fill there.")
                    .font(Theme.Font.label)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !preview.fillsOn.isEmpty {
                Text("The password will fill on: \(list(preview.fillsOn))")
                    .font(Theme.Font.label)
                    .fontWeight(.medium)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func alsoKept(_ preview: MergePreview) -> some View {
        if preview.passkeysAfter > 0 || preview.notesAfter > 0 || preview.itemsAfter > 0 || preview.passwordsInHistory > 0
            || preview.codesInHistory > 0 {
            VStack(alignment: .leading, spacing: 4) {
                Text("Also kept").font(Theme.Font.rowTitle)
                Group {
                    if preview.passkeysAfter > 0 {
                        Text("Passkeys: \(preview.passkeysBefore) → \(preview.passkeysAfter)")
                    }
                    if preview.notesAfter > 0 {
                        Text("Notes: \(preview.notesBefore) → \(preview.notesAfter)")
                    }
                    if preview.itemsAfter > 0 {
                        Text("Cards and other items: \(preview.itemsBefore) → \(preview.itemsAfter)")
                    }
                    if preview.passwordsInHistory > 0 {
                        Text("Other passwords kept in History: \(preview.passwordsInHistory)")
                    }
                    if preview.codesInHistory > 0 {
                        Text("Other verification codes kept in History: \(preview.codesInHistory)")
                    }
                }
                .font(Theme.Font.label)
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Wording

    private func label(of item: MergePreview.Item) -> String {
        guard let username = item.username else { return item.title }
        return "\(item.title) — \(username)"
    }

    private func detail(of item: MergePreview.Item) -> String {
        var parts: [String] = []
        if item.usernameIsConcealed {
            parts.append(String(localized: "Username hidden"))
        } else if let username = item.username {
            parts.append(username)
        }
        if item.hasPassword {
            parts.append(String(localized: "Password"))
        }
        if item.passkeyCount == 1 {
            parts.append(String(localized: "Passkey"))
        } else if item.passkeyCount > 1 {
            parts.append(String(localized: "\(item.passkeyCount) passkeys"))
        }
        if item.hasCode {
            parts.append(String(localized: "Verification code"))
        }
        if item.noteCount > 0 {
            parts.append(String(localized: "Notes"))
        }
        if let host = item.origins.lazy.compactMap({ URL(string: $0)?.host }).first {
            parts.append(host)
        }
        let dates = item.dates.caption(style: .list)
        if !dates.isEmpty {
            parts.append(dates)
        }
        return parts.joined(separator: " · ")
    }

    private func hosts(_ origins: [String]) -> String {
        let names = origins.compactMap { URL(string: $0)?.host }
        return names.isEmpty ? String(localized: "No website") : list(names)
    }

    private func list(_ values: [String]) -> String {
        ListFormatter.localizedString(byJoining: values)
    }

    /// What confirming does, before the details: who moves to the Trash and what that blocks. The merged credential stands for the
    /// others in later imports, so they can't come back beside it.
    private func consequence(of proposal: CredentialMergeProposal) -> String {
        let items = proposal.preview.items
        let kept = items.first { $0.id == proposal.picks.survivor }?.title ?? ""
        let gone = items.filter { $0.id != proposal.picks.survivor }
        if gone.count == 1, let only = gone.first {
            return String(localized: """
                “\(only.title)” moves to Trash with its history, and its password and code stay in the History of “\(kept)”. \
                It can’t be restored while “\(kept)” is in the vault.
                """)
        }
        return String(localized: """
            \(gone.count) credentials move to Trash with their history, and their passwords and codes stay in the History of \
            “\(kept)”. They can’t be restored while “\(kept)” is in the vault.
            """)
    }

    // MARK: Actions

    private func ticked(_ origin: String, in proposal: CredentialMergeProposal) -> Binding<Bool> {
        Binding(
            get: { proposal.picks.extraWebsites.contains(origin) },
            set: { isOn in
                var picks = proposal.picks
                if isOn {
                    picks.extraWebsites.insert(origin)
                } else {
                    picks.extraWebsites.remove(origin)
                }
                Task { await reload(picks: picks) }
            }
        )
    }

    /// Reads the merge again, from the vault as it is now. The previous proposal stays when the new one is refused, so a pick the
    /// rules reject leaves the sheet as it was, with the reason.
    private func reload(survivor: UUID? = nil, picks: MergePicks? = nil) async {
        do {
            proposal = try await model.mergeProposal(ids: ids, survivor: survivor, picks: picks)
            message = nil
        } catch {
            message = CredentialSettingsModel.mergeMessage(for: error)
        }
    }

    private func merge(_ proposal: CredentialMergeProposal) {
        isWorking = true
        Task {
            do {
                try await model.confirmMerge(proposal)
                close(true)
            } catch {
                message = CredentialSettingsModel.mergeMessage(for: error)
                isWorking = false
                // A vault that changed meanwhile is read again, so the next Merge is made against what is there.
                if case CredentialVaultError.staleRevision = error {
                    await reload(picks: proposal.picks)
                }
            }
        }
    }
}
