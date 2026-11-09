// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import SwiftUI
import WSurfVault

/// The editor's cards, addresses and other items. Each value is typed in place; a hidden one (a card number, a key) is masked until
/// its eye button shows it. A custom field's type (Text, Hidden, Date, Number, Email) is chosen from its menu, and a date can be
/// picked from a calendar. The editor was opened under Touch ID when it holds a sensitive item (`SecureItem.isSensitive`), so
/// nothing here asks again. It reads and writes only the open draft; nothing is stored before Save.
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
                    .selectable(!concealed)
                    .privacySensitive(concealed)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if concealed && !shown.contains(key) {
                SecureField(title, text: value(index, position)).labelsHidden().privacySensitive()
            } else if field.field?.fieldType == .date {
                TextField(title, text: value(index, position), prompt: Text(verbatim: "YYYY-MM-DD")).labelsHidden()
                SecureItemDateButton(text: value(index, position), title: title)
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
                Picker("Type", selection: fieldType(index, position)) {
                    ForEach(typeChoices(field), id: \.self) { type in
                        Text(verbatim: type.label).tag(type)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
                .help("Type")
                .accessibilityLabel("Type of \(title)")
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

    private func fieldType(_ index: Int, _ position: Int) -> Binding<CredentialEditableFieldType> {
        Binding(
            get: { field(index, position)?.field?.fieldType ?? .string },
            set: { model.draft?.setCustomFieldType($0, item: index, field: position) }
        )
    }

    /// The menu's types, and the field's own when an import gave it another one, so it shows as it is.
    private func typeChoices(_ field: SecureItemField) -> [CredentialEditableFieldType] {
        let current = field.field?.fieldType ?? .string
        let choices = CredentialEditableFieldType.customFieldChoices
        return choices.contains(current) ? choices : choices + [current]
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

/// Picks a date for a date value from a calendar. The text stays the value: a date is written as the Credential Exchange's
/// "YYYY-MM-DD", read and shown in UTC so no time zone moves it by a day.
private struct SecureItemDateButton: View {
    @Binding var text: String
    let title: String
    @State private var isPicking = false

    private static let style = Date.ISO8601FormatStyle().year().month().day()

    var body: some View {
        Button {
            isPicking = true
        } label: {
            Image(systemName: "calendar").frame(width: 24, height: 24).contentShape(.rect)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.secondary)
        .help("Choose Date")
        .accessibilityLabel("Choose \(title)")
        .popover(isPresented: $isPicking) {
            DatePicker(title, selection: date, displayedComponents: .date)
                .datePickerStyle(.graphical)
                .labelsHidden()
                .environment(\.timeZone, .gmt)
                .padding(12)
        }
    }

    private var date: Binding<Date> {
        Binding(
            get: { (try? Self.style.parse(text)) ?? .now },
            set: { text = $0.formatted(Self.style) }
        )
    }
}

private extension View {
    /// A concealed value is never selectable, shown or not: ⌘C would go around the clipboard clearing (`SecretClipboard`).
    @ViewBuilder
    func selectable(_ allowed: Bool) -> some View {
        if allowed {
            textSelection(.enabled)
        } else {
            textSelection(.disabled)
        }
    }
}
