// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0 AND BUSL-1.1
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
// Linen portions: Apache-2.0; WSurf modifications: BUSL-1.1. See NOTICE.

import Foundation
import os

actor JSONFileStore {
    static let shared = JSONFileStore()

    func write(_ value: some Encodable & Sendable, to url: URL, sortedKeys: Bool = false) {
        Self.encodeAndWrite(value, to: url, sortedKeys: sortedKeys)
    }

    nonisolated static func encodeAndWrite(
        _ value: some Encodable,
        to url: URL,
        sortedKeys: Bool = false
    ) {
        try? writeAtomically(value, to: url, sortedKeys: sortedKeys)
    }

    nonisolated static func writeAtomically(_ value: some Encodable, to url: URL, sortedKeys: Bool) throws {
        let encoder = JSONEncoder()
        if sortedKeys {
            encoder.outputFormatting = [.sortedKeys]
        }
        let data = try encoder.encode(value)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }
}

/// Local edits coalesce off the main thread. A received edit waits for older writes to this same file.
@MainActor
final class QueuedJSONFile {
    private let queue = DispatchQueue(label: "WSurf.QueuedJSONFile", qos: .utility)
    private let url: URL
    private let sortedKeys: Bool
    private var pending: (job: DispatchWorkItem, saved: OSAllocatedUnfairLock<Bool>)?
    private var needsInitialRead = true

    init(_ url: URL, sortedKeys: Bool = false) {
        self.url = url
        self.sortedKeys = sortedKeys
    }

    func readIfNeeded<T: Decodable>(_ type: T.Type, apply: (T) -> Void) throws {
        guard needsInitialRead else { return }
        do {
            let value = try JSONDecoder().decode(type, from: Data(contentsOf: url))
            needsInitialRead = false
            apply(value)
        } catch CocoaError.fileReadNoSuchFile {
            // A new profile has no overrides yet.
            needsInitialRead = false
        }
    }

    func schedule(_ value: some Encodable & Sendable) {
        pending?.job.cancel()
        let saved = OSAllocatedUnfairLock(initialState: false)
        let work = DispatchWorkItem { @Sendable [url, sortedKeys] in
            if (try? JSONFileStore.writeAtomically(value, to: url, sortedKeys: sortedKeys)) != nil {
                saved.withLock { $0 = true }
            }
        }
        pending = (work, saved)
        queue.async(execute: work)
    }

    /// A matching peer edit can acknowledge a local value without calling the adapter's receive method.
    func flushPending(_ value: @autoclosure () -> some Encodable & Sendable) throws {
        guard let pending else { return }
        let saved = queue.sync { @Sendable [result = pending.saved] in result.withLock { $0 } }
        if !saved {
            try saveNow(value())
        }
        self.pending = nil
    }

    func saveNow(_ value: some Encodable & Sendable) throws {
        // Let the preceding local save finish even if this replacement fails.
        try withFile { [sortedKeys] url in
            try JSONFileStore.writeAtomically(value, to: url, sortedKeys: sortedKeys)
        }
        pending = nil
    }

    func withFile(_ action: @Sendable (URL) throws -> Void) rethrows {
        try queue.sync { @Sendable [url] in try action(url) }
    }

    func waitForPendingSave() async {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume() }
        }
    }
}
