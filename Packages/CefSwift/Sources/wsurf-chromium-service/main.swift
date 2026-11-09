// D4 spike: entry point of `WSurf Chromium.xpc`, the out-of-process Chromium service. launchd starts it on WSurf's first
// message. CEF needs its NSApplication subclass before anything touches NSApp; the service never runs NSApp's event loop:
// windowless browsers take input through CEF's API, and the main thread runs the NSRunLoop that `XPCService.RunLoopType`
// asks xpc_main for, which also drives CEF's external message pump.

import AppKit
import CCefAppKit
import CefKit
import XPC

// The owner's keychain check (option b), run from Terminal with `--d4-keychain read`; returns at once otherwise.
D4KeychainProbe.runIfRequested(identity: "WSurf Chromium")
CEFApplication.install()
// No Dock tile, no menu bar, never active: the service is not an app the person sees.
NSApp.setActivationPolicy(.prohibited)
note("service launched: pid \(getpid()), parent \(getppid())")
xpc_main { connection in
    ServiceHost.accept(connection)
}
