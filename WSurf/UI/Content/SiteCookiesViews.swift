// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: BUSL-1.1

import SwiftUI

/// One website's cookies, shared by the summary row and the list that manages them, so a removal in one updates the other.
@MainActor
@Observable
final class SiteCookiesModel {
    let host: String
    let context: BrowserProfileContext
    /// Nil while counting.
    private(set) var cookies: [SiteCookie]?
    private(set) var chromiumUnavailable = false
    /// Chromium may hold cookies for this website but is not running; Load Chromium Cookies or a deletion starts it.
    private(set) var chromiumNotLoaded = false
    /// Bumped by every reload and removal, so a slower listing that began before one cannot put back what it removed.
    private var generation = 0
    /// The ids of the cookies being removed, and `allID` while every cookie is.
    private(set) var deleting: Set<String> = []
    var error: String?
    /// Set when Clear Cached Favicon ran, so the button can say so.
    private(set) var clearedFavicon = false

    static let allID = "*"

    init(host: String, context: BrowserProfileContext) {
        self.host = host
        self.context = context
    }

    var countLabel: LocalizedStringResource {
        switch cookies?.count {
        case nil:
            "Counting…"
        case 0:
            "None"
        case let count?:
            "\(count) cookies"
        }
    }

    var hasBothEngines: Bool {
        Set((cookies ?? []).map(\.engine)).count > 1
    }

    /// Whether Delete All can remove something: a listed cookie, or Chromium's, which are not listed until it is loaded.
    var canDeleteAll: Bool {
        guard let cookies, !deleting.contains(Self.allID) else { return false }
        return !cookies.isEmpty || chromiumNotLoaded
    }

    /// Lists the cookies again. Opening a panel lists without starting Chromium; Load Chromium Cookies passes true.
    func reload(allowChromiumStartup: Bool = false) async {
        generation &+= 1
        let started = generation
        let listing = await SiteCookies.list(host: host, context: context, allowChromiumStartup: allowChromiumStartup)
        guard started == generation else { return }
        cookies = listing.cookies
        chromiumUnavailable = listing.chromiumUnavailable
        chromiumNotLoaded = listing.chromiumNotLoaded
    }

    func loadChromium() async {
        await reload(allowChromiumStartup: true)
    }

    func delete(_ cookie: SiteCookie) async {
        generation &+= 1
        deleting.insert(cookie.id)
        defer { deleting.remove(cookie.id) }
        do {
            try await SiteCookies.delete(cookie, context: context)
            cookies?.removeAll { $0.id == cookie.id }
        } catch {
            self.error = error.localizedDescription
            await reload()
        }
    }

    func deleteAll() async {
        generation &+= 1
        deleting.insert(Self.allID)
        defer { deleting.remove(Self.allID) }
        do {
            try await SiteCookies.deleteAll(host: host, context: context)
        } catch {
            self.error = error.localizedDescription
        }
        await reload()
    }

    func clearFavicon() {
        context.forgetFavicon(host: host)
        clearedFavicon = true
    }
}

/// A cookie's name, where it applies and its flags; opened, every attribute and the value, with Copy Value. Only an opened row
/// shows the value, so a list of session cookies is not on screen at once.
struct SiteCookieRow: View {
    let cookie: SiteCookie
    let isDeleting: Bool
    let onDelete: () -> Void

    @State private var isExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(Theme.Motion.quick) { isExpanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: cookie.name.isEmpty ? " " : cookie.name)
                                .font(Theme.Font.rowTitle)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text(verbatim: "\(cookie.displayDomain)\(cookie.path)")
                                .font(Theme.Font.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                        Spacer(minLength: 6)
                        Tag(cookie.engine.label)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(verbatim: cookie.name))
                .accessibilityValue(Text(verbatim: "\(String(localized: cookie.engine.label)), \(cookie.displayDomain)"))
                .accessibilityHint(isExpanded ? Text("Hides the cookie’s details") : Text("Shows the cookie’s details"))

