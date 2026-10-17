// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import AppKit
import Foundation
import MCP
import Testing

@testable import WSurf

/// The log itself and the commands that reach the kill switch. Nothing here needs a web view.
@MainActor
struct ExternalActivityLogTests {
    @Test func activityIsBoundedAndKeepsTheNewestEntries() {
        let log = ExternalActivityLog(client: "Client")
        let total = ExternalActivityLog.capacity + 100
        for ref in 1...total {
            log.record(tool: "clickOnPage", target: "element \(ref)", outcome: .succeeded)
        }

        #expect(log.entries.count == ExternalActivityLog.capacity)
        #expect(log.entries.first?.target == "element 101")
        #expect(log.entries.last?.target == "element \(total)")
    }

    @Test func aNoteIsBoundedAndStaysOnOneLine() throws {
        let log = ExternalActivityLog()
        log.record(tool: "navigate", outcome: .failed, detail: "example.com\nsecond line\u{7}" + String(repeating: "x", count: 500))

        let detail = try #require(log.entries.first?.detail)
        #expect(!detail.contains("\n"))
        #expect(!detail.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
        #expect(detail.count <= ExternalActivityLog.detailLimit + 1)
        #expect(detail.hasPrefix("example.com second line"))
    }

    @Test func aBlankNoteIsDropped() {
        let log = ExternalActivityLog()
        log.record(tool: "navigate", outcome: .succeeded, detail: " \n ")

        #expect(log.entries.first?.detail == nil)
    }

    @Test func costCountsTextAndImageBlocks() {
        let result = CallTool.Result(
            content: [
                .text(text: "abcd", annotations: nil, _meta: nil),
                .image(data: "xyz", mimeType: "image/jpeg", annotations: nil, _meta: nil),
            ], isError: false)

        #expect(ExternalActivityLog.bytes(of: result) == 7)
    }

    @Test func theStopCommandIsOnlyOfferedWhileAnAppIsConnected() throws {
        var context = CommandPaletteContext()
        let id = "action-\(CommandPaletteAction.stopExternalConnections.rawValue)"
        #expect(!CommandPaletteCatalog.commands(context: context) { _ in }.contains { $0.id == id })

        context.hasExternalConnections = true
        var performed: [CommandPaletteAction] = []
        let commands = CommandPaletteCatalog.commands(context: context) { performed.append($0) }
        let command = try #require(commands.first { $0.id == id })
        #expect(command.title == "Stop External Connections")
        #expect(command.shortcut == "⌥⌘.")
        #expect(CommandPaletteCatalog.matching("kill switch", in: commands).first?.id == id)
        command.run()
        #expect(performed == [.stopExternalConnections])
    }

    @Test func theMenuCommandHasItsShortcutAndIsOffWithoutAConnection() throws {
        let coordinator = AppCoordinator()
        let menu = MainMenu(coordinator: coordinator)
        menu.install()
        defer { NSApp.mainMenu = nil }
        let root = try #require(NSApp.mainMenu)
        let item = try #require(
            root.items.compactMap(\.submenu).flatMap(\.items)
                .first { $0.title == String(localized: "Stop External Connections") })

        #expect(item.keyEquivalent == ".")
        #expect(item.keyEquivalentModifierMask == [.command, .option])
        #expect(!menu.validateMenuItem(item))
    }
}
