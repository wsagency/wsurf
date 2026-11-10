// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import SwiftUI

/// The Pick Credential… sheet on the page's window: a search field over the unlocked vaults' logins and verification codes, this
/// website's first. It shows titles, usernames and websites only; nothing secret ever reaches it. For a code field it also holds the
/// native field macOS lists the codes of Messages and Mail under (`MessagesCodeField`), in a sheet of the key window.
@MainActor
enum CredentialPickerSheet {
    /// A sheet on screen, the picker's or the password generator's (`PasswordGeneratorSheet`): its profile, the page it is for, the
    /// sheet and its window.
    private struct Entry {
        let profileID: UUID
        weak var page: BrowserPage?
        let sheet: NSWindow
        let window: NSWindow
    }

    private static var open: [Entry] = []

    /// Ends the sheets of `profileID` (all with nil) as a Cancel: its vault access ended or the autofill policy changed, so the list
    /// of titles, or a generated password, does not stay on screen.
    static func dismiss(profileID: UUID? = nil) {
        for entry in open where profileID == nil || entry.profileID == profileID {
            entry.window.endSheet(entry.sheet)
        }
    }

    /// Ends the sheets of `page` only, as a Cancel: an agent took its tab (`BrowserTab.agentControlChanged`). The sheets of other
    /// tabs, of the same profile and window included, stay: an agent can take a background tab.
    static func dismiss(page: BrowserPage) {
        for entry in open where entry.page === page {
            entry.window.endSheet(entry.sheet)
        }
    }

    /// The person's answer; nil for Cancel, Escape, a window that went away or `dismiss`.
    static func present(
        rows: [CredentialPicker.Row], host: String, canUnlock: Bool, offersCode: Bool = false, profileID: UUID, page: BrowserPage? = nil,
        in window: NSWindow
    ) async -> CredentialPicker.Answer? {
        await show(size: NSSize(width: 460, height: 440), profileID: profileID, page: page, in: window) { finish in
            CredentialPickerList(rows: rows, host: host, canUnlock: canUnlock, offersCode: offersCode, finish: finish)
        }
    }

    /// `content` as a sheet of `size` on `window`, until it calls its `finish` once: nil for Cancel, Escape, a window that went away
    /// or `dismiss`.
    static func show<Answer: Sendable, Content: View>(
        size: NSSize, profileID: UUID, page: BrowserPage?, in window: NSWindow,
        content: (_ finish: @escaping @MainActor @Sendable (Answer?) -> Void) -> Content
    ) async -> Answer? {
        await withCheckedContinuation { continuation in
            let once = SheetAnswer<Answer>()
            once.continuation = continuation
            let sheet = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: true)
            sheet.isReleasedWhenClosed = false
            let finish: @MainActor @Sendable (Answer?) -> Void = { [weak window, weak sheet] answer in
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
            sheet.contentViewController = NSHostingController(rootView: content(finish))
            // A window that closes with the sheet on it is a cancel too.
            once.closing = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                MainActor.assumeIsolated { finish(nil) }
            }
            open.append(Entry(profileID: profileID, page: page, sheet: sheet, window: window))
            window.beginSheet(sheet) { _ in finish(nil) }
        }
    }
}

/// One sheet's answer, given once.
private final class SheetAnswer<Answer> {
    var continuation: CheckedContinuation<Answer?, Never>?
    var closing: NSObjectProtocol?
}

struct CredentialPickerList: View {
    let rows: [CredentialPicker.Row]
    let host: String
    let canUnlock: Bool
    var offersCode = false
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
            if offersCode {
                MessagesCodeEntry(host: host) { finish(.code($0)) }
                    .frame(height: MessagesCodeBridge.fieldHeight)
            }
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

/// The native code field in the sheet. Escape is the sheet's Cancel; a code leaves the field empty.
private struct MessagesCodeEntry: NSViewRepresentable {
    let host: String
    let submit: @MainActor (String) -> Void

    func makeNSView(context: Context) -> MessagesCodeField {
        let field = MessagesCodeField(site: host)
        field.onCode = submit
        return field
    }

    func updateNSView(_ field: MessagesCodeField, context: Context) {
        field.onCode = submit
    }

    /// Whatever was typed and not confirmed does not outlive the sheet.
    static func dismantleNSView(_ field: MessagesCodeField, coordinator: ()) {
        field.onCode = nil
        field.clear()
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
