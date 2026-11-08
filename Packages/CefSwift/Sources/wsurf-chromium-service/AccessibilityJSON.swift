// D4 spike: CEF's accessibility updates (a cef_value_t tree built from Chromium's AXTreeUpdate) as JSON bytes for WSurf.

import CCef
import Foundation

enum AccessibilityJSON {
    static func data(_ value: UnsafeMutablePointer<cef_value_t>?) -> Data {
        let object = convert(value)
        guard JSONSerialization.isValidJSONObject(object) else { return Data("{}".utf8) }
        return (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
    }

    private static func convert(_ value: UnsafeMutablePointer<cef_value_t>?) -> Any {
        guard let value, let type = value.pointee.get_type?(value) else { return NSNull() }
        switch type {
        case VTYPE_BOOL:
            return value.pointee.get_bool?(value) == 1
        case VTYPE_INT:
            return Int(value.pointee.get_int?(value) ?? 0)
        case VTYPE_DOUBLE:
            return value.pointee.get_double?(value) ?? 0
        case VTYPE_STRING:
            return Native.take(value.pointee.get_string?(value))
        case VTYPE_DICTIONARY:
            let dictionary = value.pointee.get_dictionary?(value)
            defer { Native.release(dictionary.map(UnsafeMutableRawPointer.init)) }
            return convert(dictionary: dictionary)
        case VTYPE_LIST:
            let list = value.pointee.get_list?(value)
            defer { Native.release(list.map(UnsafeMutableRawPointer.init)) }
            return convert(list: list)
        default:
            return NSNull()
        }
    }

    private static func convert(dictionary: UnsafeMutablePointer<cef_dictionary_value_t>?) -> [String: Any] {
        guard let dictionary, let keys = cef_string_list_alloc() else { return [:] }
        defer { cef_string_list_free(keys) }
        _ = dictionary.pointee.get_keys?(dictionary, keys)
        var result: [String: Any] = [:]
        for index in 0..<cef_string_list_size(keys) {
            var key = cef_string_t()
            defer { ccef_string_clear(&key) }
            guard cef_string_list_value(keys, index, &key) == 1 else { continue }
            let name = withUnsafePointer(to: &key) { Native.string($0) }
            let item = dictionary.pointee.get_value?(dictionary, &key)
            defer { Native.release(item.map(UnsafeMutableRawPointer.init)) }
            result[name] = convert(item)
        }
        return result
    }

    private static func convert(list: UnsafeMutablePointer<cef_list_value_t>?) -> [Any] {
        guard let list else { return [] }
        let count = list.pointee.get_size?(list) ?? 0
        return (0..<count).map { index in
            let item = list.pointee.get_value?(list, index)
            defer { Native.release(item.map(UnsafeMutableRawPointer.init)) }
            return convert(item)
        }
    }
}
