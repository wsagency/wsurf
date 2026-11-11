// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import SwiftUI
import WSurfVault

/// The popover of the Passwords item in the menu bar. It draws vault content only while the model's session is backed by the manager's
/// current authorization (`PasswordsMenuPhase.content`); locked, it says so and offers Unlock…, which opens the Passwords window where
/// the unlock runs. It copies a password or a code and never shows one.
struct PasswordsMenuView: View {
    private let model: CredentialSettingsModel
    private let actions: PasswordsStatusItem
    @State private var content: PasswordsMenuContent
    @FocusState private var searchFocused: Bool

    /// `origin` is the origin of the front browser tab, for "Matching This Website".
    init(model: CredentialSettingsModel, origin: String?, actions: PasswordsStatusItem) {
        self.model = model
        self.actions = actions
        _content = State(initialValue: PasswordsMenuContent(model: model, origin: origin))
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            phase
            Divider()
            footer
        }
        .frame(width: PasswordsStatusItem.popoverSize.width, height: PasswordsStatusItem.popoverSize.height)
        .task(id: model.authorizationEpoch) {
            await model.load()
            content.refresh()
        }
        .onChange(of: content.query) { content.refresh() }
        .onChange(of: model.revision) { content.refresh() }
        .onChange(of: model.menuPhase) { content.refresh() }
        .onChange(of: model.notice) { _, notice in
            if let notice {
                AccessibilityNotification.Announcement(notice.text).post()
            }
        }
        // The field exists only once the vault is read, which is after the popover appears: focus it when it does.
        .task(id: model.menuPhase) {
            searchFocused = model.menuPhase == .content
        }
        .onExitCommand { actions.closePopover() }
    }

    // MARK: Header and footer

    private var header: some View {
        HStack {
            Label("Passwords", systemImage: "key.fill").font(.headline)
            Spacer()
            if model.menuPhase == .content, model.vaults.count > 1 {
                Menu {
                    ForEach(model.vaults.sorted { $0.ordinal < $1.ordinal }, id: \.vaultID) { listing in
                        Button(listing.label) { Task { await model.select(vaultID: listing.vaultID) } }
                    }
                } label: {
                    Text(verbatim: model.vaults.first { $0.vaultID == model.selectedVaultID }?.label ?? "")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
        }
        .padding(10)
    }

    private var footer: some View {
        HStack {
            if let message = model.error ?? model.notice?.text {
                Text(verbatim: message)
                    .font(.caption)
                    .foregroundStyle(model.error == nil ? Color.secondary : Color.red)
                    .lineLimit(2)
            }
            Spacer()
            Menu {
                Button("Open Passwords") { actions.openPasswords() }
                Button("Lock Credentials") { actions.lockNow() }
                    .help(Text("Locks every vault and Input History of every profile."))
                Divider()
                Button("Settings…") { actions.openSettings() }
                Button("Quit WSurf") { actions.quit() }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .accessibilityLabel(Text("More Actions"))
        }
        .padding(10)
    }

    // MARK: Content

    @ViewBuilder private var phase: some View {
        switch model.menuPhase {
        case .unavailable:
            message(Text("Credentials are unavailable"), symbol: "lock")
        case .opening:
            ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .locked:
            VStack(spacing: 12) {
                Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(.secondary)
                Text("Credentials are locked").foregroundStyle(.secondary)
                Button("Unlock…") { actions.unlock() }.buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .content:
            unlocked
        }
    }

    private func message(_ text: Text, symbol: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.largeTitle).foregroundStyle(.secondary)
            text.foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var unlocked: some View {
        VStack(spacing: 0) {
            TextField("Search Credentials", text: $content.query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .padding(10)
                .onSubmit { performPrimary() }
                .onKeyPress(.upArrow) { content.move(-1) ? .handled : .ignored }
                .onKeyPress(.downArrow) { content.move(1) ? .handled : .ignored }
                .onKeyPress(.return, phases: .down) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    perform(.openWebsite)
                    return .handled
                }
            if content.rows.isEmpty {
                message(Text("No Matching Credentials"), symbol: "magnifyingglass")
            } else {
                list
            }
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    section("Matching This Website", content.sections?.matching ?? [])
                    section("Recent", content.sections?.recent ?? [])
                    if let more = content.sections?.more, more > 0 {
                        Button("Show All in Passwords") { actions.openPasswords() }
                            .buttonStyle(.link)
                            .padding(10)
                    }
                }
            }
            .onChange(of: content.selection) { _, id in
                if let id {
                    proxy.scrollTo(id)
                }
            }
        }
    }

    @ViewBuilder private func section(_ title: LocalizedStringKey, _ rows: [CredentialSummary]) -> some View {
        if !rows.isEmpty {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.top, 8)
            ForEach(rows) { summary in
                PasswordsMenuRow(summary: summary, isSelected: content.selection == summary.id) { action in
                    content.selection = summary.id
                    actions.perform(action, on: summary)
                }
                .id(summary.id)
            }
        }
    }

    // MARK: Keys

    private func performPrimary() {
        guard let selected = content.selected, let primary = PasswordsMenuAction.primary(for: selected) else { return }
        actions.perform(primary, on: selected)
    }

    private func perform(_ action: PasswordsMenuAction) {
        guard let selected = content.selected, PasswordsMenuAction.offered(for: selected).contains(action) else { return }
        actions.perform(action, on: selected)
    }
}
