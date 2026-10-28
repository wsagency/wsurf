// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import WebKit

/// Cross-site frames in a Chromium tab. Under site isolation such a frame (an out-of-process iframe, OOPIF) runs in another
/// renderer, which the page's DevTools session does not reach: none of WSurf's page scripts ran there. The page's session
/// auto-attaches to each one (`Target.setAutoAttach`, flat protocol, paused until its scripts are in) and gives it a session
/// of its own: a child `ChromiumDevTools` that sends through the page's connection with the frame's `sessionId`. The child
/// keeps its own frames, contexts and bindings, exactly as the page's session does for the page's process, so a message from
/// the frame names Chromium's frame and origin for it, never anything the page or the frame says. The same applies one level
/// down: each child auto-attaches to the cross-site frames inside its own.
extension ChromiumDevTools {
    /// One opt-in to cross-site frames: a world whose all-frames scripts (`forMainFrameOnly: false`) also run there, in the page's
    /// order, and whose message handlers then hear those frames.
    struct CrossSiteFrameScripts {
        let world: WKContentWorld
        /// The world's scripts that run there; nil: all of them. A world other features share names its own.
        var scripts: Set<String>?
        /// The world's handlers that hear those frames; nil: all of them.
        var handlers: Set<String>?
    }

    /// What runs in Chromium's cross-site frames. WebKit runs every all-frames script in every frame; Chromium runs only these
    /// there. A feature opts in with one entry; a page-world script only by its source, and with no handler.
    static let crossSiteFrameScripts = [
        // Autofill, Pick Credential…, save offers and Input History. Nothing else is in this world.
        CrossSiteFrameScripts(world: AutofillPage.world),
        // Iframe audio: the services world is shared (SiteContentGuard, PageActivityMonitor, …), so only the media script and its
        // handler. Neither reaches the autofill world, and the autofill script and handlers never reach this one.
        CrossSiteFrameScripts(world: BrowserPage.servicesWorld, scripts: [MediaScript.source],
                              handlers: [MediaCenter.frameScriptHandlerName]),
        // A public-key request ends at once instead of waiting forever on CEF's own WebAuthn. Sends nothing, so no relay.
        CrossSiteFrameScripts(world: .page, scripts: [WebAuthnScript.engineRefusal], handlers: []),
    ]

    static func runsInCrossSiteFrames(_ script: Script) -> Bool {
        !script.mainFrameOnly && crossSiteFrameScripts.contains { entry in
            entry.world === WKContentWorld.page
                ? script.worldName.isEmpty && entry.scripts?.contains(script.source) == true
                : !script.worldName.isEmpty && entry.world.name == script.worldName && entry.scripts?.contains(script.source) != false
        }
    }

    static func hearsCrossSiteFrames(_ key: HandlerKey) -> Bool {
        !key.worldName.isEmpty && crossSiteFrameScripts.contains {
            $0.world.name == key.worldName && $0.handlers?.contains(key.name) != false
        }
    }

    /// Auto-attach to this session's cross-site frames. Each new one waits, before its document loads, until its session has
    /// registered its scripts and lets it run. Not fatal: a Chromium that refuses leaves such frames without scripts, as before.
    /// Chromium also holds every new dedicated (and shared) worker of the page while this is on, filter or not, so workers are
    /// attached too, and let go at once (`attachedToTarget`); service workers are not held.
    func attachCrossSiteFrames() async throws {
        _ = try? await command("Target.setAutoAttach", params: [
            "autoAttach": true, "waitForDebuggerOnStart": true, "flatten": true,
            "filter": [["type": "iframe", "exclude": false], ["type": "worker", "exclude": false], ["type": "shared_worker", "exclude": false]],
        ])
        guard !closed else { throw sessionID == nil ? ChromiumError.closed : ChromiumError.staleFrame }
    }

