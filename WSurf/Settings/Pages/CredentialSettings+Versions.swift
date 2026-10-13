// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

extension RevisionItem {
    var title: String {
        String(localized: "Version \(version) · \(String(localized: subject.label))")
    }

    /// When it was replaced, and why if the writer said.
    var detail: String {
        let when = recordedAt.formatted(date: .abbreviated, time: .shortened)
        guard let cause, !cause.isEmpty else { return when }
        return "\(when) · \(cause)"
    }
}

/// The earlier versions of one credential, as the model lists them. Restoring is an ordinary save: the value being replaced
/// becomes a new earlier version, so a restore can itself be undone. Passkeys are listed but never offered for restore.
struct CredentialVersionsSheet: View {
    let model: CredentialSettingsModel
    let run: (@escaping () async throws -> Void) -> Void

    @State private var restoring: RevisionItem?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Earlier Versions").font(Theme.Font.row).fontWeight(.semibold)
            if model.revisionItems.isEmpty {
                Text("No earlier versions are kept.").font(Theme.Font.label).foregroundStyle(.secondary)
            }
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(model.revisionItems) { item in
                        DetailRow(verbatimTitle: item.title, verbatimCaption: item.detail) {
                            if item.subject.restoresFromEarlierVersions {
                                Button("Restore…") { restoring = item }.buttonStyle(.bordered).disabled(model.isBusy)
                            }
                        }
                        RowSeparator()
                    }
                    if model.revisionHasMore {
                        Button("Show More") { run { try await model.loadMoreVersions() } }
                            .buttonStyle(.bordered)
                            .disabled(model.isBusy)
                            .padding(.top, 8)
                    }
                }
            }
            .frame(maxHeight: 320)
            if let error = model.error {
                Text(verbatim: error).font(Theme.Font.label).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Done") { model.closeVersions() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .confirmationDialog(
            "Restore This Version?",
            isPresented: Binding(get: { restoring != nil }, set: { if !$0 { restoring = nil } }),
            presenting: restoring
        ) { item in
            Button("Restore") { run { await model.restoreVersion(revisionID: item.id) } }
            Button("Cancel", role: .cancel) {}
        } message: { item in
            Text("The current value is kept as an earlier version. “\(item.title)” becomes the current one.")
        }
    }
}
