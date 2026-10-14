// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation

/// Pure validation and profile data for the MCP development viewport. No native state lives here.
nonisolated enum PageViewport {
    static let minAxis = 64
    static let maxAxis = 4_096
    static let maxCSSArea = 8_388_608
    static let maxBackingArea = 33_554_432.0

    enum Axis: Equatable { case width, height }

    enum Failure: Error, Equatable {
        case axisOutOfRange(Axis, Int)
        case areaTooLarge
        case backingTooLarge
        case invalidScale

        var message: String {
            switch self {
            case .axisOutOfRange(let axis, let value):
                "The viewport \(axis == .width ? "width" : "height") \(value) must be between \(PageViewport.minAxis) and \(PageViewport.maxAxis) CSS pixels."
            case .areaTooLarge: "The viewport may cover at most \(PageViewport.maxCSSArea) CSS pixels."
            case .backingTooLarge: "The viewport would need more than \(Int(PageViewport.maxBackingArea)) backing pixels at the current zoom and scale."
            case .invalidScale: "The page zoom or device scale is not a positive finite number."
            }
        }
    }

    struct Request: Equatable {
        let width: Int
        let height: Int
    }

    enum Orientation: String { case portrait, landscape }

    struct Profile: Equatable {
        let name: String
        /// Short and long CSS axes; portrait is (short, long), landscape (long, short).
        let short: Int
        let long: Int
        /// Device pixel ratio the profile requires; 1 for viewport-only profiles.
        let scale: Double
        /// True when DPR, touch and mobile-viewport behavior must all be supported by the engine.
        let deviceAxes: Bool

        var requiredAxes: [String] { deviceAxes ? ["viewport", "dpr", "touch", "mobile"] : ["viewport"] }

        func dimensions(_ orientation: Orientation) -> Request {
            orientation == .portrait ? Request(width: short, height: long) : Request(width: long, height: short)
        }
    }

    static let profiles: [Profile] = [
        Profile(name: "responsive-phone", short: 390, long: 844, scale: 1, deviceAxes: false),
        Profile(name: "responsive-tablet", short: 768, long: 1_024, scale: 1, deviceAxes: false),
        Profile(name: "responsive-desktop", short: 800, long: 1_280, scale: 1, deviceAxes: false),
        Profile(name: "phone", short: 390, long: 844, scale: 3, deviceAxes: true),
        Profile(name: "tablet", short: 768, long: 1_024, scale: 2, deviceAxes: true),
    ]

    static func profile(named name: String) -> Profile? { profiles.first { $0.name == name } }

    /// Checks every ceiling before anything is applied: per-axis range, CSS area, then estimated backing pixels
    /// (`width × height × (zoom × scale)²`).
    static func validate(width: Int, height: Int, zoom: Double, scale: Double) -> Result<Request, Failure> {
        guard zoom.isFinite, zoom > 0, scale.isFinite, scale > 0 else { return .failure(.invalidScale) }
        for (axis, value) in [(Axis.width, width), (.height, height)] where !(minAxis...maxAxis).contains(value) {
            return .failure(.axisOutOfRange(axis, value))
        }
        guard width * height <= maxCSSArea else { return .failure(.areaTooLarge) }
        let factor = zoom * scale
        guard Double(width) * Double(height) * factor * factor <= maxBackingArea else { return .failure(.backingTooLarge) }
        return .success(Request(width: width, height: height))
    }

    static func request(_ profile: Profile, orientation: Orientation, zoom: Double) -> Result<Request, Failure> {
        let size = profile.dimensions(orientation)
        return validate(width: size.width, height: size.height, zoom: zoom, scale: profile.scale)
    }
}
