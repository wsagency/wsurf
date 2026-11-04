// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CoreGraphics
import Foundation
import Testing

@testable import WSurf

/// Dragging the player: where each corner is, where a drop lands, and that the card never leaves the window.
struct MediaPlayerPlacementTests {
    private let window = CGRect(x: 0, y: 0, width: 1000, height: 600)
    /// The page beside a 268 pt sidebar and under a 44 pt top bar, 6 pt in from the window's other edges.
    private let page = CGRect(x: 280, y: 44, width: 700, height: 500)
    private let card = CGSize(width: 300, height: 150)
    private let margin = MediaPlayerPlacement.margin

    private func origin(_ corner: MediaPlayerCorner, page: CGRect? = nil, window: CGRect? = nil) -> CGPoint {
        MediaPlayerPlacement.origin(of: corner, size: card, page: page ?? self.page, window: window ?? self.window)
    }

    // MARK: - Corners

    @Test func eachCornerRestsOneMarginInFromTheEdgesOfThePage() {
        #expect(origin(.topLeft) == CGPoint(x: page.minX + margin, y: page.minY + margin))
        #expect(origin(.topRight) == CGPoint(x: page.maxX - margin - card.width, y: page.minY + margin))
        #expect(origin(.bottomLeft) == CGPoint(x: page.minX + margin, y: page.maxY - margin - card.height))
        #expect(origin(.bottomRight) == CGPoint(x: page.maxX - margin - card.width, y: page.maxY - margin - card.height))
    }

    @Test func theLeftCornersSitBesideTheSidebarNotOverIt() {
        let besideTheSidebar = page.minX
        #expect(origin(.topLeft).x >= besideTheSidebar)
        #expect(origin(.bottomLeft).x >= besideTheSidebar)
        let sidebarHidden = CGRect(x: 6, y: 44, width: 974, height: 500)
        #expect(origin(.topLeft, page: sidebarHidden).x == 6 + margin)
    }

    // MARK: - Staying inside the window

    @Test func aCardThatFitsIsLeftWhereItIs() {
        #expect(MediaPlayerPlacement.clamped(CGPoint(x: 400, y: 300), size: card, within: window) == CGPoint(x: 400, y: 300))
    }

    @Test func aCardPulledPastAnEdgeIsPulledBack() {
        #expect(MediaPlayerPlacement.clamped(CGPoint(x: 900, y: 590), size: card, within: window) == CGPoint(x: 700, y: 450))
        #expect(MediaPlayerPlacement.clamped(CGPoint(x: -40, y: -5), size: card, within: window) == .zero)
    }

    @Test func aWindowTooSmallForTheCardKeepsItsTopLeft() {
        let small = CGRect(x: 0, y: 0, width: 200, height: 100)
        #expect(MediaPlayerPlacement.clamped(CGPoint(x: 50, y: 80), size: card, within: small) == .zero)
    }

    @Test func everyCornerStaysInsideAWindowAsItShrinks() {
        let sizes = [
            CGSize(width: 1000, height: 600), CGSize(width: 500, height: 400),
            CGSize(width: 340, height: 200), CGSize(width: 200, height: 100),
        ]
        for size in sizes {
            let shrunk = CGRect(origin: .zero, size: size)
            let shrunkPage = CGRect(x: 6, y: 44, width: max(0, size.width - 12), height: max(0, size.height - 50))
            for corner in MediaPlayerCorner.allCases {
                let at = origin(corner, page: shrunkPage, window: shrunk)
                #expect(at.x >= shrunk.minX && at.y >= shrunk.minY, "\(corner) in \(size)")
                #expect(at.x + card.width <= shrunk.maxX || at.x == shrunk.minX, "\(corner) in \(size)")
                #expect(at.y + card.height <= shrunk.maxY || at.y == shrunk.minY, "\(corner) in \(size)")
            }
        }
    }

    @Test func aCornerFollowsThePageWhenTheWindowGrows() {
        let wider = CGRect(x: 0, y: 0, width: 1400, height: 600)
        let widerPage = CGRect(x: 280, y: 44, width: 1100, height: 500)
        #expect(origin(.topRight, page: widerPage, window: wider).x == widerPage.maxX - margin - card.width)
        #expect(origin(.topRight, page: widerPage, window: wider).x > origin(.topRight).x)
    }

    // MARK: - Dropping

    private func landing(at point: CGPoint, dock: CGPoint? = nil) -> MediaPlayerCorner {
        MediaPlayerPlacement.nearestCorner(to: point) { corner in
            if corner == .dock, let dock {
                return dock
            }
            return origin(corner)
        }
    }

    @Test func aDropLandsInTheNearestCorner() {
        #expect(landing(at: CGPoint(x: 300, y: 60)) == .topLeft)
        #expect(landing(at: CGPoint(x: 640, y: 80)) == .topRight)
        #expect(landing(at: CGPoint(x: 320, y: 400)) == .bottomLeft)
        #expect(landing(at: CGPoint(x: 600, y: 350)) == .bottomRight)
    }

    @Test func aDropExactlyOnACornerKeepsIt() {
        for corner in MediaPlayerCorner.allCases {
            #expect(landing(at: origin(corner)) == corner)
        }
    }

    @Test func theDockCountsWhereTheSidebarPutsIt() {
        let dock = CGPoint(x: 12, y: 440)
        #expect(landing(at: CGPoint(x: 250, y: 400), dock: dock) == .bottomLeft)
        #expect(landing(at: CGPoint(x: 500, y: 380), dock: dock) == .bottomRight)
        #expect(landing(at: CGPoint(x: 520, y: 70), dock: dock) == .topRight)
    }
}

@MainActor
struct MediaPlayerCornerSettingsTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: AppDatabase.defaultsSuite("MediaPlayerCornerTests-\(UUID().uuidString)"))!
    }

    @Test func thePlayerStartsDockedAtTheBottomLeft() {
        #expect(BrowserSettings(defaults: makeDefaults()).mediaPlayerCorner == .bottomLeft)
    }

    @Test func theCornerIsRememberedAcrossLaunches() {
        let defaults = makeDefaults()

        BrowserSettings(defaults: defaults).mediaPlayerCorner = .topRight

        #expect(BrowserSettings(defaults: defaults).mediaPlayerCorner == .topRight)
    }

    @Test func theLastCornerWins() {
        let defaults = makeDefaults()
        let settings = BrowserSettings(defaults: defaults)

        settings.mediaPlayerCorner = .topLeft
        settings.mediaPlayerCorner = .bottomRight

        #expect(BrowserSettings(defaults: defaults).mediaPlayerCorner == .bottomRight)
    }

    @Test func aCornerNobodyKnowsFallsBackToTheDock() {
        let defaults = makeDefaults()
        defaults.set("middle", forKey: BrowserSettings.Key.mediaPlayerCorner)

        #expect(BrowserSettings(defaults: defaults).mediaPlayerCorner == .dock)
    }
}
