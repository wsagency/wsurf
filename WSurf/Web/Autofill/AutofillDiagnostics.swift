// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import os
import WebKit

nonisolated enum AutofillDiagnostics {
    nonisolated enum Event: String, Sendable {
        case scriptReady, saveScriptReady, policyEnabled, policyDisabled, fieldSelected
        case lookupFailed, lookupCompleted, dropdownShown
        case editNoScope, editDisabled, editRecorded, submitNoEdits, submitInvalid, submitCaptured, saveOffered
        case submissionPending, submissionCompleted
        // Why a save offer did not appear. The tab-side reasons are native, the capture reasons come from the page script.
        case offerDroppedNotLive, offerDroppedAmbiguous, offerDroppedBlocked, offerDroppedDismissed, offerDroppedUnchanged
        case attemptExpired, completionBlockedByField, stageDroppedUnknownDocument
        case captureAbandonedByLink, captureUnsafeAction
        // Generate Password…: its sheet opened, it refused the field, the new login was saved, the password was filled.
        case generatorShown, generatorRefused, generatorSaved, generatorFilled
        // Why nothing was offered for a field or a right-click (`refused(_:by:)`, logged in release builds too). `formUnsafe`, `formShape`,
        // `notVisible` and `disabled` come from the page script (`Event(skipReason:)`), the rest are native.
        case insecurePage, agentControlled, disabled, noOriginMatch, formUnsafe, formShape, notVisible, rectRefused
        // menuNotEditable also fires for a right-click on a link or the page itself: the engine only says the point is not editable.
        case frameNotTrusted, menuNotEditable, menuNotOffered
    }

    private static let log = Logger(subsystem: "io.wsagency.wsurf", category: "autofill")
    private static let limiter = OSAllocatedUnfairLock(initialState: RefusalLimiter())

    /// Why `offerOrigin` gave no dropdown, in the order it checks, or nil when nothing refuses. Mirrors that guard chain; the inputs are
    /// booleans so that nothing about the page (address, host) is ever at hand here.
    static func offerRefusal(
        enabled: Bool, topIsSecure: Bool, hasOnlySecureContent: Bool, agentControlled: Bool, frameOriginTrusted: Bool
    ) -> Event? {
        if !enabled {
            return .disabled
        }
        if !topIsSecure || !hasOnlySecureContent {
            return .insecurePage
        }
        if agentControlled {
            return .agentControlled
        }
        return frameOriginTrusted ? nil : .frameNotTrusted
    }

    /// Why a right-click menu has no usable Pick Credential… item, or nil when it has one. `refusal` is the picker's own reason for a
    /// disabled item (`CredentialPicker.refusal`), the one source of agent control and the not-fully-secure page.
    static func menuRefusal(editable: Bool, offered: Bool, refusal: CredentialPicker.Refusal?) -> Event? {
        guard editable else {
            return .menuNotEditable
        }
        if offered {
            return nil
        }
        switch refusal {
        case .agentControl:
            return .agentControlled
        case .insecurePage:
            return .insecurePage
        case nil:
            return .menuNotOffered
        }
    }

    /// Logs why nothing was offered, at `.info`, in every build: only the event's fixed name and a count, never an address, host, field,
    /// value or page text. At most `RefusalLimiter.limit` lines per `owner` (a page or its view) per window, so a page that keeps
    /// focusing fields cannot fill the log; the count says how many lines the last window dropped. Returns whether a line was logged.
    @discardableResult
    static func refused(_ event: Event, by owner: AnyObject, now: ContinuousClock.Instant = .now) -> Bool {
        let key = ObjectIdentifier(owner)
        guard let suppressed = limiter.withLock({ $0.admit(key, event, at: now) }) else { return false }
        log.info("refused reason=\(event.rawValue, privacy: .public) suppressed=\(suppressed, privacy: .public)")
        return true
    }

    /// A page script's `skip`: logged when its reason is on the allow-list, dropped otherwise. Returns the event that was logged.
    @discardableResult
    static func pageSkipped(_ reason: Any?, by owner: AnyObject) -> Event? {
        guard let event = Event(skipReason: reason), refused(event, by: owner) else { return nil }
        return event
    }

    /// Budget for `refused`, per owner and reason: `limit` lines per `window`, the rest counted and reported with the next window's first line.
    nonisolated struct RefusalLimiter: Sendable {
        static let limit = 10
        static let window: Duration = .seconds(60)
        static let capacity = 256
        private struct Key: Hashable, Sendable {
            let owner: ObjectIdentifier
            let event: Event
        }
        private struct Entry: Sendable {
            var start: ContinuousClock.Instant
            var logged = 1
            var suppressed = 0
        }
        private var entries: [Key: Entry] = [:]
        var trackedCount: Int {
            entries.count
        }

        /// How many lines were dropped since the last one that was logged (0 usually), or nil when this one is over budget.
        mutating func admit(_ owner: ObjectIdentifier, _ event: Event, at now: ContinuousClock.Instant) -> Int? {
            let key = Key(owner: owner, event: event)
            if var entry = entries[key], now < entry.start.advanced(by: Self.window) {
                guard entry.logged < Self.limit else {
                    entry.suppressed += 1
                    entries[key] = entry
                    return nil
                }
                entry.logged += 1
                entries[key] = entry
                return 0
            }
            let carried = entries[key]?.suppressed ?? 0
            // ponytail: a full table drops the expired windows, then all of them; this is only a log budget.
            if entries.count >= Self.capacity {
                entries = entries.filter { now < $0.value.start.advanced(by: Self.window) }
            }
            if entries.count >= Self.capacity {
                entries = [:]
            }
            entries[key] = Entry(start: now)
            return carried
        }
    }

    enum PolicyOperation: String {
        case password, save
    }

    static func policyFailed(_ operation: PolicyOperation, error: any Error, isMainFrame: Bool) {
        #if DEBUG
        let failure = error as NSError
        let webKit = failure.domain == WKError.errorDomain
        // Exception messages can contain page text or URLs. Log only a known
        // exception class and the numeric error code, never the message or domain.
        let message = failure.userInfo["WKJavaScriptExceptionMessage"] as? String ?? ""
        let exception = ["SecurityError", "TypeError", "ReferenceError", "SyntaxError", "InvalidStateError"]
            .first { message.hasPrefix($0 + ":") } ?? "other"
        log.error("""
        policyFailed operation=\(operation.rawValue, privacy: .public) webKit=\(webKit, privacy: .public) \
        code=\(failure.code, privacy: .public) exception=\(exception, privacy: .public) mainFrame=\(isMainFrame, privacy: .public)
        """)
        #endif
    }

    static func note(_ event: Event, kind: AutofillSaveKind, count: Int = 0) {
        #if DEBUG
        switch event {
        case .scriptReady, .saveScriptReady:
            // Once per page load, always count=0: 5.5k lines per test run at notice level.
            log.debug("\(event.rawValue, privacy: .public) kind=\(kind.rawValue, privacy: .public) count=\(count, privacy: .public)")
        default:
            log.notice("\(event.rawValue, privacy: .public) kind=\(kind.rawValue, privacy: .public) count=\(count, privacy: .public)")
        }
        #endif
    }
}

