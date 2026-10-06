// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation

nonisolated final class InMemoryUserDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any]
    private let lock = NSLock()

    init(inheriting defaults: UserDefaults) {
        values = defaults.dictionaryRepresentation()
        super.init(suiteName: nil)!
    }

    override func object(forKey defaultName: String) -> Any? {
        lock.withLock { values[defaultName] }
    }

    override func set(_ value: Any?, forKey defaultName: String) {
        lock.withLock { values[defaultName] = value }
    }

    override func removeObject(forKey defaultName: String) {
        lock.withLock { values[defaultName] = nil }
    }

    override func dictionaryRepresentation() -> [String: Any] {
        lock.withLock { values }
    }

    override func register(defaults registrationDictionary: [String: Any]) {
        lock.withLock { values.merge(registrationDictionary) { existing, _ in existing } }
    }

    override func bool(forKey defaultName: String) -> Bool {
        let value = object(forKey: defaultName)
        return (value as? NSNumber)?.boolValue ?? (value as? Bool ?? false)
    }

    override func integer(forKey defaultName: String) -> Int {
        (object(forKey: defaultName) as? NSNumber)?.intValue ?? 0
    }

    override func double(forKey defaultName: String) -> Double {
        (object(forKey: defaultName) as? NSNumber)?.doubleValue ?? 0
    }

    override func string(forKey defaultName: String) -> String? {
        object(forKey: defaultName) as? String
    }

    override func stringArray(forKey defaultName: String) -> [String]? {
        object(forKey: defaultName) as? [String]
    }

    override func array(forKey defaultName: String) -> [Any]? {
        object(forKey: defaultName) as? [Any]
    }

    override func dictionary(forKey defaultName: String) -> [String: Any]? {
        object(forKey: defaultName) as? [String: Any]
    }

    override func data(forKey defaultName: String) -> Data? {
        object(forKey: defaultName) as? Data
    }

    override func url(forKey defaultName: String) -> URL? {
        object(forKey: defaultName) as? URL
    }

    override func synchronize() -> Bool {
        true
    }
}

@MainActor
enum ProfileSettingsStore {
    private static var privateDefaults: InMemoryUserDefaults?

    static func suiteName(for id: UUID) -> String {
        "io.wsagency.wsurf.profile.\(id.uuidString)"
    }

    static func defaults(for profile: Profile) -> UserDefaults {
        if profile.isPrivate {
            if let privateDefaults {
                return privateDefaults
            }
            let persistentProfile = ProfileStore.shared.profileToReturnTo
            let inherited = defaults(for: persistentProfile)
            let fresh = InMemoryUserDefaults(inheriting: inherited)
            privateDefaults = fresh
            return fresh
        }
        #if DEBUG
        if StageMode.isActive {
            return StageMode.defaults
        }
        #endif
        guard !profile.isOriginal else { return .standard }
        return UserDefaults(suiteName: suiteName(for: profile.id)) ?? .standard
    }

    static func forget(_ id: UUID) {
        if id == Profile.privateID {
            privateDefaults = nil
            return
        }
        UserDefaults.standard.removePersistentDomain(forName: suiteName(for: id))
    }
}
