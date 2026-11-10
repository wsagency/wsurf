// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import SwiftUI

/// The Generate Password… sheet on the page's window (`PasswordGeneratorFlow`), with the picker's look and dismissal: the password in
/// clear, Regenerate, the format and length, the vault to save in when several are unlocked, and what Use Password will do. The
/// password cannot be selected or copied; it leaves the sheet only through Use Password, and the sheet's state drops it when the sheet
/// closes.
@MainActor
enum PasswordGeneratorSheet {
    static let width: CGFloat = 460
    static let height: CGFloat = 400

    /// The person's answer; nil for Cancel, Escape, a window that went away or `CredentialPickerSheet.dismiss`.
    static func present(
        _ proposal: PasswordGeneratorFlow.Proposal, profileID: UUID, page: BrowserPage, in window: NSWindow
    ) async -> PasswordGeneratorFlow.Answer? {
        await CredentialPickerSheet.show(size: NSSize(width: width, height: height), profileID: profileID, page: page, in: window) { finish in
            PasswordGeneratorView(proposal: proposal, finish: finish)
        }
    }
}

struct PasswordGeneratorView: View {
    let proposal: PasswordGeneratorFlow.Proposal
    let finish: @MainActor (PasswordGeneratorFlow.Answer?) -> Void
    @State private var format: PasswordFormat
    @State private var length: Int
    @State private var vaultID: UUID
    @State private var password: GeneratedPassword?

