// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Foundation

extension BrowserSettings {
    var translationTarget: Locale.Language {
        get {
            translationTargetID.isEmpty
                ? TranslationLanguage.preferred
                : Locale.Language(identifier: translationTargetID)
        }
        set { translationTargetID = TranslationLanguage.key(newValue) }
    }

    func alwaysTranslates(_ language: Locale.Language) -> Bool {
        alwaysTranslatedLanguages.contains(TranslationLanguage.key(language))
    }

    func setAlwaysTranslates(_ always: Bool, _ language: Locale.Language) {
        let key = TranslationLanguage.key(language)
        if always {
            alwaysTranslatedLanguages.insert(key)
        } else {
            alwaysTranslatedLanguages.remove(key)
        }
    }
}
