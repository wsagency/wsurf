// SPDX-FileCopyrightText: 2026 WSurf Agency
// SPDX-License-Identifier: Apache-2.0

import SwiftUI

/// How long a background tab may sit before it unloads: a preset or a custom number of minutes or hours.
struct SleepAfterRow: View {
    @Bindable var settings: BrowserSettings

    private enum Unit: Hashable {
        case minutes
        case hours

        var factor: Int {
            self == .hours ? 60 : 1
        }
    }

    /// Minutes. 0 waits for memory pressure alone.
    private static let presets = [0, 15, 30, 60, 120, 180, 240]
    private static let customChoice = -1

    @State private var isCustom: Bool
    @State private var unit: Unit
    @State private var amount: String
    @FocusState private var amountFocused: Bool
    @State private var isInvalid = false

    init(settings: BrowserSettings) {
        self.settings = settings
        let minutes = settings.sleepAfterMinutes
        _isCustom = State(initialValue: minutes > 0 && !Self.presets.contains(minutes))
        let hours = minutes > 0 && minutes.isMultiple(of: 60)
        _unit = State(initialValue: hours ? .hours : .minutes)
        _amount = State(initialValue: minutes > 0 ? String(minutes / (hours ? 60 : 1)) : "")
    }

    private static func label(for minutes: Int) -> String {
        guard minutes > 0 else { return String(localized: "When memory is low") }
        return Duration.seconds(minutes * 60)
            .formatted(.units(allowed: [.hours, .minutes], width: .wide))
    }

    private var options: [SettingsMenu<Int>.Option] {
        Self.presets.map { .init(value: $0, label: Self.label(for: $0)) }
            + [.init(value: Self.customChoice, label: String(localized: "Custom…"))]
    }

    private var choice: Binding<Int> {
        Binding {
            isCustom ? Self.customChoice : settings.sleepAfterMinutes
        } set: { value in
            isInvalid = false
            isCustom = value == Self.customChoice
            if isCustom {
                let minutes = settings.sleepAfterMinutes
                unit = minutes > 0 && minutes.isMultiple(of: 60) ? .hours : .minutes
                amount = minutes > 0 ? String(minutes / unit.factor) : ""
            } else {
                settings.sleepAfterMinutes = value
            }
        }
    }

    /// The minutes a typed amount means, nil unless it is a whole number above zero within the app's `Int32` minute bound.
    static func minutes(from amount: String, factor: Int) -> Int? {
        let digits = amount.trimmingCharacters(in: .whitespaces)
        guard let value = Int(digits), value > 0, value <= Int(Int32.max) / factor else { return nil }
        return value * factor
    }

    /// What the stored duration is, or why the draft was refused; the draft itself changes nothing until applied.
    private var customCaption: LocalizedStringResource {
        isInvalid
            ? "Enter a whole number greater than zero, no larger than 2,147,483,647 minutes."
            : "Applied: \(Self.label(for: settings.sleepAfterMinutes))"
    }

    /// Applies the draft only when asked to; an invalid draft is flagged and the stored duration stays as it was.
    private func applyAmount() {
        guard let minutes = Self.minutes(from: amount, factor: unit.factor) else {
            isInvalid = true
            return
        }
        isInvalid = false
        settings.sleepAfterMinutes = minutes
        isCustom = !Self.presets.contains(minutes)
        unit = minutes.isMultiple(of: 60) ? .hours : .minutes
        amount = String(minutes / unit.factor)
    }

    var body: some View {
        DetailRow(
            title: "Sleep after",
            caption: """
            Background tabs unload after they have been out of view this long, and reload when you open them. \
            Favorites and tabs that play audio, use a camera or microphone, hold unsaved form input or are \
            downloading stay loaded. Unloaded Chromium tabs restore only their URL.
            """
        ) {
            SettingsMenu(options: options, selection: choice)
        }
        .settingsAnchor("general.sleepAfter")

        if isCustom {
            RowSeparator()

            DetailRow(title: "Custom time", caption: customCaption) {
                HStack(spacing: 8) {
                    FieldChrome(isFocused: amountFocused) {
                        TextField("", text: $amount)
                            .textFieldStyle(.plain)
                            .font(Theme.Font.label)
                            .multilineTextAlignment(.trailing)
                            .focused($amountFocused)
                            .onSubmit(applyAmount)
                            .onChange(of: amount) { isInvalid = false }
                            .accessibilityLabel("Custom time")
                    }
                    SettingsMenu(
                        options: [
                            .init(value: Unit.minutes, label: String(localized: "minutes")),
                            .init(value: Unit.hours, label: String(localized: "hours")),
                        ],
                        selection: $unit
                    )
                    .onChange(of: unit) { isInvalid = false }
                    Button("Apply", action: applyAmount)
                        .disabled(Self.minutes(from: amount, factor: unit.factor) == settings.sleepAfterMinutes)
                }
            }
        }
    }
}