    /// The page's session: takes a cross-site frame session's result or event (true), which CEF's parsed callbacks would hand
    /// on without its `sessionId`. False for the page's own messages, which go on to `receiveResult` and `receiveEvent`.
    func receiveSessionMessage(_ pointer: UnsafeRawPointer, size: Int) -> Bool {
        guard sessionID == nil, size > 0 else { return false }
        // Only a message that names a session at all is parsed here; the page's own are left to CEF, and are not copied or read
        // beyond a search for the name, which every message of the page, its results and its events, goes through.
        guard Self.contains("\"sessionId\"", in: pointer, size: size) else { return false }
        let data = Data(bytesNoCopy: UnsafeMutableRawPointer(mutating: pointer), count: size, deallocator: .none)
        loadStatistics.sessionMessagesParsed += 1
        guard let message = try? Self.jsonObject(data) as? [String: Any] else {
            // Chromium puts a session's ID last: one that ends so is dropped rather than handed to the page's session.
            let tail = String(decoding: data.suffix(160), as: UTF8.self)
            return tail.range(of: #","sessionId":"[^"\\]*"\}\s*$"#, options: .regularExpression) != nil
        }
        guard let session = message["sessionId"] as? String else { return false }
        guard !closed else { return true }
        if let id = message["id"] as? Int {
            guard isPending(id, in: session) else { return true }
            if size > 8 * 1_048_576 {
                finishFailure(id: id, error: ChromiumError.protocolFailure("DevTools result is too large."))
            } else if let error = message["error"] as? [String: Any] {
                finishFailure(id: id, error: ChromiumError.protocolFailure(error["message"] as? String ?? "DevTools command failed."))
            } else {
                finishSuccess(id: id, value: message["result"] as? [String: Any] ?? [:])
            }
        } else if let method = message["method"] as? String, size <= 8 * 1_048_576 {
            sessions[session]?.receiveEvent(name: method, params: message["params"] as? [String: Any] ?? [:])
        }
        return true
    }

    /// A cross-site frame this session auto-attached to. It is paused: its session registers the listed scripts, then lets it
    /// run, whatever happened. Anything but a frame (a worker) is resumed and let go at once.
    func attachedToTarget(_ params: [String: Any]) {
        let owner = root ?? self
        guard let session = params["sessionId"] as? String, !session.isEmpty, owner.sessions[session] == nil else { return }
        let info = params["targetInfo"] as? [String: Any]
        let target = info?["targetId"] as? String ?? ""
        let child = ChromiumDevTools(root: owner, parent: self, sessionID: session, targetID: target)
        child.scripts = owner.scripts.filter { Self.runsInCrossSiteFrames($0) }.map {
            Script(source: $0.source, worldName: $0.worldName, injectionTime: $0.injectionTime, mainFrameOnly: $0.mainFrameOnly)
        }
        owner.sessions[session] = child
        let isFrame = info?["type"] as? String == "iframe" && !target.isEmpty
        Task { await child.startCrossSiteFrameSession(isFrame: isFrame) }
    }

    private func startCrossSiteFrameSession(isFrame: Bool) async {
        let attached = ContinuousClock.now
        var ready = isFrame
        if ready {
            do { try await prepare() } catch { ready = false }
        }
        // A frame left waiting would never load: it is resumed even when its session already ended here.
        _ = try? await root?.command("Runtime.runIfWaitingForDebugger", params: [:], session: sessionID, dispatchCheck: nil,
                                     prepareParameters: nil)
        if isFrame, let root {
            let held = ContinuousClock.now - attached
            root.loadStatistics.framePauses += 1
            root.loadStatistics.framePauseTotal += held
            root.loadStatistics.framePauseMax = max(root.loadStatistics.framePauseMax, held)
        }
        guard !ready || closed else { return }
        if let parent, let sessionID {
            _ = try? await parent.command("Target.detachFromTarget", params: ["sessionId": sessionID])
        }
        endCrossSiteFrameSession()
    }

    /// Chromium let go of one of this session's frames: it was removed, navigated back into its parent's process or into
    /// another, or its process is gone.
    func detachedFromTarget(_ params: [String: Any]) {
        guard let session = params["sessionId"] as? String, let child = (root ?? self).sessions[session], child.parent === self else { return }
        child.endCrossSiteFrameSession()
    }

    /// The renderer of one of this session's frames crashed: its documents are gone, its session stays for the reloaded frame.
    func targetCrashed(_ params: [String: Any]) {
        guard let target = params["targetId"] as? String,
              let child = (root ?? self).sessions.values.first(where: { $0.targetID == target && $0.parent === self }) else { return }
        let documents = child.framesByID.values.map(\.documentID)
        // A crashed renderer plays nothing, and its frames' last word about their sound would otherwise stand (the reloaded
        // frame says its own, and the old one is forgotten here, so nothing would retire it).
        page?.owner?.onFramesRetired?(Set(child.framesByID.keys))
        child.forgetDocuments()
        child.invalidateCredentialContexts(documents: documents, pageWide: false)
    }

    /// Everything the session knew is dropped, its pending commands fail, the sessions it attached end with it, and every
    /// document it reported ends its credential contexts (autofill forgets those frames).
    func endCrossSiteFrameSession() {
        guard let sessionID, !closed else { return }
        closed = true
        let documents = framesByID.values.map(\.documentID)
        frameRevision &+= 1
        // What these frames said about their sound is over; they send no `Page.frameDetached` when their session ends as a whole.
        if !framesByID.isEmpty {
            page?.owner?.onFramesRetired?(Set(framesByID.keys))
        }
        framesByID.removeAll()
        contextsByUniqueID.removeAll()
        uniqueIDByExecutionID.removeAll()
        scripts.removeAll()
        bindingWorlds.removeAll()
        root?.sessions[sessionID] = nil
        root?.failPending(in: sessionID)
        endCrossSiteFrameSessions()
        invalidateCredentialContexts(documents: documents, pageWide: false)
    }

    /// Ends the cross-site frame sessions under this one: for the page's session, all of them.
    func endCrossSiteFrameSessions() {
        for child in Array((root ?? self).sessions.values) where sessionID == nil || child.parent === self {
            child.endCrossSiteFrameSession()
        }
    }

    /// The session that reported `frame`'s document: the page's own, or a cross-site frame's. A frame no session knows is the
    /// page's, which then finds it stale.
    func session(for frame: BrowserFrame?) -> ChromiumDevTools {
        guard sessionID == nil, let frame, let id = frame.chromiumID, framesByID[id]?.documentID != frame.documentID else { return self }
        return sessions.values.first { !$0.closed && $0.framesByID[id]?.documentID == frame.documentID } ?? self
    }

    /// A cross-site frame session speaks only for its own frame and the frames of its process under it.
    func isInOwnSubtree(_ frame: FrameState) -> Bool {
        sessionID == nil || frame.id == targetID || frame.parentID.map { framesByID[$0] != nil } == true
    }

    /// The page's frames and those of every cross-site frame session.
    func framesIncludingCrossSiteFrames() async throws -> [BrowserFrame] {
        var all = try await frames()
        for child in Array(sessions.values) where !child.closed {
            all += (try? await child.frames()) ?? []
        }
        return all
    }
}
