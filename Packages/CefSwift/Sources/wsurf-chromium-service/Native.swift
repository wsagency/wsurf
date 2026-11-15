// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

// Helpers for the CEF C API in the service (the same rules as WSurf's ChromiumInterop), and the service's log. D4-4a keeps only
// what ServiceHost uses; the callback allocation helpers come with the browser handlers (D4-4b).

import CCef
import Darwin
import Foundation
import os

enum Native {
    /// A zeroed, refcounted CEF struct (refcount 1, the caller's) whose hidden header retains `owner` until the count reaches 0.
    static func allocate<T>(_ type: T.Type, owner: AnyObject) -> UnsafeMutablePointer<T> {
        let retained = Unmanaged.passRetained(owner).toOpaque()
        guard let memory = ccef_object_alloc(MemoryLayout<T>.stride, retained, { object in
            guard let object else { return }
            Unmanaged<AnyObject>.fromOpaque(object).release()
        }) else {
            Unmanaged<AnyObject>.fromOpaque(retained).release()
            preconditionFailure("Could not allocate a CEF callback.")
        }
        return memory.assumingMemoryBound(to: T.self)
    }

    /// The owner an `allocate`d struct was given, from the `self` pointer of one of its callbacks.
    static func owner<T: AnyObject>(_ type: T.Type, _ pointer: UnsafeMutableRawPointer?) -> T? {
        guard let pointer, let object = ccef_object_get_swift(pointer) else { return nil }
        return Unmanaged<AnyObject>.fromOpaque(object).takeUnretainedValue() as? T
    }

    static func retain(_ pointer: UnsafeMutableRawPointer?) {
        guard let base = pointer?.assumingMemoryBound(to: cef_base_ref_counted_t.self) else { return }
        base.pointee.add_ref?(base)
    }

    static func release(_ pointer: UnsafeMutableRawPointer?) {
        guard let base = pointer?.assumingMemoryBound(to: cef_base_ref_counted_t.self) else { return }
        _ = base.pointee.release?(base)
    }

    /// Closes `browser` in a later turn of the main queue (CEF's UI thread), holding a reference of its own until then. For a
    /// close decided in `on_after_created`: CEF goes on using the browser after that callback returns
    /// (`AlloyBrowserHostImpl::CreateInternal` calls its platform delegate), and a forced close of a windowless browser made
    /// inside the callback can destroy that delegate first, which crashed the service (a null dereference).
    static func closeLater(_ browser: UnsafeMutablePointer<cef_browser_t>) {
        retain(UnsafeMutableRawPointer(browser))
        let address = UInt(bitPattern: browser)
        DispatchQueue.main.async {
            guard let browser = UnsafeMutablePointer<cef_browser_t>(bitPattern: address) else { return }
            defer { Native.release(UnsafeMutableRawPointer(browser)) }
            guard let host = browser.pointee.get_host?(browser) else { return }
            host.pointee.close_browser?(host, 1)
            Native.release(UnsafeMutableRawPointer(host))
        }
    }

    static func string(_ value: UnsafePointer<cef_string_t>?) -> String {
        guard let value, let characters = value.pointee.str, value.pointee.length > 0 else { return "" }
        return String(decoding: UnsafeBufferPointer(start: characters, count: value.pointee.length), as: UTF16.self)
    }

    /// A string CEF returned (the caller frees it).
    static func take(_ value: cef_string_userfree_t?) -> String {
        guard let value else { return "" }
        defer { cef_string_userfree_utf16_free(value) }
        return string(UnsafePointer(value))
    }

    static func withString<T>(_ value: String, _ body: (UnsafePointer<cef_string_t>) throws -> T) rethrows -> T {
        var native = cef_string_t()
        set(value, &native)
        defer { ccef_string_clear(&native) }
        return try body(&native)
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
