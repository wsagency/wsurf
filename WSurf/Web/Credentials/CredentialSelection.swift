// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Observation

/// Which rows of the credential list, or of the Trash, are selected, and where the keyboard cursor is. Pure state, shared by both lists.
///
/// The list tells it the rows it shows (`show`) once per refresh. Every other operation is O(1) except a range (`extend`), which is
/// O(range), and select all, which is O(rows). Rows read `selected` and `cursor` themselves, so a change redraws only the rows that
/// are built. A row the list stops showing (a search, a filter, a removal) leaves the selection, so an action never acts on rows
/// you cannot see.
@MainActor
@Observable
final class CredentialSelection {
    private(set) var selected: Set<UUID> = []
    /// The row the keyboard acts on when nothing is selected, and where an arrow key starts.
    private(set) var cursor: UUID?
    /// Where a range from the keyboard or a shift-click starts.
    private(set) var anchor: UUID?
    /// True while the list receives the keyboard: a row was clicked, or the search field handed it over.
    private(set) var ownsKeyboard = false
    /// Changes when the list should take the keyboard, so the key catcher becomes first responder again.
    private(set) var keyboardRequestID = 0
    /// Changes when a key moved the cursor, so the list scrolls to it. A click never scrolls.
    private(set) var scrollRequestID = 0
    /// The rows in the order the list shows them: the flat list, or the groups one after another with "By Site".
    @ObservationIgnored private(set) var order: [UUID] = []
    @ObservationIgnored private var position: [UUID: Int] = [:]

    var isEmpty: Bool {
        selected.isEmpty
    }

    /// What an action acts on, in list order: the selection, else the cursor row.
    var targets: [UUID] {
        if !selected.isEmpty {
            return order.filter { selected.contains($0) }
        }
        return cursor.map { [$0] } ?? []
    }

    // MARK: Rows

    /// The rows the list shows now, in order. Selected rows, the cursor and the anchor that are no longer among them are dropped.
    func show(_ ids: [UUID]) {
        order = ids
        position = Dictionary(ids.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        if selected.contains(where: { position[$0] == nil }) {
            selected = selected.filter { position[$0] != nil }
        }
        if let cursor, position[cursor] == nil {
            self.cursor = nil
        }
        if let anchor, position[anchor] == nil {
            self.anchor = nil
        }
    }

    /// Back to nothing, for another vault, a lock or another list.
    func reset() {
        selected = []
        cursor = nil
        anchor = nil
        ownsKeyboard = false
        order = []
        position = [:]
    }

    // MARK: Keyboard

    /// Moves the cursor by `delta` rows, stopping at the ends. `extending` selects the range from the anchor to the new cursor row.
    func moveCursor(by delta: Int, extending: Bool) {
        guard !order.isEmpty else { return }
        let target: Int
        if let current = cursor.flatMap({ position[$0] }) {
            target = min(max(current + delta, 0), order.count - 1)
        } else {
            target = delta >= 0 ? 0 : order.count - 1
        }
        let id = order[target]
        if extending {
            extend(to: id)
        } else {
            cursor = id
            anchor = id
        }
        scrollRequestID += 1
    }

    /// Selects or deselects the cursor row.
    func toggleCursor() {
        if let cursor {
            toggle(cursor)
        }
    }

    func selectAll() {
        selected = Set(order)
    }

    /// Deselects everything. The cursor stays.
    func clear() {
        if !selected.isEmpty {
            selected = []
        }
        anchor = cursor
    }

    // MARK: Mouse

    /// A plain click: the row gets the cursor and the keyboard. It selects nothing.
    func click(_ id: UUID) {
        cursor = id
        anchor = id
        takeKeyboard()
    }

    /// Command-click: toggles the row.
    func toggle(_ id: UUID) {
        if selected.contains(id) {
            selected.remove(id)
        } else {
            selected.insert(id)
        }
        cursor = id
        anchor = id
    }

    /// Shift-click and shift-arrow: selects the rows from the anchor to `id`, in list order, and puts the cursor on `id`.
    func extend(to id: UUID) {
        guard let end = position[id] else { return }
        let start = anchor.flatMap { position[$0] } ?? cursor.flatMap { position[$0] } ?? end
        if anchor == nil {
            anchor = cursor ?? id
        }
        selected = Set(order[min(start, end)...max(start, end)])
        cursor = id
    }

    // MARK: Focus

    /// The list takes the keyboard. With a row it starts there; without, the cursor stays or starts on the first row.
    func takeKeyboard(cursor row: UUID? = nil) {
        if let row, position[row] != nil {
            cursor = row
            anchor = row
        } else if cursor == nil, let first = order.first {
            cursor = first
            anchor = first
        }
        ownsKeyboard = true
        keyboardRequestID += 1
    }

    /// Another control took the keyboard (the search field, a sheet).
    func releaseKeyboard() {
        ownsKeyboard = false
    }

    // MARK: Removal

    /// The row the cursor goes to when `ids` leave the list: the next row that stays, else the previous one.
    func cursorAfterRemoving(_ ids: [UUID]) -> UUID? {
        let gone = Set(ids)
        let positions = ids.compactMap { position[$0] }
        guard let first = positions.min(), let last = positions.max() else { return cursor }
        return order.dropFirst(last + 1).first { !gone.contains($0) } ?? order.prefix(first).last { !gone.contains($0) }
    }

    /// Puts the cursor on `id` (or nowhere) without selecting it, for the row that takes over after a removal.
    func place(cursor id: UUID?) {
        cursor = id
        anchor = id
    }
}
