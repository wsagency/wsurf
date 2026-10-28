// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A session's start-up (`prepare`): the domains it enables, the auto-attach to cross-site frames and the registration of the scripts
/// that run in each new document. The page's first load waits for the page session's, and a cross-site frame is held until its
/// own session's is done, so neither goes command by command: what does not depend on a previous answer goes out together.
extension ChromiumDevTools {
    /// The page's session start-up, which the first load waits for: the domains it reads, then the auto-attach, one after the other.
    /// Its scripts are registered by `prepare`.
    func preparePageSession(marksNewDocuments: Bool = false) async throws {
        _ = try await command("Page.enable")
        if marksNewDocuments {
            try await markNewDocuments(registered: 0)
        }
        _ = try await command("Security.enable")
        _ = try await command("Network.enable")
        try await attachCrossSiteFrames()
    }

    /// A frame session's start-up, run while its frame is paused: `Page.enable`, the nested auto-attach and the registration of its
    /// scripts go out together, and `startCrossSiteFrameSession` lets the frame run only once every one of them has been answered,
    /// so no script can be missed. Each world's scripts are one registration (its shim first, then the scripts in the order they were
    /// installed), so nothing depends on how Chromium orders commands that are in flight at once: no command here needs another's
    /// answer, and the worlds are separate. A script of its own is a `try`, so one that throws stops none after it, as separate
    /// registrations would not; they are self-contained, as everything listed for these frames is.
    func prepareFrameSession() async throws {
        struct Registration: Sendable {
            let worldName: String
            let indices: [Int]
            let source: String
        }
        var worlds: [String] = []
        for script in scripts where script.identifier == nil && !worlds.contains(script.worldName) {
            worlds.append(script.worldName)
        }
        let registrations = worlds.map { world -> Registration in
            let indices = scripts.indices.filter { scripts[$0].identifier == nil && scripts[$0].worldName == world }
            var chunks: [String] = []
            // Claimed before the first await, as `installBinding` does, so nothing registers the shim twice.
            if !bindingWorlds.contains(world), needsBinding(world) {
                bindingWorlds.insert(world)
                chunks.append(Self.bindingSource)
            }
            chunks += indices.map { "try {\n" + registrationSource(scripts[$0]) + "\n} catch {}" }
            return Registration(worldName: world, indices: indices, source: chunks.joined(separator: "\n"))
        }
        var tasks: [Task<Void, Error>] = [
            Task { @MainActor [self] in
                _ = try await command("Page.enable")
            },
            Task { @MainActor [self] in
                try await attachCrossSiteFrames()
            },
        ]
        for registration in registrations {
            tasks.append(Task { @MainActor [self] in
                let identifier = try await register(registration.source, worldName: registration.worldName)
                guard !closed else { throw ChromiumError.staleFrame }
                for index in registration.indices where scripts.indices.contains(index) {
                    scripts[index].identifier = identifier
                }
            })
        }
        try await Self.settle(tasks)
    }

    /// Waits for every task, so none is left running behind a failure, and throws the first failure in order.
    static func settle(_ tasks: [Task<Void, Error>]) async throws {
        var failure: Error?
        for task in tasks {
            do {
                try await task.value
            } catch {
                failure = failure ?? error
            }
        }
        if let failure {
            throw failure
        }
    }
}
