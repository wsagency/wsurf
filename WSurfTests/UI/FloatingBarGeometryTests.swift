// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import Foundation
import Testing

@testable import WSurf

/// Where the floating toolbar sits: pure functions of rectangles in screen coordinates, no window. The bar stays on a screen
/// (and is docked when there is none), near its own window, at a place saved as a fraction of that window's size.
@MainActor
@Suite(.serialized)
struct FloatingBarGeometryTests {
    private let screens = [CGRect(x: 0, y: 0, width: 1_440, height: 860), CGRect(x: 1_440, y: -200, width: 1_920, height: 1_080)]
    private let size = CGSize(width: 720, height: 44)

    private func row(_ x: CGFloat, _ y: CGFloat) -> CGRect {
        CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    @Test func aBarOutsideEveryScreenIsMovedBackTheLeastDistance() {
        #expect(FloatingBarMetrics.clamped(row: row(100, 100), in: screens) == row(100, 100), "inside: untouched")
        #expect(FloatingBarMetrics.clamped(row: row(-300, 100), in: screens) == row(0, 100))
        #expect(FloatingBarMetrics.clamped(row: row(900, 100), in: screens) == row(720, 100), "right edge of the first screen")
        #expect(FloatingBarMetrics.clamped(row: row(100, 900), in: screens) == row(100, 816))
        #expect(FloatingBarMetrics.clamped(row: row(100, -500), in: screens) == row(100, 0))
        #expect(FloatingBarMetrics.clamped(row: row(5_000, 100), in: screens) == row(2_640, 100), "the nearest screen is the second")
    }

    @Test func aBarOnTheSecondScreenIsClampedToThatScreen() {
        #expect(FloatingBarMetrics.clamped(row: row(1_600, -150), in: screens) == row(1_600, -150))
        #expect(FloatingBarMetrics.clamped(row: row(1_600, -300), in: screens) == row(1_600, -200), "the second screen starts at -200")
        #expect(FloatingBarMetrics.clamped(row: row(3_000, 700), in: screens) == row(2_640, 700))
    }

    @Test func aBarAcrossTwoScreensBelongsToTheOneItIsMostOn() {
        let straddling = row(1_000, 100)
        #expect(FloatingBarMetrics.screen(for: straddling, in: screens) == screens[0], "its centre is on the first")
        let mostlySecond = row(1_300, 100)
        #expect(FloatingBarMetrics.screen(for: mostlySecond, in: screens) == screens[1])
        #expect(FloatingBarMetrics.screen(for: row(0, 0), in: []) == nil)
        #expect(FloatingBarMetrics.clamped(row: row(7, 9), in: []) == row(7, 9), "no screen, no change")
    }

    @Test func aBarWiderThanTheScreenSitsAtItsOrigin() {
        let wide = CGRect(x: 50, y: 50, width: 2_000, height: 44)
        #expect(FloatingBarMetrics.clamped(row: wide, in: [CGRect(x: 0, y: 0, width: 1_000, height: 800)]).minX == 0)
    }

    @Test func askOpensTowardTheMiddleOfTheScreen() {
        #expect(FloatingBarMetrics.opensUpward(row: row(100, 20), in: screens), "low on the screen: upward")
        #expect(!FloatingBarMetrics.opensUpward(row: row(100, 800), in: screens), "high on the screen: downward")
        #expect(FloatingBarMetrics.opensUpward(row: row(1_600, -150), in: screens), "the second screen's own middle counts")
        #expect(!FloatingBarMetrics.opensUpward(row: row(1_600, 600), in: screens))
        #expect(FloatingBarMetrics.opensUpward(row: row(0, 0), in: []), "with no screen, as a bar at the bottom")
    }

    @Test func thePanelKeepsTheRowsEdgeFixedWhateverAskDoes() {
        let bar = row(200, 300)
        for upward in [true, false] {
            let closed = FloatingBarMetrics.panelFrame(row: bar, opensUpward: upward, hasExtras: false)
            let open = FloatingBarMetrics.panelFrame(row: bar, opensUpward: upward, hasExtras: true)
            #expect(closed == bar.insetBy(dx: -FloatingBarMetrics.shadowInset, dy: -FloatingBarMetrics.shadowInset))
            #expect(open.height == closed.height + FloatingBarMetrics.askHeadroom)
            #expect(open.width == closed.width)
            #expect(upward ? open.minY == closed.minY : open.maxY == closed.maxY, "the edge Ask grows away from stays put")
            for extras in [false, true] {
                let frame = FloatingBarMetrics.panelFrame(row: bar, opensUpward: upward, hasExtras: extras)
                #expect(FloatingBarMetrics.row(inPanel: frame, opensUpward: upward, hasExtras: extras) == bar,
                        "upward \(upward) extras \(extras)")
            }
        }
    }

