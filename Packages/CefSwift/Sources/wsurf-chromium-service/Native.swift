// D4 spike: helpers for the CEF C API in the service (the same rules as WSurf's ChromiumInterop).

import CCef
import Darwin
import Foundation

enum Native {
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

    static func string(_ value: UnsafePointer<cef_string_t>?) -> String {
        guard let value, let characters = value.pointee.str, value.pointee.length > 0 else { return "" }
        return String(decoding: UnsafeBufferPointer(start: characters, count: value.pointee.length), as: UTF16.self)
    }

    static func take(_ value: cef_string_userfree_t?) -> String {
        guard let value else { return "" }
        defer { cef_string_userfree_utf16_free(value) }
        return string(UnsafePointer(value))
    }

    static func set(_ value: String, _ target: inout cef_string_t) {
        let characters = Array(value.utf16)
        characters.withUnsafeBufferPointer { buffer in
            _ = ccef_string_set_utf16(buffer.baseAddress, buffer.count, &target)
        }
    }

    static func withString<T>(_ value: String, _ body: (UnsafePointer<cef_string_t>) throws -> T) rethrows -> T {
        var native = cef_string_t()
        set(value, &native)
        defer { ccef_string_clear(&native) }
        return try body(&native)
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

    static var nowSeconds: Double {
        Double(nowNanoseconds) / 1e9
    }
}

/// A line log for the spike. Before WSurf names a file (in its stage home) lines wait in memory.
final class ServiceLog {
    static let shared = ServiceLog()
    private var handle: FileHandle?
    private var pending: [String] = []
    private let lock = NSLock()

    func open(path: String) {
        lock.lock()
        defer { lock.unlock() }
        guard handle == nil, !path.isEmpty else { return }
        FileManager.default.createFile(atPath: path, contents: nil)
        handle = FileHandle(forWritingAtPath: path)
        handle?.seekToEndOfFile()
        for line in pending {
            handle?.write(Data(line.utf8))
        }
        pending.removeAll()
    }

    func write(_ text: String) {
        let line = String(format: "%.3f [%d] ", Clock.nowSeconds, getpid()) + text + "\n"
        lock.lock()
        defer { lock.unlock() }
        if let handle {
            handle.write(Data(line.utf8))
        } else if pending.count < 2_000 {
            pending.append(line)
        }
    }
}

func note(_ text: String) {
    ServiceLog.shared.write(text)
}
