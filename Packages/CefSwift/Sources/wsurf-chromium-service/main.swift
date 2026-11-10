// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

// Entry point of `WSurf Chromium.xpc`, the out-of-process Chromium service (WSURF-PATCHES.md, patch 3). launchd starts it on
// WSurf's first message. This is the D4-2 stub: it does not start CEF yet. It answers `{op: "ping"}` with its pid, in plain XPC
// keys, so the bundle layout, the launch and the TCC attribution can be tested before any protocol exists.
//
// CEF needs its NSApplication subclass before anything touches NSApp. The service never runs NSApp's event loop: the main
// thread runs the NSRunLoop that `XPCService.RunLoopType` asks xpc_main for.

import AppKit
import CCefAppKit
import XPC

CEFApplication.install()
// No Dock tile, no menu bar, never active: the service is not an app the person sees.
NSApp.setActivationPolicy(.prohibited)

xpc_main { peer in
    xpc_connection_set_event_handler(peer) { event in
        // Errors (an interrupted or closed peer) need no answer, and anything but a dictionary is not ours.
        guard xpc_get_type(event) == XPC_TYPE_DICTIONARY, let reply = xpc_dictionary_create_reply(event) else { return }
        guard let op = xpc_dictionary_get_string(event, "op"), String(cString: op) == "ping" else {
            xpc_dictionary_set_string(reply, "error", "unknown op")
            xpc_connection_send_message(peer, reply)
            return
        }
        xpc_dictionary_set_string(reply, "op", "ping")
        xpc_dictionary_set_int64(reply, "pid", Int64(getpid()))
        xpc_connection_send_message(peer, reply)
    }
    xpc_connection_activate(peer)
}
