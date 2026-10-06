// SPDX-License-Identifier: Apache-2.0
#if DEBUG
import AppKit
import CryptoKit
import Foundation
import LocalAuthentication
import Security
import WebKit

/// Temporary owned-fixture authenticator. Keys live only in this Debug-stage process.
/// No production vault, platform credential provider, trust store or engine settings are changed.
@MainActor
enum CredentialWebAuthnProbe {
    private static let world = WKContentWorld.world(name: "WSurfOwnedCredentialProbe")
    private static let handler = "wsurfOwnedCredentialProbe"
    private static var sessions: [ObjectIdentifier: Session] = [:]

    static func present(coordinator: AppCoordinator) {
        guard StageMode.isActive, ProcessInfo.processInfo.environment["WSURF_CREDENTIAL_PROBE"] == "1",
              NSApp.isActive else { return }
        Task {
            let alert = NSAlert()
            alert.messageText = "Owned WebAuthn transport probe"
            alert.informativeText = "Open the owned HTTPS fixture in a stage tab and select its rendering engine first. Arming reloads only that active tab. Registration/assertion still require a webpage button, fresh native confirmation and fresh LocalAuthentication for required UV. Iframes are rejected: native effective Permissions Policy is unavailable. No Apple fallback."
            alert.addButton(withTitle: "Arm Active Fixture Tab and Reload")
            alert.addButton(withTitle: "Disarm Active Tab")
            alert.addButton(withTitle: "Cancel")
            guard let tab = coordinator.browser.activeTab, tab.isMaterialised,
                  let window = tab.page.window, window.isKeyWindow else { return }
            let answer = await alert.beginSheetModal(for: window)
            guard NSApp.isActive, coordinator.browser.activeTab === tab, tab.isMaterialised else { return }
            let page = tab.page
            let key = ObjectIdentifier(page)
            if answer == .alertSecondButtonReturn {
                sessions.removeValue(forKey: key)?.disarm()
                coordinator.statusMessage = "Owned WebAuthn probe disarmed; close the owned tab to remove installed scripts."
                return
            }
            guard answer == .alertFirstButtonReturn else { return }
            do {
                let origin = try fixtureOrigin()
                guard originOf(page.url) == origin else {
                    throw Failure("SecurityError", "The active native page is not the configured owned HTTPS localhost fixture.")
                }
                for (id, existing) in sessions where existing.isClosed {
                    existing.disarm()
                    sessions[id] = nil
                }
                sessions.removeValue(forKey: key)?.disarm()
                let session = try Session(coordinator: coordinator, tab: tab, page: page, origin: origin)
                sessions[key] = session
                session.arm()
                tab.reload() // this exact foreground button explicitly authorizes this owned-tab reload
                coordinator.statusMessage = "Owned WebAuthn probe armed on \(page.engine.rawValue). Native gate remains unverified."
            } catch {
                coordinator.statusMessage = (error as? Failure)?.message ?? "Owned WebAuthn probe could not be armed."
            }
        }
    }

    private static func fixtureOrigin() throws -> String {
        let raw = ProcessInfo.processInfo.environment["WSURF_CREDENTIAL_FIXTURE_ORIGIN"] ?? "https://localhost:8443"
        guard let url = URL(string: raw), url.scheme == "https", url.host == "localhost",
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.isEmpty || url.path == "/", (url.port ?? 443) > 0,
              let origin = originOf(url) else {
            throw Failure("SecurityError", "Fixture origin must be an exact HTTPS localhost origin.")
        }
        return origin
    }

    private static func originOf(_ url: URL?) -> String? {
        guard let url, url.scheme == "https", url.host == "localhost", url.user == nil, url.password == nil else { return nil }
        let port = url.port ?? 443
        return "https://localhost" + (port == 443 ? "" : ":\(port)")
    }

    private struct Failure: Error {
        let name: String
        let message: String
        init(_ name: String, _ message: String) { self.name = name; self.message = message }
    }

    private struct Credential {
        let id: Data
        let user: Data
        let username: String
        let key: P256.Signing.PrivateKey
    }

    @MainActor
    private final class Pending {
        let id: String
        let document: String
        let frame: BrowserFrame
        let generation: UInt64
        let deadline: ContinuousClock.Instant
        var cancelled = false
        var context: LAContext?
        var sheet: NSWindow?
        init(id: String, document: String, frame: BrowserFrame, generation: UInt64, timeout: Double) {
            self.id = id; self.document = document; self.frame = frame; self.generation = generation
            deadline = .now.advanced(by: .seconds(timeout))
        }
        func cancel() {
            cancelled = true
            context?.invalidate()
            if let sheet, let parent = sheet.sheetParent { parent.endSheet(sheet, returnCode: .abort) }
        }
    }

