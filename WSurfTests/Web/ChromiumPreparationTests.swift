// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Darwin
import Foundation
import Testing

@testable import WSurf

/// After a launch has drawn, the app reads Chromium's framework into memory off the main thread, so the first Chromium tab does
/// not wait for the disk. Reading starts nothing: Chromium itself starts with the first Chromium tab, and not at all for a person
/// who never opens one. CEF cannot be stopped in a process, so what a test can hold it to is that it is no more started than it
/// was.
@MainActor
@Suite(.serialized)
struct ChromiumPreparationTests {
    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wsurf-prepare-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// The share of `file`'s pages that are in the page cache.
    private func resident(_ file: URL) -> Double {
        let descriptor = open(file.path, O_RDONLY)
        guard descriptor >= 0 else { return -1 }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_size > 0 else { return -1 }
        let size = Int(info.st_size)
        guard let map = mmap(nil, size, PROT_READ, MAP_SHARED, descriptor, 0), map != MAP_FAILED else { return -1 }
        defer { munmap(map, size) }
        let page = Int(getpagesize())
        let pages = (size + page - 1) / page
        var vector = [CChar](repeating: 0, count: pages)
        guard mincore(map, size, &vector) == 0 else { return -1 }
        return Double(vector.filter { $0 & 1 != 0 }.count) / Double(pages)
    }

    @Test func preparingStartsNoChromium() async throws {
        let runtime = ChromiumRuntime.shared
        let wasRunning = runtime.isInitialized
        let context = BrowserProfileContext(profile: .privateBrowsing())
        // A profile's catalog directory marks Chromium as used, so the framework is read.
        let marker = runtime.catalogDirectory(profileID: UUID())
        try FileManager.default.createDirectory(at: marker, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: marker) }

        await runtime.prepareInBackground().value

        #expect(runtime.isInitialized == wasRunning)
        #expect(!runtime.hasContext(contextID: context.contextID))
        await context.endPrivateSession()
    }

    @Test func aFrameworkIsReadWhereAPageLoadedInChromium() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!ChromiumRuntime.hasUsedChromium(root: root), "a new installation")

        // Erasing a profile leaves a mark here, not a catalog.
        let erased = root.appendingPathComponent("Profiles/Erased", isDirectory: true)
        try FileManager.default.createDirectory(at: erased, withIntermediateDirectories: true)
        try Data().write(to: erased.appendingPathComponent(UUID().uuidString))
        #expect(!ChromiumRuntime.hasUsedChromium(root: root), "only a profile that was erased")

        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Profiles/\(UUID().uuidString)", isDirectory: true), withIntermediateDirectories: true
        )
        #expect(ChromiumRuntime.hasUsedChromium(root: root), "a profile's catalog exists once a page loaded")
    }

    /// A clone of a file shares its blocks, not its pages in memory, so it starts out unread (the original, just written, is in
    /// memory).
    @Test func readingAheadBringsAFileIntoMemory() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("original")
        try Data(repeating: 7, count: 64 << 20).write(to: original)
        let copy = directory.appendingPathComponent("copy")
        try #require(clonefile(original.path, copy.path, 0) == 0, "the temporary directory is on a volume that clones files")
        let before = resident(copy)
        #expect(before >= 0 && before < 0.5, "the clone starts unread")

        ChromiumRuntime.readAhead(copy)

        #expect(await waitUntil(timeout: .seconds(30)) { resident(copy) > 0.99 }, "resident before: \(before), after: \(resident(copy))")
    }

    @Test func readingAheadOfAFileThatIsNotThereDoesNothing() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        ChromiumRuntime.readAhead(directory.appendingPathComponent("missing"))
    }
}
