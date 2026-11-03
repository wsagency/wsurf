// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import Foundation

/// How a browser window is laid out. Standard has the sidebar and the toolbar; Minimal gives the page the window, with a
/// floating bar and a tab list that slides in.
nonisolated enum BrowserWindowStyle: String, CaseIterable, Identifiable {
    case standard
    case minimal

    var id: String {
        rawValue
    }

    var label: LocalizedStringResource {
        switch self {
        case .standard:
            "Standard"
        case .minimal:
            "Minimal"
        }
    }

    /// Only the Standard sidebar can narrow to icons; the Minimal tab list always shows each tab's title.
    var offersIconsOnlySidebar: Bool {
        self == .standard
    }

    var caption: LocalizedStringResource {
        switch self {
        case .standard:
            "A sidebar for tabs and a toolbar above the page."
        case .minimal:
            "The page fills the window, with a floating bar."
        }
    }
}

/// The window edge the Minimal bar floats at.
nonisolated enum MinimalBarEdge: String, CaseIterable, Identifiable {
    case bottom
    case top

    var id: String {
        rawValue
    }

    var label: LocalizedStringResource {
        switch self {
        case .bottom:
            "Bottom"
        case .top:
            "Top"
        }
    }
}

/// When the Minimal bar floats out of the way. The bar floats over the end of the page, which could not be read otherwise, so
/// the choice stays While scrolling unless the person picks another.
nonisolated enum MinimalBarHiding: String, CaseIterable, Identifiable {
    case never
    case whileScrolling
    case fiveSeconds
    case tenSeconds
    case thirtySeconds

    var id: String {
        rawValue
    }

    var label: LocalizedStringResource {
        switch self {
        case .never:
            LocalizedStringResource("settings.minimalBarHide.never", defaultValue: "Never")
        case .whileScrolling:
            LocalizedStringResource("settings.minimalBarHide.whileScrolling", defaultValue: "While scrolling")
        case .fiveSeconds:
            LocalizedStringResource("settings.minimalBarHide.fiveSeconds", defaultValue: "After 5 seconds")
        case .tenSeconds:
            LocalizedStringResource("settings.minimalBarHide.tenSeconds", defaultValue: "After 10 seconds")
        case .thirtySeconds:
            LocalizedStringResource("settings.minimalBarHide.thirtySeconds", defaultValue: "After 30 seconds")
        }
    }

    /// How long the bar rests unused before it goes; nil for the two choices that do not time it.
    var interval: Duration? {
        switch self {
        case .never, .whileScrolling:
            nil
        case .fiveSeconds:
            .seconds(5)
        case .tenSeconds:
            .seconds(10)
        case .thirtySeconds:
            .seconds(30)
        }
    }

    /// The stored choice. Until 0.1.16 the key held a Bool: on was While scrolling, off was Never. A value this build cannot
    /// read, or none, is While scrolling.
    init(stored: Any?) {
        if let name = stored as? String, let choice = Self(rawValue: name) {
            self = choice
        } else if let hides = stored as? Bool {
            self = hides ? .whileScrolling : .never
        } else {
            self = .whileScrolling
        }
    }
}

/// The 1 pt line WSurf draws along the edge of the window, over the outline macOS draws with the shadow. Subtle and Accent
/// follow the theme in light and dark mode; Custom is one colour for both.
nonisolated enum WindowBorder: String, CaseIterable, Identifiable {
    case none
    case subtle
    case accent
    case custom

    var id: String {
        rawValue
    }

    var label: LocalizedStringResource {
        switch self {
        case .none:
            LocalizedStringResource("settings.windowBorder.none", defaultValue: "None")
        case .subtle:
            LocalizedStringResource("settings.windowBorder.subtle", defaultValue: "Subtle")
        case .accent:
            LocalizedStringResource("settings.windowBorder.accent", defaultValue: "Accent")
        case .custom:
            LocalizedStringResource("settings.windowBorder.custom", defaultValue: "Custom")
        }
    }

    /// Where Custom starts: the lead violet of the WSurf mark.
    static let defaultColor: UInt32 = 0x6D55FF

    /// The stored Custom colour as `0xRRGGBB`. A value that is not a colour, or none, is `defaultColor`.
    static func storedColor(_ stored: Any?) -> UInt32 {
        guard let value = stored as? Int, (0...0xFFFFFF).contains(value) else { return defaultColor }
        return UInt32(value)
    }

    /// The line the window draws. A full-screen window has no edge. With Increase Contrast on, a window whose shadow is off
    /// and whose border is None would have none either, so it gets Subtle, as the page does (`ThemeShape.pageFrame`).
    func drawn(shadow: Bool, increaseContrast: Bool, isFullScreen: Bool) -> WindowBorder {
        if isFullScreen {
            return .none
        }
        return increaseContrast && !shadow && self == .none ? .subtle : self
    }
}

