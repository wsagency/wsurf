// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import SwiftUI

/// The Minimal toolbar as a panel of its own, a child of the browser window (`FloatingBarController`). It follows the window
/// across Spaces, minimises, hides and closes with it, yet can be dragged out of it. It exists only while the bar is
/// detached, which is off by default.
///
/// It takes the keyboard (the address is typed in it), so the window and the panel are one unit as far as the rest of the app
/// is concerned: `KeyUnit`, `AppCoordinator.isKeyWindow` and `NSWindow.sheetHost`.
class FloatingBarPanel: NSPanel {
    /// Called when a drag of the bar ends: the one place the place is saved and clamped.
    var onDragEnd: (() -> Void)?

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        false
    }

    convenience init(frame: NSRect) {
        self.init(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        // The bar draws its own shadow.
        hasShadow = false
        // Buttons act without taking the keyboard from the page; the address field takes it.
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isExcludedFromWindowsMenu = true
        isReleasedWhenClosed = false
        isRestorable = false
        animationBehavior = .none
        collectionBehavior = [.ignoresCycle]
        setAccessibilityLabel(String(localized: "WSurf Toolbar"))
        setAccessibilitySubrole(.floatingWindow)
    }

    /// The address field is in this panel, so ending the edit (Return, Escape, a click elsewhere) ends it here, and the panel would
    /// keep the keyboard with nothing to give it to: Space and the arrow keys would go nowhere until the page is clicked. The
    /// window's own first responder (the page) was never touched, so handing the keyboard back is all the page needs.
    override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
        let wasEditing = firstResponder is NSTextView
        let accepted = super.makeFirstResponder(responder)
        if accepted, wasEditing, !(responder is NSTextView), isKeyWindow {
            parent?.makeKey()
        }
        return accepted
    }

    /// `super` returns when the mouse is released.
    override func performDrag(with event: NSEvent) {
        super.performDrag(with: event)
        onDragEnd?()
    }

    /// The bar sits where it was put; AppKit does not move it back inside the screen (`FloatingBarMetrics.clamped` does).
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    // MARK: - Window commands go to the browser window

    /// Minimize, Zoom, Enter Full Screen and Close reach the key window, which is this panel while the address is edited.
    private static let windowCommands: Set<Selector> = [
        #selector(NSWindow.performMiniaturize(_:)), #selector(NSWindow.performZoom(_:)),
        #selector(NSWindow.toggleFullScreen(_:)), #selector(NSWindow.performClose(_:)),
    ]

    override func performMiniaturize(_ sender: Any?) {
        parent?.performMiniaturize(sender)
    }

    override func performZoom(_ sender: Any?) {
        parent?.performZoom(sender)
    }

    override func toggleFullScreen(_ sender: Any?) {
        parent?.toggleFullScreen(sender)
    }

    override func performClose(_ sender: Any?) {
        parent?.performClose(sender)
    }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if let action = item.action, Self.windowCommands.contains(action) {
            return parent?.validateUserInterfaceItem(item) ?? false
        }
        return super.validateUserInterfaceItem(item)
    }

    override func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if let action = item.action, Self.windowCommands.contains(action) {
            return parent?.validateMenuItem(item) ?? false
        }
        return super.validateMenuItem(item)
    }
}

extension NSWindow {
    /// The window, or its floating toolbar panel, has the keyboard: the two are one unit as far as the app is concerned.
    var isKeyUnit: Bool {
        isKeyWindow || childWindows?.contains { $0 is FloatingBarPanel && $0.isKeyWindow } == true
    }

    /// The window a sheet, an alert or a window command belongs to: the browser window for its floating toolbar panel, which
    /// is 44 pt high and would hold a sheet it cannot show. Every `NSApp.keyWindow` that picks a window to attach to goes
    /// through this.
    var sheetHost: NSWindow {
        (self as? FloatingBarPanel)?.parent ?? self
    }
}

/// Whether the Ask surface has anything to show beside the bar's row (results, a question, pages attached to one). The panel
/// grows toward the screen's middle by `FloatingBarMetrics.askHeadroom` while it does, and not otherwise.
nonisolated struct AskExtrasKey: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

/// The geometry of the panel, as pure functions of rectangles in screen coordinates. The bar's row (`row`) is the fixed point:
/// the panel is the row, room for its shadow, and, while Ask has extras, headroom on the side Ask opens to.
enum FloatingBarMetrics {
    /// Room around the bar for the shadow it draws.
    static let shadowInset: CGFloat = 16
    /// How far Ask's results grow beyond the bar's row.
    static let askHeadroom: CGFloat = 420

