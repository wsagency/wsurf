// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation

actor MCPClientInstaller {
    struct Result: Sendable {
        let alreadyPresent: Bool
        let backupURL: URL?
    }

    func isInstalled(_ target: MCPClientTarget, command: String) throws -> Bool {
        try installation(target, command: command) != .absent
    }

    /// Reads the saved configuration without changing it.
    func installation(_ target: MCPClientTarget, command: String) throws -> MCPClientInstallation {
        do {
            let file = try MCPConfigurationFile(url: target.configurationURL)
            guard file.original != nil else { return .absent }
            if target.kind == .codex {
                guard let executable = target.codexExecutable else { throw MCPClientSetupError.missingCodex }
                return try MCPCodexConfiguration.installation(in: file.original, executable: executable, command: command)
            }
            return try MCPClientConfiguration.installation(in: file.original, command: command)
        } catch let error as MCPClientSetupError {
            throw error
        } catch {
            throw MCPClientSetupError.invalidConfiguration
        }
    }

    /// Adds WSurf to the client, or with a token sets only the pairing token of an existing WSurf entry.
    func install(_ target: MCPClientTarget, command: String, token: String? = nil) throws -> Result {
        do {
            let file = try MCPConfigurationFile(url: target.configurationURL)
            let replacement: Data?
            if target.kind == .codex {
                guard let executable = target.codexExecutable else { throw MCPClientSetupError.missingCodex }
                replacement = try MCPCodexConfiguration.adding(to: file.original, executable: executable, command: command, token: token)
            } else {
                replacement = try MCPClientConfiguration.addingJSON(to: file.original, kind: target.kind, command: command, token: token)
            }
            guard let replacement else { return Result(alreadyPresent: true, backupURL: nil) }
            try Task.checkCancellation()
            return Result(alreadyPresent: false, backupURL: try file.commit(replacement))
        } catch let error as MCPClientSetupError {
            throw error
        } catch {
            throw MCPClientSetupError.fileAccess
        }
    }

    /// Writes a fresh token into the client's entry (adding the entry when missing) and then records its hash. A client
    /// that is already paired through this entry keeps its record and gets the new token; the old token stops working.
    /// The record is saved only after the configuration is, so a failed write never leaves a pairing for an unconfigured
    /// client.
    func pair(
        _ target: MCPClientTarget, command: String, trustStore: MCPTrustStore, name: String? = nil
    ) async throws -> (client: PairedClient, backupURL: URL?) {
        await trustStore.loadIfNeeded()
        guard await trustStore.isAvailable else { throw MCPClientSetupError.pairingUnavailable }
        let previous: PairedClient?
        if case .installed(let token?) = try installation(target, command: command) {
            previous = await trustStore.client(forToken: token)
        } else {
            previous = nil
        }
        let token = try MCPPairing.makeToken()
        let result = try install(target, command: command, token: token)
        do {
            let client = try await trustStore.pair(
                token: token, name: name ?? target.kind.name, kind: target.kind, replacing: previous?.id
            )
            return (client, result.backupURL)
        } catch {
            throw MCPClientSetupError.pairingFailed
        }
    }
}
