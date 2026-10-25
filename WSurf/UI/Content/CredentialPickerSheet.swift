// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

/// The Pick Credential… sheet on the page's window: a search field over the unlocked vaults' logins and verification codes, this
/// website's first. It shows titles, usernames and websites only; nothing secret ever reaches it.
@MainActor
enum CredentialPickerSheet {
    /// The sheets on screen: their profile, the sheet and its window.
    private static var open: [(profileID: UUID, sheet: NSWindow, window: NSWindow)] = []

    /// Ends the sheets of `profileID` (all with nil) as a Cancel: its vault access ended or the autofill policy changed, so the list
    /// of titles does not stay on screen.
    static func dismiss(profileID: UUID? = nil) {
        for entry in open where profileID == nil || entry.profileID == profileID {
            entry.window.endSheet(entry.sheet)
        }
    }

    /// The person's answer; nil for Cancel, Escape, a window that went away or `dismiss`.
    static func present(
        rows: [CredentialPicker.Row], host: String, canUnlock: Bool, profileID: UUID, in window: NSWindow
    ) async -> CredentialPicker.Answer? {
        await withCheckedContinuation { continuation in
            final class Once {
                var continuation: CheckedContinuation<CredentialPicker.Answer?, Never>?
                var closing: NSObjectProtocol?
            }
            let once = Once()
            once.continuation = continuation
            let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 440), styleMask: [.titled], backing: .buffered, defer: true)
            sheet.isReleasedWhenClosed = false
            let finish: @MainActor @Sendable (CredentialPicker.Answer?) -> Void = { [weak window, weak sheet] answer in
                guard let resume = once.continuation else { return }
                once.continuation = nil
                open.removeAll { $0.sheet === sheet }
                if let closing = once.closing {
                    NotificationCenter.default.removeObserver(closing)
                }
                if let window, let sheet {
                    window.endSheet(sheet)
                }
                resume.resume(returning: answer)
            }
            sheet.contentViewController = NSHostingController(
                rootView: CredentialPickerList(rows: rows, host: host, canUnlock: canUnlock, finish: finish)
            )
            // A window that closes with the sheet on it is a cancel too.
            once.closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { finish(nil) }
            }
            open.append((profileID, sheet, window))
            window.beginSheet(sheet) { _ in finish(nil) }
        }
    }
}

struct CredentialPickerList: View {
    let rows: [CredentialPicker.Row]
    let host: String
    let canUnlock: Bool
    let finish: @MainActor (CredentialPicker.Answer?) -> Void
    @State private var query = ""
    @State private var selection: UUID?
    @FocusState private var searching: Bool

    var body: some View {
        let shown = CredentialPicker.filter(rows, query: query)
        VStack(alignment: .leading, spacing: 12) {
            Text("Pick a Credential for \(host)")
                .font(.headline)
                .lineLimit(1)
                .truncationMode(.middle)
            TextField("Search Credentials", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searching)
                .onKeyPress(.downArrow) { move(1, in: shown) }
                .onKeyPress(.upArrow) { move(-1, in: shown) }
                .onSubmit { choose(in: shown) }
            if shown.isEmpty {
                Text(rows.isEmpty ? "No Saved Credentials" : "No Matching Credentials")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $selection) {
                    section("On This Website", shown.filter(\.matchesSite))
                    section("Other Websites", shown.filter { !$0.matchesSite })
                }
                .contextMenu(forSelectionType: UUID.self, menu: { _ in EmptyView() }, primaryAction: { ids in
                    if let id = ids.first {
                        finish(.row(id))
                    }
                })
            }
            HStack(spacing: 8) {
                if canUnlock {
                    Button("Unlock Other Vaults…") { finish(.unlock) }
                }
                Spacer(minLength: 0)
                Button("Cancel", role: .cancel) { finish(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Fill") { choose(in: shown) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!shown.contains { $0.id == selection })
            }
        }
        .padding(16)
        .frame(width: 460, height: 440)
        .onAppear {
            searching = true
            selection = shown.first?.id
        }
        .onChange(of: query) {
            selection = CredentialPicker.filter(rows, query: query).first?.id
        }
    }

    @ViewBuilder
    private func section(_ title: LocalizedStringKey, _ rows: [CredentialPicker.Row]) -> some View {
        if !rows.isEmpty {
            Section(title) {
                ForEach(rows) { row in
                    CredentialPickerRow(row: row).tag(row.id)
                }
            }
        }
    }

    private func move(_ step: Int, in shown: [CredentialPicker.Row]) -> KeyPress.Result {
        guard !shown.isEmpty else { return .handled }
        let index = shown.firstIndex { $0.id == selection } ?? (step > 0 ? -1 : shown.count)
        selection = shown[min(max(index + step, 0), shown.count - 1)].id
        return .handled
    }

    private func choose(in shown: [CredentialPicker.Row]) {
        if let selection, shown.contains(where: { $0.id == selection }) {
            finish(.row(selection))
        }
    }
}

private struct CredentialPickerRow: View {
    let row: CredentialPicker.Row

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: row.fill == .code ? "number" : "key")
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: row.title).lineLimit(1)
                if !row.detail.isEmpty {
                    Text(verbatim: row.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
