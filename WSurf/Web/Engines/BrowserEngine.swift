// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import WebKit

nonisolated enum BrowserEngine: String, Codable, CaseIterable, Sendable {
    case webKit = "webkit"
    case chromium

    var label: LocalizedStringResource {
        switch self {
        case .webKit:
            "WebKit"
        case .chromium:
            "Chromium"
        }
    }
}

@MainActor
final class PageNavigation {
    let id = UUID()
    let webKit: WKNavigation?
    var authorization: (@MainActor () -> Bool)?

    init(webKit: WKNavigation? = nil, authorization: (@MainActor () -> Bool)? = nil) {
        self.webKit = webKit
        self.authorization = authorization
    }
}

@MainActor
final class PageHistoryItem {
    let url: URL
    let initialURL: URL
    let title: String?
    let webKit: WKBackForwardListItem?
    let chromiumIndex: Int?
    /// A Chromium entry WSurf restored itself (`ChromiumHistoryRecord`), which Chromium does not hold: going to it loads its address.
    let restoredID: Int?

    init(webKit: WKBackForwardListItem) {
        url = webKit.url
        initialURL = webKit.initialURL
        title = webKit.title
        self.webKit = webKit
        chromiumIndex = nil
        restoredID = nil
    }

    init(url: URL, title: String?, chromiumIndex: Int? = nil, restoredID: Int? = nil) {
        self.url = url
        initialURL = url
        self.title = title
        webKit = nil
        self.chromiumIndex = chromiumIndex
        self.restoredID = restoredID
    }
}

@MainActor
struct PageHistoryList {
    var backList: [PageHistoryItem] = []
    var forwardList: [PageHistoryItem] = []
    var currentItem: PageHistoryItem?
}
