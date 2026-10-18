// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

extension BrowserSettings {
    /// Where each group of command palette results appears, first on top. It is app-wide, like the palette itself.
    /// The setter completes a partial list so a section can never drop out of the palette.
    var commandPaletteOrder: [CommandPaletteSection] {
        get { globalValue(\.commandPaletteOrder, storage: storedCommandPaletteOrder) }
        set {
            setGlobal(
                \BrowserSettings.commandPaletteOrder,
                storage: \BrowserSettings.storedCommandPaletteOrder,
                value: Self.completeOrder(newValue),
                key: Key.commandPaletteOrder,
                encode: { $0.map(\.rawValue) }
            )
        }
    }

    /// Moves a section up (negative) or down (positive); a move past either end does nothing.
    func moveCommandPaletteSection(_ section: CommandPaletteSection, by offset: Int) {
        var order = commandPaletteOrder
        guard let index = order.firstIndex(of: section), order.indices.contains(index + offset) else { return }
        order.insert(order.remove(at: index), at: index + offset)
        commandPaletteOrder = order
    }

    func resetCommandPaletteOrder() {
        commandPaletteOrder = CommandPaletteSection.allCases
    }
}
