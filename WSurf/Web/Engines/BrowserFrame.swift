// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import WebKit

nonisolated struct BrowserSecurityOrigin: Equatable, Sendable {
    let `protocol`: String
    let host: String
    let port: Int

    init(protocol: String, host: String, port: Int) {
        self.protocol = `protocol`.lowercased()
        self.host = host.lowercased()
        self.port = port
    }

    init(url: URL) {
        self.init(protocol: url.scheme ?? "", host: url.host() ?? "", port: url.port ?? 0)
    }
}

@MainActor
final class BrowserFrame {
    let webKit: WKFrameInfo?
    let chromiumID: String?
    let documentID: String
    let isMainFrame: Bool
    let request: URLRequest
    let chromiumParentID: String?
    let securityOrigin: BrowserSecurityOrigin
    let hasTrustedSecurityOrigin: Bool

    init(webKit: WKFrameInfo, documentID: String = "") {
        self.webKit = webKit
        chromiumID = nil
        chromiumParentID = nil
        self.documentID = documentID
        isMainFrame = webKit.isMainFrame
        request = webKit.request
        securityOrigin = BrowserSecurityOrigin(
            protocol: webKit.securityOrigin.protocol,
            host: webKit.securityOrigin.host,
            port: webKit.securityOrigin.port
        )
        hasTrustedSecurityOrigin = ["http", "https"].contains(webKit.securityOrigin.protocol.lowercased())
            && !webKit.securityOrigin.host.isEmpty
    }

    init(
        id: String,
        documentID: String,
        url: URL,
        isMainFrame: Bool,
        securityOrigin: BrowserSecurityOrigin,
        parentID: String? = nil,
        hasTrustedSecurityOrigin: Bool = true
    ) {
        webKit = nil
        chromiumID = id
        chromiumParentID = parentID
        self.documentID = documentID
        self.isMainFrame = isMainFrame
        request = URLRequest(url: url)
        self.securityOrigin = securityOrigin
        self.hasTrustedSecurityOrigin = hasTrustedSecurityOrigin
    }
}

@MainActor
struct BrowserScriptMessage {
    let page: BrowserPage
    let body: Any
    let frameInfo: BrowserFrame
    let name: String
}
