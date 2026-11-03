// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import CCef
import Foundation

extension ChromiumPage {
    /// Chromium's DevTools in a window of its own, over the element at `point` (the browser's own coordinates) when given. CEF
    /// brings the window forward when it is already open.
    func showDevTools(inspectAt point: CGPoint? = nil) {
        withHost { host in
            var info = cef_window_info_t()
            info.size = MemoryLayout<cef_window_info_t>.stride
            info.bounds = cef_rect_t(x: 0, y: 0, width: 900, height: 700)
            info.runtime_style = CEF_RUNTIME_STYLE_DEFAULT
            var settings = cef_browser_settings_t()
            settings.size = MemoryLayout<cef_browser_settings_t>.stride
            guard let point else {
                host.pointee.show_dev_tools?(host, &info, nil, &settings, nil)
                return
            }
            var at = cef_point_t(x: Int32(point.x.rounded()), y: Int32(point.y.rounded()))
            host.pointee.show_dev_tools?(host, &info, nil, &settings, &at)
        }
    }

    func closeDevTools() {
        withHost { $0.pointee.close_dev_tools?($0) }
    }

    var hasDevTools: Bool {
        withHost { ($0.pointee.has_dev_tools?($0) ?? 0) != 0 } ?? false
    }

    // MARK: Find

    /// Finds `text` with Chromium's own find, which highlights every match and the active one. `completion` gets whether the page
    /// has a match, once Chromium has counted; the count and the active match are then in `find.latest`. The same text again
    /// moves to the next match (the previous with `backwards`); other text starts a new search. Case is ignored, as in WebKit's.
    func find(_ text: String, backwards: Bool, completion: @escaping @MainActor (Bool) -> Void) {
        let continuing = find.begin(text)
        guard sendFind(text, forward: !backwards, next: continuing) else {
            completion(false)
            return
        }
        find.wait { [weak self] counted in
            // Chromium counts a new search without choosing a match: step on to the first, as a find bar shows it.
            guard let self, !continuing, counted.total > 0, counted.active == 0, find.query == text,
                  sendFind(text, forward: true, next: true)
            else {
                completion(counted.total > 0)
                return
            }
            find.wait { completion($0.total > 0) }
        }
    }

    private func sendFind(_ text: String, forward: Bool, next: Bool) -> Bool {
        withHost { host -> Bool in
            ChromiumInterop.withString(text) { native in
                host.pointee.find?(host, native, forward ? 1 : 0, 0, next ? 1 : 0)
            }
            return true
        } == true
    }

    /// Ends the search: the highlights go, and so does the selection on the active match, as WebKit's find leaves none.
    func stopFinding() {
        find.end()
        withHost { $0.pointee.stop_finding?($0, 1) }
    }
}
