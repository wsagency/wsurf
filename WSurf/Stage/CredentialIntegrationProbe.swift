// SPDX-License-Identifier: Apache-2.0
// Temporary native prerequisite gate; removed after credential integration acceptance.

#if DEBUG
import AppKit
import AuthenticationServices
import CryptoKit
import Foundation
import Security
import Darwin

@MainActor
private enum CredentialProbeChecks {
    static func recovered(_ recoveredDEK: Data, originalDEKBytes: Data) {
        precondition(recoveredDEK.count == 32)
        precondition(recoveredDEK == originalDEKBytes)
    }

    static func independent(firstCredentialID: Data, secondCredentialID: Data, firstUserID: Data, secondUserID: Data) {
        precondition(firstCredentialID != secondCredentialID)
        precondition(firstUserID != secondUserID)
    }

    static func refusals(wrongPRFWasRejected: Bool, missingPRFWasRejected: Bool) {
        precondition(wrongPRFWasRejected && missingPRFWasRejected)
    }
}

@MainActor
final class CredentialIntegrationProbe: NSObject, NSWindowDelegate,
    ASAuthorizationControllerDelegate, ASAuthorizationControllerPresentationContextProviding {
    static var isEnabled: Bool {
        StageMode.isActive && (coreSmokeRequested ? coreSmokePhase != nil
            : ProcessInfo.processInfo.environment["WSURF_CREDENTIAL_PROBE"] == "1")
    }

    private static var coreSmokeRequested: Bool {
        ProcessInfo.processInfo.environment["WSURF_CREDENTIAL_CORE_SMOKE"] != nil
    }

    private enum CoreSmokePhase: String {
        case prepare, verify
    }

    private static var coreSmokePhase: CoreSmokePhase? {
        guard let raw = ProcessInfo.processInfo.environment["WSURF_CREDENTIAL_CORE_SMOKE"] else { return nil }
        return CoreSmokePhase(rawValue: raw)
    }

    private static let processID = UUID()
    private static var active: CredentialIntegrationProbe?
    private static let relyingParty = "wsurf.app"
    private static let labels = ["WSurf Credential Probe 1", "WSurf Credential Probe 2"]
    private let coordinator: AppCoordinator
    private let fixtureURL: URL
    private let panel: NSPanel
    private let output = NSTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 260))
    private var registrationButtons: [NSButton] = []
    private var assertionButtons: [NSButton] = []
    private var fixture: Fixture
    private var controller: ASAuthorizationController?
    private var pending: Pending?
    private var closing = false
    private var coreSmokeStarted = false
    // Only the DEK survives between explicit buttons, in RAM for at most five minutes.
    // Swift reference release is not a promise of physical RAM erasure.
    private var originalDEKBytes: Data?
    private var keyExpiry: Task<Void, Never>?
    private var message = "Native gate NOT VERIFIED. Obtain exact external-action approval before each ceremony."

    private struct Credential: Codable {
        var credentialID: Data
        var userID: Data
        var prfInput: Data
        var prfSupported: Bool
        var wrappedDEK: Data?
        var wrappedInProcess: UUID?
        var assertions = 0
        var assertionsAfterBothRegistrations = 0
        var restartAssertions = 0
        var wrongPRFWasRejected = false
        var missingPRFWasRejected = false
        var lastAuthenticatorFlags: UInt8?
        var lastSignatureBytes: Int?
    }

    private struct Fixture: Codable {
        var version = 1
        var relyingParty = CredentialIntegrationProbe.relyingParty
        var profileID = UUID()
        var vaultID = UUID()
        var createdInProcess = CredentialIntegrationProbe.processID
        var credentials: [Credential] = []
        var encryptedPayload: Data?
        var nativeCancellations = 0
        var cancellationRequests = 0
        var events: [String] = []
    }

    private struct Pending {
        var slot: Int
        var registering: Bool
        var challenge: Data
        var userID: Data
        var prfInput: Data
    }

    private enum ProbeError: String, Error {
        case unsupportedPRF
        case invalidFixture
        case invalidNativeResult
        case requiresUnlockedProbe
        case incorrectRecoveredKey
        case wrongPRFAccepted
        case missingPRFAccepted
        case randomGenerationFailed
    }
    private struct CoreSmokeKeys: Codable {
        var purpose = "synthetic-test-only; no provider secrets"
        var profileID: UUID
        var credentials: [CoreSmokeCredential]
    }

    private struct CoreSmokeCredential: Codable {
        var credentialID: Data
        var prfInput: Data
        var syntheticPRFOutput: Data
    }

    private struct CoreSmokeResult: Codable {
        var purpose = "synthetic credential-vault core smoke; no provider calls"
        var preparedProcessID: Int32
        var preparedRunID: UUID
        var verifiedProcessID: Int32?
        var verifiedRunID: UUID?
        var assertions: [String]
    }

    private struct CoreSmokeFailure: Error, CustomStringConvertible {
        var description: String
        init(_ description: String) { self.description = description }
    }

    static func present(coordinator: AppCoordinator) {
        guard isEnabled else { return }
        if let active {
            active.closing = false
            active.panel.makeKeyAndOrderFront(nil)
            return
        }
        do {
            let probe = try CredentialIntegrationProbe(coordinator: coordinator)
            active = probe
            probe.panel.center()
            probe.panel.makeKeyAndOrderFront(nil)
            if Self.coreSmokePhase != nil {
                Task { @MainActor in await probe.runCoreSmoke() }
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Credential probe unavailable"
            alert.informativeText = "An explicit absolute WSURF_STAGE_HOME and a valid owned fixture are required. \(error)"
            alert.runModal()
        }
    }

    private init(coordinator: AppCoordinator) throws {
        guard Self.isEnabled,
              let path = ProcessInfo.processInfo.environment["WSURF_STAGE_HOME"],
              path.hasPrefix("/"), path != "/", let home = StageMode.home else {
            throw ProbeError.invalidFixture
        }
        self.coordinator = coordinator
        fixtureURL = home.appendingPathComponent("credential-prf-probe.json", isDirectory: false)
        if Self.coreSmokePhase == nil {
            if FileManager.default.fileExists(atPath: fixtureURL.path) {
                let values = try fixtureURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      let size = values.fileSize, size <= 65_536 else { throw ProbeError.invalidFixture }
                fixture = try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: fixtureURL))
                try Self.validate(fixture)
            } else {
                fixture = Fixture()
            }
        } else {
            fixture = Fixture()
        }
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 760, height: 590),
                        styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        panel.title = Self.coreSmokePhase == nil ? "WSurf Credential Probe — native PRF gate" : "WSurf Credential Vault Core Smoke"
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        makeUI()
        refresh()
    }

    private func coreSmokeDirectory(create: Bool) throws -> URL {
        guard let path = ProcessInfo.processInfo.environment["WSURF_STAGE_HOME"],
              path.hasPrefix("/"), path != "/", let home = StageMode.home,
              home.standardizedFileURL.path == URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL.path,
              try Self.isOwnedDirectory(home, permissions: nil) else {
            throw CoreSmokeFailure("WSURF_STAGE_HOME must be an explicit absolute owned directory.")
        }
        let directory = home.appendingPathComponent("credential-vault-smoke", isDirectory: true)
        if !FileManager.default.fileExists(atPath: directory.path), create {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        }
        guard try Self.isOwnedDirectory(directory, permissions: 0o700) else {
            throw CoreSmokeFailure("The dedicated credential-vault-smoke child must be an owned mode-0700 directory.")
        }
        return directory
    }

    private static func isOwnedDirectory(_ url: URL, permissions: Int?) throws -> Bool {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let owner = (attributes[.ownerAccountID] as? NSNumber)?.uint32Value
        let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue
        return values.isDirectory == true && values.isSymbolicLink != true && owner == getuid()
            && (permissions == nil || mode == permissions)
    }

    private static func requireOwnedFile(_ url: URL, maximumBytes: Int) throws {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size <= maximumBytes,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == getuid(),
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600 else {
            throw CoreSmokeFailure("Synthetic key/result file must be bounded, owned, regular, non-symlink, and mode 0600.")
        }
    }

    private static func writeOwnedFile(_ data: Data, to url: URL, maximumBytes: Int) throws {
        guard data.count <= maximumBytes else { throw CoreSmokeFailure("Core smoke file exceeded its size bound.") }
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try requireOwnedFile(url, maximumBytes: maximumBytes)
    }

    private func runCoreSmoke() async {
        guard !coreSmokeStarted, let phase = Self.coreSmokePhase else { return }
        coreSmokeStarted = true
        do {
            let directory = try coreSmokeDirectory(create: phase == .prepare)
            let resultURL = directory.appendingPathComponent("result.json", isDirectory: false)
            let keyURL = directory.appendingPathComponent("synthetic-test-prf-keys.json", isDirectory: false)
            let vaultDirectory = directory.appendingPathComponent("vault", isDirectory: true)
            if phase == .prepare {
                try await prepareCoreSmoke(directory: directory, vaultDirectory: vaultDirectory,
                                           keyURL: keyURL, resultURL: resultURL)
            } else {
                try await verifyCoreSmoke(directory: directory, vaultDirectory: vaultDirectory,
                                          keyURL: keyURL, resultURL: resultURL)
            }
        } catch {
            message = "CORE SMOKE FAILED: \(error)"
            refresh()
        }
    }

    private func prepareCoreSmoke(directory: URL, vaultDirectory: URL, keyURL: URL, resultURL: URL) async throws {
        guard !FileManager.default.fileExists(atPath: keyURL.path),
              !FileManager.default.fileExists(atPath: resultURL.path),
              !FileManager.default.fileExists(atPath: vaultDirectory.path) else {
            throw CoreSmokeFailure("Preparation refuses to overwrite an existing smoke fixture or vault.")
        }
        try FileManager.default.createDirectory(at: vaultDirectory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        guard try Self.isOwnedDirectory(vaultDirectory, permissions: 0o700) else {
            throw CoreSmokeFailure("The owned vault directory must have mode 0700.")
        }

        let profileID = UUID()
        let profile = Profile(id: profileID, name: "Credential Core Smoke", symbol: "key", color: .blue)
        let first = try Self.makeCoreSmokeCredential()
        var second = try Self.makeCoreSmokeCredential()
        while first.credentialID == second.credentialID || first.prfInput == second.prfInput
                || first.syntheticPRFOutput == second.syntheticPRFOutput {
            second = try Self.makeCoreSmokeCredential()
        }
        let proofs = [first, second].map {
            VaultUnlockProof(credentialID: $0.credentialID, prfInput: $0.prfInput,
                             prf: SymmetricKey(data: $0.syntheticPRFOutput))
        }
        let manager = try CredentialManager(profile: profile, directory: vaultDirectory)
        let managerAccess = manager.beginAccess()
        try await manager.completeCreate(proofs[0], access: managerAccess)
        let account = Self.coreSmokeAccount()
        let commit = try await manager.commit([account], expectedRevision: 0)
        try Self.require(commit.revision == 1, "manager account commit revision")

        let vaultFile = vaultDirectory.appendingPathComponent("Credentials.vault", isDirectory: false)
        let beforeWrongKey = try Data(contentsOf: vaultFile)
        let wrongVault = try CredentialVault(profileID: profileID, directory: vaultDirectory)
        let wrongAccess = Self.makeCoreSmokeAccess(profileID: profileID, epoch: 2)
        var wrongOutput = try Self.randomBytes()
        while wrongOutput == first.syntheticPRFOutput { wrongOutput = try Self.randomBytes() }
        do {
            try await wrongVault.unlock(credentialID: first.credentialID,
                                        prf: SymmetricKey(data: wrongOutput), access: wrongAccess)
            throw CoreSmokeFailure("Wrong synthetic key unexpectedly unlocked the vault.")
        } catch CredentialVaultError.authenticationFailed {}
        let afterWrongKey = try Data(contentsOf: vaultFile)
        try Self.require(afterWrongKey == beforeWrongKey, "wrong-key rejection preserved exact vault bytes")

        manager.lock(reason: .manual)
        do {
            _ = try await manager.snapshot()
            throw CoreSmokeFailure("Manager remained authorized after lock.")
        } catch CredentialVaultError.unauthorized {}

        let vault = try CredentialVault(profileID: profileID, directory: vaultDirectory)
        let access = Self.makeCoreSmokeAccess(profileID: profileID, epoch: 3)
        try await vault.unlock(credentialID: first.credentialID, prf: proofs[0].prf, access: access)
        let added = try await vault.addUnlock(proofs[1], using: access)
        try Self.require(added.revision == 2, "second independent unlock wrapper added")

        let beforeFailedCommit = try Data(contentsOf: vaultFile)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: vaultDirectory.path)
        guard let originalPermissions = (directoryAttributes[.posixPermissions] as? NSNumber)?.intValue else {
            throw CoreSmokeFailure("Could not record owned vault-directory permissions.")
        }
        var permissionsRestored = false
        defer {
            if !permissionsRestored {
                try? FileManager.default.setAttributes([.posixPermissions: originalPermissions],
                                                       ofItemAtPath: vaultDirectory.path)
            }
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: vaultDirectory.path)
        var writeRejected = false
        do {
            _ = try await vault.commit([Self.coreSmokeAccount(password: "synthetic-updated")],
                                       expectedRevision: added.revision, using: access)
        } catch {
            writeRejected = true
        }
        try Self.require(writeRejected, "permission-denied atomic write rejected")
        let afterFailedCommit = try Data(contentsOf: vaultFile)
        try Self.require(afterFailedCommit == beforeFailedCommit, "failed atomic write preserved exact vault bytes")
        try FileManager.default.setAttributes([.posixPermissions: originalPermissions], ofItemAtPath: vaultDirectory.path)
        permissionsRestored = true

        await vault.lock()
        do {
            _ = try await vault.snapshot(using: access)
            throw CoreSmokeFailure("Vault access remained authorized after lock/revocation.")
        } catch CredentialVaultError.unauthorized {}
        let reopened = try await Self.verifyBothCoreSmokeWrappers(profile: profile, vaultDirectory: vaultDirectory,
                                                             proofs: proofs, expectedRevision: 2)
        try Self.require(reopened, "both wrappers reopened the committed account")

        let keys = CoreSmokeKeys(profileID: profileID, credentials: [first, second])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try Self.writeOwnedFile(encoder.encode(keys), to: keyURL, maximumBytes: 4_096)
        let result = CoreSmokeResult(preparedProcessID: ProcessInfo.processInfo.processIdentifier,
                                     preparedRunID: Self.processID, assertions: [
                                        "actual Profile + CredentialManager + CredentialVault",
                                        "create and account commit",
                                        "wrong-key rejection preserved exact bytes",
                                        "manager and vault lock/revocation",
                                        "second wrapper added",
                                        "permission-denied atomic failure preserved exact bytes",
                                        "both wrappers reopened account independently"
                                     ])
        try Self.writeOwnedFile(encoder.encode(result), to: resultURL, maximumBytes: 4_096)
        message = "CORE SMOKE PHASE 1 PREPARED. Exit this app process, then relaunch with WSURF_CREDENTIAL_CORE_SMOKE=verify.\nProcess ID: \(result.preparedProcessID)\nRun ID: \(result.preparedRunID)\nOwned data: \(directory.path)"
        refresh()
    }

    private func verifyCoreSmoke(directory: URL, vaultDirectory: URL, keyURL: URL, resultURL: URL) async throws {
        guard try Self.isOwnedDirectory(vaultDirectory, permissions: 0o700) else {
            throw CoreSmokeFailure("The dedicated vault directory must remain owned and mode 0700.")
        }
        try Self.requireOwnedFile(keyURL, maximumBytes: 4_096)
        try Self.requireOwnedFile(resultURL, maximumBytes: 4_096)
        let keys = try JSONDecoder().decode(CoreSmokeKeys.self, from: Data(contentsOf: keyURL))
        var result = try JSONDecoder().decode(CoreSmokeResult.self, from: Data(contentsOf: resultURL))
        try Self.require(keys.purpose == "synthetic-test-only; no provider secrets" && keys.credentials.count == 2
                         && keys.credentials.allSatisfy({ $0.credentialID.count == 32 && $0.prfInput.count == 32 && $0.syntheticPRFOutput.count == 32 }),
                         "bounded synthetic test-only PRF fixture")
        try Self.require(keys.credentials[0].credentialID != keys.credentials[1].credentialID
                         && keys.credentials[0].prfInput != keys.credentials[1].prfInput
                         && keys.credentials[0].syntheticPRFOutput != keys.credentials[1].syntheticPRFOutput,
                         "independently generated wrappers")
        try Self.require(result.purpose == "synthetic credential-vault core smoke; no provider calls"
                         && result.verifiedProcessID == nil && result.verifiedRunID == nil,
                         "unverified phase-one result")
        let processID = ProcessInfo.processInfo.processIdentifier
        try Self.require(processID != result.preparedProcessID && Self.processID != result.preparedRunID,
                         "phase two ran in a distinct process")
        let profile = Profile(id: keys.profileID, name: "Credential Core Smoke", symbol: "key", color: .blue)
        let proofs = keys.credentials.map {
            VaultUnlockProof(credentialID: $0.credentialID, prfInput: $0.prfInput,
                             prf: SymmetricKey(data: $0.syntheticPRFOutput))
        }
        let reopened = try await Self.verifyBothCoreSmokeWrappers(profile: profile, vaultDirectory: vaultDirectory,
                                                             proofs: proofs, expectedRevision: 2)
        try Self.require(reopened, "both synthetic wrappers independently reopened after process restart")
        result.verifiedProcessID = processID
        result.verifiedRunID = Self.processID
        result.assertions.append("distinct process IDs and run IDs; both wrappers reopened after restart")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try Self.writeOwnedFile(encoder.encode(result), to: resultURL, maximumBytes: 4_096)
        message = "CORE SMOKE PASSED. Distinct process IDs: \(result.preparedProcessID) → \(processID).\nAssertions: \(result.assertions.joined(separator: "; "))\nResult: \(resultURL.path)"
        refresh()
    }

    private static func verifyBothCoreSmokeWrappers(profile: Profile, vaultDirectory: URL,
                                                    proofs: [VaultUnlockProof], expectedRevision: UInt64) async throws -> Bool {
        guard proofs.count == 2 else { throw CoreSmokeFailure("Expected exactly two synthetic wrappers.") }
        for proof in proofs {
            let vault = try CredentialVault(profileID: profile.id, directory: vaultDirectory)
            let access = makeCoreSmokeAccess(profileID: profile.id, epoch: UInt64.random(in: 10...1_000_000))
            try await vault.unlock(credentialID: proof.credentialID, prf: proof.prf, access: access)
            let snapshot = try await vault.snapshot(using: access)
            try require(snapshot.revision == expectedRevision && snapshot.accounts.count == 1
                        && snapshot.accounts[0].username == "credential-core-smoke"
                        && snapshot.accounts[0].password == "synthetic-test-only",
                        "wrapper independently reopened committed account")
            await vault.lock()
        }
        return true
    }

    private static func makeCoreSmokeCredential() throws -> CoreSmokeCredential {
        CoreSmokeCredential(credentialID: try randomBytes(), prfInput: try randomBytes(),
                            syntheticPRFOutput: try randomBytes())
    }

    private static func makeCoreSmokeAccess(profileID: UUID, epoch: UInt64) -> VaultAccess {
        VaultAccess(profileID: profileID, epoch: epoch, deadline: ContinuousClock().now.advanced(by: .seconds(300)))
    }

    private static func coreSmokeAccount(password: String = "synthetic-test-only") -> CredentialAccount {
        CredentialAccount(id: UUID(), username: "credential-core-smoke", displayName: "Synthetic Core Smoke",
                          origins: ["https://example.test"], loginURLs: [URL(string: "https://example.test/login")!],
                          password: password, passkeys: [], totp: nil)
    }

    private static func require(_ condition: @autoclosure () -> Bool, _ description: String) throws {
        guard condition() else { throw CoreSmokeFailure("Assertion failed: \(description)") }
    }

    private func makeCoreSmokeUI(in stack: NSStackView) {
        let notice = NSTextField(wrappingLabelWithString:
            "DEBUG stage only • synthetic app-core vault checks • no AuthenticationServices/provider calls • no production data")
        stack.addArrangedSubview(notice)
        output.isEditable = false
        output.isSelectable = true
        output.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        output.autoresizingMask = [.width]
        output.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = output
        stack.addArrangedSubview(scroll)
        guard let content = panel.contentView else { return }
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            notice.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 260)
        ])
    }

    private func makeUI() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        if Self.coreSmokePhase != nil {
            makeCoreSmokeUI(in: stack)
            return
        }
        let warning = NSTextField(wrappingLabelWithString:
            "DEBUG stage only • RP wsurf.app\nNo ceremony starts automatically. The controller must obtain exact approval immediately before each Create/Assert button; provider safety approval remains interactive. Do not use production credentials.")
        stack.addArrangedSubview(warning)
        for slot in 0..<2 {
            let create = NSButton(title: "Create \(Self.labels[slot])", target: self, action: #selector(register(_:)))
            let assert = NSButton(title: "Assert Probe \(slot + 1) once", target: self, action: #selector(assertCredential(_:)))
            create.tag = slot
            assert.tag = slot
            registrationButtons.append(create)
            assertionButtons.append(assert)
            let row = NSStackView(views: [create, assert])
            row.spacing = 12
            stack.addArrangedSubview(row)
        }
        let actions = NSStackView(views: [
            NSButton(title: "Cancel Pending Ceremony", target: self, action: #selector(cancelCeremony)),
            NSButton(title: "Forget In-Memory DEK", target: self, action: #selector(forgetKey)),
            NSButton(title: "WebAuthn Probe", target: self, action: #selector(showWebAuthn))
        ])
        actions.spacing = 12
        stack.addArrangedSubview(actions)
        output.isEditable = false
        output.isSelectable = true
        output.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        output.autoresizingMask = [.width]
        output.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.documentView = output
        stack.addArrangedSubview(scroll)
        guard let content = panel.contentView else { return }
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            warning.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 260)
        ])
    }

    @objc private func register(_ button: NSButton) {
        begin(slot: button.tag, registering: true)
    }

    @objc private func assertCredential(_ button: NSButton) {
        begin(slot: button.tag, registering: false)
    }

    private func begin(slot: Int, registering: Bool) {
        guard Self.isEnabled, NSApp.isActive, panel.isKeyWindow, controller == nil,
              (0..<2).contains(slot) else { return }
        guard registering ? slot == fixture.credentials.count : slot < fixture.credentials.count else { return }
        if registering && slot == 1 && (originalDEKBytes == nil || fixture.credentials[0].wrappedDEK == nil) {
            message = "Assert Probe 1 to unlock its existing encrypted fixture before creating Probe 2."
            refresh()
            return
        }
        let alert = NSAlert()
        alert.messageText = "\(registering ? "Create" : "Assert") \(Self.labels[slot])?"
        alert.informativeText = "RP: wsurf.app\n\(registering ? "This creates one external test passkey with a new random user ID." : "This uses only the selected owned test credential and requests its PRF output.")\nContinue only after the controller obtained explicit approval for this exact action at this point of risk. Approval of the implementation plan is not ceremony approval. Keep provider approval interactive."
        alert.addButton(withTitle: "Approved — Continue")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn, Self.isEnabled, NSApp.isActive, panel.isKeyWindow else { return }
        do {
            let challenge = try Self.randomBytes()
            let userID = registering ? try Self.randomBytes() : fixture.credentials[slot].userID
            let prfInput = registering ? try Self.randomBytes() : fixture.credentials[slot].prfInput
            if registering && fixture.credentials.contains(where: { $0.userID == userID }) {
                throw ProbeError.invalidNativeResult
            }
            let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(relyingPartyIdentifier: Self.relyingParty)
            let request: ASAuthorizationRequest
            if registering {
                let registration = provider.createCredentialRegistrationRequest(
                    challenge: challenge, name: Self.labels[slot], userID: userID)
                registration.displayName = Self.labels[slot]
                registration.userVerificationPreference = .required
                registration.prf = .checkForSupport
                request = registration
            } else {
                let assertion = provider.createCredentialAssertionRequest(challenge: challenge)
                assertion.allowedCredentials = [
                    ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: fixture.credentials[slot].credentialID)
                ]
                assertion.userVerificationPreference = .required
                assertion.prf = .inputValues(.init(saltInput1: prfInput, saltInput2: nil))
                request = assertion
            }
            pending = Pending(slot: slot, registering: registering, challenge: challenge, userID: userID, prfInput: prfInput)
            let authorization = ASAuthorizationController(authorizationRequests: [request])
            controller = authorization
            authorization.delegate = self
            authorization.presentationContextProvider = self
            message = "Awaiting native \(registering ? "registration" : "assertion") for \(Self.labels[slot])."
            refresh()
            authorization.performRequests()
        } catch {
            message = "Probe refused: \(error)"
            refresh()
        }
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        panel
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard self.controller === controller else { return }
        guard let pending, Self.isEnabled, panel.isVisible, !closing else {
            finishController()
            message = "Late native success ignored after cancellation; no wrapper committed. An external registration may have completed: obtain approval before inspecting or retrying it."
            record("Late native success discarded after cancellation; external registration outcome requires inspection")
            refresh()
            return
        }
        finishController()
        do {
            if pending.registering {
                guard let result = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialRegistration else {
                    throw ProbeError.invalidNativeResult
                }
                let credentialID: Data = result.credentialID
                let clientData: Data = result.rawClientDataJSON
                guard !credentialID.isEmpty, credentialID.count <= 1_024,
                      !fixture.credentials.contains(where: { $0.credentialID == credentialID }) else {
                    throw ProbeError.invalidNativeResult
                }
                try validateClientData(clientData, challenge: pending.challenge, type: "webauthn.create")
                // Preserve public discovery even when the external registration lacks PRF.
                // Never recreate/replace that external credential automatically.
                var candidate = fixture
                candidate.credentials.append(Credential(credentialID: credentialID, userID: pending.userID,
                                                       prfInput: pending.prfInput, prfSupported: result.prf?.isSupported == true))
                if candidate.credentials.count == 2 {
                    CredentialProbeChecks.independent(firstCredentialID: candidate.credentials[0].credentialID,
                                                      secondCredentialID: credentialID,
                                                      firstUserID: candidate.credentials[0].userID, secondUserID: pending.userID)
                }
                appendEvent("Registered Probe \(pending.slot + 1); PRF supported: \(result.prf?.isSupported == true)", to: &candidate)
                try save(candidate)
                guard result.prf?.isSupported == true else { throw ProbeError.unsupportedPRF }
                message = "Registered \(Self.labels[pending.slot]). Press its Assert button twice, with separate approvals."
            } else {
                guard let result = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion else {
                    throw ProbeError.invalidNativeResult
                }
                try consumeAssertion(result, pending: pending)
                message = "Probe \(pending.slot + 1): native PRF wrap/unlock and wrong/missing PRF refusal verified locally."
            }
        } catch {
            message = "Native gate STOP: \(error). No substitute key or Keychain fallback."
            record("Result refused: \(error)")
        }
        refresh()
    }

    func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: any Error) {
        guard self.controller === controller else { return }
        finishController()
        let nativeError = error as NSError
        var candidate = fixture
        if nativeError.domain == ASAuthorizationErrorDomain && nativeError.code == ASAuthorizationError.canceled.rawValue {
            candidate.nativeCancellations += 1
            message = "Native provider cancellation observed; no credential/wrapper mutation."
            appendEvent("Native cancellation observed", to: &candidate)
        } else {
            // Do not persist arbitrary provider error text, which may contain account information.
            message = "Native gate STOP: \(nativeError.domain), code \(nativeError.code). Verify signed association/provisioning."
            appendEvent("Native failure: \(nativeError.domain), code \(nativeError.code)", to: &candidate)
        }
        do { try save(candidate) } catch { message += "\nEvidence write failed: \(error)" }
        refresh()
    }

    private func consumeAssertion(_ result: ASAuthorizationPlatformPublicKeyCredentialAssertion, pending: Pending) throws {
        let slot = pending.slot
        let credential = fixture.credentials[slot]
        let clientData: Data = result.rawClientDataJSON
        let authenticatorData: Data = result.rawAuthenticatorData
        let signature: Data = result.signature
        guard result.credentialID == credential.credentialID, result.userID == credential.userID,
              !signature.isEmpty, signature.count <= 1_024,
              authenticatorData.count >= 37, authenticatorData.count <= 16_384 else {
            throw ProbeError.invalidNativeResult
        }
        try validateClientData(clientData, challenge: pending.challenge, type: "webauthn.get")
        guard Data(authenticatorData.prefix(32)) == Data(SHA256.hash(data: Data(Self.relyingParty.utf8))),
              authenticatorData[32] & 0x05 == 0x05 else { throw ProbeError.invalidNativeResult }
        // This is the only positive wrapping key path: an actual native assertion output.
        guard let prf = result.prf?.first, prf.bitCount == 256 else { throw ProbeError.unsupportedPRF }
        var candidate = fixture
        let dek: Data
        if let wrapped = credential.wrappedDEK {
            let secondRecoveredDEK = try unwrap(wrapped, prf: prf, credential: credential, fixture: fixture)
            dek = secondRecoveredDEK
            if let originalDEKBytes {
                CredentialProbeChecks.recovered(dek, originalDEKBytes: originalDEKBytes)
            }
        } else {
            if slot == 0 {
                dek = try Self.randomBytes()
                candidate.createdInProcess = Self.processID
                candidate.encryptedPayload = try AES.GCM.seal(payload(for: fixture), using: SymmetricKey(data: dek),
                                                            authenticating: payloadAAD(for: fixture)).combined
            } else {
                guard let originalDEKBytes else { throw ProbeError.requiresUnlockedProbe }
                dek = originalDEKBytes
            }
            let wrappingKey = try wrappingKey(prf: prf, fixture: fixture)
            let wrapped = try AES.GCM.seal(dek, using: wrappingKey,
                                           authenticating: wrapperAAD(credential: credential, fixture: fixture)).combined
            guard let wrapped else { throw ProbeError.invalidFixture }
            let firstRecoveredDEK = try unwrap(wrapped, prf: prf, credential: credential, fixture: fixture)
            CredentialProbeChecks.recovered(firstRecoveredDEK, originalDEKBytes: dek)
            candidate.credentials[slot].wrappedDEK = wrapped
            candidate.credentials[slot].wrappedInProcess = Self.processID
        }
        guard dek.count == 32, let encryptedPayload = candidate.encryptedPayload else { throw ProbeError.invalidFixture }
        let recoveredPayload = try AES.GCM.open(AES.GCM.SealedBox(combined: encryptedPayload),
                                               using: SymmetricKey(data: dek), authenticating: payloadAAD(for: fixture))
        guard recoveredPayload == payload(for: fixture) else { throw ProbeError.incorrectRecoveredKey }
        guard let wrapped = candidate.credentials[slot].wrappedDEK else { throw ProbeError.invalidFixture }
        var wrongBytes = prf.withUnsafeBytes { Data($0) }
        guard !wrongBytes.isEmpty else { throw ProbeError.unsupportedPRF }
        wrongBytes[0] ^= 1
        var wrongPRFWasRejected = false
        do {
            _ = try unwrap(wrapped, prf: SymmetricKey(data: wrongBytes), credential: credential, fixture: fixture)
        } catch CryptoKitError.authenticationFailure {
            wrongPRFWasRejected = true
        }
        guard wrongPRFWasRejected else { throw ProbeError.wrongPRFAccepted }
        var missingPRFWasRejected = false
        do {
            _ = try unwrap(wrapped, prf: nil, credential: credential, fixture: fixture)
        } catch ProbeError.unsupportedPRF {
            missingPRFWasRejected = true
        }
        guard missingPRFWasRejected else { throw ProbeError.missingPRFAccepted }
        CredentialProbeChecks.refusals(wrongPRFWasRejected: wrongPRFWasRejected, missingPRFWasRejected: missingPRFWasRejected)
        candidate.credentials[slot].assertions += 1
        if candidate.credentials.count == 2 { candidate.credentials[slot].assertionsAfterBothRegistrations += 1 }
        let afterRestart = credential.wrappedDEK != nil && credential.wrappedInProcess != Self.processID
        if afterRestart { candidate.credentials[slot].restartAssertions += 1 }
        candidate.credentials[slot].wrongPRFWasRejected = wrongPRFWasRejected
        candidate.credentials[slot].missingPRFWasRejected = missingPRFWasRejected
        candidate.credentials[slot].lastAuthenticatorFlags = authenticatorData[32]
        candidate.credentials[slot].lastSignatureBytes = signature.count
        appendEvent("Probe \(slot + 1): assertion \(candidate.credentials[slot].assertions), AES-GCM authenticated; wrong/missing PRF refused; after restart: \(afterRestart)", to: &candidate)
        try save(candidate)
        retainDEKUntilExpiry(dek)
    }

    private func validateClientData(_ data: Data, challenge: Data, type: String) throws {
        guard data.count <= 16_384,
              let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["type"] as? String == type,
              json["challenge"] as? String == challenge.base64EncodedString()
                .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
                .replacingOccurrences(of: "=", with: ""),
              json["origin"] as? String == "https://\(Self.relyingParty)",
              (json["crossOrigin"] as? Bool) != true else { throw ProbeError.invalidNativeResult }
    }

    private func wrappingKey(prf: SymmetricKey?, fixture: Fixture) throws -> SymmetricKey {
        guard let prf, prf.bitCount == 256 else { throw ProbeError.unsupportedPRF }
        return HKDF<SHA256>.deriveKey(inputKeyMaterial: prf,
                                     salt: payloadAAD(for: fixture),
                                     info: Data("WSurf Credential Probe|PRF wrapping key|v1".utf8),
                                     outputByteCount: 32)
    }

    private func unwrap(_ wrapped: Data, prf: SymmetricKey?, credential: Credential, fixture: Fixture) throws -> Data {
        let key = try wrappingKey(prf: prf, fixture: fixture)
        return try AES.GCM.open(AES.GCM.SealedBox(combined: wrapped), using: key,
                                authenticating: wrapperAAD(credential: credential, fixture: fixture))
    }

    private func payloadAAD(for fixture: Fixture) -> Data {
        Data("WSurf Credential Probe|v1|\(fixture.profileID.uuidString)|\(fixture.vaultID.uuidString)|\(fixture.relyingParty)".utf8)
    }

    private func wrapperAAD(credential: Credential, fixture: Fixture) -> Data {
        payloadAAD(for: fixture) + Data("|wrapper|\(credential.credentialID.base64EncodedString())|\(credential.prfInput.base64EncodedString())|\(credential.userID.base64EncodedString())".utf8)
    }

    private func payload(for fixture: Fixture) -> Data {
        Data("WSurf Credential Probe encrypted restart verification|\(fixture.vaultID.uuidString)".utf8)
    }

    private static func randomBytes() throws -> Data {
        var bytes = Data(count: 32)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw ProbeError.randomGenerationFailed }
        return bytes
    }

    private static func validate(_ fixture: Fixture) throws {
        guard fixture.version == 1, fixture.relyingParty == relyingParty,
              fixture.credentials.count <= 2, fixture.events.count <= 64,
              fixture.events.allSatisfy({ $0.utf8.count <= 1_024 }),
              fixture.nativeCancellations >= 0, fixture.cancellationRequests >= 0,
              fixture.encryptedPayload.map({ (28...512).contains($0.count) }) ?? true else { throw ProbeError.invalidFixture }
        for credential in fixture.credentials {
            guard (1...1_024).contains(credential.credentialID.count),
                  credential.userID.count == 32, credential.prfInput.count == 32,
                  credential.wrappedDEK.map({ $0.count == 60 }) ?? true,
                  (credential.wrappedDEK == nil) == (credential.wrappedInProcess == nil),
                  credential.assertions >= 0, credential.assertions <= 1_000,
                  (0...credential.assertions).contains(credential.assertionsAfterBothRegistrations),
                  (0...credential.assertions).contains(credential.restartAssertions),
                  credential.wrappedDEK == nil || fixture.encryptedPayload != nil else { throw ProbeError.invalidFixture }
        }
        if fixture.credentials.count == 2 {
            guard fixture.credentials[0].credentialID != fixture.credentials[1].credentialID,
                  fixture.credentials[0].userID != fixture.credentials[1].userID,
                  fixture.credentials[0].prfInput != fixture.credentials[1].prfInput else { throw ProbeError.invalidFixture }
        }
    }

    private func save(_ candidate: Fixture) throws {
        try Self.validate(candidate)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(candidate)
        guard data.count <= 65_536 else { throw ProbeError.invalidFixture }
        try FileManager.default.createDirectory(at: fixtureURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try data.write(to: fixtureURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fixtureURL.path)
        fixture = candidate
    }

    private func appendEvent(_ event: String, to fixture: inout Fixture) {
        fixture.events.append("\(Date().ISO8601Format()) \(event)")
        if fixture.events.count > 64 { fixture.events.removeFirst(fixture.events.count - 64) }
    }

    private func record(_ event: String) {
        var candidate = fixture
        appendEvent(event, to: &candidate)
        do { try save(candidate) } catch { message += "\nEvidence write failed: \(error)" }
    }

    private func retainDEKUntilExpiry(_ dek: Data) {
        if originalDEKBytes != nil { return } // An assertion never silently extends the five-minute ceiling.
        originalDEKBytes = dek
        keyExpiry = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(300)) } catch { return }
            self?.forgetKey()
        }
    }

    private func finishController() {
        controller?.delegate = nil
        controller?.presentationContextProvider = nil
        controller = nil
        pending = nil
        if closing { Self.active = nil }
    }

    @objc private func cancelCeremony() {
        guard let controller, pending != nil else { return }
        // Invalidate first, but retain controller/delegate through cancellation completion.
        pending = nil
        var candidate = fixture
        candidate.cancellationRequests += 1
        appendEvent("Controller cancellation requested; late successful callbacks invalidated", to: &candidate)
        message = "Cancellation requested; late callbacks cannot mutate the fixture."
        do { try save(candidate) } catch { message += "\nEvidence write failed: \(error)" }
        refresh()
        controller.cancel()
    }

    @objc private func forgetKey() {
        cancelCeremony()
        keyExpiry?.cancel()
        keyExpiry = nil
        originalDEKBytes = nil
        message = "In-memory DEK released. Existing ciphertext remains; assert to unlock. This is not process-restart evidence."
        refresh()
    }

    @objc private func showWebAuthn() {
        guard Self.isEnabled, NSApp.isActive, panel.isKeyWindow, controller == nil else { return }
        CredentialWebAuthnProbe.present(coordinator: coordinator)
    }

    func windowWillClose(_ notification: Notification) {
        closing = true
        cancelCeremony()
        forgetKey()
        if controller == nil { Self.active = nil }
    }

    private func refresh() {
        if Self.coreSmokePhase != nil {
            output.string = [message, "", "Mode: synthetic core smoke only",
                             "Stage home: \(ProcessInfo.processInfo.environment["WSURF_STAGE_HOME"] ?? "missing")",
                             "Phase: \(Self.coreSmokePhase?.rawValue ?? "invalid")"].joined(separator: "\n")
            return
        }
        for slot in 0..<2 {
            registrationButtons[slot].isEnabled = controller == nil && slot == fixture.credentials.count
                && (slot == 0 || (originalDEKBytes != nil && fixture.credentials[0].wrappedDEK != nil))
            assertionButtons[slot].isEnabled = controller == nil && slot < fixture.credentials.count
                && fixture.credentials[slot].prfSupported
        }
        var lines = [
            message, "", "RP: \(Self.relyingParty)",
            "Expected AASA application identifier: 5X68L55TNU.io.wsagency.wsurf",
            "Actual signing/provisioning/AASA and external approval: CONTROLLER VERIFICATION REQUIRED",
            "Fixture: \(fixtureURL.path)",
            "Process restart: \(fixture.createdInProcess != Self.processID)",
            "DEK in memory: \(originalDEKBytes != nil) (never persisted)",
            "Native provider cancellations: \(fixture.nativeCancellations); explicit cancellation requests: \(fixture.cancellationRequests)",
            ""
        ]
        for (slot, credential) in fixture.credentials.enumerated() {
            lines += [
                "\(Self.labels[slot]): \(credential.credentialID.base64EncodedString())",
                "  PRF supported: \(credential.prfSupported); wrapper: \(credential.wrappedDEK != nil)",
                "  Assertions: \(credential.assertions); after both registrations: \(credential.assertionsAfterBothRegistrations); after restart: \(credential.restartAssertions)",
                "  Wrong/missing PRF refused: \(credential.wrongPRFWasRejected)/\(credential.missingPRFWasRejected)",
                "  Native UP/UV flags: \(credential.lastAuthenticatorFlags.map { String($0) } ?? "not observed"); signature bytes: \(credential.lastSignatureBytes.map { String($0) } ?? "not observed")"
            ]
        }
        lines += ["", "Required: assert each credential at least twice, including after both registrations; quit/relaunch the owned stage and assert both again; exercise provider and pending/dismissal cancellation. No native gate success is inferred from these counters.", ""] + fixture.events
        output.string = lines.joined(separator: "\n")
    }
}
#endif
