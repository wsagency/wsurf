// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CCef
import Foundation

extension ChromiumPage {
    /// The click that asked for a window, as the engine read its modifiers: Command or the middle button, with Shift or without,
    /// and Shift alone (a window, which a WebKit tab answers with a peek). `other` is a page's own.
    nonisolated enum ClickDisposition: Equatable {
        case backgroundTab, foregroundTab, window, other

        init(_ disposition: cef_window_open_disposition_t) {
            if disposition == CEF_WOD_NEW_BACKGROUND_TAB {
                self = .backgroundTab
            } else if disposition == CEF_WOD_NEW_FOREGROUND_TAB {
                self = .foregroundTab
            } else if disposition == CEF_WOD_NEW_WINDOW {
                self = .window
            } else {
                self = .other
            }
        }
    }
}

/// The items of a WebKit tab's context menu that the engine's own menu lacks (`TabWebView`): Open Link in Peek and Summarize Link,
/// Open Image in New Tab and Download Image, Download Linked File, and Save Page As… and Print Page…, which act through the same
/// code as there (`PageSaving`, `PagePrinting`, the download handler, the tab's peek and summary).
extension ChromiumClient {
    /// What the right-click landed on, as far as these items care.
    nonisolated struct ContextTarget: Equatable {
        var link: URL?
        var image: URL?
        /// The page's own background: no link, media, selection or field.
        var isPage = false
        /// The address of the frame that was clicked, which names the source of a tab the item opens.
        var frameURL: URL?
    }

    /// What choosing an item does besides opening a tab or a window (`ChromiumPage.onContextAction`).
    nonisolated enum ContextAction: Equatable {
        case peek(URL), summarize(URL), download(URL), savePage, printPage
    }

    /// The commands after the PDF ones.
    nonisolated static let peekCommand = pickCredentialCommand + 6
    nonisolated static let summarizeCommand = pickCredentialCommand + 7
    nonisolated static let savePageCommand = pickCredentialCommand + 8
    nonisolated static let printPageCommand = pickCredentialCommand + 9
    nonisolated static let openImageCommand = pickCredentialCommand + 10
    nonisolated static let downloadImageCommand = pickCredentialCommand + 11
    nonisolated static let downloadLinkCommand = pickCredentialCommand + 12

    typealias ContextEntry = (id: Int32, title: LocalizedStringResource)

    /// The items for a right-click on `target`, in the order of a WebKit tab's menu: the groups that go above the engine's own items
    /// (a link's, then an image's), and the items that go below them.
    nonisolated static func contextItems(
        for target: ContextTarget, isPrivate: Bool
    ) -> (leading: [[ContextEntry]], trailing: [ContextEntry]) {
        var leading: [[ContextEntry]] = []
        var trailing: [ContextEntry] = []
        if target.link != nil {
            leading.append(
                linkCommands(isPrivate: isPrivate).map { ($0.id, $0.title) } + [
                    (peekCommand, "Open Link in Peek"),
                    (summarizeCommand, "Summarize Link"),
                ]
            )
            trailing.append((downloadLinkCommand, "Download Linked File"))
        }
        if target.image != nil {
            leading.append([
                (openImageCommand, "Open Image in New Tab"),
                (downloadImageCommand, "Download Image"),
            ])
        }
        return (leading, trailing)
    }

    /// Save Page As… and Print Page…, which a WebKit tab's menu has under Reload Page. Here they take the place of the engine's own
    /// Print, which does not reach `PagePrinting`.
    nonisolated static let pageCommands: [ContextEntry] = [
        (savePageCommand, "Save Page As…"),
        (printPageCommand, "Print Page…"),
    ]

    /// Whether a right-click with these type flags (`cef_context_menu_type_flags_t`) landed on the page itself, in a frame or not,
    /// and not on a link, an image or video, a selection or a field.
    nonisolated static func isPageBackground(typeFlags: UInt32) -> Bool {
        let own = UInt32(CM_TYPEFLAG_PAGE.rawValue | CM_TYPEFLAG_FRAME.rawValue)
        let other = UInt32(CM_TYPEFLAG_LINK.rawValue | CM_TYPEFLAG_MEDIA.rawValue | CM_TYPEFLAG_SELECTION.rawValue
            | CM_TYPEFLAG_EDITABLE.rawValue)
        return typeFlags & own != 0 && typeFlags & other == 0
    }

