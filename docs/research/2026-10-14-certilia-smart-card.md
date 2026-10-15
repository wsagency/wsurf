# Certilia smart-card integration feasibility

Research date: 2026-10-14. Research only; no WSurf implementation or deployment.

- Worktree: `/Users/klukacin/projects/wsurf/.worktrees/certilia-smartcard-research-20261014`
- Branch: `feature/certilia-smartcard-research-20261014`
- Base: freshly fetched `origin/main`, `7b99516`.

## User goal and conclusion

The initial goal was to import a card identity once into Credential Vault and then authenticate or sign without a card or Certilia installation. The user subsequently accepted retaining the physical card and asked whether REA-assisted analysis could enable a WSurf-native module/extension instead of a separate Certilia middleware installation.

**The first goal is not supported by Certilia's published card-key policies. The revised goal is technically plausible, but no real-card compatibility has been demonstrated.** It requires native card support, browser client-certificate integration, and separate compatibility work for document-signing portals. A JavaScript browser extension alone cannot replace those native components.

The user selected an independently implemented WSurf-native component, with REA-assisted interoperability research. Requirements now include Certilia and FINA/possibly Asseco devices, enable-triggered loading, toolbar Load/Unload like existing extensions, and later investigation of concrete middleware/website failures. Exact device families and failing scenarios remain unprovided. This route requires exact card/protocol evidence and an authorised interoperability basis. Licensed vendor-library bundling is not the selected implementation. REA is development tooling, not shipped middleware, a driver, a certification, or permission to copy vendor code.

## Why a certificate import cannot replace the card

