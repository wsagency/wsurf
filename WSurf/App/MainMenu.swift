// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AppKit

@MainActor
enum ShortcutPriority {
    private static let leftArrow = String(UnicodeScalar(NSLeftArrowFunctionKey)!)
    private static let rightArrow = String(UnicodeScalar(NSRightArrowFunctionKey)!)

    private static let pageFirst: [(key: String, modifiers: NSEvent.ModifierFlags)] = [
        ("z", [.command]),
        ("z", [.command, .shift]),
        ("x", [.command]),
        ("c", [.command]),
        ("v", [.command]),
        ("v", [.command, .option, .shift]),
        ("a", [.command]),
        ("f", [.command]),
        ("g", [.command]),
        ("g", [.command, .shift]),
        (leftArrow, [.command]),
        (rightArrow, [.command]),
    ]

    static func menuAnswersFirst(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        guard flags.contains(.command) || flags.contains(.control) else { return false }
        guard let key = event.charactersIgnoringModifiers?.lowercased() else { return false }
        return !pageFirst.contains { $0.key == key && $0.modifiers == flags }
    }
}

@MainActor
final class MainMenu: NSObject, NSMenuItemValidation {
    private let fallbackCoordinator: AppCoordinator?
    private weak var application: BrowserApplication?
    private var coordinator: AppCoordinator {
        if let application {
            return application.ensureActiveWindow()
        }
        guard let fallbackCoordinator else { preconditionFailure("Menu has no application") }
        return fallbackCoordinator
    }

    init(coordinator: AppCoordinator) {
        fallbackCoordinator = coordinator
        super.init()
    }

    init(application: BrowserApplication) {
        fallbackCoordinator = nil
        self.application = application
        super.init()
    }

    func install() {
        let root = NSMenu()
        root.addItem(submenu(appMenu(), titled: "WSurf"))
        root.addItem(submenu(fileMenu(), titled: "File"))
        root.addItem(submenu(editMenu(), titled: "Edit"))
        root.addItem(submenu(viewMenu(), titled: "View"))
        root.addItem(submenu(historyMenu(), titled: "History"))

        let window = windowMenu()
        root.addItem(submenu(window, titled: "Window"))

        let help = NSMenu(title: "Help")
        root.addItem(submenu(help, titled: "Help"))

        NSApp.mainMenu = root
        NSApp.windowsMenu = window
        NSApp.helpMenu = help

        let coordinators = application?.windows ?? fallbackCoordinator.map { [$0] } ?? []
        for coordinator in coordinators {
            guard let nativeWindow = coordinator.nativeWindow,
                  !nativeWindow.isExcludedFromWindowsMenu else { continue }
            NSApp.addWindowsItem(nativeWindow, title: nativeWindow.title, filename: false)
        }
    }

    // MARK: - Menus

