// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CCef
import Foundation
import WebKit

@MainActor
final class ChromiumDevTools {
    weak var page: ChromiumPage?
    private var host: UnsafeMutablePointer<cef_browser_host_t>?
    private var observer: UnsafeMutablePointer<cef_dev_tools_message_observer_t>?
    private var registration: UnsafeMutablePointer<cef_registration_t>?
    private var nextMessageID = 1
    private var pending: [Int: PendingCommand] = [:]
    private var timeouts: [Int: Task<Void, Never>] = [:]
    var closed = false
    private var prepared = false
    private var preparing = false
    private var prepareWaiters: [CheckedContinuation<Void, Error>] = []

    struct FrameState {
        let id: String
        let parentID: String?
        let documentID: String
        let url: URL
        let securityOrigin: BrowserSecurityOrigin
        let hasTrustedSecurityOrigin: Bool
        let isMainFrame: Bool
        var browserFrame: BrowserFrame {
            BrowserFrame(id: id, documentID: documentID, url: url,
                         isMainFrame: isMainFrame, securityOrigin: securityOrigin,
                         parentID: parentID, hasTrustedSecurityOrigin: hasTrustedSecurityOrigin)
        }
    }

    struct ContextState {
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
        /// Non-nil once registered with Chromium; nil means not (or no longer) installed.
        var identifier: String?
    }

    struct HandlerKey: Hashable {
        let name: String
        let worldName: String
    }

    typealias Handler = (BrowserScriptMessage) -> Void

    var framesByID: [String: FrameState] = [:]
    var frameRevision = 0
    var contextsByUniqueID: [String: ContextState] = [:]
    var uniqueIDByExecutionID: [Int: String] = [:]
    private var scripts: [Script] = []
    var handlers: [HandlerKey: Handler] = [:]
    private var bindingWorlds: Set<String> = []
    /// Serializes script registration so Chromium's registration order always matches `scripts`.
    private var scriptQueue: Task<Void, Never>?

    private let commandTimeout: Duration = .seconds(15)
    let maxBindingPayload = 1_048_576

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
                owner.frameRevision &+= 1
                owner.framesByID.removeAll()
                owner.contextsByUniqueID.removeAll()
                owner.uniqueIDByExecutionID.removeAll()
                owner.page?.owner?.invalidateCredentialContexts()
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

