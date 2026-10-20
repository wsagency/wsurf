// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import WebKit

extension ChromiumDevTools {
    func receiveEvent(name: String, pointer: UnsafeRawPointer?, size: Int) {
        guard !closed, size <= 8 * 1_048_576 else { return }
        let params: [String: Any]
        if size == 0 {
            params = [:]
        } else {
            guard let value = try? Self.jsonObject(pointer, size: size) as? [String: Any] else { return }
            params = value
        }
        if let diagnosticsSink, Self.diagnosticEvents.contains(name) {
            diagnosticsSink(name, params)
        }
        switch name {
        // Runtime events arrive only while a diagnostics capture enables the domain.
        case "Runtime.executionContextCreated":
            contextCreated(params)
        case "Runtime.executionContextDestroyed":
            if let executionID = params["executionContextId"] as? Int, let documentID = removeContexts(executionID: executionID) {
                invalidateCredentialContexts(documents: [documentID], pageWide: false)
            }
        case "Runtime.executionContextsCleared":
            let hadContexts = !contextsByUniqueID.isEmpty
            contextsByUniqueID.removeAll()
            uniqueIDByExecutionID.removeAll()
            if hadContexts {
                invalidateCredentialContexts(documents: [], pageWide: true)
            }
        case "Runtime.bindingCalled":
            bindingCalled(params)
        case "Page.frameNavigated":
            frameNavigated(params)
        case "Page.frameDetached":
            frameDetached(params)
        case "Network.responseReceived":
            documentResponseReceived(params)
        case "Security.securityStateChanged":
            if let state = params["securityState"] as? String {
                page?.didChangeSecurity(state == "secure")
            }
        case "Security.visibleSecurityStateChanged":
            if let visible = params["visibleSecurityState"] as? [String: Any],
               let state = visible["securityState"] as? String {
                page?.didChangeSecurity(state == "secure")
            }
        default:
            break
        }
    }

    private static let diagnosticEvents: Set<String> = [
        "Runtime.consoleAPICalled", "Runtime.exceptionThrown", "Network.requestWillBeSent", "Network.responseReceived",
        "Network.loadingFinished", "Network.loadingFailed", "Network.requestWillBeSentExtraInfo", "Network.responseReceivedExtraInfo",
    ]