    /// What `params` says the right-click landed on.
    nonisolated static func contextTarget(
        of params: UnsafeMutablePointer<cef_context_menu_params_t>, frameURL: URL?
    ) -> ContextTarget {
        let flags = params.pointee.get_type_flags?(params).rawValue ?? 0
        let isImage = params.pointee.get_media_type?(params) == CM_MEDIATYPE_IMAGE
        return ContextTarget(
            link: URL(string: ChromiumInterop.takeString(params.pointee.get_link_url?(params))),
            image: isImage ? URL(string: ChromiumInterop.takeString(params.pointee.get_source_url?(params))) : nil,
            isPage: isPageBackground(typeFlags: UInt32(flags)),
            frameURL: frameURL
        )
    }

    /// Adds the items for `target` to the menu that is about to open and remembers the target for the command that is chosen. The
    /// page items are left out while the tab shows a PDF, whose own items save it.
    func offerContextItems(in model: UnsafeMutablePointer<cef_menu_model_t>, target: ContextTarget) {
        page?.contextTarget = nil
        guard let page else { return }
        let items = Self.contextItems(for: target, isPrivate: page.context.profile.isPrivate)
        var offered = false
        var index = 0
        for group in items.leading {
            let before = index
            for entry in group where insert(entry, into: model, at: index) {
                index += 1
            }
            if index > before, model.pointee.insert_separator_at?(model, index) == 1 {
                index += 1
            }
        }
        offered = index > 0
        if append(items.trailing, to: model) {
            offered = true
        }
        if target.isPage, page.showsPDF?() != true, offerPageItems(in: model) {
            offered = true
        }
        page.contextTarget = offered ? target : nil
    }

    /// Save Page As… and Print Page… where the engine's own Print is, which they replace; at the end when it has none.
    private func offerPageItems(in model: UnsafeMutablePointer<cef_menu_model_t>) -> Bool {
        let print = Int32(MENU_ID_PRINT.rawValue)
        let printIndex = Int(model.pointee.get_index_of?(model, print) ?? -1)
        guard printIndex >= 0 else {
            return append(Self.pageCommands, to: model)
        }
        var index = printIndex
        for entry in Self.pageCommands where insert(entry, into: model, at: index) {
            index += 1
        }
        guard index > printIndex else { return false }
        _ = model.pointee.remove?(model, print)
        return true
    }

    /// Runs a command of the menu that is open, if it is one of these items.
    func runContextItem(_ command: Int32) -> Bool {
        guard let page, let target = page.contextTarget else { return false }
        if let opening = Self.linkCommands(isPrivate: false).first(where: { $0.id == command })?.opening {
            guard let link = target.link else { return false }
            page.contextTarget = nil
            page.openLinkFromMenu?(link, target.frameURL, opening)
            return true
        }
        let action: ContextAction
        switch command {
        case Self.openImageCommand:
            guard let image = target.image else { return false }
            page.contextTarget = nil
            page.openLinkFromMenu?(image, target.frameURL, .tab)
            return true
        case Self.peekCommand:
            guard let link = target.link else { return false }
            action = .peek(link)
        case Self.summarizeCommand:
            guard let link = target.link else { return false }
            action = .summarize(link)
        case Self.downloadLinkCommand:
            guard let link = target.link else { return false }
            action = .download(link)
        case Self.downloadImageCommand:
            guard let image = target.image else { return false }
            action = .download(image)
        case Self.savePageCommand where target.isPage:
            action = .savePage
        case Self.printPageCommand where target.isPage:
            action = .printPage
        default:
            return false
        }
        page.contextTarget = nil
        page.onContextAction?(action)
        return true
    }

    private func insert(_ entry: ContextEntry, into model: UnsafeMutablePointer<cef_menu_model_t>, at index: Int) -> Bool {
        ChromiumInterop.withString(String(localized: entry.title)) {
            model.pointee.insert_item_at?(model, index, entry.id, $0)
        } == 1
    }

    /// Puts `entries` last, set off from the engine's items by a separator when there are any. True when one was added.
    private func append(_ entries: [ContextEntry], to model: UnsafeMutablePointer<cef_menu_model_t>) -> Bool {
        var count = Int(model.pointee.get_count?(model) ?? 0)
        var added = false
        for entry in entries {
            if !added, count > 0, model.pointee.get_type_at?(model, count - 1) != MENUITEMTYPE_SEPARATOR,
               model.pointee.insert_separator_at?(model, count) == 1 {
                count += 1
            }
            if insert(entry, into: model, at: count) {
                count += 1
                added = true
            }
        }
        return added
    }
}
