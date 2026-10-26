// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

extension ChromiumDevTools {
    /// A session's execution contexts by unique ID, and by what a lookup names: the frame, document and world. Every evaluation and
    /// every bound document asks the second way, which a scan of all contexts answered in time that grew with the page's frames.
    /// Every change goes through here, so the two views cannot drift apart.
    struct ContextTable: Sequence {
        private struct Key: Hashable {
            let frameID: String
            let documentID: String
            let worldName: String

            init(_ state: ContextState) {
                frameID = state.frameID
                documentID = state.documentID
                worldName = state.worldName
            }

            init(frameID: String, documentID: String, worldName: String) {
                self.frameID = frameID
                self.documentID = documentID
                self.worldName = worldName
            }
        }

        private var states: [String: ContextState] = [:]
        private var uniqueIDs: [Key: String] = [:]

        var isEmpty: Bool {
            states.isEmpty
        }

        var values: Dictionary<String, ContextState>.Values {
            states.values
        }

        subscript(_ uniqueID: String) -> ContextState? {
            get { states[uniqueID] }
            set {
                if let old = states[uniqueID], uniqueIDs[Key(old)] == uniqueID {
                    uniqueIDs.removeValue(forKey: Key(old))
                }
                states[uniqueID] = newValue
                if let newValue {
                    uniqueIDs[Key(newValue)] = uniqueID
                }
            }
        }

        /// The context of `worldName` (empty: the main world) in the frame's document, if one is recorded.
        func context(frameID: String, documentID: String, worldName: String) -> ContextState? {
            uniqueIDs[Key(frameID: frameID, documentID: documentID, worldName: worldName)].flatMap { states[$0] }
        }

        @discardableResult
        mutating func removeValue(forKey uniqueID: String) -> ContextState? {
            let old = self[uniqueID]
            self[uniqueID] = nil
            return old
        }

        mutating func removeAll() {
            states.removeAll()
            uniqueIDs.removeAll()
        }

        /// The frame's contexts now belong to `documentID` (a page restored from the cache brings its contexts back).
        mutating func setDocument(_ documentID: String, ofFrame frameID: String) {
            for (uniqueID, state) in states where state.frameID == frameID {
                var updated = state
                updated.documentID = documentID
                self[uniqueID] = updated
            }
        }

        func makeIterator() -> Dictionary<String, ContextState>.Iterator {
            states.makeIterator()
        }
    }
}
