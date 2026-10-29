// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

nonisolated enum WebAuthnOperation: String, Sendable {
    case create
    case get
}

nonisolated enum WebAuthnContextError: Error, Sendable {
    case privateProfile
    case closedPage
    case staleFrame
    case untrustedOrigin
    case insecureOrigin
    case policyUnavailable
    case policyDenied
    case crossOriginCreationRequiresActivation
    case crossOriginCreationActivationCannotBeConsumed
    case unsupportedWebKitFrame
}

/// Native engine evidence bound to one page generation and document. Consumers revalidate after asynchronous work and at dispatch.
@MainActor
final class WebAuthnContext {
    let profileID: UUID
    let isPrivate: Bool
    let origin: String
    let topOrigin: String?
    let crossOrigin: Bool
    let operation: WebAuthnOperation
    let credentialGeneration: UInt64
    let policyFeature: String
    let frame: BrowserFrame
    let frameDocumentID: String
    let executionContextID: String?
    let pageIdentity: ObjectIdentifier
    let originEvidence: BrowserSecurityOrigin
    private weak var page: BrowserPage?

    fileprivate init(
        page: BrowserPage,
        frame: BrowserFrame,
        origin: String,
        topOrigin: String?,
        crossOrigin: Bool,
        operation: WebAuthnOperation,
        policyFeature: String,
        executionContextID: String?
    ) {
        self.page = page
        pageIdentity = ObjectIdentifier(page)
        profileID = page.profileID
        isPrivate = page.isPrivate
        credentialGeneration = page.credentialGeneration
        self.frame = frame
        frameDocumentID = frame.documentID
        originEvidence = frame.securityOrigin
        self.origin = origin
        self.topOrigin = topOrigin
        self.crossOrigin = crossOrigin
        self.operation = operation
        self.policyFeature = policyFeature
        self.executionContextID = executionContextID
    }

    func validate() async throws {
        guard let page else { throw WebAuthnContextError.closedPage }
        try await page.validateCredentialContext(self)
    }

    func validateForDispatch() throws {
        guard let page else { throw WebAuthnContextError.closedPage }
        try page.validateCredentialContextForDispatch(self)
    }

    func belongs(to page: BrowserPage) -> Bool {
        pageIdentity == ObjectIdentifier(page) && self.page === page
    }
}

extension BrowserPage {
    func credentialContext(for frame: BrowserFrame, operation: WebAuthnOperation) async throws -> WebAuthnContext {
        guard !isClosed else { throw WebAuthnContextError.closedPage }
        guard !isPrivate else { throw WebAuthnContextError.privateProfile }
        // No loading gate: a page asks while its subresources still load (Google does), and a navigation start is already
        // fenced by the credential generation and the registry's current-document and policy evidence.
        guard frame.hasTrustedSecurityOrigin, !frame.documentID.isEmpty else {
            throw WebAuthnContextError.staleFrame
        }
        let generation = credentialGeneration
        let feature = operation == .create
            ? "publickey-credentials-create"
            : "publickey-credentials-get"
        let chain: [BrowserFrame]
        if let chromium {
            chain = try await chromium.devTools.frameChain(for: frame)
        } else {
            chain = try await webKitFrameChain(for: frame, feature: feature)
        }
        guard let topFrame = chain.last, topFrame.isMainFrame,
              chain.first?.documentID == frame.documentID else {
            throw WebAuthnContextError.untrustedOrigin
        }
        let origin = try Self.credentialOrigin(frame.securityOrigin)
        let top = try Self.credentialOrigin(topFrame.securityOrigin)
        let crossOrigin = try chain.contains { candidate in
            try Self.credentialOrigin(candidate.securityOrigin).serialized != origin.serialized
        }
        let topOrigin = crossOrigin ? top.serialized : nil
        let executionContextID: String?
        if let chromium {
            guard try await chromium.devTools.permissionsPolicyAllows(frame: frame, feature: feature) else {
                throw WebAuthnContextError.policyDenied
            }
            if operation == .create, crossOrigin {
                let active = try await chromium.devTools.transientUserActivationIsActive(
                    in: frame, world: PageAutomationGuard.world
                )
                guard active else { throw WebAuthnContextError.crossOriginCreationRequiresActivation }
                throw WebAuthnContextError.crossOriginCreationActivationCannotBeConsumed
            }
            executionContextID = try await chromium.devTools.executionContextIdentity(
                for: frame, world: PageAutomationGuard.world
            )
        } else {
            // A WebKit frame is served only within the top document's origin (`webKitFrameChain`), so that document's policy is its own.
            guard let allowed = PageFrameRegistry.shared.mainFramePolicyAllows(
                topFrame, feature: feature, in: self
            ) else {
                throw WebAuthnContextError.policyUnavailable
            }
            guard allowed else { throw WebAuthnContextError.policyDenied }
            if operation == .create, crossOrigin {
                let active = try await evaluateJavaScript(
                    "navigator.userActivation?.isActive === true",
                    in: frame,
                    contentWorld: PageAutomationGuard.world
                ) as? Bool == true
                guard active else { throw WebAuthnContextError.crossOriginCreationRequiresActivation }
                throw WebAuthnContextError.crossOriginCreationActivationCannotBeConsumed
            }
            executionContextID = nil
        }
        guard generation == credentialGeneration, !isClosed else {
            throw WebAuthnContextError.staleFrame
        }
        let context = WebAuthnContext(
            page: self,
            frame: frame,
            origin: origin.serialized,
            topOrigin: topOrigin,
            crossOrigin: crossOrigin,
            operation: operation,
            policyFeature: feature,
            executionContextID: executionContextID
        )
        try await validateCredentialContext(context)
        return context
    }