                if isDeleting {
                    Spinner(size: 12)
                        .foregroundStyle(.secondary)
                        .frame(width: 22)
                } else {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Delete Cookie")
                    .accessibilityLabel(Text("Delete cookie \(cookie.name)"))
                }
            }

            if isExpanded {
                details
                    .padding(.leading, 15)
                    .transition(.opacity)
            }
        }
        .padding(.vertical, 6)
    }

    private var expiry: String {
        cookie.expiresDate?.formatted(date: .abbreviated, time: .shortened) ?? String(localized: "Session")
    }

    private var flags: String {
        var flags: [String] = []
        if cookie.isSecure { flags.append("Secure") }
        if cookie.isHTTPOnly { flags.append("HttpOnly") }
        return flags.isEmpty ? String(localized: "None") : flags.joined(separator: ", ")
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 6) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 10, verticalSpacing: 3) {
                attribute("Domain", cookie.domain)
                attribute("Path", cookie.path)
                attribute("Expires", expiry)
                attribute("Flags", flags)
                attribute("SameSite", cookie.sameSite ?? String(localized: "Not set"))
                if let partition = cookie.partitionKey {
                    attribute("Partition", partition)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Value")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                Text(verbatim: cookie.value.isEmpty ? " " : cookie.value)
                    .font(Theme.Font.monoCaption)
                    .lineLimit(3)
                    .truncationMode(.tail)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                Button {
                    SecretClipboard.shared.copy(cookie.value, from: .cookie)
                } label: {
                    Label("Copy Value", systemImage: "doc.on.doc")
                        .font(Theme.Font.label)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(cookie.value.isEmpty)
            }
        }
    }

    private func attribute(_ label: LocalizedStringResource, _ value: String) -> some View {
        GridRow {
            Text(label)
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: value)
                .font(Theme.Font.caption)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}

/// The cookies the list shows: those whose name or domain contains `query`, of `engine` when one is chosen.
enum SiteCookieFilter {
    static func apply(_ cookies: [SiteCookie], query: String, engine: BrowserEngine?) -> [SiteCookie] {
        let needle = query.trimmingCharacters(in: .whitespaces)
        return cookies.filter { cookie in
            (engine == nil || cookie.engine == engine)
                && (needle.isEmpty || cookie.name.localizedStandardContains(needle)
                    || cookie.domain.localizedStandardContains(needle))
        }
    }
}

// MARK: - Website Settings popover

struct SiteCookiesSection: View {
    let tab: BrowserTab
    let host: String

    @State private var model: SiteCookiesModel?
    @State private var isManaging = false
    @State private var confirmingDelete = false

    var body: some View {
        SiteControlGroup {
            if let model {
                SiteCookiesSummary(model: model, isManaging: $isManaging, confirmingDelete: $confirmingDelete)
            }
        }
        .task(id: host) {
            let next = SiteCookiesModel(host: host, context: tab.context)
            model = next
            await next.reload()
        }
    }
}

private struct SiteCookiesSummary: View {
    let model: SiteCookiesModel
    @Binding var isManaging: Bool
    @Binding var confirmingDelete: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                    .accessibilityHidden(true)

                Text("Cookies")
                    .font(.system(size: 12.5))

                Spacer(minLength: 12)

                if model.cookies == nil {
                    ProgressView()
                        .controlSize(.mini)
                        .accessibilityLabel(Text("Counting cookies"))
                } else {
                    Text(model.countLabel)
                        .font(Theme.Font.label)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            .padding(.horizontal, SiteControlsMetrics.inset)
            .frame(minHeight: 32)
            .accessibilityElement(children: .combine)

            if confirmingDelete {
                confirmation
            } else {
                actions
            }
        }
        .alert(
            "Couldn’t update cookies",
            isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.error ?? String(localized: "Try again."))
        }
    }

    private var actions: some View {
        HStack(spacing: 8) {
            Button("Manage…") {
                isManaging = true
            }
            .popover(isPresented: $isManaging, arrowEdge: .trailing) {
                SiteCookiesManagerPopover(model: model)
            }

            Spacer(minLength: 0)

            Button("Delete Cookies", role: .destructive) {
                confirmingDelete = true
            }
            .disabled(!model.canDeleteAll)
        }
        .controlSize(.small)
        .padding(.horizontal, SiteControlsMetrics.inset)
        .padding(.leading, 28)
        .padding(.bottom, 4)
    }

    private var confirmation: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Delete cookies for \(model.host) in WebKit and Chromium, and its cached icon? You’ll be signed out of this website.")
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel", role: .cancel) {
                    confirmingDelete = false
                }
                .keyboardShortcut(.cancelAction)
                Button("Delete", role: .destructive) {
                    confirmingDelete = false
                    Task { await model.deleteAll() }
                }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, SiteControlsMetrics.inset)
        .padding(.leading, 28)
        .padding(.bottom, 6)
    }
}