    @Test func theSavedPlaceIsAFractionOfTheWindowsSize() {
        let parent = CGRect(x: 300, y: 200, width: 1_000, height: 700)
        let bar = row(450, 260)

        let offset = FloatingBarMetrics.offset(of: bar, in: parent)
        #expect(offset == CGPoint(x: 0.15, y: 60.0 / 700.0))
        #expect(FloatingBarMetrics.row(at: offset, size: size, in: parent) == bar)
        let moved = CGRect(x: 700, y: 50, width: 1_000, height: 700)
        let there = FloatingBarMetrics.row(at: offset, size: size, in: moved).origin
        #expect(abs(there.x - 850) < 0.001 && abs(there.y - 110) < 0.001, "another window of the same size, the same place")
        #expect(FloatingBarMetrics.offset(of: bar, in: .zero) == .zero, "a window with no size saves nothing odd")
    }

    /// S3: a bar dragged near the top of a tall window must not land far above a short one, over whatever is there.
    @Test func aSmallerWindowPutsTheBarAtTheSamePlaceRelativeToItself() {
        let tall = CGRect(x: 0, y: 0, width: 1_200, height: 1_200)
        let nearTheTop = row(240, 1_150)
        let saved = FloatingBarMetrics.offset(of: nearTheTop, in: tall)

        let short = CGRect(x: 100, y: 100, width: 600, height: 600)
        let placed = FloatingBarMetrics.row(at: saved, size: size, in: short)
        #expect(abs(placed.minY - (100 + saved.y * 600)) < 0.001, "proportional: near the top of the short window")
        #expect(placed.minY < short.maxY + short.height, "and nowhere near 550 pt above it as an absolute offset would put it")
        #expect(abs(placed.minY - 675) < 1, "1,150/1,200 of 600 is 575 from its bottom")
    }

