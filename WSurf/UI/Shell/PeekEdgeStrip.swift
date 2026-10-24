// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import SwiftUI

/// The sensor along the window's leading edge that opens a peek, the hidden sidebar floated over the page or the Minimal
/// tab list. It opens on rest, not on pass-over: the pointer has to stay on the strip for `dwell`.
enum PeekEdge {
    static let width: CGFloat = 10
    static let dwell: Duration = .milliseconds(75)

    static func isHeld(pointer: CGPoint?, frame: CGRect) -> Bool {
        guard let pointer, !frame.isEmpty else { return false }
        return frame.contains(pointer)
    }

    /// A window point (origin bottom-left, from `mouseLocationOutsideOfEventStream`) in the shell's space (origin
    /// top-left). The content view is the whole window, the full-screen title strip included, and the shell lays out
    /// below that strip, so the frames the sensors measure sit lower by the strip and need no correction here.
    static func shellPoint(fromWindow location: CGPoint, contentHeight: CGFloat) -> CGPoint {
        CGPoint(x: location.x, y: contentHeight - location.y)
    }

    /// The Standard sidebar has a sensor while it is hidden. The Minimal window has no Standard sidebar.
    static func armsSidebar(isMinimal: Bool, isSidebarShowing: Bool) -> Bool {
        !isMinimal && !isSidebarShowing
    }

    /// The Minimal tab list has a sensor while it is closed. Kept open, it is docked and there is nothing to peek at.
    static func armsTabList(isPinned: Bool, isTabListOpen: Bool) -> Bool {
        !isPinned && !isTabListOpen
    }
}

struct PeekEdgeStrip: View {
    let coordinator: AppCoordinator
    let onPeek: () -> Void

    @State private var frame: CGRect = .zero
    @State private var dwell: Task<Void, Never>?

    var body: some View {
        Color.clear
            .frame(width: PeekEdge.width)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                frame = $0
            }
            .onHover { inside in
                dwell?.cancel()
                guard inside else { return }
                dwell = Task {
                    try? await Task.sleep(for: PeekEdge.dwell)
                    guard !Task.isCancelled,
                          PeekEdge.isHeld(pointer: coordinator.pointerInShell, frame: frame) else { return }
                    onPeek()
                }
            }
            .onDisappear { dwell?.cancel() }
            .accessibilityHidden(true)
    }
}
