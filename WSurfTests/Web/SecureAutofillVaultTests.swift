// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation
import LocalAuthentication
import Synchronization
import Testing
import WebKit

@testable import WSurf

nonisolated final class MemoryAutofillStorage: AutofillSecureStorage {
    private struct State {
        var data: [String: Data] = [:]
        var reads = 0
        var writes = 0
        var erases = 0
        var existenceChecks = 0
        var failingExistence = false
        var readFailure: OSStatus?
    }
    private let state = Mutex(State())

    var itemCount: Int {
        state.withLock { $0.data.count }
    }
    /// How many times a secret was read: a presence check is not one.
    var readCount: Int {
        state.withLock { $0.reads }
    }
    var writeCount: Int {
        state.withLock { $0.writes }
    }
    var eraseCount: Int {
        state.withLock { $0.erases }
    }
    var existenceCheckCount: Int {
        state.withLock { $0.existenceChecks }
    }

    /// Makes `exists` fail the way a Keychain query error does.
    func failExistenceChecks() {
        state.withLock { $0.failingExistence = true }
    }

    /// Makes every read fail with `status`, as a canceled or failed authentication does.
    func failReads(with status: OSStatus?) {
        state.withLock { $0.readFailure = status }
    }

    func read(service: String, context: LAContext) throws -> Data? {
        try state.withLock {
            $0.reads += 1
            if let status = $0.readFailure {
                throw AutofillVaultError.keychain(status)
            }
            return $0.data[service]
        }
    }

    func write(_ data: Data, service: String, context: LAContext) throws {
        state.withLock {
            $0.writes += 1
            $0.data[service] = data
        }
    }

    func erase(service: String) throws {
        state.withLock {
            $0.erases += 1
            _ = $0.data.removeValue(forKey: service)
        }
    }

    func exists(service: String) throws -> Bool {
        try state.withLock {
            $0.existenceChecks += 1
            if $0.failingExistence {
                throw AutofillVaultError.keychain(errSecNotAvailable)
            }
            return $0.data[service] != nil
        }
    }
}

@MainActor
struct SecureAutofillVaultTests {
    @Test func passwordsStayInSecureStorageAndAreIsolatedByProfile() async throws {
        let storage = MemoryAutofillStorage()
        let first = SecureAutofillVault<SavedPassword>(profileID: UUID(), kind: "passwords", reason: "Test", storage: storage)
        let second = SecureAutofillVault<SavedPassword>(profileID: UUID(), kind: "passwords", reason: "Test", storage: storage)
        let record = try SavedPassword(website: "https://example.test", username: "ada", password: "test-secret")
        _ = try await first.update { _ in [record] }
        #expect(try await first.records() == [record])
        #expect(try await second.records().isEmpty)
        #expect(storage.itemCount == 1)
        try await first.erase()
        #expect(try await first.records().isEmpty)
    }

    @Test func privateVaultRefusesEveryOperation() async {
        let storage = MemoryAutofillStorage()
        let vault = SecureAutofillVault<SavedPassword>(profileID: Profile.privateID, kind: "passwords", reason: "Test", storage: storage)
        await #expect(throws: AutofillVaultError.self) { try await vault.records() }
        await #expect(throws: AutofillVaultError.self) { try await vault.update { $0 } }
        await #expect(throws: AutofillVaultError.self) { try await vault.erase() }
        #expect(storage.itemCount == 0)
    }

    @Test func credentialMatchingUsesExactHTTPSOrigins() throws {
        let record = try SavedPassword(website: "https://EXAMPLE.test:443/login", username: "ada", password: "old")
        #expect(record.origin == "https://example.test")
        #expect(SavedPassword.origin(for: URL(string: "http://example.test")!) == nil)
        #expect(SavedPassword.origin(for: URL(string: "https://user@example.test")!) == nil)
        #expect(SavedPassword.origin(for: URL(string: "https://sub.example.test")!) != record.origin)
        #expect(SavedPassword.origin(for: URL(string: "https://example.test:8443")!) != record.origin)
        let sameLogin = try SavedPassword(website: "example.test/account", username: "ada", password: "new")
        #expect(sameLogin.origin == record.origin)
        #expect(throws: AutofillVaultError.self) { try SavedPassword(website: "example.test", username: "ada", password: "") }
    }

    @Test func generatedPasswordsAreLongAndVary() throws {
        let generated = try (0..<20).map { _ in try SavedPassword.generate() }
        #expect(Set(generated).count == generated.count)
        #expect(generated.allSatisfy { $0.count == 24 })
    }

    @Test func enabledPasswordExtensionsAreRecognizedButDisabledAndUnrelatedOnesAreNot() {
        var password = InstalledExtension(id: "nngceckbapebfimnlniiiahkandclblb", displayName: "Bitwarden", version: "1", enabled: true, installedAt: .now)
        let other = InstalledExtension(id: "other", displayName: "Reader", version: "1", enabled: true, installedAt: .now)
        #expect(PasswordExtensionPolicy.provider(in: [other, password])?.id == password.id)
        password.enabled = false
        #expect(PasswordExtensionPolicy.provider(in: [other, password]) == nil)
        let apple = InstalledExtension(id: "system", displayName: "Passwords", version: "1", enabled: true, installedAt: .now)
        #expect(PasswordExtensionPolicy.provider(in: [apple])?.id == apple.id)
        #expect(PasswordExtensionPolicy.availableProviders(in: [other, password, apple]).map(\.id) == [apple.id])
        password.enabled = true
        #expect(PasswordExtensionPolicy.provider(in: [password, apple])?.id == password.id)
    }
}