/// The whole list of a website's cookies, beside Website Settings.
struct SiteCookiesManagerPopover: View {
    let model: SiteCookiesModel

    @State private var query = ""
    @State private var engine: BrowserEngine?
    @State private var confirmingDeleteAll = false

    private var shown: [SiteCookie] {
        SiteCookieFilter.apply(model.cookies ?? [], query: query, engine: engine)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.horizontal, SiteControlsMetrics.inset)
            list
            Divider().padding(.horizontal, SiteControlsMetrics.inset)
            footer
        }
        .frame(width: 440)
        .background(.ultraThickMaterial)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Cookies")
                        .font(.system(size: 13, weight: .semibold))
                    Text(verbatim: model.host)
                        .font(Theme.Font.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Text(model.countLabel)
                    .font(Theme.Font.label)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            HStack(spacing: 8) {
                TextField("Search cookies", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                if model.hasBothEngines {
                    Picker("Engine", selection: $engine) {
                        Text("All").tag(BrowserEngine?.none)
                        ForEach(BrowserEngine.allCases, id: \.self) {
                            Text($0.label).tag(BrowserEngine?.some($0))
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .controlSize(.small)
                    .fixedSize()
                }
            }
        }
        .padding(SiteControlsMetrics.inset)
    }

    @ViewBuilder
    private var list: some View {
        if model.cookies == nil {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Counting…")
                    .font(Theme.Font.label)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: 90)
        } else if shown.isEmpty {
            Text(model.cookies?.isEmpty == true ? "This website has no cookies." : "No cookie matches what you typed.")
                .font(Theme.Font.label)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 90)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, cookie in
                        if index > 0 {
                            Divider()
                        }
                        SiteCookieRow(cookie: cookie, isDeleting: model.deleting.contains(cookie.id)) {
                            Task { await model.delete(cookie) }
                        }
                    }
                }
                .padding(.horizontal, SiteControlsMetrics.inset)
            }
            .frame(minHeight: 90, maxHeight: 360)
        }
        if model.chromiumUnavailable {
            Text("Chromium cookies aren’t shown. Open this website in a Chromium tab to see them.")
                .font(Theme.Font.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, SiteControlsMetrics.inset)
                .padding(.bottom, 6)
        }
        if model.chromiumNotLoaded {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("Chromium isn’t running, so its cookies aren’t listed yet.")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Button("Load Chromium Cookies") {
                    Task { await model.loadChromium() }
                }
                .controlSize(.small)
            }
            .padding(.horizontal, SiteControlsMetrics.inset)
            .padding(.bottom, 6)
        }
    }

    @ViewBuilder
    private var footer: some View {
        HStack(spacing: 8) {
            if confirmingDeleteAll {
                Text("Delete every cookie and the cached icon?")
                    .font(Theme.Font.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Button("Cancel", role: .cancel) { confirmingDeleteAll = false }
                    .keyboardShortcut(.cancelAction)
                Button("Delete All", role: .destructive) {
                    confirmingDeleteAll = false
                    Task { await model.deleteAll() }
                }
            } else {
                Button(model.clearedFavicon ? "Cached Favicon Cleared" : "Clear Cached Favicon") {
                    model.clearFavicon()
                }
                .disabled(model.clearedFavicon)
                Spacer(minLength: 0)
                if model.deleting.contains(SiteCookiesModel.allID) {
                    ProgressView().controlSize(.mini)
                }
                Button("Delete All…", role: .destructive) { confirmingDeleteAll = true }
                    .disabled(!model.canDeleteAll)
            }
        }
        .controlSize(.small)
        .padding(SiteControlsMetrics.inset)
    }
}
