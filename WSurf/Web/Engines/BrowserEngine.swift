// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

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

    init(webKit: WKNavigation? = nil) {
        self.webKit = webKit
    }
}

@MainActor
final class PageHistoryItem {
    let url: URL
    let initialURL: URL
    let title: String?
    let webKit: WKBackForwardListItem?
    let chromiumIndex: Int?

    init(webKit: WKBackForwardListItem) {
        url = webKit.url
        initialURL = webKit.initialURL
        title = webKit.title
        self.webKit = webKit
        chromiumIndex = nil
    }

    init(url: URL, title: String?, chromiumIndex: Int) {
        self.url = url
        initialURL = url
        self.title = title
        webKit = nil
        self.chromiumIndex = chromiumIndex
    }
}

@MainActor
struct PageHistoryList {
    var backList: [PageHistoryItem] = []
    var forwardList: [PageHistoryItem] = []
    var currentItem: PageHistoryItem?
}
