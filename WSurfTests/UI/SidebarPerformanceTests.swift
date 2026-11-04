// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import AppKit
import SwiftUI
import XCTest

@testable import WSurf

// XCTest owns and runs one instance serially. Sendable lets its synchronous measurement callback enter the main actor.
/// The real sidebar in a window with the chip a drag carries, laid out and drawn after each click and after each step of a drag:
/// what they cost the rows that did not change. Each click and step changes the state the way the row's tap and the list's drag
/// gesture do, which keeps the events and their timing out of the measurement. Budgeted in Tools/check-performance.sh.
nonisolated final class SidebarPerformanceTests: XCTestCase, @unchecked Sendable {
    @MainActor
    private final class Rig {
        let coordinator: AppCoordinator
        let window: NSWindow
        let host: NSHostingView<AnyView>
        /// Two blank tabs at the top of the list: a click shows the Start page and loads nothing.
        let first: BrowserTab
        let second: BrowserTab

        var browser: BrowserModel {
            coordinator.browser
        }

        /// `pages` unloaded tabs, in `folders` open folders when there are any, under two blank tabs. `everyRow` draws every
        /// row at once, as the list does while VoiceOver, Switch Control or Full Keyboard Access is on; otherwise only the rows
        /// near the window are drawn.
        init(pages count: Int, folders: Int, everyRow: Bool) {
            let coordinator = AppCoordinator(browser: BrowserModel(database: .temporary()))
            self.coordinator = coordinator
            let browser = coordinator.browser
            let pages = (0..<count).map { browser.addPage("https://fixture-\($0).example/") }
            if folders > 0 {
                let size = count / folders
                for index in 0..<folders {
                    browser.createFolder(named: "Folder \(index)", containing: Array(pages[index * size..<(index + 1) * size]))
                }
            }
            second = browser.newTab()
            first = browser.newTab()
            let sidebar = ZStack {
                Sidebar(browser: browser, coordinator: coordinator)
                SidebarDragOverlay(browser: browser, model: coordinator.sidebarDrag)
            }
            .frame(width: 280, height: 700)
            .environment(\.sidebarDrawsEveryRow, everyRow)
            host = NSHostingView(rootView: AnyView(sidebar))
            host.frame = CGRect(x: 0, y: 0, width: 280, height: 700)
            window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            draw()
            draw()
        }

        func draw() {
            RunLoop.current.run(until: Date())
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
        }

        /// A plain click on the row of `tab`: what `SidebarTabRow.tapped` does, then the list drawn.
        func click(_ tab: BrowserTab) {
            let selection = browser.sidebarSelection
            selection.anchor(on: .tab(tab.id))
            coordinator.tabPreview.dismiss()
            coordinator.openTab(tab)
            selection.excludeFavorites(browser.favorites)
            draw()
        }

        func close() {
            window.contentView = nil
            window.close()
            browser.cancelPendingSave()
        }
    }

    /// Ten clicks that switch between two tabs at the top of a 300-tab sidebar that draws every row, as it does while VoiceOver,
    /// Switch Control or Full Keyboard Access is on. A click marks nothing, so only the two rows whose state changes need drawing.
    func testClickingBetweenTwoTabsOfASidebarThatDrawsEveryRow() {
        MainActor.assumeIsolated {
            let rig = Rig(pages: 300, folders: 0, everyRow: true)
            rig.click(rig.second)
            XCTAssertTrue(rig.browser.activeTab === rig.second, "a click on a row opens its tab")
            measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: .budgeted) {
                for _ in 0..<5 {
                    rig.click(rig.first)
                    rig.click(rig.second)
                }
            }
            XCTAssertTrue(rig.browser.activeTab === rig.second)
            XCTAssertTrue(rig.browser.sidebarSelection.isEmpty)
            rig.close()
        }
    }

    /// A background tab opened and closed three times over a sidebar of 1,000 tabs in 25 open folders that is on screen, drawn after
    /// each. The new row is far below the rows that are drawn, so no drawn row has changed and none should have to read every tab
    /// to draw again.
    func testOpeningAndClosingBackgroundTabsOverAThousandRowSidebar() {
        MainActor.assumeIsolated {
            let rig = Rig(pages: 1_000, folders: 25, everyRow: false)
            let count = rig.browser.tabs.count
            measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: .budgeted) {
                for _ in 0..<3 {
                    let tab = rig.browser.newTab(url: nil, activate: false)
                    rig.draw()
                    rig.browser.close(tab)
                    rig.draw()
                }
            }
            XCTAssertEqual(rig.browser.tabs.count, count, "every tab that a pass opened was closed")
            rig.close()
        }
    }

    /// The Command key pressed and released five times over the same sidebar, drawn after each. A row changes with the key only
    /// while it is hovered, so no other row needs to draw again.
    func testPressingCommandOverAThousandRowSidebar() {
        MainActor.assumeIsolated {
            let rig = Rig(pages: 1_000, folders: 25, everyRow: false)
            measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: .budgeted) {
                for _ in 0..<5 {
                    rig.coordinator.linkModifiers = [.command]
                    rig.draw()
                    rig.coordinator.linkModifiers = []
                    rig.draw()
                }
            }
            XCTAssertTrue(rig.coordinator.linkModifiers.isEmpty)
            rig.close()
        }
    }

    /// One row lifted and moved sideways in 30 steps over a sidebar of 1,000 tabs in 25 open folders, drawn after every step, then
    /// put down where it was. The row keeps its place, so a step moves only the chip under the pointer.
    func testDraggingARowInPlaceOverAThousandRowSidebar() {
        MainActor.assumeIsolated {
            let rig = Rig(pages: 1_000, folders: 25, everyRow: false)
            let model = rig.coordinator.sidebarDrag
            let lead = SidebarItem.tab(rig.first.id)
            guard let origin = model.frames[lead] else {
                XCTFail("the first row is not drawn")
                return
            }
            measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: .budgeted) {
                // What `WorkspaceList.dragChanged` writes when a drag starts and at each step, and `dragEnded` when it lands.
                model.drag = SidebarDrag(
                    items: [lead], lead: lead, origin: origin, tree: rig.browser.sidebarTree, keepsSection: false, wasKept: false
                )
                rig.draw()
                for step in 1...30 {
                    model.translation = CGSize(width: CGFloat(step) * 2, height: 0)
                    rig.draw()
                }
                model.drag = nil
                rig.draw()
            }
            rig.close()
        }
    }
}
