// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import Foundation
import Testing

@testable import WSurf

/// Private windows are drawn with `plus.square.fill`, in the profile, the palette and the profile menu.
@MainActor
struct PrivateWindowSymbolTests {
    @Test func privateWindowsUseTheNewSymbolEverywhere() throws {
        #expect(Profile.privateBrowsing().symbol == "plus.square.fill")

        let commands = CommandPaletteCatalog.commands(context: CommandPaletteContext(), perform: { _ in })
        let privateCommand = try #require(commands.first { $0.id == "action-privateBrowsing" })
        #expect(privateCommand.symbol == "plus.square.fill")

        let root = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        for path in ["WSurf/Profiles", "WSurf/UI", "WSurf/Settings"] {
            let directory = root.appending(path: path)
            let enumerator = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil))
            for case let file as URL in enumerator where file.pathExtension == "swift" {
                let text = try String(contentsOf: file, encoding: .utf8)
                #expect(!text.contains("eyeglasses"), "\(file.lastPathComponent) still names the old symbol")
            }
        }
    }
}
