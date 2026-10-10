// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import os

nonisolated enum AutofillDiagnostics {
    enum Event: String {
        case scriptReady, saveScriptReady, policyEnabled, policyDisabled, fieldSelected
        case lookupFailed, lookupCompleted, dropdownShown
        case editNoScope, editDisabled, editRecorded, submitNoEdits, submitInvalid, submitCaptured, saveOffered
        case submissionPending, submissionCompleted
    }

    private static let log = Logger(subsystem: "io.wsagency.wsurf", category: "autofill")

    static func note(_ event: Event, kind: AutofillSaveKind, count: Int = 0) {
        #if DEBUG
        log.notice("\(event.rawValue, privacy: .public) kind=\(kind.rawValue, privacy: .public) count=\(count, privacy: .public)")
        #endif
    }
}