    @MainActor
    private final class Session {
        weak var coordinator: AppCoordinator?
        weak var tab: BrowserTab?
        weak var page: BrowserPage?
        let origin: String
        let profileID: UUID
        let anchor: SecCertificate?
        var generation: UInt64 = 0
        var armed = false
        var credentials: [Credential] = []
        var pending: [String: Pending] = [:]
        var oldStarted: ((PageNavigation?, URL?) -> Void)?
        var oldCommitted: ((PageNavigation?) -> Void)?
        var oldTerminated: (() -> Void)?
        var observers: [NSObjectProtocol] = []
        var isClosed: Bool { page == nil || page?.isClosed == true || tab?.isClosed != false }

        init(coordinator: AppCoordinator, tab: BrowserTab, page: BrowserPage, origin: String) throws {
            self.coordinator = coordinator; self.tab = tab; self.page = page; self.origin = origin
            profileID = page.profileID
            anchor = try Self.ownedAnchor()
        }

        private static func ownedAnchor() throws -> SecCertificate? {
            guard let path = ProcessInfo.processInfo.environment["WSURF_CREDENTIAL_FIXTURE_CERT"] else { return nil }
            guard let home = StageMode.home else { throw Failure("SecurityError", "Owned stage home is unavailable.") }
            let file = URL(filePath: path).resolvingSymlinksInPath().standardizedFileURL
            let root = home.resolvingSymlinksInPath().standardizedFileURL.path + "/"
            guard file.path.hasPrefix(root),
                  let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 65536 else {
                throw Failure("SecurityError", "The optional fixture certificate must be a bounded public certificate inside WSURF_STAGE_HOME.")
            }
            let data = try Data(contentsOf: file)
            let der: Data
            if let text = String(data: data, encoding: .utf8), text.contains("-----BEGIN CERTIFICATE-----") {
                let body = text.replacingOccurrences(of: "-----BEGIN CERTIFICATE-----", with: "")
                    .replacingOccurrences(of: "-----END CERTIFICATE-----", with: "")
                    .components(separatedBy: .whitespacesAndNewlines).joined()
                guard let decoded = Data(base64Encoded: body) else { throw Failure("SecurityError", "Invalid owned certificate PEM.") }
                der = decoded
            } else { der = data }
            guard let certificate = SecCertificateCreateWithData(nil, der as CFData) else {
                throw Failure("SecurityError", "Invalid owned fixture certificate.")
            }
            return certificate
        }

        func arm() {
            guard let page else { return }
            armed = true
            oldStarted = page.onNavigationStarted
            oldCommitted = page.onNavigationCommitted
            oldTerminated = page.onContentProcessTerminated
            page.onNavigationStarted = { [weak self] navigation, url in
                self?.invalidate()
                self?.oldStarted?(navigation, url)
            }
            page.onNavigationCommitted = { [weak self] navigation in
                self?.invalidate()
                self?.oldCommitted?(navigation)
            }
            page.onContentProcessTerminated = { [weak self] in
                self?.invalidate()
                self?.credentials.removeAll()
                self?.oldTerminated?()
            }
            for notification in [NSApplication.didResignActiveNotification, NSWorkspace.sessionDidResignActiveNotification] {
                let center = notification == NSWorkspace.sessionDidResignActiveNotification
                    ? NSWorkspace.shared.notificationCenter : NotificationCenter.default
                observers.append(center.addObserver(forName: notification, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.invalidate() }
                })
            }
            page.addScriptMessageHandler(name: handler, in: world) { [weak self] message in self?.receive(message) }
            // The isolated relay owns the document fence. Page JavaScript supplies options, never origin/policy.
            page.installScript(isolatedScript, in: world, injectionTime: .atDocumentStart, forMainFrameOnly: false)
            let capability = LAContext()
            let canVerify = capability.canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
            capability.invalidate() // capability discovery is not authentication or reusable approval
            let adapter = adapterScript.replacingOccurrences(of: "__WSURF_OWNED_UV_CAPABILITY__", with: canVerify ? "true" : "false")
                .replacingOccurrences(of: "__WSURF_OWNED_ORIGIN__", with: "\"\(origin)\"")
            page.installScript(adapter, in: .page, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        }

        func invalidate() {
            generation &+= 1
            for request in pending.values { request.cancel() }
        }

