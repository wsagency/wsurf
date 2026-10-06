// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CCef
import Foundation
import WebKit

@MainActor
final class ChromiumDevTools {
    private weak var page: ChromiumPage?
    private var host: UnsafeMutablePointer<cef_browser_host_t>?
    private var observer: UnsafeMutablePointer<cef_dev_tools_message_observer_t>?
    private var registration: UnsafeMutablePointer<cef_registration_t>?
    private var nextMessageID = 1
    private var pending: [Int: PendingCommand] = [:]
    private var timeouts: [Int: Task<Void, Never>] = [:]
    private var closed = false
    private var prepared = false
    private var preparing = false
    private var prepareWaiters: [CheckedContinuation<Void, Error>] = []

    private struct FrameState {
        let id: String
        let parentID: String?
        let documentID: String
        let url: URL
        let securityOrigin: BrowserSecurityOrigin
        let isMainFrame: Bool
        var browserFrame: BrowserFrame {
            BrowserFrame(id: id, documentID: documentID, url: url,
                         isMainFrame: isMainFrame, securityOrigin: securityOrigin)
        }
    }

    private struct ContextState {
        let executionID: Int
        let uniqueID: String
        let frameID: String
        let worldName: String
        var documentID: String
        var markerSet = false
    }

    @MainActor
    private final class CommandResult {
        var value: [String: Any]?
    }

    private struct PendingCommand {
        let continuation: CheckedContinuation<Void, Error>
        let result: CommandResult
    }

    private struct Script {
        let source: String
        let worldName: String
        let injectionTime: WKUserScriptInjectionTime
        let mainFrameOnly: Bool
    }

    private struct HandlerKey: Hashable {
        let name: String
        let worldName: String
    }

    private typealias Handler = (BrowserScriptMessage) -> Void

    private var framesByID: [String: FrameState] = [:]
    private var contextsByUniqueID: [String: ContextState] = [:]
    private var uniqueIDByExecutionID: [Int: String] = [:]
    private var scripts: [Script] = []
    private var handlers: [HandlerKey: Handler] = [:]
    private var bindingWorlds: Set<String> = []

    private let commandTimeout: Duration = .seconds(15)
    private let maxBindingPayload = 1_048_576

    init(page: ChromiumPage) {
        self.page = page
    }

    func attach(to host: UnsafeMutablePointer<cef_browser_host_t>) throws {
        guard !closed else { throw ChromiumError.closed }
        guard self.host == nil else { return }
        let observer = ChromiumInterop.allocate(cef_dev_tools_message_observer_t.self, owner: self)
        observer.pointee.on_dev_tools_message = { _, browser, _, _ in
            ChromiumDevTools.releaseBrowser(browser)
            return 0
        }
        observer.pointee.on_dev_tools_method_result = { observerSelf, browser, messageID, success, result, resultSize in
            defer { ChromiumDevTools.releaseBrowser(browser) }
            guard let observerSelf,
                  let owner = ChromiumInterop.owner(ChromiumDevTools.self,
                                                    of: UnsafeMutableRawPointer(observerSelf)) else { return }
            MainActor.assumeIsolated {
                owner.receiveResult(id: Int(messageID), success: success != 0, pointer: result, size: resultSize)
            }
        }
        observer.pointee.on_dev_tools_event = { observerSelf, browser, method, params, paramsSize in
            defer { ChromiumDevTools.releaseBrowser(browser) }
            guard let observerSelf,
                  let owner = ChromiumInterop.owner(ChromiumDevTools.self,
                                                    of: UnsafeMutableRawPointer(observerSelf)) else { return }
            let name = method.map { ChromiumInterop.string($0) } ?? ""
            MainActor.assumeIsolated {
                owner.receiveEvent(name: name, pointer: params, size: paramsSize)
            }
        }
        observer.pointee.on_dev_tools_agent_attached = { _, browser in
            ChromiumDevTools.releaseBrowser(browser)
        }
        observer.pointee.on_dev_tools_agent_detached = { observerSelf, browser in
            defer { ChromiumDevTools.releaseBrowser(browser) }
            guard let observerSelf,
                  let owner = ChromiumInterop.owner(ChromiumDevTools.self,
                                                    of: UnsafeMutableRawPointer(observerSelf)) else { return }
            MainActor.assumeIsolated {
                owner.failAll(ChromiumError.unavailable("Chromium DevTools detached."))
            }
        }

        ChromiumInterop.retain(UnsafeMutableRawPointer(observer))
        guard let addObserver = host.pointee.add_dev_tools_message_observer else {
            ChromiumInterop.release(UnsafeMutableRawPointer(observer))
            ChromiumInterop.release(UnsafeMutableRawPointer(observer))
            throw ChromiumError.unavailable("Chromium DevTools observer could not be attached.")
        }
        guard let registration = addObserver(host, observer) else {
            // The call consumes its transfer reference even when rejected.
            ChromiumInterop.release(UnsafeMutableRawPointer(observer))
            throw ChromiumError.unavailable("Chromium DevTools observer could not be attached.")
        }
        ChromiumInterop.retain(UnsafeMutableRawPointer(host))
        self.host = host
        self.observer = observer
        self.registration = registration
    }

