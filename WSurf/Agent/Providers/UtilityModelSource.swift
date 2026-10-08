// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import AnyLanguageModel

@MainActor
enum UtilityModelSource {
    private static let providers = ModelProviderRegistry()
    @TaskLocal static var make: @MainActor @Sendable () -> (any LanguageModel)? = {
        let settings = LLMSettings.current
        let provider = ProviderCatalog.shared.provider(id: settings.providerID) ?? ProviderCatalog.openAI
        return providers.resolve(provider).makeUtilityModel(model: settings.model(for: provider)) ?? onDevice()
    }

    static var isAvailable: Bool {
        make() != nil
    }

    static let onDevice: () -> (any LanguageModel)? = {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        return SystemLanguageModel.default
    }
}
