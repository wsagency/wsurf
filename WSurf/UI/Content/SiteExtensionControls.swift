// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import SwiftUI

/// The Extensions group of Website Settings: for each extension that runs on this page, a button that blocks it on the
/// website or allows it again. On a Chromium tab it says extensions are off there instead. Nothing on an internal page or
/// when no extension runs here.
struct SiteExtensionControls: View {
    let manager: ExtensionManager
    let tab: BrowserTab

    var body: some View {
        switch manager.siteControls(for: tab) {
        case .none:
            EmptyView()
        case .webKitOnly:
            SiteControlGroup {
                heading
                note("Extensions run only in WebKit tabs. This tab uses Chromium.")
            }
        case .extensions(let controls):
            SiteControlGroup {
                heading
                ForEach(controls) { control in
                    SiteExtensionRow(manager: manager, control: control)
                }
                if manager.profile?.isPrivate == true {
                    note("Blocks made in a private window are forgotten when it closes.")
                }
            }
        }
    }

    private var heading: some View {
        Text("Extensions")
            .font(Theme.Font.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal, SiteControlsMetrics.inset)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }

    private func note(_ text: LocalizedStringResource) -> some View {
        Text(text)
            .font(Theme.Font.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, SiteControlsMetrics.inset)
            .padding(.vertical, 4)
    }
}

private struct SiteExtensionRow: View {
    let manager: ExtensionManager
    let control: ExtensionSiteControl

    /// "this site" only when the click acts on the page's own website; a parent that blocks it is named.
    private var title: LocalizedStringResource {
        if !control.isBlocked {
            return "Block on this site"
        }
        return control.isPageWebsite ? "Allow on this site" : "Allow on \(control.host)"
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 18)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: control.name)
                    .font(.system(size: 12.5))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if control.isBlocked {
                    Text("Blocked on \(control.host)")
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 12)

            Button {
                manager.toggle(control)
            } label: {
                Text(title)
                    .font(Theme.Font.label)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .frame(minHeight: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // The visible words come first so Voice Control still matches them; the name says which extension.
            .accessibilityLabel(Text(verbatim: "\(String(localized: title)), \(control.name)"))
        }
        .padding(.horizontal, SiteControlsMetrics.inset)
        .frame(minHeight: 32)
    }
}