    func prepare() async throws {
        guard !closed else { throw ChromiumError.closed }
        guard !prepared else { return }
        if preparing {
            return try await withCheckedThrowingContinuation { continuation in
                prepareWaiters.append(continuation)
            }
        }
        preparing = true
        do {
            _ = try await command("Page.enable")
            _ = try await command("Runtime.enable")
            _ = try await command("Security.enable")
            _ = try await command("Network.enable")

            let worlds = Set(scripts.map(\.worldName)).union(handlers.keys.map(\.worldName))
            for worldName in worlds.sorted() {
                try await installBinding(worldName: worldName)
            }
            for script in scripts {
                try await install(script)
            }
            prepared = true
            preparing = false
            finishPrepareWaiters(nil)
        } catch {
            preparing = false
            finishPrepareWaiters(error)
            throw error
        }
    }

    func command(_ method: String, params: [String: Any] = [:]) async throws -> [String: Any] {
        guard !closed else { throw ChromiumError.closed }
        guard let host else { throw ChromiumError.unavailable("Chromium DevTools is not attached.") }
        guard JSONSerialization.isValidJSONObject(params) else {
            throw ChromiumError.protocolFailure("DevTools parameters are not JSON serializable.")
        }
        let result = CommandResult()
        let id = nextMessageID
        nextMessageID &+= 1
        let object: [String: Any] = ["id": id, "method": method, "params": params]
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: object)
        } catch {
            throw ChromiumError.protocolFailure("DevTools parameters are not JSON serializable: \(error.localizedDescription)")
        }

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !closed else {
                    continuation.resume(throwing: ChromiumError.closed)
                    return
                }
                pending[id] = PendingCommand(continuation: continuation, result: result)
                timeouts[id] = Task { [weak self] in
                    do { try await Task.sleep(for: self?.commandTimeout ?? .seconds(15)) } catch { return }
                    guard let self else { return }
                    self.finishFailure(id: id, error: ChromiumError.unavailable("Chromium DevTools command timed out."))
                }
                let accepted = data.withUnsafeBytes { bytes in
                    host.pointee.send_dev_tools_message?(host, bytes.baseAddress, data.count) ?? 0
                }
                if accepted == 0 {
                    self.finishFailure(id: id, error: ChromiumError.unavailable("Chromium DevTools rejected the command."))
                }
            }
            guard let value = result.value else {
                throw ChromiumError.protocolFailure("Chromium DevTools command completed without a result.")
            }
            return value
        }, onCancel: { [weak self] in
            Task { @MainActor in
                self?.finishFailure(id: id, error: CancellationError())
            }
        })
    }

    func close() {
        closed = true
        finishPrepareWaiters(ChromiumError.closed)
        failAll(ChromiumError.closed)
        if let registration {
            ChromiumInterop.release(UnsafeMutableRawPointer(registration))
            self.registration = nil
        }
        if let observer {
            ChromiumInterop.release(UnsafeMutableRawPointer(observer))
            self.observer = nil
        }
        if let host {
            ChromiumInterop.release(UnsafeMutableRawPointer(host))
            self.host = nil
        }
        framesByID.removeAll()
        contextsByUniqueID.removeAll()
        uniqueIDByExecutionID.removeAll()
        bindingWorlds.removeAll()
        handlers.removeAll()
        scripts.removeAll()
    }

    func frames() async throws -> [BrowserFrame] {
        let response = try await command("Page.getFrameTree")
        guard let tree = response["frameTree"] as? [String: Any] else {
            throw ChromiumError.protocolFailure("Page.getFrameTree returned no frame tree.")
        }
        var parsed: [String: FrameState] = [:]
        parseFrameTree(tree, parentID: nil, into: &parsed)
        guard !parsed.isEmpty else {
            throw ChromiumError.protocolFailure("Page.getFrameTree returned no frames.")
        }
        updateFrames(parsed)
        return parsed.values.sorted { $0.id < $1.id }.map(\.browserFrame)
    }

    func isLive(frame: BrowserFrame) async throws -> Bool {
        guard !closed, let id = frame.chromiumID, !frame.documentID.isEmpty else { return false }
        _ = try await frames()
        guard let current = framesByID[id], !current.documentID.isEmpty else { return false }
        return current.documentID == frame.documentID
            && current.securityOrigin == frame.securityOrigin
    }

    func evaluate(_ script: String, in frame: BrowserFrame?, world: WKContentWorld) async throws -> Any {
        let target = try await targetFrame(frame)
        let context = try await context(for: target, world: world)
        let snapshot = context
        if snapshot.worldName != "" { try await setDocumentMarker(contextID: snapshot.uniqueID, documentID: snapshot.documentID) }
        let response = try await command("Runtime.evaluate", params: [
            "expression": script,
            "uniqueContextId": snapshot.uniqueID,
            "returnByValue": true,
            "awaitPromise": true,
            "userGesture": true,
        ])
        let value = try runtimeValue(response)
        guard try await isLive(frame: target), contextIsLive(snapshot) else { throw ChromiumError.staleFrame }
        return value
    }

    func callAsync(_ body: String, arguments: [String: Any], in frame: BrowserFrame?, world: WKContentWorld) async throws -> Any {
        let names = Array(arguments.keys)
        guard names.allSatisfy({ $0.range(of: #"^[A-Za-z_$][A-Za-z0-9_$]*$"#, options: .regularExpression) != nil }) else {
            throw ChromiumError.protocolFailure("Async JavaScript argument names must be valid identifiers.")
        }
        guard Set(names).count == names.count else {
            throw ChromiumError.protocolFailure("Async JavaScript argument names must be unique.")
        }
        let encoded: Data
        do {
            let values = names.map { arguments[$0] as Any }
            encoded = try JSONSerialization.data(withJSONObject: values)
        } catch {
            throw ChromiumError.protocolFailure("Async JavaScript arguments are not JSON serializable: \(error.localizedDescription)")
        }
        guard let json = String(data: encoded, encoding: .utf8) else {
            throw ChromiumError.protocolFailure("Async JavaScript arguments are not UTF-8.")
        }
        let expression = "(async function(\(names.joined(separator: ",")) {\n\(body)\n})(...JSON.parse(\(jsonLiteral(json))))"
        return try await evaluate(expression, in: frame, world: world)
    }

    func installScript(_ source: String, in world: WKContentWorld,
                       injectionTime: WKUserScriptInjectionTime, forMainFrameOnly: Bool) {
        let script = Script(source: source, worldName: worldName(world), injectionTime: injectionTime,
                            mainFrameOnly: forMainFrameOnly)
        scripts.append(script)
        guard prepared else { return }
        Task { @MainActor [weak self] in
            guard let self, !self.closed else { return }
            try? await self.installBinding(worldName: script.worldName)
            try? await self.install(script)
        }
    }

    func addScriptMessageHandler(name: String, in world: WKContentWorld,
                                 handler: @escaping (BrowserScriptMessage) -> Void) {
        let key = HandlerKey(name: name, worldName: worldName(world))
        handlers[key] = handler
        guard prepared else { return }
        Task { @MainActor [weak self] in
            guard let self, !self.closed else { return }
            try? await self.installBinding(worldName: key.worldName)
        }
    }

    func removeScriptMessageHandler(name: String, in world: WKContentWorld) {
        handlers.removeValue(forKey: HandlerKey(name: name, worldName: worldName(world)))
    }

    private func receiveResult(id: Int, success: Bool, pointer: UnsafeRawPointer?, size: Int) {
        guard !closed else { return }
        guard size <= 8 * 1_048_576 else {
            finishFailure(id: id, error: ChromiumError.protocolFailure("DevTools result is too large."))
            return
        }
        guard success else {
            let detail = (try? Self.jsonObject(pointer, size: size) as? [String: Any])?["message"] as? String
            finishFailure(id: id, error: ChromiumError.protocolFailure(detail ?? "DevTools command failed."))
            return
        }
        do {
            let result: [String: Any] = size == 0 ? [:] : (try Self.jsonObject(pointer, size: size) as? [String: Any] ?? [:])
            finishSuccess(id: id, value: result)
        } catch {
            finishFailure(id: id, error: ChromiumError.protocolFailure("Invalid DevTools result: \(error.localizedDescription)"))
        }
    }

    private func receiveEvent(name: String, pointer: UnsafeRawPointer?, size: Int) {
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
            if let executionID = params["executionContextId"] as? Int {
                removeContexts(executionID: executionID)
            }
        case "Runtime.executionContextsCleared":
            contextsByUniqueID.removeAll()
            uniqueIDByExecutionID.removeAll()
        case "Runtime.bindingCalled":
            bindingCalled(params)
        case "Page.frameNavigated":
            frameNavigated(params)
        case "Page.frameDetached":
            frameDetached(params)
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
        let oldDocument = framesByID[parsed.id]?.documentID
        framesByID[parsed.id] = parsed
        if oldDocument != nil, oldDocument != parsed.documentID {
            retireDescendants(parentID: parsed.id)
            removeContexts(frameID: parsed.id)
        }
        if !parsed.documentID.isEmpty {
            page?.didNavigate(frame: parsed.browserFrame)
        }
    }

    private func frameDetached(_ params: [String: Any]) {
        guard let frameID = params["frameId"] as? String else { return }
        var removed = Set([frameID])
        var changed = true
        while changed {
            changed = false
            for frame in framesByID.values where frame.parentID.map(removed.contains) == true && removed.insert(frame.id).inserted {
                changed = true
            }
        }
        for id in removed {
            framesByID.removeValue(forKey: id)
            removeContexts(frameID: id)
        }
    }

    private func targetFrame(_ requested: BrowserFrame?) async throws -> BrowserFrame {
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

    private func context(for frame: BrowserFrame, world: WKContentWorld) async throws -> ContextState {
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

    private func setDocumentMarker(contextID: String, documentID: String) async throws {
        guard var context = contextsByUniqueID[contextID], !context.markerSet else { return }
        let response = try await command("Runtime.evaluate", params: [
            "expression": "Object.defineProperty(globalThis, '__wsurfFrameDocumentID', {value: \(jsonLiteral(documentID)), writable: false, configurable: false, enumerable: false});",
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

    private func runtimeValue(_ response: [String: Any]) throws -> Any {
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

    private func contextIsLive(_ context: ContextState) -> Bool {
        guard let current = contextsByUniqueID[context.uniqueID], let frame = framesByID[context.frameID] else { return false }
        return current.documentID == context.documentID && frame.documentID == context.documentID
    }

    private func updateFrames(_ parsed: [String: FrameState]) {
        framesByID = parsed
        let staleContexts = contextsByUniqueID.compactMap { uniqueID, context -> (String, Int)? in
            guard let frame = parsed[context.frameID] else { return (uniqueID, context.executionID) }
            if context.documentID.isEmpty {
                return nil
            }
            return context.documentID == frame.documentID ? nil : (uniqueID, context.executionID)
        }
        for (uniqueID, executionID) in staleContexts {
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
    }

    private func parseFrameTree(_ tree: [String: Any], parentID: String?, into result: inout [String: FrameState]) {
        guard let frame = tree["frame"] as? [String: Any], let parsed = parseFrame(frame, parentID: parentID) else { return }
        result[parsed.id] = parsed
        if let children = tree["childFrames"] as? [[String: Any]] {
            for child in children {
                parseFrameTree(child, parentID: parsed.id, into: &result)
            }
        }
    }

    private func parseFrame(_ frame: [String: Any], parentID: String?) -> FrameState? {
        guard let id = frame["id"] as? String, !id.isEmpty,
              let urlString = frame["url"] as? String else { return nil }
        let url = URL(string: urlString) ?? URL(string: "about:blank")!
        let originString = frame["securityOrigin"] as? String ?? url.originString
        let originURL = URL(string: originString)
        let origin = originURL.map(BrowserSecurityOrigin.init(url:)) ?? BrowserSecurityOrigin(url: url)
        return FrameState(id: id, parentID: parentID, documentID: frame["loaderId"] as? String ?? "",
                          url: url, securityOrigin: origin, isMainFrame: parentID == nil)
    }

    private func installBinding(worldName: String) async throws {
        guard !bindingWorlds.contains(worldName) else { return }
        var params: [String: Any] = ["name": "__wsurfSend"]
        if !worldName.isEmpty { params["executionContextName"] = worldName }
        _ = try await command("Runtime.addBinding", params: params)
        let bridge = """
        (() => {
          const native = globalThis.__wsurfSend;
          Object.defineProperty(globalThis, '__wsurfSend', {
            value: (name, body) => {
              if (typeof name !== 'string' || name.length === 0 || name.length > 256) return;
              native(JSON.stringify([name, body]));
            }, writable: false, configurable: false, enumerable: false
          });
        })();
        """
        var params2: [String: Any] = ["source": bridge]
        if !worldName.isEmpty { params2["worldName"] = worldName }
        _ = try await command("Page.addScriptToEvaluateOnNewDocument", params: params2)
        bindingWorlds.insert(worldName)
    }

    private func install(_ script: Script) async throws {
        let source: String
        if script.injectionTime == .atDocumentStart {
            source = script.mainFrameOnly
                ? "if (window === window.top) {\n\(script.source)\n}"
                : script.source
        } else {
            let body = script.mainFrameOnly ? "if (window === window.top) {\n\(script.source)\n}" : script.source
            source = "(() => { const run = () => {\n\(body)\n}; " +
                "if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', run, {once: true}); " +
                "else queueMicrotask(run); })();"
        }
        var params: [String: Any] = ["source": source]
        if !script.worldName.isEmpty { params["worldName"] = script.worldName }
        _ = try await command("Page.addScriptToEvaluateOnNewDocument", params: params)
    }

    private func worldName(_ world: WKContentWorld) -> String {
        world === WKContentWorld.page ? "" : world.name ?? "defaultClient"
    }

    private func removeContexts(executionID: Int) {
        guard let uniqueID = uniqueIDByExecutionID.removeValue(forKey: executionID) else { return }
        contextsByUniqueID.removeValue(forKey: uniqueID)
    }

    private func removeContexts(frameID: String) {
        let removed = contextsByUniqueID.compactMap { uniqueID, context -> (String, Int)? in
            context.frameID == frameID ? (uniqueID, context.executionID) : nil
        }
        for (uniqueID, executionID) in removed {
            contextsByUniqueID.removeValue(forKey: uniqueID)
            uniqueIDByExecutionID.removeValue(forKey: executionID)
        }
    }
    private func retireDescendants(parentID: String) {
        var retired = Set<String>()
        var changed = true
        while changed {
            changed = false
            for frame in framesByID.values where frame.parentID == parentID || frame.parentID.map(retired.contains) == true {
                if retired.insert(frame.id).inserted {
                    changed = true
                }
            }
        }
        for id in retired {
            framesByID.removeValue(forKey: id)
            removeContexts(frameID: id)
        }
    }

    private func finishSuccess(id: Int, value: [String: Any]) {
        guard let pendingCommand = pending.removeValue(forKey: id) else { return }
        timeouts.removeValue(forKey: id)?.cancel()
        pendingCommand.result.value = value
        pendingCommand.continuation.resume()
    }

    private func finishFailure(id: Int, error: Error) {
        guard let pendingCommand = pending.removeValue(forKey: id) else { return }
        timeouts.removeValue(forKey: id)?.cancel()
        pendingCommand.continuation.resume(throwing: error)
    }

    private func failAll(_ error: Error) {
        let values = pending
        pending.removeAll()
        for (id, pendingCommand) in values {
            timeouts.removeValue(forKey: id)?.cancel()
            pendingCommand.continuation.resume(throwing: error)
        }
        timeouts.removeAll()
    }

    private func finishPrepareWaiters(_ error: Error?) {
        let waiters = prepareWaiters
        prepareWaiters.removeAll()
        for waiter in waiters {
            if let error {
                waiter.resume(throwing: error)
            } else {
                waiter.resume()
            }
        }
    }

    nonisolated private static func releaseBrowser(_ browser: UnsafeMutablePointer<cef_browser_t>?) {
        if let browser {
            ChromiumInterop.release(UnsafeMutableRawPointer(browser))
        }
    }
    private static func jsonObject(_ pointer: UnsafeRawPointer?, size: Int) throws -> Any {
        guard let pointer, size > 0 else { throw ChromiumError.protocolFailure("Empty DevTools JSON payload.") }
        let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: pointer), count: size, deallocator: .none)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
    private static func jsonObject(_ data: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    private func jsonLiteral(_ string: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: string, options: [.fragmentsAllowed]),
              let literal = String(data: data, encoding: .utf8) else { return "\"\"" }
        return literal
    }
}

private extension URL {
    var originString: String {
        guard let scheme, let host else { return "" }
        return "\(scheme)://\(host)\(port.map { ":\($0)" } ?? "")"
    }
}
