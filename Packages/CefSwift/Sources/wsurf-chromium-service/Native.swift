// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

// Helpers for the CEF C API in the service (the same rules as WSurf's ChromiumInterop), and the service's log. D4-4a keeps only
// what ServiceHost uses; the callback allocation helpers come with the browser handlers (D4-4b).

import CCef
import Darwin
import Foundation
import os

enum Native {
    static func release(_ pointer: UnsafeMutableRawPointer?) {
        guard let base = pointer?.assumingMemoryBound(to: cef_base_ref_counted_t.self) else { return }
        _ = base.pointee.release?(base)
    }

    static func set(_ value: String, _ target: inout cef_string_t) {
        let characters = Array(value.utf16)
        characters.withUnsafeBufferPointer { buffer in
            _ = ccef_string_set_utf16(buffer.baseAddress, buffer.count, &target)
        }
    }
}

/// Mach absolute time in nanoseconds: the clock NSEvent timestamps and WSurf's own stamps share.
enum Clock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    static var nowNanoseconds: UInt64 {
        mach_absolute_time() * UInt64(timebase.numer) / UInt64(timebase.denom)
    }
}

private let logger = Logger(subsystem: "io.wsagency.wsurf.chromium-service", category: "service")

/// One line to the unified log. The service never writes a CDP payload, a URL or a cookie here (plan §1.8): only its own
/// lifecycle, so the lines are public.
func note(_ text: String) {
    logger.debug("\(text, privacy: .public)")
}