    /// WebKit's chain, requesting frame first. WebKit names neither a frame's ancestors nor what its embedder allowed it, so a frame
    /// is served only when its own document shows, from WSurf's world, that every ancestor is of its origin and that no frame
    /// element on the way withholds `feature` (`allow`). Such a frame is not cross-origin. Under an embedder of another origin it
    /// is refused: whether that embedder delegated the feature cannot be read.
    private func webKitFrameChain(for frame: BrowserFrame, feature: String) async throws -> [BrowserFrame] {
        let registry = PageFrameRegistry.shared
        guard registry.isCurrent(frame, in: self), await registry.isLive(frame, in: self) else {
            throw WebAuthnContextError.policyUnavailable
        }
        guard !frame.isMainFrame else { return [frame] }
        guard let top = registry.mainFrame(in: self), top.securityOrigin == frame.securityOrigin else {
            throw WebAuthnContextError.policyUnavailable
        }
        let origin = try Self.credentialOrigin(frame.securityOrigin).serialized
        let found = try? await callAsyncJavaScript(
            Self.frameAncestry, arguments: ["nonce": frame.documentID], in: frame, contentWorld: PageAutomationGuard.world
        ) as? [String: Any]
        guard let ancestors = found?["ancestors"] as? [String], let allow = found?["allow"] as? [Any],
              !ancestors.isEmpty, ancestors.count == allow.count, ancestors.allSatisfy({ $0 == origin }) else {
            throw WebAuthnContextError.policyUnavailable
        }
        guard allow.allSatisfy({ Self.allowAttribute($0 as? String, permits: feature, to: origin) }) else {
            throw WebAuthnContextError.policyDenied
        }
        guard registry.isCurrent(frame, in: self), registry.mainFrame(in: self)?.documentID == top.documentID else {
            throw WebAuthnContextError.staleFrame
        }
        return [frame, top]
    }

    /// Read in the frame's registered document, in WSurf's world (the page cannot reach it): its ancestors' origins, nearest first,
    /// and the `allow` attribute of each frame element on the way up. Null for another document, or when a frame element cannot be
    /// read, as under an embedder of another origin.
    private static let frameAncestry = """
        if (globalThis.__wsurfNativeFrameNonce !== nonce) return null;
        const allow = [];
        for (let view = window; view !== view.top; view = view.parent) {
          const element = view.frameElement;
          if (!element) return null;
          allow.push(element.getAttribute('allow'));
        }
        return {ancestors: Array.from(location.ancestorOrigins), allow};
        """

    /// Whether an iframe's `allow` attribute lets a document of `origin`, its embedder's own origin, use `feature`. An attribute
    /// that does not name the feature leaves its default allowlist ('self'), which such a frame meets; a bare feature name means
    /// 'src', the frame's own origin, which is the embedder's here too. The first mention of the feature counts.
    nonisolated static func allowAttribute(_ attribute: String?, permits feature: String, to origin: String) -> Bool {
        for directive in (attribute ?? "").split(separator: ";") {
            let tokens = directive.split(whereSeparator: \.isWhitespace).map { $0.lowercased() }
            guard tokens.first == feature else { continue }
            let permitted: Set = ["*", "'self'", "'src'", origin.lowercased()]
            return tokens.count == 1 || tokens.dropFirst().contains { permitted.contains($0.hasSuffix("/") ? String($0.dropLast()) : $0) }
        }
        return true
    }

    /// WebKit: the document whose policy rules the context's frame, served only within the top document's origin
    /// (`webKitFrameChain`): the frame itself on top, else the current main frame. Nil when either is not current.
    func webKitPolicyFrame(for context: WebAuthnContext) -> BrowserFrame? {
        guard context.executionContextID == nil, !context.crossOrigin, context.topOrigin == nil,
              PageFrameRegistry.shared.isCurrent(context.frame, in: self) else { return nil }
        guard !context.frame.isMainFrame else { return context.frame }
        guard let top = PageFrameRegistry.shared.mainFrame(in: self), top.securityOrigin == context.frame.securityOrigin else {
            return nil
        }
        return top
    }
}
