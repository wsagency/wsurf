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
        guard !isLoading, frame.hasTrustedSecurityOrigin, !frame.documentID.isEmpty else {
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
            guard frame.isMainFrame,
                  PageFrameRegistry.shared.isCurrent(frame, in: self),
                  await PageFrameRegistry.shared.isLive(frame, in: self) else {
                throw WebAuthnContextError.policyUnavailable
            }
            chain = [frame]
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
            guard let allowed = PageFrameRegistry.shared.mainFramePolicyAllows(
                frame, feature: feature, in: self
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
        guard generation == credentialGeneration, !isLoading, !isClosed else {
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
}
