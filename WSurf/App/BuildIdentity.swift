// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit

/// Which candidate build this is. The `WSurfCandidate` and `WSurfCommit` Info.plist keys come from the
/// `WSURF_CANDIDATE` and `WSURF_COMMIT` build settings, which the candidate gate and sign drivers pass (RELEASING.md).
enum BuildIdentity {
    /// "Candidate 0.1.1-b3 · 4b1870a3", or nil for a dev build (candidate empty or `dev`). A missing commit is left out.
    static func candidateLine(info: [String: Any]? = Bundle.main.infoDictionary) -> String? {
        func value(_ key: String) -> String {
            (info?[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        }
        let candidate = value("WSurfCandidate")
        guard !candidate.isEmpty, candidate != "dev" else { return nil }
        return [String(localized: "Candidate \(candidate)"), value("WSurfCommit")]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    /// The standard About panel, with the candidate line under the version. The panel shows its credits in a
    /// selectable text view, so the line can be copied.
    @MainActor
    static func showAboutPanel() {
        var options: [NSApplication.AboutPanelOptionKey: Any] = [:]
        if let line = candidateLine() {
            let centered = NSMutableParagraphStyle()
            centered.alignment = .center
            options[.credits] = NSAttributedString(string: line, attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: centered,
            ])
        }
        NSApp.orderFrontStandardAboutPanel(options: options)
    }
}