        func disarm() {
            guard armed else { return }
            armed = false
            invalidate()
            credentials.removeAll()
            if let page {
                page.removeScriptMessageHandler(name: handler, in: world)
                page.onNavigationStarted = oldStarted
                page.onNavigationCommitted = oldCommitted
                page.onContentProcessTerminated = oldTerminated
            }
            for observer in observers {
                NotificationCenter.default.removeObserver(observer)
                NSWorkspace.shared.notificationCenter.removeObserver(observer)
            }
            observers.removeAll()
        }

        func receive(_ message: BrowserScriptMessage) {
            guard armed, let page, message.page === page,
                  let body = message.body as? [String: Any],
                  let id = body["id"] as? String, (1...80).contains(id.utf8.count),
                  let document = body["document"] as? String, (1...80).contains(document.utf8.count) else { return }
            if body["action"] as? String == "cancel" {
                if let request = pending[id], request.document == document { request.cancel() }
                return
            }
            guard body["action"] as? String == "request" else { return }
            let timeout = min(120.0, max(1.0, (body["timeout"] as? Double ?? 60000) / 1000))
            let request = Pending(id: id, document: document, frame: message.frameInfo, generation: generation, timeout: timeout)
            guard pending.isEmpty else {
                Task { await deliver(request, error: Failure("NotAllowedError", "A native fixture ceremony is already outstanding.")) }
                return
            }
            pending[id] = request
            Task {
                let timer = Task { [weak request] in
                    try? await Task.sleep(for: .seconds(timeout))
                    if !Task.isCancelled { request?.cancel() }
                }
                defer {
                    timer.cancel()
                    pending[id] = nil
                    request.context?.invalidate()
                }
                do {
                    try await validate(request)
                    let prepared = try await perform(body, request: request)
                    try await validate(request)
                    if let registration = prepared.registration { credentials.append(registration) }
                    let delivered = await deliver(request, result: prepared.result)
                    if !delivered, let registration = prepared.registration {
                        credentials.removeAll { $0.id == registration.id }
                    }
                } catch {
                    _ = await deliver(request, error: error as? Failure ?? Failure("NotAllowedError", "Owned native ceremony failed or was cancelled."))
                }
            }
        }

        private func nativeContext(_ request: Pending) throws {
            guard armed, !request.cancelled, request.generation == generation, ContinuousClock.now < request.deadline,
                  StageMode.isActive, ProcessInfo.processInfo.environment["WSURF_CREDENTIAL_PROBE"] == "1",
                  let page, !page.isClosed, let tab, !tab.isClosed, tab.isMaterialised, tab.page === page,
                  coordinator?.browser.activeTab === tab, page.profileID == profileID,
                  ChromiumRuntime.shared.currentProfile.id == profileID,
                  NSApp.isActive, let window = page.window, window.isVisible, window.isKeyWindow,
                  !page.isHiddenOrHasHiddenAncestor, !page.visibleRect.isEmpty,
                  !page.isLoading, originOf(page.url) == origin else {
                throw Failure("NotAllowedError", "The native page/profile/document is no longer foreground and live.")
            }
            guard request.frame.isMainFrame else {
                throw Failure("SecurityError", "Iframe native effective Permissions Policy/top-context evidence is unavailable; context rejected.")
            }
            let security = request.frame.securityOrigin
            let expectedPort = URL(string: origin)?.port ?? 443
            guard security.protocol == "https", security.host == "localhost",
                  (security.port == 0 ? 443 : security.port) == expectedPort,
                  originOf(request.frame.request.url) == origin, page.hasOnlySecureContent else {
                throw Failure("SecurityError", "Native HTTPS origin or secure-content evidence is unavailable.")
            }
            let source = page.webKit?.serverTrust ?? page.chromium?.certificateTrust()
            guard let source, let chain = SecTrustCopyCertificateChain(source) as? [SecCertificate], !chain.isEmpty else {
                throw Failure("SecurityError", "Native TLS certificate-chain evidence is unavailable.")
            }
            var trust: SecTrust?
            guard SecTrustCreateWithCertificates(chain as CFArray, SecPolicyCreateSSL(true, "localhost" as CFString), &trust) == errSecSuccess,
                  let trust else { throw Failure("SecurityError", "Could not establish native TLS proof.") }
            guard SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess else {
                throw Failure("SecurityError", "Could not disable external trust-network fetching.")
            }
            if let anchor {
                guard SecTrustSetAnchorCertificates(trust, [anchor] as CFArray) == errSecSuccess,
                      SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess else {
                    throw Failure("SecurityError", "Could not scope TLS proof to the owned fixture certificate.")
                }
            }
            guard SecTrustEvaluateWithError(trust, nil) else {
                throw Failure("SecurityError", "Native TLS verification failed. No global trust or browser bypass is permitted.")
            }
        }