    init(proposal: PasswordGeneratorFlow.Proposal, finish: @escaping @MainActor (PasswordGeneratorFlow.Answer?) -> Void) {
        self.proposal = proposal
        self.finish = finish
        _format = State(initialValue: proposal.format)
        _length = State(initialValue: PasswordGenerator.defaultLength)
        _vaultID = State(initialValue: proposal.vaultID)
        _password = State(initialValue: proposal.password)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Generate a Password for \(proposal.host)")
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityAddTraits(.isHeader)
                if let pageHost = proposal.pageHost {
                    Text("In a frame on \(pageHost)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                passwordText
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(action: regenerate) {
                    Label("Regenerate", systemImage: "arrow.clockwise")
                }
                .disabled(bounds == nil)
            }
            if let status {
                Text(verbatim: status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 16) {
                Picker("Format", selection: $format) {
                    ForEach(formats, id: \.self) { format in
                        Text(Self.title(of: format)).tag(format)
                    }
                }
                .fixedSize()
                Stepper(value: $length, in: lengths, step: 1) {
                    Text("Length \(shownLength)")
                        .monospacedDigit()
                }
                .disabled(bounds == nil || lengths.lowerBound == lengths.upperBound)
            }
            if proposal.vaults.count > 1 {
                Picker("Save in", selection: $vaultID) {
                    ForEach(proposal.vaults) { vault in
                        Text(verbatim: vault.label).tag(vault.id)
                    }
                }
                .fixedSize()
            }
            Text(verbatim: explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                if proposal.canUnlock {
                    Button("Unlock Other Vaults…") { finish(.unlock) }
                }
                Spacer(minLength: 0)
                Button("Cancel", role: .cancel) { finish(nil) }
                    .keyboardShortcut(.cancelAction)
                Button("Use Password") {
                    if let password {
                        finish(.use(password, vaultID: vaultID))
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(password == nil)
            }
        }
        .padding(16)
        .frame(width: PasswordGeneratorSheet.width, height: PasswordGeneratorSheet.height, alignment: .top)
        .onChange(of: format) { regenerate() }
        .onChange(of: length) { regenerate() }
        // The sheet's copy of the password goes with the sheet.
        .onDisappear { password = nil }
    }

    @ViewBuilder
    private var passwordText: some View {
        if let password {
            Text(verbatim: password.revealed)
                .font(.system(.title3, design: .monospaced))
                .environment(\.layoutDirection, .leftToRight)
                .lineLimit(3)
                .textSelection(.disabled)
                .privacySensitive()
                .accessibilityLabel(Text("Generated password"))
                .accessibilityValue(Text(verbatim: password.revealed))
                .speechSpellsOutCharacters()
        } else {
            Text("WSurf can’t make a password that meets this website’s rules.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Formats and lengths

    /// Website's Rules only for a field that has rules.
    private var formats: [PasswordFormat] {
        PasswordFormat.allCases.filter { $0 != .websiteRules || !proposal.field.rules.isEmpty }
    }

    static func title(of format: PasswordFormat) -> LocalizedStringKey {
        switch format {
        case .easyToType:
            "Easy to Type"
        case .lettersAndDigits:
            "Letters and Digits"
        case .withSymbols:
            "With Symbols"
        case .websiteRules:
            "Website’s Rules"
        }
    }

    /// The lengths the format may have for this field (`PasswordGenerator.lengthBounds`); nil when none.
    private var bounds: ClosedRange<Int>? {
        PasswordGenerator.lengthBounds(for: format, rules: proposal.field.rules, field: proposal.field.limits)
    }

    /// The stepper's range: the generator's, narrowed by the field's bounds. Only the site's own limits go below 12 (or above 64).
    private var lengths: ClosedRange<Int> {
        guard let bounds else { return PasswordGenerator.defaultLength...PasswordGenerator.defaultLength }
        func clamped(_ value: Int) -> Int {
            min(max(value, bounds.lowerBound), bounds.upperBound)
        }
        return clamped(PasswordGenerator.lengthRange.lowerBound)...clamped(PasswordGenerator.lengthRange.upperBound)
    }

    /// The length the password has: the chosen one, clamped as the generator clamps it.
    private var shownLength: Int {
        password?.count ?? min(max(length, lengths.lowerBound), lengths.upperBound)
    }

    private func regenerate() {
        password = PasswordGeneratorFlow.password(format, length: length, for: proposal.field)
        if password != nil {
            AccessibilityNotification.Announcement(String(localized: "New password")).post()
        }
    }

    // MARK: - What the sheet says

    /// Under the password: whether it follows the website's rules, or how short the field keeps it.
    private var status: String? {
        guard let password else { return nil }
        var lines: [String] = []
        if format == .websiteRules {
            lines.append(String(localized: "Follows this website’s password rules."))
        } else if let bounds, bounds.upperBound < min(max(length, PasswordGenerator.lengthRange.lowerBound), PasswordGenerator.lengthRange.upperBound) {
            lines.append(String(localized: "This field allows at most \(bounds.upperBound) characters."))
        }
        if PasswordGenerator.estimatedBits(format, count: password.count, rules: proposal.field.rules) < PasswordGenerator.weakBits {
            lines.append(String(localized: "The website’s limits make this password easier to guess than most."))
        }
        return lines.isEmpty ? nil : lines.joined(separator: " ")
    }

    private var explanation: String {
        Self.explanation(host: proposal.host, field: proposal.field)
    }

    /// The most characters of the username the sheet shows.
    nonisolated static let shownUsernameLimit = 64

    /// A page-supplied username, safe to put in this sheet's own text: control, format (bidi overrides and isolates, zero-width) and
    /// line and paragraph separator characters are dropped, so it is one line, and it is cut at `shownUsernameLimit` characters. Display
    /// only: what is saved is the username as the form shows it.
    nonisolated static func shownUsername(_ page: String) -> String {
        let hidden: Set<Unicode.GeneralCategory> = [.control, .format, .lineSeparator, .paragraphSeparator]
        let clean = String(String.UnicodeScalarView(page.unicodeScalars.filter { !hidden.contains($0.properties.generalCategory) }))
        return clean.count > shownUsernameLimit ? String(clean.prefix(shownUsernameLimit)) + "…" : clean
    }

    /// What Use Password does, with the username the form shows (page text, cleaned by `shownUsername`).
    static func explanation(host: String, field: PasswordGeneratorFlow.Field) -> String {
        let username = shownUsername(field.username)
        switch (field.hasConfirmation, username.isEmpty) {
        case (true, false):
            return String(localized: "WSurf fills this field and its confirmation, and saves the password for \(host) as \(username).")
        case (true, true):
            return String(localized: "WSurf fills this field and its confirmation, and saves the password for \(host).")
        case (false, false):
            return String(localized: "WSurf fills this field and saves the password for \(host) as \(username).")
        case (false, true):
            return String(localized: "WSurf fills this field and saves the password for \(host).")
        }
    }
}
