// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

// MARK: - Wording

extension CredentialImportReview.LocalChange {
    /// The change as one line: the field's name and, when the vault keeps one, a date. Never a value.
    var text: String {
        let what = switch kind {
        case .username:
            String(localized: "Username changed")
        case .password:
            String(localized: "Password changed")
        case .login:
            String(localized: "Login details changed")
        case .verificationCode:
            String(localized: "Verification code changed")
        case .websitesOrName:
            String(localized: "Websites or name changed")
        case let .notesAdded(count):
            if count == 1 {
                String(localized: "A note added")
            } else {
                String(localized: "\(count) notes added")
            }
        case .notesRemoved:
            String(localized: "Notes removed")
        case .merged:
            String(localized: "Merged with another credential")
        case let .movedToTrash(part):
            String(localized: "\(part.label) moved to Trash")
        }
        guard let date else { return what }
        return what + " · " + date.formatted(date: .abbreviated, time: .omitted)
    }
}

// MARK: - Sections

/// What the import review says about the vault beyond the transfer's own items, above its groups: the changes made in WSurf that the
/// import keeps, and the saved credentials the transfer no longer holds. Both start closed. The rows are children of the list's lazy
/// stack, so a long list builds only what is on screen.
struct CredentialImportReportSections: View {
    let model: CredentialSettingsModel
    let review: CredentialImportReview
    /// Kept by the sheet: a lazy stack drops the state of a view that scrolls out of sight.
    @Binding var showsKept: Bool
    @Binding var showsMissing: Bool

    var body: some View {
        if !review.keptChanges.isEmpty {
            disclosure("Changed in WSurf (kept)", count: review.keptChanges.count, isOpen: $showsKept)
            if showsKept {
                Text("These changes stay as they are. Only the names of the fields and the dates are shown, never their values.")
                    .font(Theme.Font.label)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.bottom, 6)
                ForEach(review.keptChanges) { item in
                    keptRow(item)
                }
            }
        }
        if !review.missing.isEmpty {
            disclosure("No longer in Passwords", count: review.missing.count, isOpen: $showsMissing)
            if showsMissing {
                missingHeader
                if review.transferIsComplete {
                    ForEach(review.missing) { item in
                        missingRow(item)
                    }
                }
            }
        }
    }

    private func disclosure(_ title: LocalizedStringResource, count: Int, isOpen: Binding<Bool>) -> some View {
        Button {
            isOpen.wrappedValue.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isOpen.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(Theme.Font.badge)
                    .frame(width: 10)
                Text(title).font(Theme.Font.title)
                Text(verbatim: "\(count)").foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(verbatim: "\(count)"))
        .padding(.vertical, 6)
    }

    // MARK: Changed in WSurf

    private func keptRow(_ item: CredentialImportReview.KeptChange) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: item.title).font(Theme.Font.rowTitle)
            ForEach(Array(item.changes.enumerated()), id: \.offset) { _, change in
                Text(verbatim: change.text).font(Theme.Font.label).foregroundStyle(.secondary)
            }
            Divider().padding(.top, 6)
        }
        .padding(.top, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: No longer in Passwords

    private var missingHeader: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("An earlier import brought these, and this transfer doesn’t have them. They stay in WSurf unless you move them to Trash.")
                .font(Theme.Font.label)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle(
                "This transfer has everything from Passwords",
                isOn: Binding(get: { review.transferIsComplete }, set: { model.declareImportComplete($0) })
            )
            .toggleStyle(.checkbox)
            if review.transferIsComplete {
                HStack(spacing: 12) {
                    Button("Keep All") { model.chooseMissing(moveToTrash: false) }
                    Button("Move All to Trash") { model.chooseMissing(moveToTrash: true) }
                }
                .controlSize(.small)
            } else {
                Text("If it is only part of Passwords, leave this off. WSurf can’t tell, so it keeps all of them.")
                    .font(Theme.Font.label)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 6)
    }

    private func missingRow(_ item: CredentialImportReview.Missing) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(verbatim: item.title).font(Theme.Font.rowTitle)
                Spacer(minLength: 8)
                Menu {
                    Button("Keep") { model.chooseMissing(moveToTrash: false, for: [item.accountID]) }
                    Button("Move to Trash") { model.chooseMissing(moveToTrash: true, for: [item.accountID]) }
                } label: {
                    Text(choice(item))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.vertical, 8)
            Divider()
        }
    }

    private func choice(_ item: CredentialImportReview.Missing) -> LocalizedStringResource {
        item.movesToTrash ? "Move to Trash" : "Keep"
    }
}
