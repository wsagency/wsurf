// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A short confirmation above the credential list (and in the editor's footer): what the last copy or list action did. The text
/// names the part or a count and never a value. `offersUndo` adds an Undo button for an action the page can take back.
nonisolated struct CredentialNotice: Equatable, Sendable {
    let text: String
    let offersUndo: Bool
}
