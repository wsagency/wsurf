// SPDX-FileCopyrightText: 2026 Kavoye
// SPDX-License-Identifier: Apache-2.0
// Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

import Testing

@testable import WSurf

@MainActor
struct AppleSpeechVoiceCatalogTests {
    @Test func readingAnUnpreparedCatalogDoesNotEnumerateVoices() {
        var enumerations = 0
        let catalog = AppleSpeechVoiceCatalog {
            enumerations += 1
            return []
        }

        #expect(catalog.voice == nil)
        #expect(enumerations == 0)
    }

    @Test func anEmptyCatalogIsCachedAcrossRepeatedPreparationAndTaskReads() async {
        var enumerations = 0
        let catalog = AppleSpeechVoiceCatalog {
            enumerations += 1
            return []
        }
        catalog.prepare()

        await Task { @MainActor in
            for _ in 0..<10 {
                catalog.prepare()
                #expect(catalog.voice == nil)
            }
        }.value

        #expect(enumerations == 1)
    }
}
