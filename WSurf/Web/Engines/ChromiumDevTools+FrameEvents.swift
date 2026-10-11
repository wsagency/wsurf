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
        switch name {
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
        let documentID = framesByID[frameID]?.documentID ?? ""
        contextsByUniqueID[uniqueID] = ContextState(executionID: executionID, uniqueID: uniqueID,
                                                     frameID: frameID, worldName: worldName,
                                                     documentID: documentID)
        uniqueIDByExecutionID[executionID] = uniqueID
    }

    private func bindingCalled(_ params: [String: Any]) {
        guard let name = params["name"] as? String, name == "__wsurfSend",
              let payload = params["payload"] as? String,
              payload.utf8.count <= maxBindingPayload,
              let executionID = params["executionContextId"] as? Int,
              let uniqueID = uniqueIDByExecutionID[executionID],
              let context = contextsByUniqueID[uniqueID],
              let current = framesByID[context.frameID],
              current.documentID == context.documentID else { return }
        guard let pair = try? Self.jsonObject(Data(payload.utf8)) as? [Any], pair.count == 2,
              let handlerName = pair[0] as? String, !handlerName.isEmpty, handlerName.utf8.count <= 256 else { return }
        guard let handler = handlers[HandlerKey(name: handlerName, worldName: context.worldName)],
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
            }
            invalidateCredentialContexts(documents: retired, pageWide: parsed.isMainFrame && !old.documentID.isEmpty)
        }
        if restoredFromCache {
            // Cached contexts are replayed before the restored frame's navigation event.
            var index = contextsByUniqueID.startIndex
            while index != contextsByUniqueID.endIndex {
                if contextsByUniqueID[index].value.frameID == parsed.id {
                    contextsByUniqueID.values[index].documentID = parsed.documentID
                }
                contextsByUniqueID.formIndex(after: &index)
            }
        }
        if !parsed.documentID.isEmpty {
            page?.didNavigate(frame: parsed.browserFrame, restoredFromCache: restoredFromCache)
        }
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
        if let existing = contextsByUniqueID.values.first(where: {
            $0.frameID == frameID && $0.documentID == frame.documentID && $0.worldName == name
        }) { return existing }
        guard !name.isEmpty else { throw ChromiumError.unavailable("Chromium page context is not ready.") }
        let response = try await command("Page.createIsolatedWorld", params: [
            "frameId": frameID, "worldName": name, "grantUniveralAccess": false,
        ])
        guard let executionID = response["executionContextId"] as? Int,
              let uniqueID = uniqueIDByExecutionID[executionID],
              let created = contextsByUniqueID[uniqueID], created.frameID == frameID,
              created.documentID == frame.documentID else {
            throw ChromiumError.unavailable("Chromium isolated world context is not ready.")
        }
        return created
    }

    func setDocumentMarker(contextID: String, documentID: String) async throws {
        guard let context = contextsByUniqueID[contextID], !context.markerSet else { return }
        let response = try await command("Runtime.evaluate", params: [
            "expression": "void Object.defineProperty(globalThis, '__wsurfFrameDocumentID', {value: \(jsonLiteral(documentID)), writable: false, configurable: false, enumerable: false});",
            "uniqueContextId": contextID, "returnByValue": true,
        ])
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
            let description = exception["text"] as? String ?? "JavaScript evaluation failed."
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
                          isMainFrame: parentID == nil)
    }

}
private extension URL {
    var originString: String {
        guard let scheme, let host else { return "" }
        return "\(scheme)://\(host)\(port.map { ":\($0)" } ?? "")"
    }
}
