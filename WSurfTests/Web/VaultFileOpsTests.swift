// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import Foundation
import Testing

@testable import WSurf

struct VaultFileOpsTests {
    private let ops = StoreFileOps.live

    private func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    private func read(_ url: URL) throws -> String {
        String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }

    @Test func renameExclusiveNeverOverwrites() throws {
        let environment = try VaultTestEnvironment.make()
        defer { environment.cleanUp() }
        let source = environment.directory.appendingPathComponent("source")
        let destination = environment.directory.appendingPathComponent("destination")
        let free = environment.directory.appendingPathComponent("free")
        try write("source bytes", to: source)
        try write("destination bytes", to: destination)

        #expect(throws: StoreFileError.exists) { try ops.renameExclusive(source, destination) }
        #expect(try read(source) == "source bytes")
        #expect(try read(destination) == "destination bytes")

        try ops.renameExclusive(source, free)
        #expect(try read(free) == "source bytes")
        #expect(!FileManager.default.fileExists(atPath: source.path))
    }

    @Test func renameSwapExchangesTwoFiles() throws {
        let environment = try VaultTestEnvironment.make()
        defer { environment.cleanUp() }
        let first = environment.directory.appendingPathComponent("first")
        let second = environment.directory.appendingPathComponent("second")
        try write("first bytes", to: first)
        try write("second bytes", to: second)

        try ops.renameSwap(first, second)
        #expect(try read(first) == "second bytes")
        #expect(try read(second) == "first bytes")
    }

    @Test func fsyncOnAMissingPathReportsTheErrno() throws {
        let environment = try VaultTestEnvironment.make()
        defer { environment.cleanUp() }
        let missingFile = environment.directory.appendingPathComponent("missing-file")
        let missingDirectory = environment.directory.appendingPathComponent("missing-directory", isDirectory: true)

        #expect(throws: StoreFileError.io(ENOENT)) { try ops.fullFsync(missingFile) }
        #expect(throws: StoreFileError.io(ENOENT)) { try ops.fsyncDirectory(missingDirectory) }
        #expect(!FileManager.default.fileExists(atPath: missingFile.path))
        #expect(!FileManager.default.fileExists(atPath: missingDirectory.path))
    }
}
