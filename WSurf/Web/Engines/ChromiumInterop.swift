// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CCef
import Foundation

nonisolated enum ChromiumInterop {
    static func retain(_ pointer: UnsafeMutableRawPointer?) {
        guard let base = pointer?.assumingMemoryBound(to: cef_base_ref_counted_t.self) else { return }
        base.pointee.add_ref?(base)
    }

    static func release(_ pointer: UnsafeMutableRawPointer?) {
        guard let base = pointer?.assumingMemoryBound(to: cef_base_ref_counted_t.self) else { return }
        _ = base.pointee.release?(base)
    }

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

    static func owner<T: AnyObject>(_ type: T.Type, of pointer: UnsafeMutableRawPointer?) -> T? {
        guard let pointer, let object = ccef_object_get_swift(pointer) else { return nil }
        return Unmanaged<T>.fromOpaque(object).takeUnretainedValue()
    }

    static func string(_ value: UnsafePointer<cef_string_t>?) -> String {
        guard let value, let characters = value.pointee.str else { return "" }
        return String(decoding: UnsafeBufferPointer(start: characters, count: value.pointee.length), as: UTF16.self)
    }

    static func takeString(_ value: cef_string_userfree_t?) -> String {
        guard let value else { return "" }
        defer { cef_string_userfree_utf16_free(value) }
        return string(UnsafePointer(value))
    }

    static func setString(_ value: String, to target: inout cef_string_t) {
        let characters = Array(value.utf16)
        characters.withUnsafeBufferPointer { buffer in
            _ = ccef_string_set_utf16(buffer.baseAddress, buffer.count, &target)
        }
    }

    static func withString<T>(_ value: String, _ body: (UnsafePointer<cef_string_t>) throws -> T) rethrows -> T {
        var native = cef_string_t()
        setString(value, to: &native)
        defer { ccef_string_clear(&native) }
        return try body(&native)
    }
}

nonisolated enum ChromiumError: LocalizedError {
    case unavailable(String)
    case closed
    case protocolFailure(String)
    case staleFrame

    var errorDescription: String? {
        switch self {
        case .unavailable(let detail), .protocolFailure(let detail):
            detail
        case .closed:
            String(localized: "The Chromium page is closed.")
        case .staleFrame:
            String(localized: "The page changed. Read it again before continuing.")
        }
    }
}
