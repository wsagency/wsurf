// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit
import Foundation
import WebKit

struct ExtensionPageHost {
    let configuration: WKWebViewConfiguration
    let baseURL: URL
    let name: String
    let icon: NSImage?
}

enum PageSecurity: Equatable {
    case secure
    case pending
    case mixed
    case insecure
    case none
}