    private func appMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(command("About WSurf", #selector(showAbout)))
        menu.addItem(.separator())
        menu.addItem(command("Check for Updates…", #selector(checkForUpdates)))
        menu.addItem(command("Release Notes…", #selector(showReleaseNotes)))
        menu.addItem(.separator())
        menu.addItem(command("Settings…", #selector(openSettings), key: ","))
        menu.addItem(.separator())

        let services = NSMenu(title: "Services")
        menu.addItem(submenu(services, titled: "Services"))
        NSApp.servicesMenu = services

        menu.addItem(.separator())
        menu.addItem(chain("Hide WSurf", #selector(NSApplication.hide(_:)), key: "h"))
        menu.addItem(chain(
            "Hide Others",
            #selector(NSApplication.hideOtherApplications(_:)),
            key: "h",
            modifiers: [.command, .option]
        ))
        menu.addItem(chain("Show All", #selector(NSApplication.unhideAllApplications(_:))))
        menu.addItem(.separator())
        menu.addItem(chain("Quit WSurf", #selector(NSApplication.terminate(_:)), key: "q"))
        return menu
    }

    private func fileMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(command("New Tab", #selector(newTab), key: "t"))
        menu.addItem(command("New Window", #selector(newWindow), key: "n"))
        menu.addItem(command("New Private Window", #selector(newPrivateWindow), key: "n", modifiers: [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(command("Reopen Last Closed Tab", #selector(reopenClosedTab), key: "t", modifiers: [.command, .shift]))
        menu.addItem(command("Reopen Last Closed Window", #selector(reopenClosedWindow)))
        menu.addItem(.separator())
        menu.addItem(command("Close Tab", #selector(closeOrUnloadTab), key: "w"))
        menu.addItem(command("Free Memory", #selector(freeMemory)))
        menu.addItem(.separator())
        menu.addItem(command("Pin This Page", #selector(pinPage), key: "d"))
        menu.addItem(command(
            "Back to Pinned Page",
            #selector(returnToPin),
            key: "d",
            modifiers: [.command, .shift]
        ))
        menu.addItem(.separator())
        menu.addItem(command("Open Location…", #selector(openLocation), key: "l"))
        menu.addItem(command("Search Everything…", #selector(openPalette), key: "k"))
        menu.addItem(.separator())
        menu.addItem(command("Downloads", #selector(openDownloads), key: "l", modifiers: [.command, .option]))
        menu.addItem(.separator())
        menu.addItem(chain(
            "Close Window",
            #selector(NSWindow.performClose(_:)),
            key: "w",
            modifiers: [.command, .shift]
        ))
        menu.addItem(command("Print…", #selector(printPage), key: "p"))
        return menu
    }

    private func editMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(chain("Undo", Selector(("undo:")), key: "z"))
        menu.addItem(chain("Redo", Selector(("redo:")), key: "z", modifiers: [.command, .shift]))
        menu.addItem(hidden(chain("Undo", Selector(("undo:")), key: "z", modifiers: [.control])))
        menu.addItem(hidden(chain("Redo", Selector(("redo:")), key: "z", modifiers: [.control, .shift])))
        menu.addItem(.separator())
        menu.addItem(chain("Cut", #selector(NSText.cut(_:)), key: "x"))
        menu.addItem(chain("Copy", #selector(NSText.copy(_:)), key: "c"))
        menu.addItem(chain("Paste", #selector(NSText.paste(_:)), key: "v"))
        menu.addItem(chain(
            "Paste and Match Style",
            #selector(NSTextView.pasteAsPlainText(_:)),
            key: "v",
            modifiers: [.command, .option, .shift]
        ))
        menu.addItem(chain("Delete", #selector(NSText.delete(_:))))
        menu.addItem(chain("Select All", #selector(NSText.selectAll(_:)), key: "a"))
        menu.addItem(.separator())
        menu.addItem(command("Copy Link", #selector(copyPageURL), key: "c", modifiers: [.command, .shift]))
        menu.addItem(.separator())

        let find = NSMenu(title: "Find")
        find.addItem(command("Find…", #selector(openFind), key: "f"))
        find.addItem(command("Find Next", #selector(findNext), key: "g"))
        find.addItem(command("Find Previous", #selector(findPrevious), key: "g", modifiers: [.command, .shift]))
        menu.addItem(submenu(find, titled: "Find"))
        return menu
    }

    private func viewMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(command("Reload Page", #selector(reload), key: "r"))
        menu.addItem(command("Reload Page from Origin", #selector(hardReload), key: "r", modifiers: [.command, .shift]))
        menu.addItem(command("Stop", #selector(stopLoading), key: "."))
        menu.addItem(command(
            "Stop External Connections",
            #selector(stopExternalConnections),
            key: ".",
            modifiers: [.command, .option]
        ))
        menu.addItem(.separator())
        menu.addItem(command("Actual Size", #selector(actualSize), key: "0"))
        menu.addItem(command("Zoom In", #selector(zoomIn), key: "+"))
        menu.addItem(hidden(command("Zoom In", #selector(zoomIn), key: "=")))
        menu.addItem(command("Zoom Out", #selector(zoomOut), key: "-"))
        menu.addItem(.separator())
        menu.addItem(command("Translate Page", #selector(toggleTranslation)))
        menu.addItem(command("Show Reader", #selector(toggleReader), key: "r", modifiers: [.command, .option]))
        menu.addItem(command("Read Aloud", #selector(toggleReadAloud), key: "p", modifiers: [.command, .option]))
        menu.addItem(command("Stop Reading", #selector(stopReadAloud)))
        menu.addItem(command("Watch This Page…", #selector(watchPage)))
        menu.addItem(.separator())
        menu.addItem(chain(
            "Enter Full Screen",
            #selector(NSWindow.toggleFullScreen(_:)),
            key: "f",
            modifiers: [.command, .control]
        ))
        menu.addItem(.separator())
        menu.addItem(submenu(splitViewMenu(), titled: "Split View"))
        menu.addItem(.separator())
        menu.addItem(command("Hide Sidebar", #selector(toggleSidebar), key: "s", modifiers: [.command, .control]))
        menu.addItem(command("Use Minimal Window Style", #selector(toggleWindowStyle), key: "m", modifiers: [.command, .shift]))
        menu.addItem(command("Move Bar to Top", #selector(moveMinimalBar)))
        menu.addItem(command("Keep Sidebar Open", #selector(toggleMinimalSidebarPin)))
        menu.addItem(command(
            "Show Assistant",
            #selector(toggleAgentInspector),
            key: "a",
            modifiers: [.command, .option]
        ))
        menu.addItem(command("Show Lyrics", #selector(toggleLyrics), key: "y", modifiers: [.command, .option]))
        menu.addItem(submenu(playerCornerMenu(), titled: "Move Player to Corner"))
        menu.addItem(.separator())
        let developer = NSMenu()
        developer.addItem(command("Show Web Inspector", #selector(showWebInspector), key: "i", modifiers: [.command, .option]))
        developer.addItem(command("Restart Page", #selector(restartPage)))
        developer.addItem(.separator())
        developer.addItem(command("Developer Mode for This Website", #selector(toggleDevMode(_:))))
        menu.addItem(submenu(developer, titled: "Developer"))
        return menu
    }

    private func splitViewMenu() -> NSMenu {
        let menu = NSMenu()
        let rightArrow = String(UnicodeScalar(NSRightArrowFunctionKey)!)
        let downArrow = String(UnicodeScalar(NSDownArrowFunctionKey)!)
        menu.addItem(command("Split Right", #selector(splitRight), key: rightArrow, modifiers: [.command, .control]))
        menu.addItem(command("Split Down", #selector(splitDown), key: downArrow, modifiers: [.command, .control]))
        menu.addItem(.separator())
        menu.addItem(command("Other Pane", #selector(focusOtherPane), key: "]", modifiers: [.command, .option]))
        menu.addItem(command("Swap Panes", #selector(swapPanes)))
        menu.addItem(command("Stack Pages", #selector(toggleSplitAxis)))
        menu.addItem(.separator())
        menu.addItem(command("Exit Split", #selector(exitSplit)))
        menu.addItem(command("Close Other Pages", #selector(closeOtherPanes)))
        return menu
    }

    /// The keyboard route to what dragging does: one item per corner, the current one checked.
    private func playerCornerMenu() -> NSMenu {
        let menu = NSMenu()
        for corner in MediaPlayerCorner.allCases {
            let item = command(corner.title, #selector(movePlayerToCorner(_:)))
            item.representedObject = corner.rawValue
            menu.addItem(item)
        }
        return menu
    }

    private func historyMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(command("Back", #selector(goBack), key: "["))
        menu.addItem(command("Forward", #selector(goForward), key: "]"))
        menu.addItem(hidden(command("Back", #selector(goBack), key: String(UnicodeScalar(NSLeftArrowFunctionKey)!))))
        menu.addItem(hidden(command("Forward", #selector(goForward), key: String(UnicodeScalar(NSRightArrowFunctionKey)!))))
        menu.addItem(.separator())
        menu.addItem(command("Show All History", #selector(showHistory), key: "y"))
        menu.addItem(command("Clear History…", #selector(clearHistory)))
        return menu
    }

    private func windowMenu() -> NSMenu {
        let menu = NSMenu(title: "Window")
        menu.addItem(chain("Minimize", #selector(NSWindow.performMiniaturize(_:)), key: "m"))
        menu.addItem(chain("Zoom", #selector(NSWindow.performZoom(_:))))
        menu.addItem(.separator())
        menu.addItem(command("Show Next Tab", #selector(nextTab), key: "]", modifiers: [.command, .shift]))
        menu.addItem(command("Show Previous Tab", #selector(previousTab), key: "[", modifiers: [.command, .shift]))
        menu.addItem(hidden(command("Show Next Tab", #selector(switchToNextTab), key: "\t", modifiers: [.control])))
        menu.addItem(hidden(command(
            "Show Previous Tab",
            #selector(switchToPreviousTab),
            key: "\t",
            modifiers: [.control, .shift]
        )))
        menu.addItem(.separator())
        for slot in 1...8 {
            menu.addItem(hidden(command("Show Tab \(slot)", #selector(showTabAtIndex(_:)), key: "\(slot)")))
            menu.items.last?.tag = slot - 1
        }
        menu.addItem(hidden(command("Show Last Tab", #selector(showLastTab), key: "9")))
        for slot in SpaceShortcut.slots {
            menu.addItem(hidden(command("Show Space \(slot)", #selector(showSpaceAtIndex(_:)), key: "\(slot)", modifiers: SpaceShortcut.modifiers)))
            menu.items.last?.tag = slot - 1
        }
        menu.addItem(.separator())
        menu.addItem(chain("Bring All to Front", #selector(NSApplication.arrangeInFront(_:))))
        return menu
    }

    // MARK: - Commands

    @objc private func showAbout() {
        BuildIdentity.showAboutPanel()
    }

    @objc private func openSettings() {
        coordinator.openSettings()
    }

    @objc private func checkForUpdates() {
        (application?.updates ?? coordinator.updates).checkNow()
    }
    @objc private func showReleaseNotes() {
        coordinator.showReleaseNotes()
    }

    @objc private func openDownloads() {
        coordinator.openSettings(.downloads)
    }
    @objc private func newTab() {
        coordinator.requestNewTab()
    }
    @objc private func newWindow() {
        if let coordinator = application?.activeCoordinator ?? fallbackCoordinator {
            coordinator.requestNewWindow()
        } else {
            application?.newWindow(profile: ProfileStore.shared.current)
        }
    }
    @objc private func newPrivateWindow() {
        if let coordinator = application?.activeCoordinator ?? fallbackCoordinator {
            coordinator.requestNewWindow(isPrivate: true)
        } else {
            application?.newWindow(profile: .privateBrowsing(), settingsOwner: ProfileStore.shared.current)
        }
    }

    @objc private func reopenClosedWindow() {
        application?.reopenLastClosedWindow()
    }
    /// ⌘W: a Peek closes first; a pin, favorite or page in a pinned folder unloads; any other tab closes like its sidebar X.
    @objc private func closeOrUnloadTab() {
        if coordinator.closePeek() {
            return
        }
        guard let tab = coordinator.browser.activeTab else { return }
        if tab.isPinnedForProfile {
            coordinator.unloadTab(tab)
        } else {
            coordinator.browser.close([.tab(tab.id)])
        }
    }
    @objc private func freeMemory() {
        coordinator.freeMemory()
    }
    @objc private func reopenClosedTab() {
        if let application, application.activeCoordinator == nil {
            application.reopenLastClosedWindow()
        } else {
            coordinator.browser.reopenLastClosedTab()
        }
    }
    @objc private func openLocation() {
        coordinator.focusAddressBar()
    }
    @objc private func copyPageURL() {
        coordinator.copyCurrentURL()
    }

    @objc private func pinPage() {
        coordinator.togglePin()
    }

    @objc private func returnToPin() {
        guard let tab = coordinator.browser.activeTab else { return }
        coordinator.browser.returnToPin(tab)
    }
    @objc private func openPalette() {
        coordinator.togglePalette()
    }
    @objc private func showHistory() {
        coordinator.showHistory()
    }
    @objc private func reload() {
        coordinator.pageCommandTab?.reload()
    }
    @objc private func hardReload() {
        coordinator.pageCommandTab?.page.reloadFromOrigin()
    }
    @objc private func showWebInspector() {
        coordinator.pageCommandTab?.showWebInspector()
    }
    @objc private func restartPage() {
        coordinator.pageCommandTab?.restartPage()
    }
    @objc private func toggleDevMode(_ sender: NSMenuItem) {
        // The item named a website when it was validated; a page that moved on since is not the one the person chose.
        guard let tab = coordinator.pageCommandTab, let host = sender.representedObject as? String else { return }
        coordinator.setDevMode(!tab.usesDevMode, for: tab, named: host)
    }
    @objc private func stopLoading() {
        coordinator.pageCommandTab?.stopLoading()
    }
    @objc private func goBack() {
        coordinator.pageCommandTab?.goBack()
    }
    @objc private func goForward() {
        coordinator.pageCommandTab?.goForward()
    }
    @objc private func toggleSidebar() {
        coordinator.toggleSidebar()
    }
    @objc private func toggleWindowStyle() {
        coordinator.toggleWindowStyle()
    }
    @objc private func moveMinimalBar() {
        coordinator.moveMinimalBar()
    }
    @objc private func toggleMinimalSidebarPin() {
        coordinator.toggleMinimalSidebarPin()
    }
    @objc private func toggleAgentInspector() {
        coordinator.toggleAgentInspector()
    }
    @objc private func movePlayerToCorner(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let corner = MediaPlayerCorner(rawValue: raw) else { return }
        coordinator.movePlayer(to: corner)
    }

    @objc private func toggleLyrics() {
        coordinator.toggleLyrics()
    }

    @objc private func splitRight() {
        coordinator.splitActiveTab(axis: .sideBySide)
    }
    @objc private func splitDown() {
        coordinator.splitActiveTab(axis: .stacked)
    }
    @objc private func focusOtherPane() {
        coordinator.focusOtherPane()
    }
    @objc private func swapPanes() {
        coordinator.swapSplitPanes()
    }
    @objc private func stopExternalConnections() {
        coordinator.stopExternalConnections()
    }

    @objc private func toggleSplitAxis() {
        coordinator.toggleSplitAxis()
    }
    @objc private func exitSplit() {
        coordinator.exitSplit()
    }
    @objc private func closeOtherPanes() {
        coordinator.closeOtherPanes()
    }

    @objc private func openFind() {
        coordinator.pageCommandTab?.find.open()
    }
    @objc private func findNext() {
        coordinator.pageCommandTab?.find.findNext(backwards: false)
    }
    @objc private func findPrevious() {
        coordinator.pageCommandTab?.find.findNext(backwards: true)
    }

    @objc private func nextTab() {
        coordinator.browser.cycleTab(forward: true)
    }
    @objc private func previousTab() {
        coordinator.browser.cycleTab(forward: false)
    }
    @objc private func switchToNextTab() {
        coordinator.browser.switchTab(forward: true, asTap: coordinator.isControlTap)
    }
    @objc private func switchToPreviousTab() {
        coordinator.browser.switchTab(forward: false)
    }
    @objc private func showTabAtIndex(_ sender: NSMenuItem) {
        coordinator.browser.activateTab(at: sender.tag)
    }
    @objc private func showLastTab() {
        coordinator.browser.activateLastTab()
    }
    @objc private func showSpaceAtIndex(_ sender: NSMenuItem) {
        coordinator.switchToSpace(at: sender.tag)
    }

    @objc private func clearHistory() {
        coordinator.confirmClearHistory()
    }

    @objc private func printPage() {
        coordinator.printActivePage()
    }

    @objc private func actualSize() {
        coordinator.pageCommandTab?.resetZoom()
    }
    @objc private func zoomIn() {
        coordinator.pageCommandTab?.zoomIn()
    }
    @objc private func zoomOut() {
        coordinator.pageCommandTab?.zoomOut()
    }

    @objc private func toggleTranslation() {
        guard let tab = coordinator.pageCommandTab else { return }
        coordinator.toggleTranslation(tab)
    }

    @objc private func toggleReader() {
        coordinator.toggleReader()
    }

    @objc private func toggleReadAloud() {
        coordinator.toggleReadAloud()
    }

    @objc private func stopReadAloud() {
        coordinator.stopReadAloud()
    }

    @objc private func watchPage() {
        coordinator.watchCurrentPage()
    }

    // MARK: - Validation

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {  // swiftlint:disable:this cyclomatic_complexity
        if menuItem.action == #selector(reopenClosedWindow) {
            return application?.canReopenWindow == true
        }
        if let application, application.activeCoordinator == nil {
            return [
                #selector(newWindow), #selector(newTab), #selector(newPrivateWindow),
                #selector(openSettings), #selector(checkForUpdates), #selector(reopenClosedTab), #selector(showAbout),
            ].contains(menuItem.action)
        }
        switch menuItem.action {
        case #selector(goBack):
            return coordinator.pageCommandTab?.canGoBack ?? false
        case #selector(goForward):
            return coordinator.pageCommandTab?.canGoForward ?? false
        case #selector(actualSize):
            return coordinator.pageCommandTab?.isZoomed ?? false
        case #selector(copyPageURL):
            guard let tab = coordinator.pageCommandTab else { return false }
            return coordinator.linkURL(for: tab) != nil
        case #selector(reload), #selector(hardReload):
            return coordinator.pageCommandTab?.canReload ?? false
        case #selector(zoomIn), #selector(zoomOut), #selector(openFind), #selector(findNext),
             #selector(findPrevious), #selector(printPage):
            return coordinator.pageCommandTab != nil
        case #selector(showWebInspector), #selector(toggleDevMode(_:)):
            return validateDeveloperItem(menuItem)
        case #selector(restartPage):
            guard let tab = coordinator.pageCommandTab else { return false }
            return tab.isMaterialised && !tab.isShowingSystemPage
        case #selector(toggleTranslation):
            let tab = coordinator.pageCommandTab
            let translationTitle: LocalizedStringResource = tab?.shownTranslation.isActive == true ? "Show Original" : "Translate Page"
            menuItem.title = String(localized: translationTitle)
            return tab?.canToggleTranslation ?? false
        case #selector(toggleReader):
            let readerTitle: LocalizedStringResource = coordinator.readerTab?.reader.isActive == true ? "Hide Reader" : "Show Reader"
            menuItem.title = String(localized: readerTitle)
            return coordinator.readerTab?.reader.isAvailable ?? false
        case #selector(toggleReadAloud):
            let reader = coordinator.readerTab?.reader
            let readTitle: LocalizedStringResource = switch reader?.speaker?.state ?? .idle {
            case .idle:
                "Read Aloud"
            case .playing:
                "Pause Reading"
            case .paused:
                "Resume Reading"
            }
            menuItem.title = String(localized: readTitle)
            return reader?.isActive ?? false
        case #selector(stopReadAloud):
            return coordinator.readerTab?.reader.isListening ?? false
        case #selector(watchPage):
            let watching = coordinator.watchMenuState
            menuItem.isHidden = !watching.isShown
            return watching.isEnabled
        case #selector(closeOrUnloadTab):
            let tab = coordinator.browser.activeTab
            let closeTitle: LocalizedStringResource = tab?.isPinnedForProfile == true ? "Unload Tab" : "Close Tab"
            menuItem.title = String(localized: closeTitle)
            return tab != nil
        case #selector(pinPage), #selector(returnToPin):
            return validatePinItem(menuItem)
        case #selector(stopLoading):
            return coordinator.pageCommandTab?.isLoading ?? false
        case #selector(stopExternalConnections):
            return coordinator.hasExternalConnections
        case #selector(splitRight), #selector(splitDown):
            guard coordinator.browser.activeTab != nil else { return false }
            return !(coordinator.browser.activeSplit?.isFull ?? false)
        case #selector(focusOtherPane), #selector(exitSplit), #selector(closeOtherPanes):
            return coordinator.isSplit
        case #selector(swapPanes):
            guard let split = coordinator.browser.activeSplit,
                  let id = coordinator.browser.activeTabID
            else { return false }
            return split.sibling(of: id) != nil
        case #selector(toggleSplitAxis):
            let axisTitle: LocalizedStringResource = coordinator.browser.activeSplit?.axis == .stacked
                ? "Place Side by Side"
                : "Stack Pages"
            menuItem.title = String(localized: axisTitle)
            return coordinator.browser.activeSplit?.axis != nil
        case #selector(reopenClosedTab):
            return coordinator.browser.canReopenClosedTab
        case #selector(nextTab), #selector(previousTab), #selector(showLastTab),
             #selector(switchToNextTab), #selector(switchToPreviousTab):
            return coordinator.browser.currentSpaceTabs.count > 1
        case #selector(showTabAtIndex(_:)):
            return coordinator.browser.currentSpaceTabs.indices.contains(menuItem.tag)
        case #selector(showSpaceAtIndex(_:)):
            return coordinator.spaceEntries.indices.contains(menuItem.tag)
        case #selector(clearHistory):
            return coordinator.browser.history.count > 0
        case #selector(checkForUpdates):
            return coordinator.updates.canCheck
        case #selector(toggleSidebar), #selector(toggleWindowStyle), #selector(moveMinimalBar),
             #selector(toggleMinimalSidebarPin):
            return validateWindowStyleItem(menuItem)
        case #selector(toggleAgentInspector):
            let activityTitle: LocalizedStringResource = coordinator.sidePanel.isShowing(.activity)
                ? "Hide Assistant"
                : "Show Assistant"
            menuItem.title = String(localized: activityTitle)
            return true
        case #selector(movePlayerToCorner(_:)):
            menuItem.state = (menuItem.representedObject as? String) == coordinator.settings.mediaPlayerCorner.rawValue
                ? .on
                : .off
            return coordinator.canMovePlayer
        case #selector(toggleLyrics):
            let lyricsTitle: LocalizedStringResource = coordinator.sidePanel.isShowing(.lyrics)
                ? "Hide Lyrics"
                : "Show Lyrics"
            menuItem.title = String(localized: lyricsTitle)
            menuItem.isHidden = !coordinator.settings.showsLyrics
            return coordinator.settings.showsLyrics
        default:
            return true
        }
    }

    /// ⌘D names what it will do: pin the page, update a wandering pin's page to the one on screen, or unpin a tab showing
    /// its pinned page. Back to Pinned Page answers only while the pinned tab is away.
    /// The two items of View > Developer that act on the page's website.
    private func validateDeveloperItem(_ menuItem: NSMenuItem) -> Bool {
        let tab = coordinator.pageCommandTab
        if menuItem.action == #selector(showWebInspector) {
            // Chromium has no inspector in WSurf: the item is hidden for such a tab instead of left there doing nothing.
            menuItem.isHidden = tab.map { !$0.inspectsWithWebKit } ?? false
            return tab?.canShowWebInspector ?? false
        }
        guard let tab, let host = DevMode.host(of: URL(string: tab.urlString)) else {
            menuItem.title = String(localized: "Developer Mode for This Website")
            menuItem.state = .off
            menuItem.representedObject = nil
            return false
        }
        menuItem.representedObject = host
        menuItem.title = String(localized: "Developer Mode for “\(host)”")
        menuItem.state = tab.usesDevMode ? .on : .off
        return true
    }

    private func validatePinItem(_ menuItem: NSMenuItem) -> Bool {
        let tab = coordinator.browser.activeTab
        guard menuItem.action == #selector(pinPage) else { return tab?.isAwayFromPin == true }
        let title: LocalizedStringResource = if tab?.isAwayFromPin == true {
            "Update Pinned URL"
        } else if tab?.isShowingPin == true {
            "Unpin Tab"
        } else {
            "Pin This Page"
        }
        menuItem.title = String(localized: title)
        return tab != nil
    }

    /// Hide Sidebar, which shows and hides the tab list in the Minimal window, the window style, the Minimal bar's edge and
    /// keeping the Minimal tab list open.
    private func validateWindowStyleItem(_ menuItem: NSMenuItem) -> Bool {
        let isMinimal = coordinator.isMinimal
        let title: LocalizedStringResource
        switch menuItem.action {
        case #selector(toggleWindowStyle):
            title = isMinimal ? "Use Standard Window Style" : "Use Minimal Window Style"
        case #selector(moveMinimalBar):
            title = coordinator.settings.minimalBarEdge == .top ? "Move Bar to Bottom" : "Move Bar to Top"
        case #selector(toggleMinimalSidebarPin):
            title = "Keep Sidebar Open"
            menuItem.state = coordinator.keepsMinimalSidebarOpen ? .on : .off
        default:
            if isMinimal {
                title = coordinator.isMinimalTabListOpen || coordinator.keepsMinimalSidebarOpen ? "Hide Tabs" : "Show Tabs"
            } else {
                title = coordinator.sidebar.isVisible ? "Hide Sidebar" : "Show Sidebar"
            }
        }
        menuItem.title = String(localized: title)
        let isMinimalOnly = menuItem.action == #selector(moveMinimalBar) || menuItem.action == #selector(toggleMinimalSidebarPin)
        return !isMinimalOnly || isMinimal
    }

    // MARK: - Building blocks

    private func submenu(_ menu: NSMenu, titled title: LocalizedStringResource) -> NSMenuItem {
        let name = String(localized: title)
        let holder = NSMenuItem(title: name, action: nil, keyEquivalent: "")
        menu.title = name
        holder.submenu = menu
        return holder
    }

    private func command(
        _ title: LocalizedStringResource,
        _ action: Selector,
        key: String = "",
        modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        let item = makeItem(title, action, key: key, modifiers: modifiers)
        item.target = self
        return item
    }

    private func chain(
        _ title: LocalizedStringResource,
        _ action: Selector,
        key: String = "",
        modifiers: NSEvent.ModifierFlags = .command
    ) -> NSMenuItem {
        makeItem(title, action, key: key, modifiers: modifiers)
    }

    private func makeItem(
        _ title: LocalizedStringResource,
        _ action: Selector,
        key: String,
        modifiers: NSEvent.ModifierFlags
    ) -> NSMenuItem {
        var key = key
        var modifiers = modifiers
        if modifiers.contains(.shift), key.count == 1, key >= "a", key <= "z" {
            key = key.uppercased()
            modifiers.remove(.shift)
        }
        let item = NSMenuItem(title: String(localized: title), action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        return item
    }

    private func hidden(_ item: NSMenuItem) -> NSMenuItem {
        item.isHidden = true
        item.isAlternate = false
        item.allowsKeyEquivalentWhenHidden = true
        return item
    }
}
