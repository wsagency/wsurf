// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import WebKit

extension PageDriver {
    static func valueState(ref: Int, documentID: String?, in view: BrowserPage) async -> String {
        guard let documentID, let encoded = jsonString(documentID) else { return "unverified" }
        let object = await evaluateJSON(scripted("""
            if (R.documentID !== \(encoded)) return JSON.stringify({ state: 'unverified' });
            return JSON.stringify({ state: R.valueState(\(ref)) });
            """), in: view)
        return object?["state"] as? String ?? "unverified"
    }

    /// - Parameter knownRetained: The caller already checked the value where it was written, which the runtime cannot do for a
    ///   sensitive field (it never reads one back).
    static func finishValueAction(
        status: String, ref: Int, documentID: String?, submissionRequested: Bool = false, knownRetained: Bool = false,
        refreshControls: Bool, in view: BrowserPage
    ) async -> String {
        if refreshControls {
            await PageSettle.afterInteraction(view)
        } else {
            await PageSettle.untilQuiet(view, ceiling: .milliseconds(350))
        }
        let state = submissionRequested || knownRetained ? "matched" : await valueState(ref: ref, documentID: documentID, in: view)
        let result: String
        switch state {
        case "matched":
            result = status
        case "mismatch":
            result = "The page did not retain the requested value. Inspect validation messages before retrying."
        default:
            result = "Could not verify the field value after the page changed. Inspect the current page before retrying."
        }
        guard refreshControls, feedbackMode == .snapshot else { return result }
        return result + " " + (await PageAutomationGuard.withCurrentDocument(in: view) { await snapshot(view) })
    }
}
