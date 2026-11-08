// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Observation

extension AppCoordinator {
    /// The modifier keys held now. A view that reads this redraws on every press and release, so a row must not: a
    /// hidden control stays off it. Written out by hand, what `@Observable` writes for a stored property, so that a DEBUG
    /// build can count the reads.
    var linkModifiers: NSEvent.ModifierFlags {
        get {
            access(keyPath: \.linkModifiers)
            #if DEBUG
            Self.linkModifierReads[ObjectIdentifier(self), default: 0] += 1
            #endif
            return heldModifiers
        }
        set {
            guard newValue != heldModifiers else { return }
            withMutation(keyPath: \.linkModifiers) { heldModifiers = newValue }
        }
    }

    #if DEBUG
    /// How many times `linkModifiers` was read, by any view or model, for each coordinator. A test counts the reads of its
    /// own coordinator over a press and a release; another window's coordinator does not add to them.
    static var linkModifierReads: [ObjectIdentifier: Int] = [:]
    #endif
}
