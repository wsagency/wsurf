// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CefKit
import Foundation

/// How a DevTools connection hears its browser when the browser is in the Chromium service (`attach(remote:)`): the service forwards
/// what CEF's observer would have been called with, and this hands it to the same code the observer's callbacks reach in process.
extension ChromiumDevTools {
    /// What this connection has spent on protocol traffic, as counters: the page's session counts for the frame sessions under it.
    /// They cost an addition per event; tests and the Chromium load benchmark read them.
    struct LoadStatistics: Equatable {
        /// Events CEF handed to the page's session.
        var eventsReceived = 0
        /// Of those, the ones whose parameters were parsed as JSON.
        var eventsParsed = 0
        /// Messages of a cross-site frame session, which are always parsed whole.
        var sessionMessagesParsed = 0
        /// Cross-site frames held until their session had registered its scripts: how many, the sum and the longest hold
        /// (from the frame's attach to the answer of the command that lets it run).
        var framePauses = 0
        var framePauseTotal: Duration = .zero
        var framePauseMax: Duration = .zero
    }

    /// One DevTools message from the service, with its bytes still in the message.
    func receiveRemote(_ message: CefRemoteMessage) {
        guard !closed else { return }
        switch message.op {
        case CefRemote.Event.devToolsMessage:
            message.withBytes(CefRemote.Key.data) { pointer, size in
                guard let pointer else { return }
                _ = receiveSessionMessage(pointer, size: size)
            }
        case CefRemote.Event.devToolsResult:
            let id = Int(clamping: message.int(CefRemote.Key.identifier))
            let success = message.bool(CefRemote.Key.success)
            message.withBytes(CefRemote.Key.data) { pointer, size in
                receiveResult(id: id, success: success, pointer: pointer, size: size)
            }
        case CefRemote.Event.devToolsEvent:
            let name = message.string(CefRemote.Key.method)
            message.withBytes(CefRemote.Key.data) { pointer, size in
                receiveEvent(name: name, pointer: pointer, size: size)
            }
        case CefRemote.Event.devToolsDetached:
            failAll(ChromiumError.unavailable("Chromium DevTools detached."))
            forgetDocuments()
            page?.owner?.invalidateCredentialContexts()
        default:
            break
        }
    }
}
