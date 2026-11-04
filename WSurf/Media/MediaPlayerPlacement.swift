// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CoreGraphics
import Foundation

/// Where the player rests. Bottom left is where it has always been, docked at the foot of the sidebar; the other three
/// corners float over the page.
nonisolated enum MediaPlayerCorner: String, CaseIterable, Sendable {
    case topLeft
    case topRight
    case bottomLeft
    case bottomRight

    static let dock: MediaPlayerCorner = .bottomLeft

    var title: LocalizedStringResource {
        switch self {
        case .topLeft:
            "Top Left"
        case .topRight:
            "Top Right"
        case .bottomLeft:
            "Bottom Left"
        case .bottomRight:
            "Bottom Right"
        }
    }

    /// The name of the VoiceOver action that moves the player here.
    var moveTitle: LocalizedStringResource {
        switch self {
        case .topLeft:
            "Move Player to Top Left"
        case .topRight:
            "Move Player to Top Right"
        case .bottomLeft:
            "Move Player to Bottom Left"
        case .bottomRight:
            "Move Player to Bottom Right"
        }
    }
}

/// The arithmetic behind dragging the player: where each corner is, how far it may go, and which corner a drop lands in.
/// Every rectangle shares one coordinate space, the window's.
nonisolated enum MediaPlayerPlacement {
    /// The gap between the player and the page edge it rests against. The page already keeps its own spacing from the
    /// sidebar, the side panel and the window, so the player never covers them.
    static let margin: CGFloat = 12

    /// Where the top left of a card of `size` rests in `corner` of `page`, never outside `window`. A page too small for
    /// the card puts it against the page's left and top, and a window too small for it against the window's.
    static func origin(
        of corner: MediaPlayerCorner,
        size: CGSize,
        page: CGRect,
        window: CGRect,
        margin: CGFloat = MediaPlayerPlacement.margin
    ) -> CGPoint {
        let left = page.minX + margin
        let right = max(left, page.maxX - margin - size.width)
        let top = page.minY + margin
        let bottom = max(top, page.maxY - margin - size.height)
        let resting: CGPoint
        switch corner {
        case .topLeft:
            resting = CGPoint(x: left, y: top)
        case .topRight:
            resting = CGPoint(x: right, y: top)
        case .bottomLeft:
            resting = CGPoint(x: left, y: bottom)
        case .bottomRight:
            resting = CGPoint(x: right, y: bottom)
        }
        return clamped(resting, size: size, within: window)
    }

    /// `origin` pulled back so that a card of `size` lies inside `bounds`. A card larger than `bounds` keeps its top left.
    static func clamped(_ origin: CGPoint, size: CGSize, within bounds: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(origin.x, bounds.minX), max(bounds.minX, bounds.maxX - size.width)),
            y: min(max(origin.y, bounds.minY), max(bounds.minY, bounds.maxY - size.height))
        )
    }

    /// The corner whose resting origin lies nearest `origin`. `resting` says where each corner is, because the dock does
    /// not sit in a corner of the page.
    static func nearestCorner(to origin: CGPoint, resting: (MediaPlayerCorner) -> CGPoint) -> MediaPlayerCorner {
        func gap(_ corner: MediaPlayerCorner) -> CGFloat {
            let rest = resting(corner)
            return (rest.x - origin.x) * (rest.x - origin.x) + (rest.y - origin.y) * (rest.y - origin.y)
        }
        return MediaPlayerCorner.allCases.min { gap($0) < gap($1) } ?? .dock
    }
}