extension BrowserSettings {
    /// The whole page address in the address bar instead of the website name. App-wide, off by default.
    var showsFullAddress: Bool {
        get { globalValue(\.showsFullAddress, storage: storedShowsFullAddress) }
        set {
            setGlobal(\BrowserSettings.showsFullAddress, storage: \BrowserSettings.storedShowsFullAddress,
                      value: newValue, key: Key.fullAddress)
        }
    }

    /// A mouse's side buttons (3 and 4) go Back and Forward anywhere in a browsing window, in both engines. App-wide, on by
    /// default; off leaves the buttons to the website (`BrowserWindow.sendEvent`). Software that maps them to ⌘[ or to a
    /// swipe sends that instead of the button, so WSurf goes back once either way.
    var sideButtonsNavigate: Bool {
        get { globalValue(\.sideButtonsNavigate, storage: storedSideButtonsNavigate) }
        set {
            setGlobal(\BrowserSettings.sideButtonsNavigate, storage: \BrowserSettings.storedSideButtonsNavigate,
                      value: newValue, key: Key.mouseSideButtons)
        }
    }

    /// App-wide: every window follows it. Standard unless the person picks Minimal.
    var windowStyle: BrowserWindowStyle {
        get { globalValue(\.windowStyle, storage: storedWindowStyle) }
        set {
            setGlobal(\BrowserSettings.windowStyle, storage: \BrowserSettings.storedWindowStyle,
                      value: newValue, key: Key.windowStyle, encode: { $0.rawValue })
        }
    }

    var minimalBarEdge: MinimalBarEdge {
        get { globalValue(\.minimalBarEdge, storage: storedMinimalBarEdge) }
        set {
            setGlobal(\BrowserSettings.minimalBarEdge, storage: \BrowserSettings.storedMinimalBarEdge,
                      value: newValue, key: Key.minimalBarEdge, encode: { $0.rawValue })
        }
    }

    /// When the Minimal bar slides away: never, while the page scrolls down (the default, so the end of the page can be read),
    /// or once it has gone unused for a few seconds. The pointer at the bar's edge brings it back under each choice.
    var minimalBarHiding: MinimalBarHiding {
        get { globalValue(\.minimalBarHiding, storage: storedMinimalBarHiding) }
        set {
            setGlobal(\BrowserSettings.minimalBarHiding, storage: \BrowserSettings.storedMinimalBarHiding,
                      value: newValue, key: Key.minimalBarAutoHide, encode: { $0.rawValue })
        }
    }

    /// The Minimal window's tab list stays docked open beside the page instead of sliding in over it. App-wide like the
    /// window style, off by default; it changes nothing outside the Minimal window.
    var keepsMinimalSidebarOpen: Bool {
        get { globalValue(\.keepsMinimalSidebarOpen, storage: storedKeepsMinimalSidebarOpen) }
        set {
            setGlobal(\BrowserSettings.keepsMinimalSidebarOpen, storage: \BrowserSettings.storedKeepsMinimalSidebarOpen,
                      value: newValue, key: Key.minimalSidebarPinned)
        }
    }

    /// The drop shadow of every window, and the thin outline macOS draws with it: off gives a flat window with no outline.
    /// App-wide, on by default.
    var windowShadow: Bool {
        get { globalValue(\.windowShadow, storage: storedWindowShadow) }
        set {
            setGlobal(\BrowserSettings.windowShadow, storage: \BrowserSettings.storedWindowShadow,
                      value: newValue, key: Key.windowShadow)
        }
    }

    /// The line WSurf draws around every window. App-wide, None by default.
    var windowBorder: WindowBorder {
        get { globalValue(\.windowBorder, storage: storedWindowBorder) }
        set {
            setGlobal(\BrowserSettings.windowBorder, storage: \BrowserSettings.storedWindowBorder,
                      value: newValue, key: Key.windowBorder, encode: { $0.rawValue })
        }
    }

    /// The colour of the Custom border as `0xRRGGBB`, one for light and dark.
    var windowBorderColor: UInt32 {
        get { globalValue(\.windowBorderColor, storage: storedWindowBorderColor) }
        set {
            setGlobal(\BrowserSettings.windowBorderColor, storage: \BrowserSettings.storedWindowBorderColor,
                      value: newValue & 0xFFFFFF, key: Key.windowBorderColor, encode: { Int($0) })
        }
    }

    func resetWindowStyle() {
        showsFullAddress = false
        windowStyle = .standard
        minimalBarEdge = .bottom
        minimalBarHiding = .whileScrolling
        keepsMinimalSidebarOpen = false
        windowShadow = true
        windowBorder = .none
        windowBorderColor = WindowBorder.defaultColor
    }
}
