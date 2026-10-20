// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// The editor's cards, addresses and other items. Each value is typed in place; a hidden one (a card number, a key) is masked until
/// its eye button shows it. The editor was opened under Touch ID when it holds a card or an identity document, so nothing here asks
/// again. It reads and writes only the open draft; nothing is stored before Save.
struct CredentialSecureItemsSection: View {
    let model: CredentialSettingsModel
    /// The values shown unmasked, by item and position. View state only: closing the editor masks everything again.
    @State private var shown: Set<SecureFieldPosition> = []
    @State private var pendingRemoval: Int?

    private struct SecureFieldPosition: Hashable {
        let item: Int
        let field: Int
    }

    var body: some View {
        let items = model.draft?.secureItems ?? []
        VStack(alignment: .leading, spacing: 10) {
            Text("Cards and other items").font(Theme.Font.rowTitle).accessibilityAddTraits(.isHeader)
            ForEach(items.indices, id: \.self) { index in
                itemBox(items[index], at: index)
            }
            Menu {
                ForEach(SecureItemKind.addable, id: \.self) { kind in
                    Button(kind.label) { model.draft?.addSecureItem(kind) }
                }
            } label: {
                Label("Add Item", systemImage: "plus")
            }
            .fixedSize()
            .disabled(items.count >= SecureItem.itemLimit)
        }
        .confirmationDialog(
            "Remove Item?",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            presenting: pendingRemoval
        ) { index in
            Button("Remove Item", role: .destructive) {
                model.draft?.removeSecureItem(at: index)
                shown = []
                pendingRemoval = nil
            }
            Button("Cancel", role: .cancel) { pendingRemoval = nil }
        } message: { _ in
            Text("This item is removed when you save. You can copy it back from History.")
        }
    }

    private func itemBox(_ item: SecureItem, at index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(verbatim: item.kind.label).font(Theme.Font.label).fontWeight(.medium)
                Spacer()
                missingMembersMenu(item, at: index)
                Button("Remove Item", role: .destructive) { pendingRemoval = index }
                    .controlSize(.small)
            }
            if item.kind == .customFields {
                LabeledContent("Title") {
                    TextField("Title", text: itemLabel(index)).labelsHidden()
                }
            }
            ForEach(item.fields.indices, id: \.self) { position in
                fieldRow(item, at: index, position: position)
            }
            if item.kind == .customFields {
                Button {
                    model.draft?.addCustomField(toItem: index)
                } label: {
                    Label("Add Field", systemImage: "plus")
                }
                .controlSize(.small)
            }
        }
        .padding(10)
        .background(Theme.Wash.faint, in: RoundedRectangle(cornerRadius: 8))
    }

    /// The members the exporter left out of an item, to add one; nothing for custom fields or a complete item.
    @ViewBuilder
    private func missingMembersMenu(_ item: SecureItem, at index: Int) -> some View {
        let missing = item.kind.members.filter { member in !member.isPlain && !item.fields.contains { $0.name == member.name } }
        if !missing.isEmpty {
            Menu("Add Field") {
                ForEach(missing, id: \.name) { member in
                    Button(SecureItemKind.memberLabel(member.name)) { model.draft?.addMember(member, toItem: index) }
                }
            }
            .controlSize(.small)
            .fixedSize()
        }
    }

    @ViewBuilder
    private func fieldRow(_ item: SecureItem, at index: Int, position: Int) -> some View {
        let field = item.fields[position]
        let key = SecureFieldPosition(item: index, field: position)
        let concealed = item.isConcealed(field)
        let title = item.label(of: field)
        let member = item.kind.member(field.name)
        HStack(spacing: 6) {
            if item.kind == .customFields {
                TextField("Label", text: customLabel(index, position)).frame(maxWidth: 140)
            } else {
                Text(verbatim: title).foregroundStyle(.secondary).frame(minWidth: 120, alignment: .leading)
            }
            if member?.isPlain == true {
                // An SSH key's type, private key and comment come from the transfer and are kept as they are.
                Text(verbatim: concealed && !shown.contains(key) ? "••••••••" : field.value)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .privacySensitive(concealed)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if concealed && !shown.contains(key) {
                SecureField(title, text: value(index, position)).labelsHidden().privacySensitive()
            } else {
                TextField(title, text: value(index, position)).labelsHidden().privacySensitive(concealed)
            }
            if concealed {
                Button {
                    if shown.contains(key) {
                        shown.remove(key)
                    } else {
                        shown.insert(key)
                    }
                } label: {
                    Image(systemName: shown.contains(key) ? "eye.slash" : "eye").frame(width: 24, height: 24).contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(shown.contains(key) ? "Hide" : "Show")
                .accessibilityLabel(shown.contains(key) ? "Hide \(title)" : "Show \(title)")
            }
            if item.kind == .customFields {
                Toggle("Hidden", isOn: hidden(index, position)).toggleStyle(.checkbox).controlSize(.small)
            }
            CredentialCopyButton(label: "Copy \(title)") { copy(.secureField(item: index, field: position)) }
                .disabled(field.value.isEmpty)
        }
    }

    private func copy(_ part: CredentialCopyPart) {
        Task { await model.attempt { try await model.copy(part, of: .draft) } }
    }

    // MARK: Bindings into the draft

    private func value(_ index: Int, _ position: Int) -> Binding<String> {
        Binding(
            get: { field(index, position)?.value ?? "" },
            set: { text in
                guard field(index, position) != nil else { return }
                model.draft?.secureItems[index].fields[position].value = text
            }
        )
    }

    private func customLabel(_ index: Int, _ position: Int) -> Binding<String> {
        Binding(
            get: { field(index, position)?.field?.label ?? "" },
            set: { text in
                guard let current = field(index, position) else { return }
                var metadata = current.field ?? CredentialEditableFieldMetadata(id: nil, label: nil, fieldType: .string)
                metadata.label = text
                model.draft?.secureItems[index].fields[position].field = metadata
            }
        )
    }

    private func hidden(_ index: Int, _ position: Int) -> Binding<Bool> {
        Binding(
            get: { field(index, position)?.field?.fieldType == .concealedString },
            set: { isHidden in
                guard let current = field(index, position) else { return }
                var metadata = current.field ?? CredentialEditableFieldMetadata(id: nil, label: nil, fieldType: .string)
                metadata.fieldType = isHidden ? .concealedString : .string
                model.draft?.secureItems[index].fields[position].field = metadata
            }
        )
    }

    private func itemLabel(_ index: Int) -> Binding<String> {
        Binding(
            get: { model.draft.flatMap { $0.secureItems.indices.contains(index) ? $0.secureItems[index].label : nil } ?? "" },
            set: { text in
                guard model.draft?.secureItems.indices.contains(index) == true else { return }
                model.draft?.secureItems[index].label = text
            }
        )
    }

    private func field(_ index: Int, _ position: Int) -> SecureItemField? {
        guard let items = model.draft?.secureItems, items.indices.contains(index), items[index].fields.indices.contains(position) else {
            return nil
        }
        return items[index].fields[position]
    }
}
