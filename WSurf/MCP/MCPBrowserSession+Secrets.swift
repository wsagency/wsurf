// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import MCP

/// Typing test secrets, and keeping them out of everything this connection is told.
///
/// A secret is a value the agent supplies itself (`secret: true` on `typeOnPage`, or on an item of `fillFields`) for a password,
/// one-time code or card field of the app under test. It is allowed only in the Developer tier: a paired client, a developer
/// site, a window of the Developer profile. Anywhere else the call is refused before anything is typed, and a sensitive field
/// stays the user's to fill, exactly as before. WSurf's saved passwords and autofill are never part of it: the vault is not
/// read, the field is never focused (so no suggestion list opens), and any save offer the page's form could raise is dropped.
@MainActor
extension MCPBrowserSession {
    /// The fields of one document the connection typed a secret into: refs are only meaningful for the document they came from.
    struct SecretFields {
        var documentID: String
        var refs: Set<Int>
    }

    /// What a page tool call asks to type as a secret.
    struct SecretEntry {
        /// The values, in the order the call lists them.
        var values: [String]
        /// The refs they go into.
        var refs: Set<Int>
    }

    /// The secrets `tool` would type, or nil when it types none. A malformed `secret` is the catalog's to refuse.
    static func secretEntry(tool: String, arguments: [String: Value]) -> SecretEntry? {
        switch tool {
        case "typeOnPage":
            guard arguments["secret"]?.boolValue == true, let text = arguments["text"]?.stringValue, let ref = arguments["ref"]?.intValue else { return nil }
            return SecretEntry(values: [text], refs: [ref])
        case "fillFields":
            var entry = SecretEntry(values: [], refs: [])
            for case .object(let field) in arguments["fields"]?.arrayValue ?? [] where field["secret"]?.boolValue == true {
                guard let ref = field["ref"]?.intValue, let value = field["value"]?.stringValue else { continue }
                entry.values.append(value)
                entry.refs.insert(ref)
            }
            return entry.values.isEmpty ? nil : entry
        default:
            return nil
        }
    }

    /// Why `entry` may not be typed, or nil after registering its values. Nothing is registered or typed for a refusal.
    func secretEntryRefusal(_ entry: SecretEntry, tab: BrowserTab) -> CallTool.Result? {
        guard permits(tab, capability: .developer) else {
            return failure(
                "Typing a secret needs Developer access: a paired app, a developer site, and a window of the Developer profile. Nothing was typed.")
        }
        for value in entry.values {
            switch secrets.register(value) {
            case .registered:
                continue
            case .tooShort:
                return failure("A secret must be at least \(MCPSecretScrubber.minimumBytes) characters so WSurf can keep it out of results. Nothing was typed.")
            case .tooMany:
                return failure("This connection already typed \(MCPSecretScrubber.maximumSecrets) different secrets. Disconnect to type more. Nothing was typed.")
            }
        }
        return nil
    }

    /// What a secret came to once the page had it. A form the page stored (it grouped a card number, say) is a secret too and is
    /// hidden from the agent like the value typed.
    ///
    /// The user's own records are stricter. A value is hidden there only when it went into a password, code or card field and
    /// the field kept exactly what was typed; what the page stored is hidden only when it is a known reformatting of the typed
    /// value (the same characters with spaces, dashes or dots added or removed), never some other value a page chose to put
    /// there. A phrase typed into an ordinary field is never hidden in a record. The scrubber also ignores values under
    /// `MCPSecretScrubber.minimumAuditBytes`.
    var secretWriteSink: (PageDriver.SecretWrite) -> Void {
        { [secrets] write in
            if write.stored != write.typed {
                secrets.register(write.stored)
            }
            guard write.isSensitiveField else { return }
            if write.retained {
                secrets.confirm(write.typed)
            }
            if Self.isReformatting(write.stored, of: write.typed) {
                secrets.confirm(write.stored)
            }
        }
    }