    /// The bar's width: the width it has in the window, and never wider than the screen it is on.
    static func barWidth(fullAddress: Bool, visibleWidth: CGFloat) -> CGFloat {
        IslandBar.width(fullAddress: fullAddress, available: visibleWidth - 2 * shadowInset)
    }

    /// The screen's visible frame the row is on: the one holding its centre, else the one it overlaps most, else the nearest.
    static func screen(for row: CGRect, in screens: [CGRect]) -> CGRect? {
        let centre = CGPoint(x: row.midX, y: row.midY)
        if let holding = screens.first(where: { $0.contains(centre) }) {
            return holding
        }
        func overlap(_ screen: CGRect) -> CGFloat {
            let shared = screen.intersection(row)
            return shared.isNull ? 0 : shared.width * shared.height
        }
        if let most = screens.max(by: { overlap($0) < overlap($1) }), overlap(most) > 0 {
            return most
        }
        func distance(_ screen: CGRect) -> CGFloat {
            hypot(screen.midX - centre.x, screen.midY - centre.y)
        }
        return screens.min { distance($0) < distance($1) }
    }

    /// `row` moved the least that puts it inside its screen's visible frame; a row larger than the screen sits at the frame's
    /// origin. With no screen, unchanged.
    static func clamped(row: CGRect, in screens: [CGRect]) -> CGRect {
        guard let visible = screen(for: row, in: screens) else { return row }
        var result = row
        result.origin.x = min(max(row.minX, visible.minX), max(visible.maxX - row.width, visible.minX))
        result.origin.y = min(max(row.minY, visible.minY), max(visible.maxY - row.height, visible.minY))
        return result
    }

    /// Ask opens upward when the bar is in the lower half of its screen, toward the middle of it.
    static func opensUpward(row: CGRect, in screens: [CGRect]) -> Bool {
        guard let visible = screen(for: row, in: screens) else { return true }
        return row.midY < visible.midY
    }

    /// Where the bar sits by default: centred over the window's edge the bar docks to, `gap` in from it.
    static func defaultRow(parent: CGRect, width: CGFloat, edge: MinimalBarEdge, gap: CGFloat) -> CGRect {
        let y = edge == .bottom ? parent.minY + gap : parent.maxY - gap - IslandBar.height
        return CGRect(x: parent.midX - width / 2, y: y, width: width, height: IslandBar.height)
    }

    /// The saved place: the row's origin relative to the origin of the window's frame.
    static func offset(of row: CGRect, in parent: CGRect) -> CGPoint {
        CGPoint(x: row.minX - parent.minX, y: row.minY - parent.minY)
    }

    static func row(at offset: CGPoint, size: CGSize, in parent: CGRect) -> CGRect {
        CGRect(origin: CGPoint(x: parent.minX + offset.x, y: parent.minY + offset.y), size: size)
    }

    /// The panel's frame around `row`. The row's own edge stays where it is whether or not the headroom is there.
    static func panelFrame(row: CGRect, opensUpward: Bool, hasExtras: Bool) -> CGRect {
        var frame = row.insetBy(dx: -shadowInset, dy: -shadowInset)
        if hasExtras {
            frame.size.height += askHeadroom
            if !opensUpward {
                frame.origin.y -= askHeadroom
            }
        }
        return frame
    }

    /// The inverse of `panelFrame`: where the row is in a panel's frame.
    static func row(inPanel frame: CGRect, opensUpward: Bool, hasExtras: Bool) -> CGRect {
        let bottom = frame.minY + shadowInset + (hasExtras && !opensUpward ? askHeadroom : 0)
        return CGRect(x: frame.minX + shadowInset, y: bottom, width: frame.width - 2 * shadowInset, height: IslandBar.height)
    }
}

/// Whether the window and its floating toolbar panel, as one unit, have the keyboard. Moving the keyboard from the window to
/// the panel resigns the window's key before the panel's becomes: told to the rest of the app as it comes, hold-to-talk would
/// be suspended while the address is typed.
struct KeyUnit {
    private(set) var isKey = false

    /// The unit's state when a panel appears or goes away: it is key if either was.
    mutating func seed(isKey: Bool) {
        self.isKey = isKey
    }

    /// A member became key. True when the unit was not key before: the app hears of it then, and not when the keyboard only
    /// moves between the window and the panel.
    mutating func becameKey() -> Bool {
        defer { isKey = true }
        return !isKey
    }

    /// A member resigned key, and the answer is asked one run-loop turn later, with who has the keyboard by then. True when the
    /// unit as a whole lost it: neither the window nor the panel is key.
    mutating func resigned(windowIsKey: Bool, panelIsKey: Bool) -> Bool {
        guard isKey, !windowIsKey, !panelIsKey else { return false }
        isKey = false
        return true
    }
}