[Certilia CPS edition 1.2, effective 13 April 2026](https://www.certilia.com/uploads/CERTILIA_Pravilnik_o_postupcima_certificiranja_1_2_d4c50dfce8.pdf):

- Section 6.2.4, page 69: "Privatni ključevi osoba se ne kopiraju."
- Section 6.2.6, page 70: user-card private keys "ne mogu se prenositi između kriptografskih uređaja".
- Section 6.2.7, page 70: after production, the readable private key exists only inside the QSCD.
- Section 6.2.9, page 72: removing the QSCD from its reader deactivates the private key.
- Section 1.4.2: signatures made with an identification certificate are not qualified electronic signatures; a qualified signing certificate may not be used for another purpose.

A public `.cer`/`.crt` certificate contains no private key. A token reference identifies a card-backed key but still needs the card. A genuine exportable `.p12`/`.pfx` identity can be used without its original device, but this is not a supported export route for these Certilia card keys. Certilia's fiscalization/software certificate products are different products and are not interchangeable with a personal card identity.

Cloud/remote signing is also a different identity/service path: the signing operation occurs in the provider's remote QSCD. It does not turn a card private key into a local credential or automatically satisfy arbitrary websites' client-TLS requests.

## Observed vendor package, not a live-card test

Source: [official downloads](https://www.certilia.com/preuzimanja) and [macOS package v3.9.12](https://www.certilia.com/update/Certilia_Middleware_v3.9.12.pkg). The vendor describes middleware as required for activation, website login and signing; macOS 13+ supports Intel and Apple Silicon.

Downloaded and expanded the package inside this worktree without installing it. Executed `pkgutil --payload-files`, `pkgutil --expand-full`, `pkgutil --check-signature`, `file`, `otool -L`, `nm -gU`, `codesign` and `shasum`.

Observed:

- `CertiliaMiddleware.app/Contents/pkcs11/libCertiliaPkcs11.dylib` and another copy in `CertiliaSigner.app`.
- Universal Mach-O: `x86_64` and `arm64`.
- Linked dependencies: system `PCSC.framework`, `libc++`, `libSystem`.
- Exported PKCS#11 symbols include `C_GetFunctionList`, `C_GetSlotList`, `C_Login`, `C_SignInit`, `C_Sign`, and object/certificate discovery operations. Symbol presence does not prove every exported operation is implemented or that a particular card works.
- Package signature: Developer ID Installer, AKD d.o.o., Team ID `AHQWP895JA`; `pkgutil` reported trusted notarization.
- Library signature: valid Developer ID Application, AKD d.o.o., same Team ID, hardened runtime.
- Payload also includes a Certilia signer LaunchAgent. No `.appex` appeared in the inspected package payload.

SHA-256:

| Artifact | SHA-256 |
| --- | --- |
| Official macOS package v3.9.12 | `fdbd37a922256a374a0f0f6a153064da83437ed8992f50dfa0ed3d3998915bac` |
| Middleware PKCS#11 library | `6139215b99a94abed884f607c3bfcb374080b1255e6bf32fb9a17e0bcb749be8` |

No vendor executable/library was executed, no installer was launched, no card session opened, no PIN entered, no private key accessed, and no real login or signature attempted.

## Licensing changes the recommendation

Primary evidence is `Resources/hr.lproj/License.rtf` inside the official macOS package above, decoded with `textutil -convert txt -stdout`.

- Introduction: a separate licence agreement with AKD can supersede this EULA.
- Section 1: "Ne smijete odvajati dijelove komponenti AKD Softvera za korištenje. Nemate pravo distribuiranja AKD Softver."
- Section 3 prohibits reverse engineering/decompilation/disassembly, "osim i samo u onoj mjeri u kojoj je to pravo dopušteno pozitivnim propisima Republike Hrvatske".

Consequently, public availability of the installer is not redistribution permission. Neither REA's MIT licence nor an app-contained library resolves AKD's terms. This report does not determine whether a statutory interoperability exception applies. Obtain suitable AKD terms or legal review before proprietary decompilation/reimplementation or shipping its components. Static package/signature/dependency/export inspection is the limit of the work performed here.

The [Certilia developer portal](https://developer.certilia.com/) requires sign-in. Public research did not establish SDK terms, redistribution permission, or a supported app-bundling contract. No account login was attempted.

## WSurf integration points at the researched base

Paths below are relative to this worktree.

| Area | Current evidence | Required capability |
| --- | --- | --- |
| WebKit TLS | `WSurf/Web/Tabs/BrowserTab+WebKitDelegates.swift:458-493` and `WSurf/Web/Privacy/AuthChallenge.swift:17-31` route non-password/non-server-trust challenges to default handling. No WSurf-supplied client `SecIdentity`. | Handle client-certificate challenges using a compatible identity and native card-backed key. |
| Chromium TLS | `WSurf/Web/Engines/ChromiumClient.swift:752-870` configures request handlers but not client-certificate selection. | Separate engine-specific selection/integration; WebKit support would not prove CEF support. |
| Vault | `WSurf/Web/Credentials/CredentialAccount.swift:58-120,156-182`: passwords, TOTP, ES256 passkeys; passkey PKCS#8 is WebAuthn/RP-bound. `Store/StoreFormat.swift:71-85` has no X.509 subject. | A deliberate card-identity metadata/reference record, not pretending a smart-card key is a passkey or password. Store migration/history/import/export consequences need design. |
| Extension bridge | `WSurf/Extensions/NativeMessaging.swift:73-115` and `ExtensionManager.swift:418-449` support allow-listed native hosts through WebKit extensions. | Reuse where a portal's actual extension/native protocol matches; it is not a generic document-signing implementation. |
| Packaging | `WSurf.xcodeproj/project.pbxproj:484,531` disables app sandbox; hardened runtime is enabled. | Correct native-module signing/discovery and any token-extension entitlements. Do not weaken main-process hardening as a shortcut. |

Scoped repository searches found no Certilia, PKCS#11, CryptoTokenKit, `SecIdentity`, `SecPKCS12Import`, or document-signature implementation in `WSurf/`. Existing server-trust certificate code is not client identity support.

## Native module versus browser extension

[INFERENCE] The minimum coherent shape is a WSurf-native smart-card feature, with a CryptoTokenKit token extension if required to expose the card identity through macOS Security/Keychain APIs. This does not require inventing a general plugin marketplace or storing private card keys in the vault.

- **Card transport/provider:** reuse compatible system support if demonstrated for the exact card; otherwise use an authorised PKCS#11 adapter or an independently implemented PC/SC/card protocol provider.
- **Website login:** WKWebView's native client-certificate path consumes a `SecIdentity` via `URLCredential`. A PKCS#11 object handle is not a `SecIdentity`; finding `C_Sign` is not sufficient TLS integration.
- **Document signing:** the requested format, signing certificate usage, timestamps/validation requirements and portal protocol must match. Login success is not proof of HZMO/Jana or other portal signing support.
- **Vault UX:** store public certificate metadata and a stable card/key reference plus origin policy. Private-key operations run on the card; PIN stays in native user-confirmed authorization, not page JavaScript or a saved vault password. Removing the card prevents subsequent private-key operations; it does not automatically invalidate an already established website session.
- **Browser extension:** optional compatibility layer for a specific website, calling a restricted native component. No arbitrary-origin signing oracle or exposure of keys/PINs to web content.

Apple documents [smart-card token app extensions](https://developer.apple.com/documentation/cryptotokenkit/authenticating-users-with-a-cryptographic-token) and [card-backed keychain references](https://developer.apple.com/documentation/cryptotokenkit/using-cryptographic-assets-stored-on-a-smart-card). Persistent references stop working after token removal (`errSecItemNotFound`); they are not key export. The registration described for system login as `_securityagent` is a different use case and was not performed or proposed here.

An AKD-signed library also has a different Team ID from WSurf. [Apple library-validation rules](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.cs.disable-library-validation) mean a hardened WSurf process cannot simply load arbitrary foreign-team code. Authorised packaging/signing or process isolation must be designed; this research does not recommend disabling library validation globally.

## REA assessment

[REA repository](https://github.com/morluto/rea) describes an agent/CLI toolkit for reverse engineering; it is not a Certilia driver. The [release API](https://api.github.com/repos/morluto/rea/releases/latest) reported stable `rea-agents-6.5.0`, published 2026-10-14, target commit `3b79af28e80785afce9f5998d8f03289402a1847`.

Its [native investigation guide](https://github.com/morluto/rea/blob/main/docs/native-investigation.md) and [CLI guide](https://github.com/morluto/rea/blob/main/docs/cli.md) require Hopper, Ghidra or IDA for general native decompilation/trace workflows. They can assist an authorised analysis of card-protocol handling or PIN/signature call paths. They cannot infer a complete compatible driver from metadata, remove hardware non-exportability, or establish interoperability/QES compliance without real-device and consumer verification.

Pinned REA 6.5.0 was subsequently run using `npm exec --ignore-scripts`, with HOME, TMPDIR and npm cache isolated under this worktree's `build/research`. Actual `--help` confirmed `inspect-macho`; `inspect-macho build/research/pcsc-readers --format json` succeeded on an owned throwaway arm64 PC/SC probe, using the `native-macos` provider without target execution. No REA setup/MCP registration, host configuration changes, decompiler installation or proprietary decompilation was performed. Node v26.9.0 is available; the default `java -version` command reported no Java runtime. This proves static REA tooling readiness, not card-driver correctness.

## Verification limits and concrete next gate

A native Swift probe imported CryptoTokenKit, Security and WebKit and ran successfully. It reported `TKSmartCardSlotManager.default == nil` and zero reported slots, plus availability of the client-certificate authentication constant and WKWebView API. This establishes API availability only; nil is not proof about the user's hardware or exact card support.

A separate C probe compiled with strict warnings and executed only `SCardEstablishContext`, `SCardListReaders` and `SCardReleaseContext`. It returned no reader names. No `SCardConnect`, certificate read or PIN operation was performed. The user was asked for the exact FINA card/token model; hardware-specific acceptance remains blocked.

No app code changed, so no full app build, app UI test or test-suite run is claimed. No hardware compatibility, signing performance, qualified-signature validity, or universal portal support is claimed.

Before implementation: obtain an authorised integration/analysis basis, identify the exact card family and target portal, then use an owned test card to verify certificate discovery, native PIN authorization, a signature against a throwaway challenge, and safe removal/cancellation. Prove client-TLS login and the actual document-signing portal separately. Keep the physical-card requirement visible in Credential Vault.

User hardware answer (2026-10-14): a generic USB smart-card reader and a standard chip card — no vendor model supplied. This matches Certilia's public requirement (ISO7816/PC/SC reader). Consequence for design: card support must be selected by ATR/profile detection at first device contact, with the exact card profile table filled from REA analysis and a real-device probe; the design must not hard-code one card model. Target portals and failing scenarios remain unsupplied.

## Extracted Certilia card and signer facts (static analysis, 2026-10-15)

Static extraction from the retained 3.9.12 payload (strings/otool/nm only; nothing executed; raw notes in ignored `build/research/card-profile-evidence.md`). These are interoperability facts for our independent implementation, not copied code.

**Card registry (15 ATR/ATS strings, exact full-string match; no mask logic found):** AkdEidBaseCard on JCOP 2.4.2 R3/R2 JavaCards (`3BF91300008131FE454A434F503234325233A2`, `3BFE9100FF918171FE400041380011F7B14A434F503234325211`, ATS `0E78F7B102…`/`0E7880B102…`); AkdEidCard `3BFF1300008131FE450031B9640444ECC1…0012`; MupCorporateCard `…0401…0057`, `3B8F8001…00BE`, ATS `1478F7B102…`; AkdEidHealthCard `…0402…0054`/`…00BD`; HlkCorporateCard `…0403…0055`; KidCorporateCard `…0404…0052`; AkdEidGen2Card `3BDF18FF81B1FE451FC39E414B44654944322E302D53534344D1` ("AKDeID2.0-SSCD"); CertiliaGen2Card `3BDD18FF81B1FE451FC39E414B442D43657274696C6961BD` ("AKD-Certilia").

**Protocol:** Gen2 applet AID `A000000167455349474E` ("ESIGN"); Gen1 EF.DIR via AID `A0000005016961736563632E617070` ("iasecc.app"). Headers: SELECT `00A4040C`/`00A40904`/`00A4000C`, GET/PUT DATA `00CB3FFF`/`00DB3FFF`, VERIFY `00200000`, MSE SET `002241A4/B6/B8`, PSO sign `002A9E9A`, decipher `002A8086`. MSE ECDSA templates `8004FF1408008401<keyref>` (SHA-256) / `8004FF15…` (SHA-384); sign accepts only 32/48-byte hashes. Algorithms: ECDSA P-256/P-384, RSA PKCS 1024–2048, ECDH, MD5/SHA-1/SHA-2 digests. PKCS#11 labels "Signature"/"Identification"/"Additonal"(sic)/"Authentication" with " Certificate"/" RSA|EC Public|Private Key" suffixes; token strings manufacturer "AKD", model "Certilia Card". PIN min/max not hardcoded — read from card via GET DATA `4D08 7006BF81<id>`. Secure channel: Gen2 AES-CBC+CMAC, Gen1 3DES retail MAC; no in-dylib caller of `OpenSecureChannel` found, so whether verify/sign requires it is a G3 runtime question.

**Signer:** local HTTPS (cpp-httplib) on port **55554** (immediate value 0xd902; the 55555 in Certilia's public support text appears stale), server certificate CN `esign-local.id.hr`; route `POST /signHash` with JSON fields `hash`, `mimetype`, `verificationCode`, `scope`, `signedHash`, `signerCertificate`, `timeStamp`; CORS allows GET/POST/HEAD/OPTIONS + private-network access; URL scheme `certiliasigner://`; cloud endpoints `https://esign.certilia.com/api/v2/middleware/scheme/init|signed`; LaunchAgent autostart. Whether `esign-local.id.hr` resolves to 127.0.0.1 was not checked (no network).

**Not found:** ATR masks; certificate FIDs; PIN/key references; purposes of `80260000`/`80800000`/`0022C1A4`; per-class Gen1 APDU diffs. These remain G3 real-card discovery items; no values were invented for them.

## FINA: card support and portal bridge are separate

FINA's [macOS Thales guide, revision 1-10/2025](https://rdc.fina.hr/upute/Korisnicka_uputa_za_instalaciju_i_koristenje_Thales_uredaja_na_MacOS.pdf), sections 6.1 and 6.2.2, requires SafeNet Authentication Client followed by SignErgy. SAC supplies device support; SignErgy establishes browser-to-device communication for certificate activation, download and renewal in CMS. The guide names `SafeNetAuthenticationClient.10.9.2499.0.dmg` and links the [official package](https://rdc.fina.hr/download/InstallationSAC.zip). It explicitly limits support to compatible services. A card driver alone therefore does not replace every portal signing protocol.

FINA's [downloads page](https://www.fina.hr/finadigicert/programska-podrska-i-preuzimanje-certifikata) also names ActivClient for other devices. “FINA” is not one card protocol. The user's exact card/token, reader and portal remain necessary inputs; they were not discoverable from the reader-only probe.

[OpenSC's IDPrime driver](https://github.com/OpenSC/OpenSC/blob/master/src/libopensc/card-idprime.c) is LGPL-2.1-or-later and contains support for specific Gemalto IDPrime families. Reuse a compatible existing driver rather than rewrite it, subject to device proof and its licence obligations. This does not establish support for all FINA devices or for Croatian Certilia/eOI.

Asseco may be the SignErgy supplier, but official attribution was not established here. [ASEE Secure Sign](https://see.asseco.com/more-sectors/407/426/881/) supports hardware PKI, cloud and software certificates; that page does not identify SignErgy. Do not conflate that cloud-capable product with a card driver or promise interoperability with an unspecified bank/portal variant.

## Statutory interoperability route

[Croatian ZAPSP, NN 111/2021](https://narodne-novine.nn.hr/clanci/sluzbeni/2021_10_111_1941.html), articles 208 and 209, provides distinct exceptions for authorised observation/testing and necessary, narrowly scoped decompilation for interoperability of an independently created program. Article 209 restricts purpose, disclosure and use to create a program substantially similar in expression; contrary contractual terms are void. [Directive 2009/24/EC](https://eur-lex.europa.eu/legal-content/EN/TXT/HTML/?uri=CELEX:32009L0024), articles 5(3), 6 and 8, supplies the corresponding EU conditions.

These provisions mean the EULA's restriction is not proof that every interoperability analysis is forbidden. They do not establish that this task qualifies: lawful-copy/use authority, the unavailable interoperability information and necessary target functions still need to be established. Public specifications and compatible open-source implementations come first. REA remains a development tool, not a shipped runtime; no proprietary code, embedded Java/Windows emulator, private-key export or vendor-library redistribution is proposed.

## Existing extension lifecycle: reuse the surface, do not assume runtime controls

`ExtensionManager.swift:612-623` persists Enable and immediately loads or unloads a WebKit extension. `start():245-265` loads enabled records, while `actionableExtensions:657-659` excludes unloaded contexts. `contextMenu:793-819` offers pin visibility, options and Disable/Remove, not Load/Unload. `ExtensionsSettingsSection.swift:185-195` binds its toggle to `setEnabled`. No extension idle-unload mechanism was found; sleeping tabs are a separate feature.

The requested native components therefore need distinct persisted enablement and runtime state, not just relabelled Disable. Manual Unload must be honoured by subsequent window/bootstrap and page events, and an enabled/unloaded toolbar entry must remain reachable for Load. An isolated WSurf-owned worker can exit on Unload; that must not be presented as terminating macOS-managed CryptoTokenKit processes or invalidating an existing authenticated web session. Detailed architecture remains subject to user review before product implementation.

## Browser consumption surfaces on macOS (verified 2026-10-14)

| Consumer | Mechanism | Primary source |
| --- | --- | --- |
| Safari | CryptoTokenKit token extension; system copies token identities into Keychain on insertion. No PKCS#11 path documented. | [Apple CTK](https://developer.apple.com/documentation/cryptotokenkit/using-cryptographic-assets-stored-on-a-smart-card), [Apple deployment guide](https://support.apple.com/guide/deployment/supported-smart-card-functions-on-mac-depc47f60521/web) |
| Chrome / Chromium | Keychain only: `net/ssl/client_cert_store_mac.cc` (`SecItemCopyMatching`, `kSecClassIdentity`). No PKCS#11 module loading on macOS. Chromium bug 41351500 (CTK intermediates not fetched) is known only from an inaccessible search snippet; fix status unverified — chain handling is a verification item, not a confirmed current defect. | [Chromium source](https://chromium.googlesource.com/chromium/src/+/main/net/ssl/client_cert_store_mac.cc) |
| CEF (WSurf Chromium engine) | `CefRequestHandler::OnSelectClientCertificate` callback; certificate list comes from Chromium `net`, i.e. Keychain on macOS. | [CEF header](https://bitbucket.org/chromiumembedded/cef/raw/master/include/cef_request_handler.h) |
| Firefox | Own NSS PKCS#11 module database; GUI load, WebExtension `pkcs11.installModule()`, or `SecurityDevices` policy. | [NSS docs](https://nss-crypto.org/reference/security/nss/legacy/pkcs11/module_installation/index.html), [Mozilla policy](https://firefox-admin-docs.mozilla.org/reference/policies/securitydevices) |
| CTK enable/disable | User: System Settings → Login Items & Extensions → Smart Card Readers. No public API for an app to unload a CTK extension. | [Apple Mac Help](https://support.apple.com/guide/mac-help/change-login-items-settings-mtusr003/mac) |

Certilia's own published architecture matches: PKCS#11 dylib at `/Applications/CertiliaMiddleware.app/Contents/pkcs11/libCertiliaPkcs11.dylib` (Firefox loads it as module "Certilia"), plus "Certilia Client" and "Certilia Signer" components; the Signer is a localhost service on port 55555 driven by browser popups ([install guide](https://www.certilia.com/uploads/Certilia_Middleware_Upute_za_Mac_OS_instalaciju_1_2_8bf7accc6e.pdf), [Firefox guide](https://www.certilia.com/uploads/Certilia_Middleware_Upute_za_Firefox_HR_1_3_fe6aef6974.pdf), [support portal](https://support.certilia.com/category-list/certilia-middleware)). A 2023 support page describes Safari reading the card via a Keychain "Certilia card" folder, implying a CTK extension existed in older versions; no `.appex` was found in the 3.9.12 payload, so the current Safari path is unverified. Public docs name "Certilia osobna/korporativna kartica" and the eOI card with any ISO7816/PC-SC reader, but publish no card model or ATR list.
