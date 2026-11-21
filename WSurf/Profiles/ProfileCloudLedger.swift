// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import WSurfCore

/// Stored in profiles.json so the intent and the profile list have a single commit point.
nonisolated struct ProfileCloudLedger: Codable, Equatable {
    var outgoing: Set<CloudProfileInstance> = []
    /// The deletion warning approved these links before the normal local revocation detached them.
    var detached: [UUID: Set<CloudProfileInstance>] = [:]
    var pending: [UUID: CloudProfileInstance] = [:]
    var active: [UUID: [String: UUID]] = [:]
    /// A choice interrupted while the independently durable settings and shared links are being moved.
    var creating: [UUID: CloudProfileInstance] = [:]
}

enum ProfileDeletionScope {
    case confirmed(Set<CloudProfileInstance>)
    case localOnly(CloudProfileInstance)

    var retired: CloudProfileInstance? {
        if case .localOnly(let retired) = self {
            return retired
        }
        return nil
    }

    func sharedCopies(_ live: Set<CloudProfileInstance>) -> Set<CloudProfileInstance> {
        switch self {
        case .confirmed(let warned):
            warned.intersection(live)
        case .localOnly:
            []
        }
    }
}
