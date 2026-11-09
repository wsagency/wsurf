// D4 spike only (branch spike/chromium-oop, never merged). The owner's check of option (b) for moving "Chromium Safe
// Storage" to the service: can WSurf rewrite an item's access list to trust itself and the service, and can the service
// then read the item, with no prompt? Run by the owner from Terminal, never by an agent: it writes the login keychain. It
// uses its own item ("WSurf D4 Spike Safe Storage"), never Chromium's, and `delete` removes it.
//
// WSurf:    WSurf.app/Contents/MacOS/WSurf --d4-keychain create|read|trust <service executable>|delete
// Service:  WSurf.app/Contents/XPCServices/WSurf Chromium.xpc/Contents/MacOS/WSurf Chromium --d4-keychain read

import Foundation
import Security

public enum D4KeychainProbe {
    static let service = "WSurf D4 Spike Safe Storage"
    static let account = "Chromium"

    /// Runs `--d4-keychain <command> [argument]` and exits; returns at once when the arguments do not ask for it.
    public static func runIfRequested(identity: String) {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--d4-keychain") else { return }
        let command = index + 1 < arguments.count ? arguments[index + 1] : ""
        let argument = index + 2 < arguments.count ? arguments[index + 2] : nil
        let status: OSStatus
        switch command {
        case "create": status = create()
        case "read": status = read()
        case "trust": status = trust(argument)
        case "delete": status = delete()
        default:
            print("usage: --d4-keychain create | read | trust <service executable> | delete")
            exit(2)
        }
        let message = (SecCopyErrorMessageString(status, nil) as String?) ?? ""
        print("[\(identity), pid \(getpid())] \(command): OSStatus \(status) \(message)")
        exit(status == errSecSuccess ? 0 : 1)
    }

    /// A 16-byte random secret, base64, like Chromium's. The item's access list is the default: the creating app.
    private static func create() -> OSStatus {
        var bytes = [UInt8](repeating: 0, count: 16)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let secret = Array(Data(bytes).base64EncodedString().utf8)
        return secret.withUnsafeBytes { buffer in
            SecKeychainAddGenericPassword(nil, UInt32(service.utf8.count), service, UInt32(account.utf8.count), account,
                                          UInt32(buffer.count), buffer.baseAddress!, nil)
        }
    }

    private static func find() -> (OSStatus, SecKeychainItem?) {
        var item: SecKeychainItem?
        let status = SecKeychainFindGenericPassword(nil, UInt32(service.utf8.count), service, UInt32(account.utf8.count), account,
                                                    nil, nil, &item)
        return (status, item)
    }

    /// Reads the secret (which needs the decrypt right) and prints only its length.
    private static func read() -> OSStatus {
        var length: UInt32 = 0
        var data: UnsafeMutableRawPointer?
        let status = SecKeychainFindGenericPassword(nil, UInt32(service.utf8.count), service, UInt32(account.utf8.count), account,
                                                    &length, &data, nil)
        if status == errSecSuccess {
            print("read \(length) bytes; the secret itself is not printed")
            _ = SecKeychainItemFreeContent(nil, data)
        }
        return status
    }

    /// Option (b): replaces the item's access with one that trusts this app and the given executable.
    private static func trust(_ path: String?) -> OSStatus {
        guard let path else {
            print("trust needs the path of the service's executable")
            return errSecParam
        }
        let (found, item) = find()
        guard found == errSecSuccess, let item else { return found }
        var me: SecTrustedApplication?
        var status = SecTrustedApplicationCreateFromPath(nil, &me)
        guard status == errSecSuccess, let me else { return status }
        var other: SecTrustedApplication?
        status = SecTrustedApplicationCreateFromPath(path, &other)
        guard status == errSecSuccess, let other else { return status }
        var access: SecAccess?
        status = SecAccessCreate(service as CFString, [me, other] as CFArray, &access)
        guard status == errSecSuccess, let access else { return status }
        return SecKeychainItemSetAccess(item, access)
    }

    private static func delete() -> OSStatus {
        let (found, item) = find()
        guard found == errSecSuccess, let item else { return found }
        return SecKeychainItemDelete(item)
    }
}
