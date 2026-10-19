# Readability 0.6.0

Mozilla Readability, Apache-2.0 (`LICENSE.md` in this folder), copied unmodified.

- Source: <https://github.com/mozilla/readability>, tag `0.6.0` (annotated tag
  `b81a8d97bfd5c6cc6dc2ba7c88eca9e696e62354`, commit
  `04fd32f72b448c12b02ba6c40928b67e510bac49`, `package.json` version 0.6.0).
- Fetched from that tag on 2026-10-19. The three files are byte for byte the
  copies Linen 0.9.0 ships (`Tools/vendored/readability/LICENSE.md` and
  `Linen/Features/Reader/` at commit `116b2ce718c9260a496b5d103a77a21036ce39f8`).
- App copies: `WSurf/Web/Reader/Readability.js` and
  `WSurf/Web/Reader/Readability-readerable.js`. They run only in the
  `WSurfReader` content world and are never edited here.
- `SHA256SUMS` lists every file. From the repository root:
  `shasum -a 256 -c Tools/vendored/readability/SHA256SUMS`.
  `ReaderExtractorTests` checks the bundled copies against it.

To update: fetch the new tag into an empty folder, replace the three files, run
`shasum -a 256` on them into `SHA256SUMS`, and change the version here and in
`Tools/make-acknowledgements.swift`, then regenerate
`WSurf/Support/Acknowledgements.json`.
