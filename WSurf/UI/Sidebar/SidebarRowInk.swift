// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// What a row reads from its surroundings to draw a `SidebarRowStyle`. Every kind of row keeps one, so none of
/// them reads the environment on its own.
struct SidebarRowInkSource: DynamicProperty {
    @Environment(\.colorSchemeContrast) private var contrast

    var increasedContrast: Bool {
        contrast == .increased
    }
}