    private func documentResponseReceived(_ params: [String: Any]) {
        guard params["type"] as? String == "Document",
              let frameID = params["frameId"] as? String,
              let loaderID = params["loaderId"] as? String,
              let response = params["response"] as? [String: Any],
              let address = response["url"] as? String, let url = URL(string: address),
              let status = response["status"] as? Int,
              let fields = response["headers"] as? [String: Any] else { return }
        var headers = fields.reduce(into: [String: String]()) { headers, field in
            headers[field.key.lowercased()] = String(describing: field.value)
        }
        if headers["content-type"] == nil, let mime = response["mimeType"] as? String, !mime.isEmpty {
            headers["content-type"] = mime
        }
        guard let confirmation = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers),
              let current = page?.client?.documentResponses.confirm(confirmation, frameID: frameID, loaderID: loaderID)
        else { return }
        page?.didReceiveMainFrameResponse(current)
    }

    private func contextCreated(_ params: [String: Any]) {
        guard let context = params["context"] as? [String: Any],
              let executionID = context["id"] as? Int,
              let uniqueID = context["uniqueId"] as? String, !uniqueID.isEmpty,
              let aux = context["auxData"] as? [String: Any],
              let frameID = aux["frameId"] as? String else { return }
        let isDefault = aux["isDefault"] as? Bool ?? false
        let worldName = isDefault ? "" : (context["name"] as? String ?? "")
        guard isDefault || !worldName.isEmpty else { return }
        // A context `isolatedContext` already recorded keeps its record, binding and marker state.
        if let known = uniqueIDByExecutionID[executionID].flatMap({ contextsByUniqueID[$0] }),
           known.frameID == frameID, known.worldName == worldName { return }
        let documentID = framesByID[frameID]?.documentID ?? ""
        contextsByUniqueID[uniqueID] = ContextState(executionID: executionID, uniqueID: uniqueID,
                                                     frameID: frameID, worldName: worldName,
                                                     documentID: documentID, fromRuntimeEvent: true)
        uniqueIDByExecutionID[executionID] = uniqueID
    }

    private func bindingCalled(_ params: [String: Any]) {
        guard let name = params["name"] as? String, name == Self.nativeBinding,
              let payload = params["payload"] as? String,
              payload.utf8.count <= maxBindingPayload,
              let executionID = params["executionContextId"] as? Int,
              let uniqueID = uniqueIDByExecutionID[executionID],
              let context = contextsByUniqueID[uniqueID],
              let current = framesByID[context.frameID],
              current.documentID == context.documentID else { return }
        guard let pair = try? Self.jsonObject(Data(payload.utf8)) as? [Any], pair.count == 2,
              let handlerName = pair[0] as? String, !handlerName.isEmpty, handlerName.utf8.count <= 256 else { return }
        // Only the page bridge forwards page-world messages, and only to page-world handlers.
        let world = context.worldName == Self.pageBridgeWorld ? "" : context.worldName
        guard let handler = handlers[HandlerKey(name: handlerName, worldName: world)],
              let owner = page?.owner else { return }
        let body = pair[1]
        handler(BrowserScriptMessage(page: owner, body: body, frameInfo: current.browserFrame, name: handlerName))
    }

    private func frameNavigated(_ params: [String: Any]) {
        guard let frame = params["frame"] as? [String: Any], let parsed = parseFrame(frame, parentID: frame["parentId"] as? String) else { return }
        let restoredFromCache = params["type"] as? String == "BackForwardCacheRestore"
        let old = framesByID[parsed.id]
        frameRevision &+= 1
        framesByID[parsed.id] = parsed
        if let old, old.documentID != parsed.documentID {
            let retired = [old.documentID] + retireDescendants(parentID: parsed.id)
            if !restoredFromCache {
                removeContexts(frameID: parsed.id)
            } else {
                // Contexts `isolatedContext` found belong to the document that left; the restored one's are found again.
                removeContexts(frameID: parsed.id) { !$0.fromRuntimeEvent }
            }
            invalidateCredentialContexts(documents: retired, pageWide: parsed.isMainFrame && !old.documentID.isEmpty)
        }
        if restoredFromCache {
            // While a diagnostics capture enables the Runtime domain, cached contexts are replayed before the restored
            // frame's navigation event.
            var index = contextsByUniqueID.startIndex
            while index != contextsByUniqueID.endIndex {
                if contextsByUniqueID[index].value.frameID == parsed.id {
                    contextsByUniqueID.values[index].documentID = parsed.documentID
                }
                contextsByUniqueID.formIndex(after: &index)
            }
        }
        if !parsed.documentID.isEmpty {
            // The page's own commit work (the startup history reset) goes first; binding sends renderer round trips.
            page?.didNavigate(frame: parsed.browserFrame, restoredFromCache: restoredFromCache)
            bindDocument(frameID: parsed.id, documentID: parsed.documentID)
            if restoredFromCache, parsed.isMainFrame {
                bindRestoredSubframes(of: parsed.id)
            }
        }
    }

    /// A page restored from the cache reports only its main frame; its frames come back with it and are bound from the tree.
    private func bindRestoredSubframes(of mainFrameID: String) {
        Task { [weak self] in
            guard let self, (try? await frames()) != nil, !closed else { return }
            for frame in framesByID.values where frame.parentID != nil && !frame.documentID.isEmpty {
                bindDocument(frameID: frame.id, documentID: frame.documentID)
            }
        }
    }

    /// Binds the new document's isolated worlds, so the messages their document-start scripts queued reach native.
    private func bindDocument(frameID: String, documentID: String) {
        let worlds = bindingWorlds.filter { !$0.isEmpty }.sorted()
        guard !worlds.isEmpty else { return }
        Task { [weak self] in
            for world in worlds {
                guard let self, !self.closed, self.framesByID[frameID]?.documentID == documentID else { return }
                _ = try? await self.isolatedContext(frameID: frameID, documentID: documentID, worldName: world)
            }
        }
    }

    /// Every document and execution context is gone (renderer exit, DevTools detach). The next renderer can reuse
    /// numeric context IDs, so no record may survive.
    func forgetDocuments() {
        frameRevision &+= 1
        framesByID.removeAll()
        contextsByUniqueID.removeAll()
        uniqueIDByExecutionID.removeAll()
    }

    private func frameDetached(_ params: [String: Any]) {
        guard let frameID = params["frameId"] as? String else { return }
        frameRevision &+= 1
        var removed = Set([frameID])
        var changed = true
        while changed {
            changed = false
            for frame in framesByID.values where frame.parentID.map(removed.contains) == true && removed.insert(frame.id).inserted {
                changed = true
            }
        }
        let wasMain = framesByID[frameID]?.isMainFrame == true
        let documents = removed.compactMap { framesByID[$0]?.documentID }
        for id in removed {
            framesByID.removeValue(forKey: id)
            removeContexts(frameID: id)
        }
        invalidateCredentialContexts(documents: documents, pageWide: wasMain)
    }

    func targetFrame(_ requested: BrowserFrame?) async throws -> BrowserFrame {
        let current = try await frames()
        if let requested {
            guard let id = requested.chromiumID,
                  !requested.documentID.isEmpty,
                  let match = current.first(where: { $0.chromiumID == id && $0.documentID == requested.documentID
                      && $0.securityOrigin == requested.securityOrigin }) else { throw ChromiumError.staleFrame }
            return match
        }
        guard let main = current.first(where: \.isMainFrame) else { throw ChromiumError.unavailable("Chromium has no main frame.") }
        return main
    }

    func context(for frame: BrowserFrame, world: WKContentWorld) async throws -> ContextState {
        guard let frameID = frame.chromiumID, !frame.documentID.isEmpty,
              let state = framesByID[frameID], state.documentID == frame.documentID else {
            throw ChromiumError.staleFrame
        }
        let name = worldName(world)
        guard name.isEmpty else {
            return try await isolatedContext(frameID: frameID, documentID: frame.documentID, worldName: name)
        }
        if let existing = contextsByUniqueID.values.first(where: {
            $0.frameID == frameID && $0.documentID == frame.documentID && $0.worldName.isEmpty
        }) { return existing }
        // Without the Runtime domain the main frame's main world is Chromium's default context. A subframe's main world is
        // reached through an object of it: unlike a context ID, an object ID names its renderer process, so a call made
        // with it never reaches another document.
        let uniqueID = "\(frameID)/\(frame.documentID)/page"
        var context = ContextState(executionID: 0, uniqueID: uniqueID, frameID: frameID, worldName: "",
                                   documentID: frame.documentID)
        if !state.isMainFrame {
            context.objectID = try await mainWorldDocument(frameID: frameID, documentID: frame.documentID)
        }
        contextsByUniqueID[uniqueID] = context
        return context
    }

    /// The subframe's `document` as an object of its main world: found from WSurf's isolated world (whose context ID is
    /// guarded by origin), as the node it names, resolved in the frame's main world.
    private func mainWorldDocument(frameID: String, documentID: String) async throws -> String {
        let isolated = try await isolatedContext(frameID: frameID, documentID: documentID, worldName: Self.pageBridgeWorld)
        let found = try await command("Runtime.evaluate", params: address(isolated).merging([
            "expression": documentGuard(isolated, marker: false) + "document", "returnByValue": false,
        ]) { $1 })
        _ = try runtimeValue(found)
        guard let isolatedDocument = (found["result"] as? [String: Any])?["objectId"] as? String else {
            throw ChromiumError.unavailable("Chromium page context is not ready.")
        }
        let node = try await command("DOM.describeNode", params: ["objectId": isolatedDocument])
        guard let backendNodeID = (node["node"] as? [String: Any])?["backendNodeId"] as? Int else {
            throw ChromiumError.unavailable("Chromium page context is not ready.")
        }
        let resolved = try await command("DOM.resolveNode", params: ["backendNodeId": backendNodeID])
        guard let objectID = (resolved["object"] as? [String: Any])?["objectId"] as? String else {
            throw ChromiumError.unavailable("Chromium page context is not ready.")
        }
        guard framesByID[frameID]?.documentID == documentID else { throw ChromiumError.staleFrame }
        return objectID
    }

    /// The context of `worldName` in the frame's `documentID`, recorded before a binding world's context is bound, so
    /// every message names a known frame and document. A context ID is unique only within its renderer process, so the
    /// record's key also names the frame and document.
    func isolatedContext(frameID: String, documentID: String, worldName: String) async throws -> ContextState {
        var context: ContextState
        if let existing = contextsByUniqueID.values.first(where: {
            $0.frameID == frameID && $0.documentID == documentID && $0.worldName == worldName
        }) {
            context = existing
        } else {
            let response = try await command("Page.createIsolatedWorld", params: [
                "frameId": frameID, "worldName": worldName, "grantUniveralAccess": false,
            ])
            guard !closed, let executionID = response["executionContextId"] as? Int else {
                throw ChromiumError.unavailable("Chromium isolated world context is not ready.")
            }
            // A navigation reported meanwhile means the ID may belong to the next document.
            guard framesByID[frameID]?.documentID == documentID else { throw ChromiumError.staleFrame }
            if let known = uniqueIDByExecutionID[executionID].flatMap({ contextsByUniqueID[$0] }),
               known.frameID == frameID, known.documentID == documentID, known.worldName == worldName {
                context = known
            } else {
                if let stale = uniqueIDByExecutionID[executionID] {
                    contextsByUniqueID.removeValue(forKey: stale)
                }
                context = ContextState(executionID: executionID, uniqueID: "\(frameID)/\(documentID)/\(worldName)/\(executionID)",
                                       frameID: frameID, worldName: worldName, documentID: documentID)
                contextsByUniqueID[context.uniqueID] = context
                uniqueIDByExecutionID[executionID] = context.uniqueID
            }
        }
        guard bindingWorlds.contains(worldName), !context.bound else { return context }
        // A context ID reused by another renderer after a commit not yet reported would get the binding without the shim:
        // messages from it are refused, but its global would show. The check narrows that to the commit itself.
        let candidate = context
        _ = try await command("Runtime.addBinding", params: [
            "name": Self.nativeBinding, "executionContextId": context.executionID,
        ], dispatchCheck: { [self] in
            guard contextIsLive(candidate) else { throw ChromiumError.staleFrame }
        })
        // A context without the shim (its document predates the world's registration) answers false and stays silent. The
        // guard keeps a context of another origin that reuses the ID from ever attaching.
        _ = try runtimeValue(try await command("Runtime.evaluate", params: address(context).merging([
            "expression": documentGuard(context, marker: false) + "globalThis.__wsurfAttach?.() === true", "returnByValue": true,
        ]) { $1 }))
        guard contextIsLive(context) else { throw ChromiumError.staleFrame }
        context.bound = true
        contextsByUniqueID[context.uniqueID]?.bound = true
        return context
    }

    /// `Runtime.evaluate` parameters that address `context`. ID 0 is the main frame's default context, which Chromium
    /// uses when none is named.
    func address(_ context: ContextState) -> [String: Any] {
        context.executionID == 0 ? [:] : ["contextId": context.executionID]
    }

    /// Prefixed to every evaluation: it runs only in the document it is aimed at. A context ID is unique only within its
    /// renderer process and the next one counts from 1 again, so a script dispatched while a navigation commits in another
    /// process could otherwise reach a different document, even its main world. A page cannot redefine `location.origin`
    /// and never sees the marker's value (the loader ID). `marker: false` is for the call that sets the marker.
    func documentGuard(_ context: ContextState, marker: Bool = true) -> String {
        var stale: [String] = []
        if let origin = framesByID[context.frameID]?.serializedOrigin {
            stale.append("location.origin !== \(jsonLiteral(origin))")
        }
        if marker, !context.worldName.isEmpty {
            stale.append("globalThis.__wsurfFrameDocumentID !== \(jsonLiteral(context.documentID))")
        }
        guard !stale.isEmpty else { return "" }
        return "if (\(stale.joined(separator: " || "))) throw \(jsonLiteral(Self.staleDocument));\n"
    }

    static let staleDocument = "wsurf:stale-document"

    func setDocumentMarker(contextID: String, documentID: String) async throws {
        guard let context = contextsByUniqueID[contextID], !context.markerSet else { return }
        let response = try await command("Runtime.evaluate", params: address(context).merging([
            "expression": documentGuard(context, marker: false)
                + "void Object.defineProperty(globalThis, '__wsurfFrameDocumentID', {value: \(jsonLiteral(documentID)), writable: false, configurable: false, enumerable: false});",
            "returnByValue": true,
        ]) { $1 })
        _ = try runtimeValue(response)
        guard var current = contextsByUniqueID[contextID],
              current.documentID == context.documentID,
              framesByID[current.frameID]?.documentID == context.documentID else {
            throw ChromiumError.staleFrame
        }
        current.markerSet = true
        contextsByUniqueID[contextID] = current
    }

    func runtimeValue(_ response: [String: Any]) throws -> Any {
        guard let result = response["result"] as? [String: Any] else {
            throw ChromiumError.protocolFailure("Runtime.evaluate returned no result.")
        }
        if let exception = response["exceptionDetails"] as? [String: Any] {
            if (exception["exception"] as? [String: Any])?["value"] as? String == Self.staleDocument {
                throw ChromiumError.staleFrame
            }
            // `text` is only "Uncaught"; the thrown object says what happened, for a compile error the SyntaxError and its message.
            let thrown = (exception["exception"] as? [String: Any])?["description"] as? String
            let description = thrown?.split(separator: "\n").first.map(String.init) ?? exception["text"] as? String ?? "JavaScript evaluation failed."
            throw ChromiumError.protocolFailure(description)
        }
        if result["type"] as? String == "undefined" { return NSNull() }
        if let value = result["value"] { return value }
        if let serialized = result["unserializableValue"] as? String { return serialized }
        return NSNull()
    }

    func contextIsLive(_ context: ContextState) -> Bool {
        guard let current = contextsByUniqueID[context.uniqueID], let frame = framesByID[context.frameID] else { return false }
        return current.documentID == context.documentID && frame.documentID == context.documentID
    }

    func updateFrames(_ parsed: [String: FrameState]) {
        frameRevision &+= 1
        var retired: [String] = []
        var pageWide = false
        for (id, old) in framesByID where !old.documentID.isEmpty && parsed[id]?.documentID != old.documentID {
            retired.append(old.documentID)
            pageWide = pageWide || old.isMainFrame
        }
        framesByID = parsed
        let staleContexts = contextsByUniqueID.compactMap { uniqueID, context -> (String, Int)? in
            guard let frame = parsed[context.frameID] else { return (uniqueID, context.executionID) }
            if context.documentID.isEmpty {
                return nil
            }
            return context.documentID == frame.documentID ? nil : (uniqueID, context.executionID)
        }
        for (uniqueID, executionID) in staleContexts {
            if let documentID = contextsByUniqueID[uniqueID]?.documentID {
                retired.append(documentID)
            }
            contextsByUniqueID.removeValue(forKey: uniqueID)
            uniqueIDByExecutionID.removeValue(forKey: executionID)
        }
        let documentUpdates = contextsByUniqueID.compactMap { uniqueID, context -> (String, ContextState)? in
            guard context.documentID.isEmpty, let frame = parsed[context.frameID] else { return nil }
            var updated = context
            updated.documentID = frame.documentID
            return (uniqueID, updated)
        }
        for (uniqueID, context) in documentUpdates {
            contextsByUniqueID[uniqueID] = context
        }
        invalidateCredentialContexts(documents: retired, pageWide: pageWide)
    }

    func parseFrameTree(_ tree: [String: Any], parentID: String?, into result: inout [String: FrameState]) {
        guard let frame = tree["frame"] as? [String: Any], let parsed = parseFrame(frame, parentID: parentID) else { return }
        result[parsed.id] = parsed
        if let children = tree["childFrames"] as? [[String: Any]] {
            for child in children {
                parseFrameTree(child, parentID: parsed.id, into: &result)
            }
        }
    }

    func parseFrame(_ frame: [String: Any], parentID: String?) -> FrameState? {
        guard let id = frame["id"] as? String, !id.isEmpty,
              let urlString = frame["url"] as? String else { return nil }
        let url = URL(string: urlString) ?? URL(string: "about:blank")!
        let protocolOrigin = frame["securityOrigin"] as? String
        let originURL = URL(string: protocolOrigin ?? url.originString)
        let origin = originURL.map(BrowserSecurityOrigin.init(url:)) ?? BrowserSecurityOrigin(url: url)
        // Credentials only trust the origin Chromium itself reported, and only for a real web origin.
        let trustedOrigin = protocolOrigin != nil
            && ["http", "https"].contains(origin.protocol)
            && !origin.host.isEmpty
            && originURL?.host?.caseInsensitiveCompare(origin.host) == .orderedSame
        return FrameState(id: id, parentID: parentID, documentID: frame["loaderId"] as? String ?? "",
                          url: url, securityOrigin: origin, hasTrustedSecurityOrigin: trustedOrigin,
                          isMainFrame: parentID == nil, serializedOrigin: trustedOrigin ? protocolOrigin : nil)
    }

}
private extension URL {
    var originString: String {
        guard let scheme, let host else { return "" }
        return "\(scheme)://\(host)\(port.map { ":\($0)" } ?? "")"
    }
}
