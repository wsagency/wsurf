// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import LocalAuthentication
import LocalAuthenticationEmbeddedUI

/// The Touch ID control on the passkey sheet: the sheet names the site and the passkey, and this one biometric
/// answers it, with no system dialog. Its context is new for this sheet, has no reuse window and ends with the sheet, so an
/// unlock or an earlier sign-in never stands in for it. A Mac with no usable sensor gets `nil` and the sheet's button.
@MainActor
final class PasskeySheetTouch: NSObject {
    let view: LAAuthenticationView
    /// True only when this sheet's own evaluation just succeeded.
    private(set) var verified = false
    private let context = LAContext()
    private let chooser: NSPopUpButton?
    private let reason: String
    private var started = false
    private var sheet: NSWindow?
    private var anchor: NSWindow?

    init?(chooser: NSPopUpButton?, reason: String) {
        context.touchIDAuthenticationAllowableReuseDuration = 0
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return nil }
        view = LAAuthenticationView(context: context, controlSize: .regular)
        self.chooser = chooser
        self.reason = reason
        super.init()
        chooser?.target = self
        chooser?.action = #selector(chooserChanged)
    }

    func begin(sheet: NSWindow, on anchor: NSWindow) {
        self.sheet = sheet
        self.anchor = anchor
        evaluate()
    }

    func end() {
        context.invalidate()
    }

    @objc private func chooserChanged() {
        evaluate()
    }

    /// Waits for a passkey to be picked when several match: a touch may only ever answer for a passkey the sheet is showing. It
    /// also stays off in an app in the background, where the touch would be meant for something else. One try per sheet: after a
    /// failure the button remains, and with it the system's verification.
    private func evaluate() {
        guard !started, NSApp.isActive, let sheet, let anchor else { return }
        if let chooser, case .declined = NativeWebAuthnInteraction.decision(from: chooser) {
            return
        }
        started = true
        nonisolated(unsafe) let context = context
        Task { [reason] in
            guard (try? await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason)) == true else { return }
            verified = true
            anchor.endSheet(sheet, returnCode: .alertFirstButtonReturn)
        }
    }
}

/// Find on the passkey sheet: searches the vault's other passkeys and says they cannot sign in here. It only reads: WebAuthn binds
/// a passkey to its relying party, so nothing it lists can be chosen. Every passkey that can answer is already on the sheet.
@MainActor
final class PasskeyFindField: NSObject, NSSearchFieldDelegate {
    let view = NSStackView()
    private let others: [WebAuthnPromptOther]
    private let field = NSSearchField()
    private let results = NSTextField(wrappingLabelWithString: "")
    private static let shownLines = 3

    init?(_ others: [WebAuthnPromptOther]) {
        guard !others.isEmpty else { return nil }
        self.others = others
        super.init()
        field.placeholderString = String(localized: "Find a passkey…")
        field.delegate = self
        results.font = .preferredFont(forTextStyle: .caption1)
        results.textColor = .secondaryLabelColor
        results.maximumNumberOfLines = Self.shownLines
        // The alert does not resize while it is up, so the lines are reserved from the start.
        results.heightAnchor.constraint(equalToConstant: CGFloat(Self.shownLines) * 16).isActive = true
        results.widthAnchor.constraint(equalToConstant: 360).isActive = true
        field.widthAnchor.constraint(equalToConstant: 360).isActive = true
        view.orientation = .vertical
        view.alignment = .leading
        view.addArrangedSubview(field)
        view.addArrangedSubview(results)
    }

    func controlTextDidChange(_ notification: Notification) {
        results.stringValue = Self.text(others, query: field.stringValue)
    }

    /// Return in the search must not press the sheet's default button.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        selector == #selector(NSResponder.insertNewline(_:))
    }

    static func matches(_ others: [WebAuthnPromptOther], query: String) -> [WebAuthnPromptOther] {
        others.filter { [$0.title, $0.userName, $0.rpID].contains { $0.localizedStandardContains(query) } }
    }

    static func text(_ others: [WebAuthnPromptOther], query: String) -> String {
        guard !query.isEmpty else { return "" }
        let found = matches(others, query: query)
        guard !found.isEmpty else { return String(localized: "No other passkey matches.") }
        let lines = found.prefix(shownLines - 1).map { "\($0.title) · \($0.userName) — \($0.rpID)" }
        return (lines + [String(localized: "Can’t sign in here: a passkey works only for the website it was made for.")])
            .joined(separator: "\n")
    }
}
