// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

// D4-20: the one table of the service's debug ops and debug creation flags. The file exists only in a service built with the
// DEBUG ops (Package.swift's WSURF_SERVICE_DEBUG_OPS, which Tools/embed-chromium.sh allows for the OOP lane and staged DEBUG ad
// hoc builds only).
//
// Why a table of texts. `Tools/check-service-strings.sh` proves a service has none of the ops by looking for text in its file. A
// wire name is no proof: the name `debug.stats` (11 bytes) is a Swift "small string", which the compiler builds from immediates in
// the code (and compares that way), so `strings` never sees it, in a service that has the op as in one that does not. Every op
// therefore logs a text of 16 bytes or more, kept in the file's string table, and that text is what the check looks for:
//
// - one entry per name of CefKit's `@_alwaysEmitIntoClient` debug names (`CefRemoteProtocol.swift`), under the SAME name here;
// - each text is at least 16 bytes and unique;
// - the handler of the op (or the creation flag's branch) logs its text with `note(DebugOps.<name>)`, so a handler compiled
//   outside the define fails to build in a service without it;
// - `Tools/check-service-strings.sh` lists the same texts, and `ChromiumServiceDebugOpsTests` fails when the two lists, or the list
//   of names, differ. A new debug op adds its name to CefKit, its text here and its text there, or that test fails.

#if WSURF_SERVICE_DEBUG_OPS
enum DebugOps {
    // Ops (`CefRemote.Op.debug*`)
    static let debugAbort = "debug.abort: the service ends itself with SIGKILL"
    static let debugStats = "debug.stats: the service answers with its live counts"
    static let debugExitOnHello = "debug.exitOnHello: the next hellos end the service"
    static let debugAskHost = "debug.askHost: the service asks WSurf a question"
    static let debugMemoryPressure = "debug.memoryPressure: the pressure handler runs"
    static let debugStubBrowser = "debug.stubBrowser: a stub browser is registered"
    static let debugHangExit = "debug.hangExit: the main thread blocks after the exit begins"
    static let debugHoldHistory = "debug.holdHistory: the browser's history reads are held back"
    // Creation flags (`CefRemote.DebugCreate`)
    static let fail = "create flag fail: the creation fails before CEF"
    static let hold = "create flag hold: CEF is never asked for the browser"
    static let closeFirst = "create flag closeFirst: a close comes before CEF's browser"
    static let cpuPaint = "create flag cpuPaint: the browser paints into memory"
    static let smallSourceCache = "create flag smallSourceCache: one source texture is kept"
}
#endif
