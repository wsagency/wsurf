// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AuthenticationServices
import Foundation
import WSurfVault

nonisolated enum CredentialUnlockResult: Sendable {
    case confirmed(UInt64)
    case reused(UInt64)

    var epoch: UInt64 {
        switch self {
        case .confirmed(let epoch), .reused(let epoch):
            epoch
        }
    }
}

/// Other callers of the same vault wait for its original caller's passkey and store verification. Each window can leave its
/// own wait. The original caller still owns cancellation of its own native and store calls.
@MainActor
final class CredentialUnlockAttempt {
    let confirmsMigration: Bool
    private var needsMigration = false
    private var result: Result<UInt64, any Error>?
    private typealias Reply = AsyncStream<Result<UInt64, any Error>>.Continuation
    private var waiters: [UUID: (confirmMigration: Bool, reply: Reply)] = [:]

    init(confirmMigration: Bool) {
        confirmsMigration = confirmMigration
    }

    func checkMigrationConsent(for state: StoreOpenState) throws {
        switch state {
        case .legacy, .resumeMigration:
            break
        case .provisional, .firstRun, .failClosed:
            return
        }
        needsMigration = true
        for (id, waiter) in waiters where !waiter.confirmMigration {
            waiter.reply.yield(.failure(CredentialStoreError.migrationNeedsConfirmation))
            waiter.reply.finish()
            waiters[id] = nil
        }
        guard confirmsMigration else { throw CredentialStoreError.migrationNeedsConfirmation }
    }

    func wait(confirmMigration: Bool) async throws -> UInt64 {
        try Task.checkCancellation()
        guard confirmMigration || !needsMigration else { throw CredentialStoreError.migrationNeedsConfirmation }
        if let result {
            return try result.get()
        }
        let id = UUID()
        let (replies, continuation) = AsyncStream<Result<UInt64, any Error>>.makeStream(bufferingPolicy: .bufferingNewest(1))
        waiters[id] = (confirmMigration, continuation)
        defer { waiters[id] = nil }
        for await reply in replies {
            try Task.checkCancellation()
            return try reply.get()
        }
        throw CancellationError()
    }

    func finish(_ result: Result<UInt64, any Error>) {
        guard self.result == nil else { return }
        self.result = result
        for waiter in waiters.values {
            waiter.reply.yield(result)
            waiter.reply.finish()
        }
        waiters.removeAll()
    }
}

extension CredentialManager {
    /// Opens the vault once. Only the caller that supplied the successful native assertion confirmed an action of its own.
    @discardableResult
    func unlock(
        in anchor: @autoclosure () -> ASPresentationAnchor, confirmMigration: Bool = false, verifying: (@Sendable (Bool) -> Void)? = nil
    ) async throws -> CredentialUnlockResult {
        try Task.checkCancellation()
        let locks = lockCount
        while let attempt = nativeUnlockAttempt {
            do {
                let epoch = try await attempt.wait(confirmMigration: confirmMigration)
                try Task.checkCancellation()
                guard authorizationEpoch == epoch else { throw CredentialVaultError.unauthorized }
                return .reused(epoch)
            } catch CredentialStoreError.migrationNeedsConfirmation where confirmMigration && !attempt.confirmsMigration {
                // The first window did not consent. This caller may start its own explicitly confirmed upgrade.
                try Task.checkCancellation()
                guard lockCount == locks else { throw CredentialVaultError.unauthorized }
            }
        }
        if let epoch = authorizationEpoch {
            return .reused(epoch)
        }

        let attempt = CredentialUnlockAttempt(confirmMigration: confirmMigration)
        nativeUnlockAttempt = attempt
        defer {
            if nativeUnlockAttempt === attempt {
                nativeUnlockAttempt = nil
            }
        }
        do {
            let epoch = try await authenticateUnlock(in: anchor(), attempt: attempt, verifying: verifying)
            guard nativeUnlockAttempt === attempt, authorizationEpoch == epoch else { throw CredentialVaultError.unauthorized }
            try Task.checkCancellation()
            attempt.finish(.success(epoch))
            return .confirmed(epoch)
        } catch {
            attempt.finish(.failure(error))
            throw error
        }
    }
}