extension AutofillDiagnostics.Event {
    /// The reasons the page script may report in `{action:'skip', reason}`: an allow-list, so a reason the page invents, or one only
    /// native can know, never reaches the log.
    nonisolated init?(skipReason raw: Any?) {
        switch raw as? String {
        case "formUnsafe":
            self = .formUnsafe
        case "formShape":
            self = .formShape
        case "notVisible":
            self = .notVisible
        case "disabled":
            self = .disabled
        default:
            return nil
        }
    }
}

extension AutofillSuggestions {
    /// The field's rectangle could not be placed (hidden frame, a field off the viewport or too small), while its request was still
    /// the current one. Logs the reason only.
    func noteRectRefused(in page: BrowserPage?, context: BrowserProfileContext, presentation id: UUID) {
        guard let page, page.context === context, id == presentationID else { return }
        AutofillDiagnostics.refused(.rectRefused, by: page)
    }

    /// A login lookup that found nothing to show: no login saved for the site's exact origin (a locked vault with no unlock row, or
    /// no vault, looks the same). Logs the reason only.
    func noteNoRows(
        _ rows: [AutofillSuggestion], kind: AutofillSaveKind, in page: BrowserPage, context: BrowserProfileContext, presentation id: UUID
    ) {
        guard kind == .password, rows.isEmpty, page.context === context, id == presentationID else { return }
        AutofillDiagnostics.refused(.noOriginMatch, by: page)
    }
}