    /// Whether `stored` is `typed` with only spaces, dashes or dots added or removed, as when a page groups a card number.
    nonisolated static func isReformatting(_ stored: String, of typed: String) -> Bool {
        func characters(_ text: String) -> String {
            text.filter { !" -.".contains($0) }
        }
        return stored != typed && !characters(typed).isEmpty && characters(stored) == characters(typed)
    }

    /// The most of a control's own label that an approval record keeps.
    nonisolated static let approvalLabelLimit = 300

    /// The record of a consequential action the Developer tier let through. What identifies the action (its category, the host,
    /// the amount when the label states one) are fields of their own, which a long label cannot push out. The label is free
    /// text from the page, cleaned for a record and cut to `approvalLabelLimit`, keeping its start and its end.
    func approvalRecord(label: String, category: SensitiveAction.Category, host: String?) -> DeveloperApprovalRecord {
        let cleaned = scrubbedForAudit(label)
        return DeveloperApprovalRecord(
            date: Date(), category: category, host: host, label: Self.keepingBothEnds(cleaned, limit: Self.approvalLabelLimit),
            labelLength: cleaned.count, amount: Self.amount(in: cleaned))
    }

    /// `text` as is, or its start and its end joined by an ellipsis when it is longer than `limit` characters.
    nonisolated static func keepingBothEnds(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        let tail = (limit - 1) / 2
        return String(text.prefix(limit - 1 - tail)) + "…" + String(text.suffix(tail))
    }

    /// The first amount of money the label states ("$500", "49,90 EUR"), or nil.
    nonisolated static func amount(in label: String) -> String? {
        let pattern = #"[$€£¥]\s?\d[\d.,]*|\d[\d.,]*\s?(?:USD|EUR|GBP|CHF|JPY)\b"#
        return label.range(of: pattern, options: .regularExpression).map { String(label[$0]) }
    }

    /// After a secret went into `view`: remember which fields hold one, and make sure neither autofill nor the vault ever sees it.
    func finishSecretEntry(_ entry: SecretEntry, tab: BrowserTab, view: BrowserPage) {
        // Suggestions would offer the vault's accounts for this site, and a save offer would put the test value in it.
        AutofillSuggestions.shared.dismiss(in: view)
        tab.autofillSave.clear()
        guard let documentID = PageDriver.observation(in: view)?.documentID else { return }
        var fields = secretFields[tab.id]?.documentID == documentID ? secretFields[tab.id] : nil
        fields = SecretFields(documentID: documentID, refs: (fields?.refs ?? []).union(entry.refs))
        secretFields[tab.id] = fields
    }

    /// How a screenshot of `tab` treats filled sensitive fields: covered in the Developer tier, a refusal everywhere else.
    func screenshotMasking(for tab: BrowserTab) -> ScreenshotMasking? {
        guard permits(tab, capability: .developer) else { return nil }
        let fields = secretFields[tab.id]
        return ScreenshotMasking(secretRefs: fields?.refs ?? [], documentID: fields?.documentID)
    }

    /// The one exit of every call. A connection that ended after it typed secrets gets nothing back (its client is gone, and
    /// what the call computed may predate the wipe). Everything else is cleaned of the secrets typed so far.
    func finished(_ result: CallTool.Result) -> CallTool.Result {
        if !isConnected, secrets.wasUsed {
            return failure("Connection is unavailable. Reconnect and request access again.")
        }
        return secrets.scrub(result)
    }

    /// `text` with every secret this connection typed hidden. For text that goes back to the agent outside a tool result: a
    /// diagnostics record, a line in a change report. Never for a record of what the agent did; see `scrubbedForAudit`.
    func scrubbed(_ text: String) -> String {
        secrets.scrub(text)
    }

    /// `text` with only the values that went into a password, code or card field hidden, each marked. For the records the user
    /// reads about what the agent did (an approval it skipped, an activity entry's tab title or target): the agent chooses what
    /// it registers, so the full registry must not touch them, or registering a record's text would erase it.
    func scrubbedForAudit(_ text: String) -> String {
        secrets.scrubForAudit(text)
    }
}
