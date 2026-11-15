// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import CefKit
import CoreGraphics
import Foundation
import IOSurface
import os
@preconcurrency import XPC

// The frames connection and the side hellos of `ChromiumRemote` (the input and frames connections' hello), split out of
// `ChromiumRemote.swift` to keep it under the file-length limit. The connections themselves are state of `ChromiumRemote`.

extension ChromiumRemote {
    // MARK: Frames

    func openFrames() {
        guard frames == nil else { return }
        let connection = Self.makeFramesConnection(serviceName: serviceName, sink: sink)
        frames = connection
        sendSideHello(CefRemote.Op.framesHello, on: connection)
    }

    /// The hello of an input or frames connection, sent with a reply: the service refuses it unless it is from the host's process
    /// and after a hello that got `ok` (review F8b). A refused connection is not attached whatever the client believes, so it is
    /// dropped (`hasFramesConnection` goes false) and made again after the next successful hello (frames) or the next send (input).
    func sendSideHello(_ op: String, on connection: xpc_connection_t) {
        let current = generation
        // The handler is Sendable and the connection is not: its identity crosses, not the object.
        let identity = ObjectIdentifier(connection)
        xpc_connection_send_message_with_reply(connection, CefRemoteMessage(op).object, DispatchQueue.main) { [weak self] answer in
            // An error object (the connection ended) is the control connection's business (`serviceEnded`), as for the hello.
            guard let reply = CefRemoteMessage(wrapping: answer), !reply.bool(CefRemote.Key.success) else { return }
            MainActor.assumeIsolated { self?.sideHelloRefused(op, connection: identity, generation: current) }
        }
    }

    /// Only the connection that was refused is dropped: one made since (after a drop or a relaunch) is another one's.
    func sideHelloRefused(_ op: String, connection refused: ObjectIdentifier, generation sentGeneration: Int) {
        guard sentGeneration == generation else { return }
        if let frames, ObjectIdentifier(frames) == refused {
            xpc_connection_cancel(frames)
            self.frames = nil
        } else if let input, ObjectIdentifier(input) == refused {
            xpc_connection_cancel(input)
            self.input = nil
        } else {
            return
        }
        sideRefusals += 1
        ChromiumOOP.log.error("\(op, privacy: .public) refused by the service: the connection is dropped")
    }

    /// The frames connection, which delivers on the sink's queue. Built outside the main actor on purpose: a handler made in a
    /// main-actor method could be treated as main-actor code, and its executor check would trap when it runs on the frames queue
    /// (every cancel delivers an invalidation there).
    nonisolated private static func makeFramesConnection(serviceName: String, sink: ChromiumFrameSink) -> xpc_connection_t {
        let connection = xpc_connection_create(serviceName, sink.framesQueue)
        xpc_connection_set_event_handler(connection) { event in
            deliverFrame(event, to: sink)
        }
        xpc_connection_activate(connection)
        return connection
    }

    /// On the frames queue: decodes a frame or a popup event and hands it to the sink. Anything else is ignored.
    nonisolated static func deliverFrame(_ event: xpc_object_t, to sink: ChromiumFrameSink) {
        guard let message = CefRemoteMessage(wrapping: event) else { return }
        switch message.op {
        case CefRemote.Event.frame:
            guard let object = xpc_dictionary_get_value(event, CefRemote.Key.surface),
                  let surface = IOSurfaceLookupFromXPCObject(object)
            else { return }
            sink.apply(surface: surface, browser: message.browser, popup: message.bool(CefRemote.Key.flag))
        case CefRemote.Event.popup:
            // The popup's rectangle is in view points, top-left origin (D4-7 sends it with these keys).
            let rect = CGRect(
                x: message.double(CefRemote.Key.originX), y: message.double(CefRemote.Key.originY),
                width: message.double(CefRemote.Key.width), height: message.double(CefRemote.Key.height)
            )
            sink.applyPopup(browser: message.browser, visible: message.bool(CefRemote.Key.flag), rect: rect)
        default:
            return
        }
    }
}