        private func validate(_ request: Pending) async throws {
            try nativeContext(request)
            guard let page else { throw Failure("NotAllowedError", "Page closed.") }
            if let chromium = page.chromium, try await chromium.isLive(frame: request.frame) == false {
                throw Failure("NotAllowedError", "Chromium native document was replaced.")
            }
            let live = try await page.callAsyncJavaScript("return globalThis.__wsurfOwnedWebAuthnFence?.live(documentID, requestID) === true;",
                arguments: ["documentID": request.document, "requestID": request.id], in: request.frame, contentWorld: world)
            guard live as? Bool == true else { throw Failure("NotAllowedError", "Isolated document fence is stale or request cancelled.") }
            try nativeContext(request)
        }

        private func deliver(_ request: Pending, result: [String: Any]? = nil, error: Failure? = nil) async -> Bool {
            guard armed, request.generation == generation, let page, !page.isClosed else { return false }
            if result != nil {
                do { try nativeContext(request) } catch { return false }
            }
            if let chromium = page.chromium, (try? await chromium.isLive(frame: request.frame)) != true { return false }
            if result != nil {
                do { try nativeContext(request) } catch { return false }
            }
            let value: [String: Any] = result.map { ["result": $0] }
                ?? ["error": ["name": error?.name ?? "NotAllowedError", "message": error?.message ?? "Request rejected."]]
            // Atomically checks the isolated document/request fence and emits in that same execution.
            // WKFrameInfo has no document ID; a page-world token is deliberately never used as proof.
            let delivered = try? await page.callAsyncJavaScript("return globalThis.__wsurfOwnedWebAuthnFence?.deliver(documentID, requestID, value) === true;",
                arguments: ["documentID": request.document, "requestID": request.id, "value": value],
                in: request.frame, contentWorld: world)
            return delivered as? Bool == true
        }