            while true {
                if let index = scripts.firstIndex(where: { $0.identifier == nil }) {
                    try await installBinding(worldName: scripts[index].worldName)
                    guard !closed, scripts.indices.contains(index) else { throw ChromiumError.closed }
                    let identifier = try await install(scripts[index])
                    guard !closed, scripts.indices.contains(index) else { throw ChromiumError.closed }
                    scripts[index].identifier = identifier
                    continue
                }
                let worlds = Set(scripts.map(\.worldName)).union(handlers.keys.map(\.worldName))
                if let worldName = worlds.sorted().first(where: { !bindingWorlds.contains($0) }) {
                    try await installBinding(worldName: worldName)
                    continue
                }
                break
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

    func command(
        _ method: String,
        params baseParams: [String: Any] = [:],
        dispatchCheck: (@MainActor @Sendable () throws -> Void)? = nil,
        prepareParameters: (@MainActor @Sendable () throws -> [String: Any])? = nil
    ) async throws -> [String: Any] {
        guard !closed else { throw ChromiumError.closed }
        guard let host else { throw ChromiumError.unavailable("Chromium DevTools is not attached.") }
        if prepareParameters == nil, !JSONSerialization.isValidJSONObject(baseParams) {
            throw ChromiumError.protocolFailure("DevTools parameters are not JSON serializable.")
        }
        let result = CommandResult()
        let id = nextMessageID
        nextMessageID &+= 1

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                guard !closed else {
                    continuation.resume(throwing: ChromiumError.closed)
                    return
                }
                do {
                    if method == "Runtime.evaluate" {
                        try Task.checkCancellation()
                        guard PageAutomationGuard.allowsExecution else { throw ChromiumError.staleFrame }
                    }
                    // Parameters are prepared and re-checked in the same synchronous turn that sends the message.
                    let params = try prepareParameters?() ?? baseParams
                    guard JSONSerialization.isValidJSONObject(params) else {
                        throw ChromiumError.protocolFailure("DevTools parameters are not JSON serializable.")
                    }
                    let object: [String: Any] = ["id": id, "method": method, "params": params]
                    let data: Data
                    do {
                        data = try JSONSerialization.data(withJSONObject: object)
                    } catch {
                        throw ChromiumError.protocolFailure("DevTools parameters are not JSON serializable: \(error.localizedDescription)")
                    }
                    try dispatchCheck?()
                    guard !closed, self.host == host else { throw ChromiumError.closed }
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
                } catch {
                    continuation.resume(throwing: error)
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
        // A browser closed natively (not through BrowserPage.close) must still end its credential contexts.
        if let owner = page?.owner, !owner.isClosed {
            owner.invalidateCredentialContexts()
        }
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
        try await refreshFrames()
        return framesByID.values.sorted { $0.id < $1.id }.map(\.browserFrame)
    }

    func frameSnapshot() -> [BrowserFrame] {
        framesByID.values.map(\.browserFrame)
    }

    private func refreshFrames() async throws {
        let revision = frameRevision
        let response = try await command("Page.getFrameTree")
        guard !closed else { throw ChromiumError.closed }
        // Events can deliver a newer document before this command's continuation resumes.
        guard frameRevision == revision else { return }
        guard let tree = response["frameTree"] as? [String: Any] else {
            throw ChromiumError.protocolFailure("Page.getFrameTree returned no frame tree.")
        }
        var parsed: [String: FrameState] = [:]
        parseFrameTree(tree, parentID: nil, into: &parsed)
        guard !parsed.isEmpty else {
            throw ChromiumError.protocolFailure("Page.getFrameTree returned no frames.")
        }
        updateFrames(parsed)
    }

    func sourceFrame(for referrer: URL?) -> BrowserFrame? {
        let origin = SitePermissions.webOrigin(for: referrer)
        guard !origin.isEmpty else { return nil }
        var match: FrameState?
        // Origin-only referrers and inherited documents cannot identify a unique URL.
        for frame in framesByID.values where !frame.documentID.isEmpty {
            if SitePermissions.webOrigin(for: frame.url) == origin
                || ChromiumClient.sameOrigin(origin, frame.securityOrigin) {
                guard match == nil else { return nil }
                match = frame
            }
        }
        return match?.browserFrame
    }

    func isLive(frame: BrowserFrame) async throws -> Bool {
        guard !closed, frame.chromiumID != nil, !frame.documentID.isEmpty else { return false }
        try await refreshFrames()
        return frameIsCurrent(frame)
    }

    func isCurrent(snapshot: [BrowserFrame]) -> Bool {
        !closed && !snapshot.isEmpty && snapshot.allSatisfy(frameIsCurrent)
    }

    private func frameIsCurrent(_ frame: BrowserFrame) -> Bool {
        guard let id = frame.chromiumID, !frame.documentID.isEmpty,
              let current = framesByID[id] else { return false }
        return current.documentID == frame.documentID
            && current.securityOrigin == frame.securityOrigin
    }

    /// Ordered requesting frame → top frame, from the live native tree. Fails closed on a stale requester,
    /// missing ancestor, cycle, or a root that is not the single main frame.
    func frameChain(for frame: BrowserFrame) async throws -> [BrowserFrame] {
        guard let id = frame.chromiumID, !frame.documentID.isEmpty else { throw WebAuthnContextError.staleFrame }
        try await refreshFrames()
        guard let requesting = framesByID[id], requesting.documentID == frame.documentID,
              requesting.securityOrigin == frame.securityOrigin,
              requesting.parentID == frame.chromiumParentID else { throw WebAuthnContextError.staleFrame }
        var chain = [requesting]
        var visited: Set<String> = [id]
        while let parentID = chain[chain.count - 1].parentID {
            guard visited.insert(parentID).inserted, let parent = framesByID[parentID],
                  !parent.documentID.isEmpty else { throw WebAuthnContextError.untrustedOrigin }
            chain.append(parent)
        }
        guard chain[chain.count - 1].isMainFrame, framesByID.values.filter({ $0.parentID == nil }).count == 1 else {
            throw WebAuthnContextError.untrustedOrigin
        }
        return chain.map(\.browserFrame)
    }

    func permissionsPolicyAllows(frame: BrowserFrame, feature: String) async throws -> Bool {
        guard let frameID = frame.chromiumID else { throw WebAuthnContextError.staleFrame }
        guard try await isLiveCredentialFrame(frame) else { throw WebAuthnContextError.staleFrame }
        let response = try await command("Page.getPermissionsPolicyState", params: ["frameId": frameID])
        guard let states = response["states"] as? [[String: Any]] else { throw WebAuthnContextError.policyUnavailable }
        let matches = states.filter { $0["feature"] as? String == feature }
        guard matches.count == 1, let allowed = matches[0]["allowed"] as? Bool else {
            throw WebAuthnContextError.policyUnavailable
        }
        guard try await isLiveCredentialFrame(frame) else { throw WebAuthnContextError.staleFrame }
        return allowed
    }

    /// Reports the document's current activation state; never grants or consumes one.
    func transientUserActivationIsActive(in frame: BrowserFrame, world: WKContentWorld) async throws -> Bool {
        let (target, snapshot) = try await credentialContext(for: frame, world: world)
        let response = try await command("Runtime.evaluate", params: [
            "expression": "navigator.userActivation?.isActive === true",
            "uniqueContextId": snapshot.uniqueID,
            "returnByValue": true,
            "awaitPromise": false,
            "userGesture": false,
        ], dispatchCheck: { [self] in
            guard credentialFrameIsCurrent(target), contextIsLive(snapshot) else { throw WebAuthnContextError.staleFrame }
        })
        let value = try runtimeValue(response)
        guard try await isLiveCredentialFrame(target), contextIsLive(snapshot) else {
            throw WebAuthnContextError.staleFrame
        }
        return value as? Bool == true
    }

    func executionContextIdentity(for frame: BrowserFrame, world: WKContentWorld) async throws -> String {
        try await credentialContext(for: frame, world: world).context.uniqueID
    }

    func isCurrentCredentialContext(frame: BrowserFrame, executionContextID: String) -> Bool {
        guard credentialFrameIsCurrent(frame),
              let context = contextsByUniqueID[executionContextID],
              context.frameID == frame.chromiumID,
              context.documentID == frame.documentID,
              uniqueIDByExecutionID[context.executionID] == executionContextID else { return false }
        return contextIsLive(context)
    }

    private func credentialFrameIsCurrent(_ frame: BrowserFrame) -> Bool {
        guard !closed, frame.hasTrustedSecurityOrigin, let id = frame.chromiumID, !frame.documentID.isEmpty,
              let current = framesByID[id] else { return false }
        return current.hasTrustedSecurityOrigin
            && current.documentID == frame.documentID
            && current.securityOrigin == frame.securityOrigin
    }

    private func isLiveCredentialFrame(_ frame: BrowserFrame) async throws -> Bool {
        guard !closed, frame.chromiumID != nil else { return false }
        try await refreshFrames()
        return credentialFrameIsCurrent(frame)
    }

    /// The live frame and its (marked) execution context for `world`, revalidated after every async step.
    private func credentialContext(
        for frame: BrowserFrame, world: WKContentWorld
    ) async throws -> (frame: BrowserFrame, context: ContextState) {
        guard try await isLiveCredentialFrame(frame), let id = frame.chromiumID, let state = framesByID[id] else {
            throw WebAuthnContextError.staleFrame
        }
        let target = state.browserFrame
        let snapshot: ContextState
        do {
            snapshot = try await context(for: target, world: world)
            if snapshot.worldName != "" {
                try await setDocumentMarker(contextID: snapshot.uniqueID, documentID: snapshot.documentID)
            }
        } catch ChromiumError.staleFrame {
            throw WebAuthnContextError.staleFrame
        }
        guard try await isLiveCredentialFrame(target), contextIsLive(snapshot) else {
            throw WebAuthnContextError.staleFrame
        }
        return (target, snapshot)
    }

    func evaluate(_ script: String, in frame: BrowserFrame?, world: WKContentWorld) async throws -> Any {
        try await evaluate(in: frame, world: world, userGesture: true, dispatchCheck: nil) { script }
    }

    private func evaluate(
        in frame: BrowserFrame?,
        world: WKContentWorld,
        userGesture: Bool,
        dispatchCheck: (@MainActor @Sendable () throws -> Void)?,
        expression: @escaping @MainActor @Sendable () throws -> String
    ) async throws -> Any {
        let target = try await targetFrame(frame)
        let snapshot = try await context(for: target, world: world)
        if snapshot.worldName != "" {
            try Task.checkCancellation()
            guard PageAutomationGuard.allowsExecution else { throw ChromiumError.staleFrame }
            try await setDocumentMarker(contextID: snapshot.uniqueID, documentID: snapshot.documentID)
        }
        try Task.checkCancellation()
        guard PageAutomationGuard.allowsExecution, canDispatch(to: target, snapshot) else {
            throw ChromiumError.staleFrame
        }
        let response = try await command("Runtime.evaluate", dispatchCheck: { [self] in
            guard canDispatch(to: target, snapshot) else { throw ChromiumError.staleFrame }
            try dispatchCheck?()
        }, prepareParameters: {
            let source = try expression()
            return [
                "expression": source,
                "uniqueContextId": snapshot.uniqueID,
                "returnByValue": true,
                "awaitPromise": true,
                "userGesture": userGesture,
            ]
        })
        let value = try runtimeValue(response)
        guard try await isLive(frame: target), contextIsLive(snapshot) else { throw ChromiumError.staleFrame }
        return value
    }

    private func canDispatch(to target: BrowserFrame, _ snapshot: ContextState) -> Bool {
        guard let frameID = target.chromiumID,
              let current = framesByID[frameID],
              current.documentID == target.documentID,
              current.securityOrigin == target.securityOrigin else { return false }
        return contextIsLive(snapshot)
    }

    func callAsync(_ body: String, arguments: [String: Any], in frame: BrowserFrame?, world: WKContentWorld) async throws -> Any {
        try await evaluate(try asyncExpression(body, arguments: arguments), in: frame, world: world)
    }

    /// Arguments are built, then `dispatchCheck` runs, in the same synchronous turn that sends the command.
    /// Never claims a user gesture, so page activation is neither fabricated nor consumed.
    func callAsync(
        _ body: String,
        in frame: BrowserFrame?,
        world: WKContentWorld,
        prepareArguments: @escaping @MainActor @Sendable () throws -> [String: Any],
        dispatchCheck: (@MainActor @Sendable () throws -> Void)? = nil
    ) async throws -> Any {
        try await evaluate(in: frame, world: world, userGesture: false, dispatchCheck: dispatchCheck) { [self] in
            try asyncExpression(body, arguments: prepareArguments())
        }
    }

    private func asyncExpression(_ body: String, arguments: [String: Any]) throws -> String {
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
        return "(async function(\(names.joined(separator: ","))) {\n\(body)\n})(...JSON.parse(\(jsonLiteral(json))))"
    }

    func installScript(_ source: String, in world: WKContentWorld,
                       injectionTime: WKUserScriptInjectionTime, forMainFrameOnly: Bool) {
        let index = scripts.count
        scripts.append(Script(source: source, worldName: worldName(world), injectionTime: injectionTime,
                              mainFrameOnly: forMainFrameOnly))
        guard prepared else { return }
        schedule { [weak self] in try await self?.installPending(from: index) }
    }

    /// Swaps the matching script's source in place (same world, injection time and position). Already swapped
    /// is success; neither source present is stale.
    func replaceScript(_ old: String, with new: String, in world: WKContentWorld) async throws {
        guard !closed else { throw ChromiumError.closed }
        let name = worldName(world)
        try await schedule { [weak self] in
            guard let self, !self.closed else { throw ChromiumError.closed }
            if self.preparing {
                try await self.prepare()
            }
            guard let start = self.scripts.firstIndex(where: { $0.source == old && $0.worldName == name }) else {
                if self.scripts.contains(where: { $0.source == new && $0.worldName == name }) {
                    return
                }
                throw ChromiumError.staleFrame
            }
            let original = self.scripts[start]
            let replacement = Script(source: new, worldName: name, injectionTime: original.injectionTime,
                                     mainFrameOnly: original.mainFrameOnly)
            guard self.prepared else {
                self.scripts[start] = replacement
                return
            }
            // Chromium runs new-document scripts in registration order: unregister the tail (last first, so a
            // failure leaves a registered prefix), then register it again with the replacement in place.
            for index in stride(from: self.scripts.count - 1, through: start, by: -1) {
                guard let identifier = self.scripts[index].identifier else { continue }
                do {
                    _ = try await self.command("Page.removeScriptToEvaluateOnNewDocument",
                                               params: ["identifier": identifier])
                } catch {
                    try? await self.installPending(from: index + 1)
                    throw error
                }
                guard !self.closed, self.scripts.indices.contains(index) else { throw ChromiumError.closed }
                self.scripts[index].identifier = nil
            }
            self.scripts[start] = replacement
            do {
                try await self.installPending(from: start)
            } catch {
                if self.scripts.indices.contains(start), self.scripts[start].identifier == nil {
                    self.scripts[start] = Script(source: old, worldName: name, injectionTime: original.injectionTime,
                                                 mainFrameOnly: original.mainFrameOnly)
                }
                try? await self.installPending(from: start)
                throw error
            }
        }.value
    }

    @discardableResult
    private func schedule(_ work: @escaping @MainActor @Sendable () async throws -> Void) -> Task<Void, Error> {
        let previous = scriptQueue
        let task = Task { @MainActor in
            await previous?.value
            try await work()
        }
        scriptQueue = Task { @MainActor in _ = try? await task.value }
        return task
    }

    /// Registers every not-yet-installed script from `start` on, in order.
    private func installPending(from start: Int) async throws {
        var index = start
        while index < scripts.count {
            if scripts[index].identifier == nil {
                let script = scripts[index]
                try await installBinding(worldName: script.worldName)
                let identifier = try await install(script)
                guard !closed, scripts.indices.contains(index) else { throw ChromiumError.closed }
                scripts[index].identifier = identifier
            }
            index += 1
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

    private func install(_ script: Script) async throws -> String {
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
        let response = try await command("Page.addScriptToEvaluateOnNewDocument", params: params)
        guard let identifier = response["identifier"] as? String else {
            throw ChromiumError.protocolFailure("Page.addScriptToEvaluateOnNewDocument returned no identifier.")
        }
        return identifier
    }

    func worldName(_ world: WKContentWorld) -> String {
        world === WKContentWorld.page ? "" : world.name ?? "defaultClient"
    }

    /// Returns the removed context's document so the caller can end credential contexts bound to it.
    @discardableResult
    func removeContexts(executionID: Int) -> String? {
        guard let uniqueID = uniqueIDByExecutionID.removeValue(forKey: executionID) else { return nil }
        return contextsByUniqueID.removeValue(forKey: uniqueID)?.documentID
    }

    func removeContexts(frameID: String) {
        let removed = contextsByUniqueID.compactMap { uniqueID, context -> (String, Int)? in
            context.frameID == frameID ? (uniqueID, context.executionID) : nil
        }
        for (uniqueID, executionID) in removed {
            contextsByUniqueID.removeValue(forKey: uniqueID)
            uniqueIDByExecutionID.removeValue(forKey: executionID)
        }
    }
    /// Removes `parentID`'s descendants and returns their document IDs.
    func retireDescendants(parentID: String) -> [String] {
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
        let documents = retired.compactMap { framesByID[$0]?.documentID }
        for id in retired {
            framesByID.removeValue(forKey: id)
            removeContexts(frameID: id)
        }
        return documents
    }

    /// Page-wide turnover bumps the page's credential generation; otherwise only the retired documents end.
    func invalidateCredentialContexts(documents: [String], pageWide: Bool) {
        guard let owner = page?.owner else { return }
        if pageWide {
            owner.invalidateCredentialContexts()
        } else {
            for documentID in Set(documents) where !documentID.isEmpty {
                owner.invalidateCredentialContexts(documentID: documentID)
            }
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
    static func jsonObject(_ pointer: UnsafeRawPointer?, size: Int) throws -> Any {
        guard let pointer, size > 0 else { throw ChromiumError.protocolFailure("Empty DevTools JSON payload.") }
        let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: pointer), count: size, deallocator: .none)
        return try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }
    static func jsonObject(_ data: Data) throws -> Any {
        try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    func jsonLiteral(_ string: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: string, options: [.fragmentsAllowed]),
              let literal = String(data: data, encoding: .utf8) else { return "\"\"" }
        return literal
    }
}
