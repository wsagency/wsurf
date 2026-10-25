// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

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

extension BrowserSettings {
    /// The whole page address in the address bar instead of the website name. App-wide, off by default.
    var showsFullAddress: Bool {
        get { globalValue(\.showsFullAddress, storage: storedShowsFullAddress) }
        set {
            setGlobal(\BrowserSettings.showsFullAddress, storage: \BrowserSettings.storedShowsFullAddress,
                      value: newValue, key: Key.fullAddress)
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

    /// The Minimal bar slides away while the page scrolls down and comes back when it scrolls up. On by default: the bar
    /// floats over the end of the page, which could not be read otherwise.
    var hidesMinimalBar: Bool {
        get { globalValue(\.hidesMinimalBar, storage: storedHidesMinimalBar) }
        set {
            setGlobal(\BrowserSettings.hidesMinimalBar, storage: \BrowserSettings.storedHidesMinimalBar,
                      value: newValue, key: Key.minimalBarAutoHide)
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

    func resetWindowStyle() {
        showsFullAddress = false
        windowStyle = .standard
        minimalBarEdge = .bottom
        hidesMinimalBar = true
        keepsMinimalSidebarOpen = false
    }
}