        private func perform(_ body: [String: Any], request: Pending) async throws -> (result: [String: Any], registration: Credential?) {
            guard let operation = body["operation"] as? String, ["create", "get"].contains(operation),
                  let options = body["options"] as? [String: Any],
                  (body["mediation"] as? String ?? "optional") == "optional" else {
                throw Failure("NotSupportedError", "Only explicit non-conditional create/get probe ceremonies are supported.")
            }
            if let raw = options["extensions"], (raw as? [String: Any])?.isEmpty != true {
                throw Failure("NotSupportedError", "The owned probe does not claim extension support.")
            }
            let challenge = try decode(options["challenge"], maximum: 1024)
            guard challenge.count >= 16 else { throw Failure("TypeError", "Challenge is too short.") }
            let rawRP = operation == "create" ? (options["rp"] as? [String: Any])?["id"] : options["rpId"]
            if let rawRP, !(rawRP is String) { throw Failure("TypeError", "RP ID must be a string.") }
            let rp = rawRP as? String
            guard (rp ?? "localhost") == "localhost" else {
                throw Failure("SecurityError", "Only the native-owned localhost fixture RP is allowed.")
            }
            let selection = options["authenticatorSelection"] as? [String: Any]
            let verification = (operation == "create" ? selection?["userVerification"] : options["userVerification"]) as? String ?? "preferred"
            guard ["required", "preferred", "discouraged"].contains(verification) else {
                throw Failure("TypeError", "Invalid userVerification.")
            }
            let credential: Credential
            if operation == "create" {
                guard let algorithms = options["pubKeyCredParams"] as? [[String: Any]], algorithms.count <= 32,
                      algorithms.contains(where: { $0["type"] as? String == "public-key" && $0["alg"] as? Int == -7 }) else {
                    throw Failure("NotSupportedError", "No supported ES256 algorithm; nothing was created.")
                }
                guard let user = options["user"] as? [String: Any],
                      let username = user["name"] as? String, (1...128).contains(username.utf8.count),
                      let displayName = user["displayName"] as? String, displayName.utf8.count <= 128 else {
                    throw Failure("TypeError", "A bounded account identity is required.")
                }
                let userID = try decode(user["id"], maximum: 64)
                guard !userID.isEmpty, credentials.count < 128 else { throw Failure("NotAllowedError", "Invalid identity or probe capacity reached.") }
                let excluded = try ids(options["excludeCredentials"])
                guard !credentials.contains(where: { excluded.contains($0.id) }) else {
                    throw Failure("InvalidStateError", "An excluded owned credential already exists.")
                }
                let attestation = options["attestation"] as? String ?? "none"
                guard ["direct", "indirect", "none"].contains(attestation), selection?["authenticatorAttachment"] as? String != "cross-platform" else {
                    throw Failure("NotSupportedError", "Unsupported attestation/attachment; no hardware or enterprise claim is made.")
                }
                credential = Credential(id: try randomBytes(32), user: userID, username: username, key: P256.Signing.PrivateKey())
            } else {
                let allowed = try ids(options["allowCredentials"])
                let available = credentials.filter { allowed.isEmpty || allowed.contains($0.id) }
                guard !available.isEmpty else { throw Failure("NotAllowedError", "No matching ephemeral owned credential.") }
                credential = try await choose(available, request: request)
            }
            try await validate(request)
            let verified = try await consent(credential, operation: operation, verification: verification, request: request)
            try await validate(request)
            let client = try JSONSerialization.data(withJSONObject: ["type": operation == "create" ? "webauthn.create" : "webauthn.get",
                "challenge": base64(challenge), "origin": origin, "crossOrigin": false], options: [.sortedKeys])
            var auth = Data(SHA256.hash(data: Data("localhost".utf8)))
            auth.append(0x01 | (verified ? 0x04 : 0) | (operation == "create" ? 0x40 : 0))
            auth.append(Data(repeating: 0, count: 4)) // transferable software credential counter is zero
            let response: [String: Any]
            if operation == "create" {
                let point = credential.key.publicKey.x963Representation
                let cose = map([(integer(1), integer(2)), (integer(3), integer(-7)), (integer(-1), integer(1)),
                                (integer(-2), bytes(Data(point[1..<33]))), (integer(-3), bytes(Data(point[33..<65])))])
                auth.append(Data(repeating: 0, count: 16)) // no hardware AAGUID/attestation claim
                auth.append(contentsOf: [UInt8(credential.id.count >> 8), UInt8(credential.id.count & 255)])
                auth.append(credential.id)
                auth.append(cose)
                let signature = try credential.key.signature(for: auth + Data(SHA256.hash(data: client))).derRepresentation
                let none = options["attestation"] as? String == "none" || options["attestation"] == nil
                let attestation = map([(text("fmt"), text(none ? "none" : "packed")), (text("authData"), bytes(auth)),
                    (text("attStmt"), none ? map([]) : map([(text("alg"), integer(-7)), (text("sig"), bytes(signature))]))])
                response = ["clientDataJSON": base64(client), "attestationObject": base64(attestation),
                            "authenticatorData": base64(auth), "publicKey": base64(credential.key.publicKey.derRepresentation)]
            } else {
                let signature = try credential.key.signature(for: auth + Data(SHA256.hash(data: client))).derRepresentation
                response = ["clientDataJSON": base64(client), "authenticatorData": base64(auth),
                            "signature": base64(signature), "userHandle": base64(credential.user)]
            }
            return (["operation": operation, "id": base64(credential.id), "rawId": base64(credential.id), "response": response],
                    operation == "create" ? credential : nil)
        }

