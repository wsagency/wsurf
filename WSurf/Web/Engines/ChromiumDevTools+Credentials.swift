// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import WebKit

/// Credential (WebAuthn) frame checks of the page's session. Moved verbatim out of `ChromiumDevTools.swift` for the type's length.
extension ChromiumDevTools {
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
        let response = try await command("Runtime.evaluate", params: address(snapshot).merging([
            "expression": documentGuard(snapshot) + "navigator.userActivation?.isActive === true",
            "returnByValue": true,
            "awaitPromise": false,
            "userGesture": false,
        ]) { $1 }, dispatchCheck: { [self] in
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
}
