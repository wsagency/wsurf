// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation

extension PageDriver {
    /// The page's digest. Without `commit` it only reads: refs, signatures and the snapshot id stay as they are, so the digest
    /// taken before an action cannot change what the action is allowed to touch. With `commit` it is an observation, as
    /// `readPage` is: the snapshot rotates and every control gets a ref.
    static func digest(in view: BrowserPage, commit: Bool, viewportOnly: Bool) async -> PageDigest? {
        let script = scripted("return JSON.stringify(R.digest(\(viewportOnly), \(commit)));")
        guard let object = await evaluateJSON(script, in: view), object["stale"] == nil else { return nil }
        return parseDigest(object)
    }

    /// The observation after an action, taken on whatever document the page is on by then. A page that is still loading is
    /// waited for once.
    static func digestAfterAction(
        in view: BrowserPage, viewportOnly: Bool, validate: (@MainActor @Sendable () -> Bool)? = nil
    ) async -> PageDigest? {
        for attempt in 0..<2 {
            let digest = await PageAutomationGuard.rescoped(in: view, validate: validate) {
                await Self.digest(in: view, commit: true, viewportOnly: viewportOnly)
            }
            if let digest {
                return digest
            }
            guard attempt == 0, !Task.isCancelled else { return nil }
            await PageSettle.untilIdle(view)
        }
        return nil
    }

    /// The script's answer. A click or a submit can navigate before the page answers, and the answer is lost with the
    /// document: when the page was left, `fallback` stands for it. Nil when the page did not answer and was not left.
    static func evaluateAction(_ script: String, fallback: [String: Any], in view: BrowserPage) async -> [String: Any]? {
        let document = view.mainDocumentID, url = view.url
        if let answer = await evaluateJSON(script, in: view) {
            return answer
        }
        return await PageSettle.pageWasLeft(view, document: document, url: url) ? fallback : nil
    }

    /// Tells the runtime that the client has now seen the controls `pairs` name (ref and signature hash), so those refs follow
    /// the control's current state. A ref the client was not shown again keeps the signature it last saw, and is refused once
    /// its control changed.
    static func acknowledge(
        _ pairs: [(ref: Int, hash: Int)], in view: BrowserPage, validate: (@MainActor @Sendable () -> Bool)? = nil
    ) async {
        guard !pairs.isEmpty else { return }
        let list = pairs.map { "[\($0.ref),\($0.hash)]" }.joined(separator: ",")
        // The observation that listed these controls rotated the snapshot the guard may still name.
        _ = await PageAutomationGuard.rescoped(in: view, validate: validate) {
            await evaluateJSON(scripted("return JSON.stringify({ ok: R.acknowledge([\(list)]) });"), in: view)
        }
    }

    /// Records `digest` as the page's observation so its refs work on the next call. The refs earlier observations of the same
    /// document delivered stay valid; `listed` are the ones the reply gave the client now.
    static func adopt(_ digest: PageDigest, listed: Set<Int>, in view: BrowserPage) {
        observations.setObject(
            PageObservation(id: digest.snapshot, documentID: digest.documentID, url: digest.url, refs: delivered(listed, in: digest.documentID, of: view)),
            forKey: view)
    }

    static func parseDigest(_ object: [String: Any]) -> PageDigest? {
        guard let document = object["document"] as? String, let url = object["url"] as? String, let snapshot = object["snapshot"] as? String else {
            return nil
        }
        let scroll = object["scroll"] as? [String: Any] ?? [:]
        let focus = (object["focus"] as? [String: Any]).flatMap { focus -> String? in
            guard let kind = focus["k"] as? String else { return nil }
            let label = focus["l"] as? String ?? ""
            let ref = focus["r"] as? Int ?? 0
            return (ref > 0 ? "[\(ref)] " : "") + kind + (label.isEmpty ? "" : " \"\(label)\"")
        }
        return PageDigest(
            documentID: document, url: url, title: object["title"] as? String ?? "", snapshot: snapshot,
            controls: (object["controls"] as? [[String: Any]] ?? []).compactMap(parseControl),
            controlTotal: object["controlTotal"] as? Int ?? 0, texts: object["texts"] as? [String] ?? [], focus: focus,
            scrollY: scroll["y"] as? Int ?? 0, scrollHeight: scroll["h"] as? Int ?? 0, viewportHeight: scroll["vh"] as? Int ?? 0)
    }

    private static func parseControl(_ control: [String: Any]) -> PageDigest.Control? {
        guard let ref = control["r"] as? Int, let kind = control["k"] as? String else { return nil }
        let label = control["l"] as? String ?? ""
        var state = ["text": label, "disabled": control["d"] as? Int == 1 ? "true" : "false"]
        if control["s"] as? Int == 1 {
            // A sensitive field reports that it holds something, never what.
            state["filled"] = control["f"] as? Int == 1 ? "true" : "false"
        } else if kind == "field" || kind == "select" {
            state["value"] = control["v"] as? String ?? ""
        }
        if let checked = control["c"] as? Int { state["checked"] = checked == 1 ? "true" : "false" }
        if let expanded = control["expanded"] as? String { state["expanded"] = expanded }
        if let pressed = control["pr"] as? Int { state["pressed"] = pressed == 1 ? "true" : "false" }
        if let selected = control["se"] as? Int { state["selected"] = selected == 1 ? "true" : "false" }
        return PageDigest.Control(
            ref: ref, kind: kind, label: label, state: state, inViewport: control["vp"] as? Bool ?? false, line: renderControl(control),
            signature: control["sg"] as? Int ?? 0)
    }
}
