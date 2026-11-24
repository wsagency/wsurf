// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CefKit
import Foundation

/// Temporary diagnostic trace (draft PR only, never merged): the ordered navigation callbacks of a page, sent to
/// `diagnosticEventSink` when a test sets it. Nil in the app, so nothing is built. Addresses appear only as `scheme:path`.
extension ChromiumPage {
    static func tracePath(_ url: URL?) -> String {
        guard let url else { return "-" }
        let scheme = url.scheme ?? "?"
        return scheme == "data" ? "data:" : "\(scheme):\(url.path)"
    }

    static func tracePath(_ string: String) -> String {
        tracePath(URL(string: string))
    }

    static func traceID(_ navigation: PageNavigation?) -> String {
        navigation.map { String((UInt(bitPattern: ObjectIdentifier($0).hashValue) >> 4) & 0xFFFF, radix: 16) } ?? "nil"
    }

    static func traceList(_ list: [CefRemote.HistoryEntry]) -> String {
        "[" + list.map { "\($0.id)\($0.isCurrent ? "*" : ""):\(tracePath($0.url))" }.joined(separator: ",") + "]"
    }

    static func traceChange(_ change: ChromiumHistoryRecord.Change) -> String {
        switch change {
        case .unchanged:
            "unchanged"
        case .forwardDropped:
            "forwardDropped"
        case let .collapse(keeping, count):
            "collapse(\(tracePath(keeping)), \(count))"
        }
    }

    var traceState: String {
        "await=\(awaitingNativeNavigation) started=\(navigationStarted) nav=\(Self.traceID(navigation)) moved=\(historyRecord.hopHasMoved)"
    }

    func trace(_ event: @autoclosure () -> String) {
        diagnosticEventSink?(event())
    }
}