        private func choose(_ choices: [Credential], request: Pending) async throws -> Credential {
            if choices.count == 1 { return choices[0] }
            try await validate(request)
            guard let window = page?.window else { throw Failure("NotAllowedError", "No foreground window.") }
            let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 28))
            for choice in choices { popup.addItem(withTitle: choice.username + " · " + base64(choice.id.prefix(6))) }
            let alert = NSAlert()
            alert.messageText = "Choose owned localhost account"
            alert.informativeText = "Selected account is bound to its original RP and user handle."
            alert.accessoryView = popup
            alert.addButton(withTitle: "Select Account")
            alert.addButton(withTitle: "Cancel")
            request.sheet = alert.window
            let answer = await alert.beginSheetModal(for: window)
            request.sheet = nil
            try await validate(request)
            guard answer == .alertFirstButtonReturn, choices.indices.contains(popup.indexOfSelectedItem) else {
                throw Failure("NotAllowedError", "Account selection cancelled.")
            }
            return choices[popup.indexOfSelectedItem]
        }

        private func consent(_ credential: Credential, operation: String, verification: String, request: Pending) async throws -> Bool {
            try await validate(request)
            guard let window = page?.window else { throw Failure("NotAllowedError", "No native foreground window.") }
            let alert = NSAlert()
            alert.messageText = operation == "create" ? "Create owned fixture passkey?" : "Use owned fixture passkey?"
            alert.informativeText = "Native domain: \(origin)\nRP: localhost\nAccount: \(credential.username)\nUser handle: \(base64(credential.user))\nEphemeral credential: \(base64(credential.id))\n\nOnly this isolated test account is affected. UV required: \(verification == "required" ? "yes — fresh system verification follows" : "no — UV will remain false"). No Apple credential is created or used."
            alert.addButton(withTitle: operation == "create" ? "Create Owned Test Passkey" : "Sign Owned Test Assertion")
            alert.addButton(withTitle: "Cancel")
            request.sheet = alert.window
            let answer = await alert.beginSheetModal(for: window)
            request.sheet = nil
            try await validate(request)
            guard answer == .alertFirstButtonReturn else { throw Failure("NotAllowedError", "Native consent declined.") }
            guard verification == "required" else { return false }
            let context = LAContext() // never reused; a vault-unlock context is not user verification
            context.touchIDAuthenticationAllowableReuseDuration = 0
            request.context = context
            var error: NSError?
            guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
                throw Failure("NotAllowedError", "Fresh LocalAuthentication is unavailable; required UV rejected.")
            }
            let success = try await context.evaluatePolicy(.deviceOwnerAuthentication,
                localizedReason: "Verify owned localhost fixture account \(credential.username) for this one WebAuthn ceremony")
            try await validate(request)
            guard success else { throw Failure("NotAllowedError", "Fresh native user verification did not succeed.") }
            return true
        }
    }

    private static func ids(_ raw: Any?) throws -> [Data] {
        guard let raw else { return [] }
        guard let items = raw as? [[String: Any]], items.count <= 128 else { throw Failure("TypeError", "Invalid credential list.") }
        return try items.map { item in
            guard item["type"] as? String == "public-key" else { throw Failure("TypeError", "Invalid credential descriptor.") }
            let value = try decode(item["id"], maximum: 1024)
            guard !value.isEmpty else { throw Failure("TypeError", "Empty credential ID.") }
            return value
        }
    }

    private static func decode(_ raw: Any?, maximum: Int) throws -> Data {
        guard let value = raw as? String, value.utf8.count <= maximum * 2,
              let data = Data(base64Encoded: value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
                + String(repeating: "=", count: (4 - value.count % 4) % 4)), data.count <= maximum, base64(data) == value else {
            throw Failure("TypeError", "Invalid bounded base64url BufferSource.")
        }
        return data
    }

    private static func base64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func randomBytes(_ count: Int) throws -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, count, buffer.baseAddress!)
        }
        guard status == errSecSuccess else { throw Failure("NotAllowedError", "Native random generation failed.") }
        return data
    }

    private static func head(_ major: UInt8, _ count: UInt64) -> Data {
        if count < 24 { return Data([major << 5 | UInt8(count)]) }
        if count <= 255 { return Data([major << 5 | 24, UInt8(count)]) }
        if count <= 65535 { return Data([major << 5 | 25, UInt8(count >> 8), UInt8(count & 255)]) }
        return Data([major << 5 | 26, UInt8((count >> 24) & 255), UInt8((count >> 16) & 255), UInt8((count >> 8) & 255), UInt8(count & 255)])
    }
    private static func integer(_ number: Int) -> Data { head(number < 0 ? 1 : 0, UInt64(number < 0 ? -1 - number : number)) }
    private static func bytes(_ value: Data) -> Data { head(2, UInt64(value.count)) + value }
    private static func text(_ value: String) -> Data { let data = Data(value.utf8); return head(3, UInt64(data.count)) + data }
    private static func map(_ items: [(Data, Data)]) -> Data {
        var data = head(5, UInt64(items.count))
        for (key, value) in items { data.append(key); data.append(value) }
        return data
    }
    private static let isolatedScript = #"""
    (() => {
      if (globalThis.__wsurfOwnedWebAuthnFence) return;
      const documentID = crypto.randomUUID();
      const requests = new Set();
      let active = true;
      const send = body => globalThis.__wsurfSend('wsurfOwnedCredentialProbe', {...body, document:documentID});
      const emit = (id, value) => document.dispatchEvent(new CustomEvent('wsurf-owned-credential-result',
        {detail:JSON.stringify({id,...value})}));
      document.addEventListener('wsurf-owned-credential-request', event => {
        if (!active || typeof event.detail !== 'string' || event.detail.length > 131072) return;
        let body; try { body=JSON.parse(event.detail); } catch { return; }
        if (!body || typeof body.id !== 'string' || body.id.length > 80) return;
        if (body.action === 'cancel') {
          if (requests.delete(body.id)) { try { send({action:'cancel',id:body.id}); } catch {} }
          return;
        }
        if (body.action !== 'request' || requests.size >= 16 || requests.has(body.id)) return;
        requests.add(body.id);
        try { send(body); }
        catch {
          requests.delete(body.id);
          emit(body.id,{error:{name:'NotAllowedError',message:'Owned native probe handler is not armed.'}});
        }
      });
      addEventListener('pagehide', () => {
        active=false;
        for (const id of requests) { try { send({action:'cancel',id}); } catch {} }
        requests.clear();
      });
      const fence = Object.freeze({
        live: (doc,id) => active && doc === documentID && requests.has(id) && document.visibilityState === 'visible',
        deliver: (doc,id,value) => {
          if (!active || doc !== documentID || !requests.has(id)) return false;
          if (value.result && document.visibilityState !== 'visible') return false;
          requests.delete(id); emit(id,value); return true;
        }
      });
      Object.defineProperty(globalThis,'__wsurfOwnedWebAuthnFence',{value:fence});
    })();
    """#

    private static let adapterScript = #"""
    (() => {
      const container=navigator.credentials;
      if (!container || container.create.__wsurfOwnedProbe) return;
      const originals={create:container.create.bind(container),get:container.get.bind(container)};
      const requests=new Map();
      const failure=(name,message)=>new DOMException(message,name);
      const encode = input => {
        let bytes;
        if (input instanceof ArrayBuffer) bytes=new Uint8Array(input);
        else if (ArrayBuffer.isView(input)) bytes=new Uint8Array(input.buffer,input.byteOffset,input.byteLength);
        else throw new TypeError('Expected BufferSource');
        if(bytes.byteLength>65536) throw new TypeError('BufferSource exceeds owned probe limit');
        let raw='';for(const byte of bytes) raw+=String.fromCharCode(byte);
        return btoa(raw).replaceAll('+','-').replaceAll('/','_').replace(/=+$/,'');
      };
      const decode = value => Uint8Array.from(atob(value.replaceAll('-','+').replaceAll('_','/')+
        '='.repeat((4-value.length%4)%4)), c=>c.charCodeAt(0)).buffer;
      const emit = value => document.dispatchEvent(new CustomEvent('wsurf-owned-credential-request',
        {detail:JSON.stringify(value)}));
      function marshal(pk,operation) {
        const result={...pk,challenge:encode(pk.challenge)};
        if(operation==='create') {
          if(!pk.user) throw new TypeError('Missing public-key user');
          result.user={...pk.user,id:encode(pk.user.id)};
          result.rp={...pk.rp};
          result.pubKeyCredParams=pk.pubKeyCredParams.map(item=>({...item}));
        }
        const list=operation==='create'?'excludeCredentials':'allowCredentials';
        result[list]=(pk[list]||[]).map(item=>({...item,id:encode(item.id)}));
        return result;
      }
      function object(prototype,properties) {
        const value=Object.create(prototype);
        for(const [key,item] of Object.entries(properties)) Object.defineProperty(value,key,{value:item,enumerable:true});
        return value;
      }
      function credential(value) {
        const operation=value.operation, r=value.response;
        const client=decode(r.clientDataJSON);
        let response;
        if(operation==='create') {
          const auth=decode(r.authenticatorData),publicKey=decode(r.publicKey),attestation=decode(r.attestationObject);
          response=object(AuthenticatorAttestationResponse.prototype,{
            clientDataJSON:client,attestationObject:attestation,
            getTransports:()=>['internal'],getPublicKeyAlgorithm:()=>-7,
            getPublicKey:()=>publicKey.slice(0),getAuthenticatorData:()=>auth.slice(0),
            toJSON:()=>({clientDataJSON:r.clientDataJSON,attestationObject:r.attestationObject,
              authenticatorData:r.authenticatorData,publicKey:r.publicKey,publicKeyAlgorithm:-7,transports:['internal']})
          });
        } else {
          response=object(AuthenticatorAssertionResponse.prototype,{
            clientDataJSON:client,authenticatorData:decode(r.authenticatorData),
            signature:decode(r.signature),userHandle:decode(r.userHandle),
            toJSON:()=>({clientDataJSON:r.clientDataJSON,authenticatorData:r.authenticatorData,
              signature:r.signature,userHandle:r.userHandle})
          });
        }
        return object(PublicKeyCredential.prototype,{
          id:value.id,rawId:decode(value.rawId),type:'public-key',authenticatorAttachment:'platform',response,
          getClientExtensionResults:()=>({}),
          toJSON:()=>({id:value.id,rawId:value.rawId,type:'public-key',authenticatorAttachment:'platform',
            response:response.toJSON(),clientExtensionResults:{}})
        });
      }
      function settle(id,error,result) {
        const pending=requests.get(id);if(!pending)return;
        requests.delete(id);clearTimeout(pending.timer);
        pending.signal?.removeEventListener('abort',pending.abort);
        if(error) pending.reject(failure(error.name,error.message));
        else { try { pending.resolve(credential(result)); } catch(e) { pending.reject(e); } }
      }
      document.addEventListener('wsurf-owned-credential-result',event=>{
        if(typeof event.detail!=='string'||event.detail.length>262144)return;
        let value;try{value=JSON.parse(event.detail);}catch{return;}
        settle(value.id,value.error,value.result);
      });
      function intercept(operation,options) {
        if(!options?.publicKey) return originals[operation](options);
        return new Promise((resolve,reject)=>{
          if(options.signal && !(options.signal instanceof AbortSignal)) { reject(new TypeError('Expected AbortSignal'));return; }
          if(options.mediation && options.mediation!=='optional') {
            reject(failure('NotSupportedError','Owned probe supports no conditional/background mediation'));return;
          }
          if(options.signal?.aborted) { reject(failure('AbortError','Request already aborted'));return; }
          let pk;try{pk=marshal(options.publicKey,operation);}catch(e){reject(e);return;}
          const id=crypto.randomUUID();
          const timeout=Number.isFinite(pk.timeout)?Math.min(120000,Math.max(1000,pk.timeout)):60000;
          const abort=()=>{emit({action:'cancel',id});settle(id,{name:'AbortError',message:'Request aborted'});};
          const timer=setTimeout(()=>{
            emit({action:'cancel',id});settle(id,{name:'NotAllowedError',message:'Owned probe request timed out'});
          },timeout);
          requests.set(id,{resolve,reject,timer,signal:options.signal,abort});
          options.signal?.addEventListener('abort',abort,{once:true});
          const body={action:'request',id,operation,options:pk,mediation:options.mediation||'optional',timeout};
          try {
            if(JSON.stringify(body).length>131072)throw new TypeError('Options exceed owned probe limit');
            emit(body);
          } catch(e) { settle(id,{name:e.name,message:e.message}); }
        });
      }
      for(const operation of ['create','get']) {
        const fn=options=>intercept(operation,options);
        Object.defineProperty(fn,'__wsurfOwnedProbe',{value:true});
        Object.defineProperty(container,operation,{value:fn,configurable:true});
      }
      // Test-only comparison path is deliberately restricted to non-public-key operations.
      Object.defineProperty(globalThis,'__wsurfOwnedProbeOriginal',{value:Object.freeze({
        get:options=>{if(options?.publicKey)throw new TypeError('No public-key fallback');return originals.get(options);},
        create:options=>{if(options?.publicKey)throw new TypeError('No public-key fallback');return originals.create(options);}
      })});
      Object.defineProperty(PublicKeyCredential,'isConditionalMediationAvailable',{value:()=>Promise.resolve(false),configurable:true});
      // These values describe only this explicitly armed software probe, not the system provider.
      const ownedContext=()=>window===top && location.origin===__WSURF_OWNED_ORIGIN__;
      const canVerify=__WSURF_OWNED_UV_CAPABILITY__;
      Object.defineProperty(PublicKeyCredential,'isUserVerifyingPlatformAuthenticatorAvailable',{
        value:()=>Promise.resolve(ownedContext() && canVerify),configurable:true});
      Object.defineProperty(PublicKeyCredential,'getClientCapabilities',{value:()=>Promise.resolve({
        conditionalGet:false,conditionalCreate:false,hybridTransport:false,
        userVerifyingPlatformAuthenticator:ownedContext() && canVerify,passkeyPlatformAuthenticator:ownedContext()
      }),configurable:true});
      addEventListener('pagehide',()=>{
        for(const id of [...requests.keys()]){
          emit({action:'cancel',id});settle(id,{name:'NotAllowedError',message:'Document navigated away'});
        }
      });
    })();
    """#
}
#endif
