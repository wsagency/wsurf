// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// When a credential came into the vault and when it last changed, read from fields the vault already stores (spec §12.1).
/// Only a credential WSurf created has a creation date of its own. A moved or imported one says so instead of claiming to
/// have been created, and a date the vault never recorded stays unknown rather than being guessed.
nonisolated struct CredentialDates: Equatable, Sendable {
    enum Origin: Sendable {
        case created
        case movedToWSurf
        case imported
    }

    /// Where a caption is shown: a list row has room for the date only, the editor adds the time.
    enum Style: Sendable {
        case list
        case editor
    }

    let added: (date: Date, origin: Origin)?
    /// The last semantic change; `nil` when it is the same moment as `added`, or unknown.
    let updated: Date?

    init(_ account: CredentialAccount) {
        if let createdAt = account.createdAt {
            added = (createdAt, .created)
        } else if let migratedAt = account.migratedAt {
            added = (migratedAt, .movedToWSurf)
        } else if let importedAt = account.passwordEvents?.lastImportedAt ?? account.totpEvents?.lastImportedAt {
            added = (importedAt, .imported)
        } else {
            added = nil
        }
        updated = account.modifiedAt == added?.date ? nil : account.modifiedAt
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.added?.date == rhs.added?.date && lhs.added?.origin == rhs.added?.origin && lhs.updated == rhs.updated
    }

    /// "Created Oct 5, 2026 · Updated Oct 9, 2026"; empty when no date is known.
    func caption(style: Style) -> String {
        func formatted(_ date: Date) -> String {
            date.formatted(date: .abbreviated, time: style == .editor ? .shortened : .omitted)
        }
        var parts: [String] = []
        if let added {
            let when = formatted(added.date)
            let line = switch added.origin {
            case .created:
                String(localized: "Created \(when)")
            case .movedToWSurf:
                String(localized: "Moved to WSurf \(when)")
            case .imported:
                String(localized: "Imported \(when)")
            }
            parts.append(line)
        }
        if let updated {
            parts.append(String(localized: "Updated \(formatted(updated))"))
        }
        return parts.joined(separator: " · ")
    }
}
