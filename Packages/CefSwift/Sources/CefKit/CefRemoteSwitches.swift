// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

// D4-20: what a `hello` may ask of the Chromium service, in one place that WSurf's client and the service both read. The client
// filters what it sends (it is trusted, so this only keeps a bug from loosening Chromium); the service refuses anything else
// before CEF starts (it does not trust what reaches it: the service must hold up if a caller other than WSurf's client says hello).

import Foundation

public enum CefRemoteSwitches {
    /// Every Chromium switch WSurf adds, with the value it gives it (nil: the switch has none). None may loosen what a `file:` page
    /// can read: left alone, Chromium stops a local page from fetching other local files. WSurf's in-process Chromium starts with
    /// exactly this list (`ChromiumRuntime.extraCommandLineSwitches`), and `ChromiumFileAccessTests` guards it.
    public static let allowed: [String: String?] = [
        "disable-backgrounding-occluded-windows": nil,
        // Without it Chrome's own sign-in prompt takes HTTP authentication, and inside WSurf it ends in
        // ERR_INVALID_AUTH_CREDENTIALS; with it CEF asks `get_auth_credentials`, which shows WSurf's sheet.
        "disable-chrome-login-prompt": nil,
    ]

    /// The file the service's log may go to, in the folder of the staged run (the parent of the root: `<home>/Chromium`) or in the
    /// root itself. Any other path is refused by the service; WSurf names it only in a staged DEBUG run.
    public static let logFileName = "chromium-service.log"

    /// `requested` without what is not allowed: the name and the value must both be exactly an allowed one.
    public static func filter(_ requested: [String: String?]) -> [String: String?] {
        requested.filter { name, value in
            guard let wanted = allowed[name] else { return false }
            return wanted == value
        }
    }

    /// The names in `wire` (a hello's switches as they travel: a switch with no value has the empty string) that are not allowed,
    /// sorted. Empty when the hello asks for nothing WSurf does not.
    public static func refused(wire: [String: String]) -> [String] {
        wire.filter { name, value in
            guard let wanted = allowed[name] else { return true }
            return (wanted ?? "") != value
        }.keys.sorted()
    }

    /// The only two paths a log file may have, for a canonical `root`. A path is compared after the service resolved it, so a link
    /// that leads elsewhere is not one of them.
    public static func logFileCandidates(root: String) -> [String] {
        let parent = (root as NSString).deletingLastPathComponent
        return [root, parent].map { ($0 as NSString).appendingPathComponent(logFileName) }
    }
}
