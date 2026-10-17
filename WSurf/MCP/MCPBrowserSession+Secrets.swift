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

    /// What a field holds after a secret went in, when a page changed it (it formatted a card number, say): that form is a
    /// secret too, and is hidden like the value that was typed.
    var storedSecretSink: (String) -> Void {
        { [secrets] stored in
            secrets.register(stored)
        }
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

    /// `text` with this connection's secrets hidden. For anything that carries page content outside a tool result before it
    /// is stored or shown: an activity entry's tab title or target, a diagnostics record, a line in a change report.
    func scrubbed(_ text: String) -> String {
        secrets.scrub(text)
    }
}