    @Test func aBarIsKeptWithinOneWindowSizeOfItsWindow() {
        let parent = CGRect(x: 1_000, y: 500, width: 800, height: 600)
        let far = row(9_000, 9_000)

        let kept = FloatingBarMetrics.near(far, parent: parent)
        #expect(kept.maxX <= parent.maxX + parent.width + 0.001 && kept.maxY <= parent.maxY + parent.height + 0.001)
        #expect(kept.minX >= parent.minX - parent.width - 0.001)
        let beside = row(1_900, 700)
        #expect(FloatingBarMetrics.near(beside, parent: parent) == beside, "beside the window or on a neighbouring display: untouched")
        let place = FloatingBarPlace(offset: CGPoint(x: 40, y: 40), windowID: UUID(), windowSize: parent.size)
        let huge = [CGRect(x: -5_000, y: -5_000, width: 60_000, height: 60_000)]
        let applied = FloatingBarMetrics.applied(place, size: size, windowID: UUID(), parent: parent, in: huge)
        #expect((applied?.minX ?? .infinity) <= parent.maxX + parent.width,
                "a saved place far outside, in another window, is brought back near that window")
    }

    // MARK: - A drag is free; a saved place is applied near its window unless it is this window's own

    private let id = UUID()
    private let other = UUID()
    private let window = CGRect(x: 200, y: 100, width: 1_000, height: 700)

    private func close(_ left: CGRect?, _ right: CGRect) -> Bool {
        guard let left else { return false }
        return abs(left.minX - right.minX) < 0.001 && abs(left.minY - right.minY) < 0.001
            && abs(left.width - right.width) < 0.001 && abs(left.height - right.height) < 0.001
    }

    private func place(of bar: CGRect, in parent: CGRect, window: UUID) -> FloatingBarPlace {
        FloatingBarPlace(offset: FloatingBarMetrics.offset(of: bar, in: parent), windowID: window, windowSize: parent.size)
    }

    @Test func aDragMayDropTheBarOnAnotherDisplayFarFromItsWindow() {
        let far = row(2_500, 100)

        #expect(FloatingBarMetrics.dropped(far, in: screens) == far, "second display, 1,300 pt from the window: allowed")
        #expect(FloatingBarMetrics.placed(far, parent: window, in: screens) != far, "the near-the-window rule would have refused it")
        let lost = FloatingBarMetrics.dropped(row(9_000, 9_000), in: screens)
        #expect(lost.map { r in screens.contains { $0.contains(CGPoint(x: r.midX, y: r.midY)) } } == true, "but never off every screen")
        #expect(FloatingBarMetrics.dropped(far, in: []) == nil)
    }

    @Test func aRelaunchPutsTheBarWhereThePersonDroppedItWhileTheDisplayAndTheWindowAreThere() {
        let far = row(2_500, 100)
        let saved = place(of: far, in: window, window: id)

        let applied = FloatingBarMetrics.applied(saved, size: size, windowID: id, parent: window, in: screens)
        #expect(close(applied, far), "the same window, the same size, the second display still there: where it was put")
    }

    @Test func withTheSecondDisplayGoneTheBarComesBackNextToItsWindowAndDoesNotDock() throws {
        let saved = place(of: row(2_500, 100), in: window, window: id)

        let applied = try #require(FloatingBarMetrics.applied(saved, size: size, windowID: id, parent: window, in: [screens[0]]))
        #expect(close(applied, row(720, 100)), "on the display that is left, within one window size of the window")
        #expect(applied.intersects(window), "next to its window: it touches it")
        #expect(FloatingBarMetrics.applied(saved, size: size, windowID: id, parent: window, in: []) == nil, "no screen: the caller docks")
    }

    @Test func aNewMuchSmallerWindowKeepsTheBarNearItself() throws {
        let saved = place(of: row(2_500, 100), in: window, window: id)
        let small = CGRect(x: 100, y: 100, width: 400, height: 300)

        let fresh = try #require(FloatingBarMetrics.applied(saved, size: size, windowID: other, parent: small, in: screens))
        #expect(fresh.minX <= small.maxX + small.width - size.width + 0.001, "within one window size of the small window: \(fresh)")
        #expect(close(fresh, row(180, 100)))
        let shrunk = try #require(FloatingBarMetrics.applied(saved, size: size, windowID: id, parent: small, in: screens))
        #expect(close(shrunk, row(180, 100)), "the same window after it became much smaller is no longer trusted with the place")
    }

    @Test func anotherWindowOfTheSameSizeDoesNotPutItsBarOnTheFarDisplay() throws {
        let saved = place(of: row(2_500, 100), in: window, window: id)

        let another = try #require(FloatingBarMetrics.applied(saved, size: size, windowID: other, parent: window, in: screens))
        #expect(another.maxX <= window.maxX + window.width + 0.001, "never farther than one window size from its own window")
        #expect(another != row(2_500, 100))
    }

    @Test func aWindowIsTheSameWindowWhileItIsNotMuchSmallerThanItWas() {
        let saved = FloatingBarPlace(offset: .zero, windowID: id, windowSize: CGSize(width: 1_000, height: 800))

        #expect(FloatingBarMetrics.isOwn(saved, windowID: id, windowSize: CGSize(width: 1_000, height: 800)))
        #expect(FloatingBarMetrics.isOwn(saved, windowID: id, windowSize: CGSize(width: 1_600, height: 1_200)), "bigger is fine")
        #expect(FloatingBarMetrics.isOwn(saved, windowID: id, windowSize: CGSize(width: 750, height: 600)), "three quarters is the limit")
        #expect(!FloatingBarMetrics.isOwn(saved, windowID: id, windowSize: CGSize(width: 749, height: 800)))
        #expect(!FloatingBarMetrics.isOwn(saved, windowID: id, windowSize: CGSize(width: 1_000, height: 599)))
        #expect(!FloatingBarMetrics.isOwn(saved, windowID: other, windowSize: CGSize(width: 1_000, height: 800)), "another window")
    }

    // MARK: - S2: a bar that cannot be seen is brought back, or docked

    @Test func aBarOnADisplayThatWentAwayComesBackOntoTheOnesThatAreLeft() {
        let parent = CGRect(x: 100, y: 100, width: 1_000, height: 700)
        let wanted = row(1_300, 300)
        let both = [screens[0], screens[1]]

        let onSecond = FloatingBarMetrics.placed(wanted, parent: parent, in: both)
        #expect(onSecond == wanted, "within one window size of the window, on the second display")
        let afterUnplug = FloatingBarMetrics.placed(wanted, parent: parent, in: [screens[0]])
        #expect(afterUnplug == row(720, 300), "the second display is gone: onto the first")
        #expect(FloatingBarMetrics.placed(wanted, parent: parent, in: []) == nil, "no screen at all: nothing to place it on")
    }

    @Test func aWindowThatMovedTakesItsBarNearWithIt() throws {
        let before = CGRect(x: 100, y: 100, width: 1_000, height: 700)
        let saved = FloatingBarMetrics.offset(of: row(300, 120), in: before)
        let after = CGRect(x: 200, y: 700, width: 1_000, height: 700)

        let moved = FloatingBarMetrics.placed(FloatingBarMetrics.row(at: saved, size: size, in: after), parent: after, in: screens)
        let there = try #require(moved)
        #expect(abs(there.minX - 400) < 0.001 && abs(there.minY - 720) < 0.001, "the bar went with the window")
        let offTheTop = CGRect(x: 200, y: 2_000, width: 1_000, height: 700)
        let clamped = FloatingBarMetrics.placed(FloatingBarMetrics.row(at: saved, size: size, in: offTheTop), parent: offTheTop, in: screens)
        #expect(clamped?.maxY ?? .infinity <= 860.001, "a window dragged above the screen does not take the bar out of it")
    }

    @Test func theBarStartsOverItsDockEdge() {
        let parent = CGRect(x: 100, y: 100, width: 1_000, height: 700)

        let bottom = FloatingBarMetrics.defaultRow(parent: parent, width: 720, edge: .bottom, gap: 14)
        #expect(bottom == CGRect(x: 240, y: 114, width: 720, height: 44))
        let top = FloatingBarMetrics.defaultRow(parent: parent, width: 720, edge: .top, gap: 14)
        #expect(top == CGRect(x: 240, y: 742, width: 720, height: 44))
    }

    @Test func theBarIsNeverWiderThanItsScreen() {
        #expect(FloatingBarMetrics.barWidth(fullAddress: false, visibleWidth: 3_000) == 720)
        #expect(FloatingBarMetrics.barWidth(fullAddress: true, visibleWidth: 3_000) == 860)
        #expect(FloatingBarMetrics.barWidth(fullAddress: true, visibleWidth: 500) == 500 - 2 * FloatingBarMetrics.shadowInset)
    }
}
