# Smart-card middleware for macOS: Certilia-compatible cards in Safari, Chromium, Firefox and WSurf

Status: **Draft for user review.** Architecture approved in conversation on 2026-10-15 ("Potvrđujem — piši specifikaciju"); that approval covers the presented architecture as the basis for this text, not this text itself. Nothing in this document has been built; every UNVERIFIED item is an acceptance gate, not a claim. No product code exists yet.
Branch: `feature/certilia-smartcard-research-20261014`, base `origin/main` `7b99516`.

Evidence labels. **EXISTING** = verified in source or a primary document (anchor given). **DESIGN** = proposed here; nothing exists. **UNVERIFIED** = nobody has observed it; it is a verification gate in §10, not a fact.

Evidence base: `docs/research/2026-10-14-certilia-smart-card.md` (same branch) holds the full citations, hashes and probe logs; this spec references it as `RES`.

---

## 1. Goal and user decisions

Goal: our own macOS smart-card middleware, compatible with what Certilia Middleware enables today, so the user's smart card works in **Safari, Chrome/Chromium, Firefox and WSurf (WebKit and CEF engines)** — plus the FINA token layers. Built with REA-assisted analysis of Certilia's software, within the statutory interoperability frame (§7).

Decided by the user (not re-litigated here):

1. **Own native components**, not bundling, loading or redistributing AKD/Certilia binaries; REA is a development-time analysis tool only, never shipped (`RES` REA section).
2. **Certilia scope:** compatible with the card types Certilia supports. Public docs name only "Certilia osobna/korporativna kartica" and the eOI card, with any ISO7816/PC-SC reader, and publish no card-model/ATR list (EXISTING, `RES` Browser surfaces §). Card profiles therefore come from REA analysis + a real-device probe (§5).
3. **FINA scope:** cover FINA's layers — token driver (today: SafeNet Authentication Client / ActivClient) and the portal bridge (today: SignErgy) (EXISTING, FINA macOS guide rev. 1-10/2025, `RES` FINA §).
4. **Hardware:** user has a generic USB smart-card reader and a standard chip card; no vendor model (user, 2026-10-14). Design must not hard-code one card model (§5).
5. **Lifecycle:** components appear in WSurf's Extensions surfaces; Enable loads; toolbar Load/Unload; manual Unload is never auto-reversed by page or window events (approved 2026-10-14, `RES` lifecycle §).
6. **Physical card retained.** Private keys never leave the card; PIN is never stored or proxied into page JavaScript (Certilia CPS 1.2 §6.2.4/6.2.6/6.2.7 confirms keys are card-only, `RES`).

## 2. Non-goals

- No Java or .exe emulation, no Windows support, no generic plugin marketplace.
- No copying of AKD code, strings, ATR tables-as-code or any vendor bytes into our product (§7).
- No weakening of WSurf's hardened runtime / library validation to load foreign dylibs (EXISTING constraint, `RES` WSurf §).
- No speculative portal fixes: portal-specific work happens only for portals the user names with a failing scenario (§12).
- No claim that WebAuthn/passkeys replace X.509 client certificates, or vice versa.
- No programmatic unload of the CTK extension (Apple exposes none, EXISTING §3); the Load/Unload lifecycle governs only our own processes (§9.3).

## 3. Verified constraints (EXISTING)

| # | Fact | Anchor |
|---|---|---|
| C1 | Safari consumes smart-card identities only via a CryptoTokenKit token extension; the system copies token identities into Keychain on insertion and removes them on removal | [Apple CTK](https://developer.apple.com/documentation/cryptotokenkit/using-cryptographic-assets-stored-on-a-smart-card), [Apple deployment](https://support.apple.com/guide/deployment/supported-smart-card-functions-on-mac-depc47f60521/web) |
| C2 | Chrome/Chromium on macOS reads client certificates **only from Keychain** (`SecItemCopyMatching`, `kSecClassIdentity`, `kSecAttrCanSign`); no PKCS#11 module loading | [client_cert_store_mac.cc](https://chromium.googlesource.com/chromium/src/+/main/net/ssl/client_cert_store_mac.cc) |
| C3 | CEF exposes `CefRequestHandler::OnSelectClientCertificate`; the candidate list comes from Chromium `net`, i.e. Keychain on macOS | [cef_request_handler.h](https://bitbucket.org/chromiumembedded/cef/raw/master/include/cef_request_handler.h) |
| C4 | Firefox uses its own NSS PKCS#11 module database (GUI load, WebExtension `pkcs11.installModule()`, or `SecurityDevices` policy) | [NSS](https://nss-crypto.org/reference/security/nss/legacy/pkcs11/module_installation/index.html), [Mozilla policy](https://firefox-admin-docs.mozilla.org/reference/policies/securitydevices) |
| C5 | CTK extensions are enabled/disabled by the user in System Settings → Login Items & Extensions → Smart Card Readers; no public API lets an app unload one | [Apple Mac Help](https://support.apple.com/guide/mac-help/change-login-items-settings-mtusr003/mac) |
| C6 | Certilia Middleware = PKCS#11 dylib (`/Applications/CertiliaMiddleware.app/Contents/pkcs11/libCertiliaPkcs11.dylib`) + "Certilia Client" (cert import) + "Certilia Signer" (localhost service, port 55555, browser-popup driven; Chrome/Edge/Firefox named) | [Certilia install guide](https://www.certilia.com/uploads/Certilia_Middleware_Upute_za_Mac_OS_instalaciju_1_2_8bf7accc6e.pdf), [support portal](https://support.certilia.com/category-list/certilia-middleware) |
| C7 | Certilia pkg 3.9.12 payload contains **no `.appex`**; a 2023 support page describes Safari via a Keychain "Certilia card" folder (implies an older CTK extension). Current Certilia Safari path: **UNVERIFIED** | `RES` package §, [2023 support page](https://support.certilia.com/show/nemogucnost-prijave-na-certilia-portal-u-macos-u-i-linux-os-u-zbog-certifikata-koji-nije-valjan-ili-dostupan) |
| C8 | FINA macOS guide rev. 1-10/2025: SAC 10.9.2499 first, then SignErgy; SignErgy is the browser↔device bridge for the FINA CMS (activation, download, renewal); support is per-portal | [FINA guide PDF](https://rdc.fina.hr/upute/Korisnicka_uputa_za_instalaciju_i_koristenje_Thales_uredaja_na_MacOS.pdf) |
| C9 | OpenSC (LGPL-2.1-or-later) supports specific Gemalto IDPrime families (3810/830/930/3930/940/940C/840, eToken 5110 variants); FINA MD830 appears in FINA's 2020 activation doc. No Croatian AKD/Certilia card support exists in OpenSC | [card-idprime.c](https://github.com/OpenSC/OpenSC/blob/master/src/libopensc/card-idprime.c), `RES` FINA § |
| C10 | WSurf WebKit routes client-certificate challenges to default handling and returns **no credential**; CEF client sets no client-certificate callback. Neither engine consumes a card identity today | `WSurf/Web/Privacy/AuthChallenge.swift:17-31`, `WSurf/Web/Tabs/BrowserTab+WebKitDelegates.swift:458-493`, `WSurf/Web/Engines/ChromiumClient.swift:752-870` |
| C11 | WSurf extension lifecycle: `setEnabled` persists and immediately loads/unloads; `start()` loads every enabled record per window bootstrap; context menu has pin/options/disable-remove, **no Load/Unload**; no extension idle mechanism | `WSurf/Extensions/ExtensionManager.swift:245-265,612-623,657-659,793-819`, `ExtensionsSettingsSection.swift:185-195` |
| C12 | Credential Vault stores passwords/TOTP/ES256 passkeys; no X.509 subject; passkeys are RP-bound, not card identities | `WSurf/Web/Credentials/CredentialAccount.swift:58-120,156-182`, `Store/StoreFormat.swift:71-85` |
| C13 | WSurf app: sandbox disabled, hardened runtime enabled; foreign-Team-ID dylibs cannot be loaded without disabling library validation | `WSurf.xcodeproj/project.pbxproj:484,531` |
| C14 | Chromium bug 41351500 (intermediates not fetched from CTK tokens) is known only from an inaccessible search snippet; fix status unknown → **UNVERIFIED**, chain handling is a §10 test item | `RES` Browser surfaces § |
| C15 | Croatian ZAPSP (NN 111/2021) art. 208/209 and EU Directive 2009/24 art. 5(3)/6/8 permit observation/testing by an authorised user and narrowly-scoped interoperability decompilation; contrary contract terms are void; AKD EULA §1/§3 restricts separation/distribution/RE except as law permits | [NN 111/2021](https://narodne-novine.nn.hr/clanci/sluzbeni/2021_10_111_1941.html), [2009/24/EC](https://eur-lex.europa.eu/legal-content/EN/TXT/HTML/?uri=CELEX:32009L0024), `RES` legal § |
| C16 | Local probes: `TKSmartCardSlotManager.default == nil`, zero slots; PC/SC `SCardListReaders` returned no reader names on the Air. User's reader/card were never attached to the dev machine | `RES` verification § |

## 4. Architecture (DESIGN)

One shared card engine, three system-facing frontends, one WSurf integration layer. New code lives in `SmartCard/` in this repo (same branch→PR flow as everything else); WSurf-side changes in `WSurf/`.

```
                        ┌──────────────────────────────┐
                        │ CardCore (Swift package)     │
                        │ PC/SC transport · ATR detect │
                        │ card profiles · PIN/session  │
                        └───────────┬──────────────────┘
        ┌───────────────────────────┼────────────────────────────┐
┌───────▼────────┐        ┌─────────▼─────────┐        ┌─────────▼─────────┐
│ CTK token      │        │ PKCS#11 module    │        │ Signer service    │
│ extension      │        │ (.dylib)          │        │ (localhost)       │
│ (.appex+host)  │        │ drop-in for       │        │ Certilia-protocol │
│ → Keychain     │        │ libCertiliaPkcs11 │        │ compatible        │
└───────┬────────┘        └─────────┬─────────┘        └─────────┬─────────┘
  Safari/Chrome/WSurf          Firefox, signing apps        portal JS (any browser)
  WebKit/CEF (via Keychain)
```

- **CardCore** — Swift package, statically linked into each frontend. PC/SC via `PCSC.framework`; ATR-based profile selection (§5); APDU sessions per profile; PIN entry via the frontend's native prompt, never stored. No UI, no network.
- **CTK token extension** (`TKSmartCardTokenDriver`/`TKSmartCardToken`/`TKSmartCardTokenSession`, `com.apple.ctk.driver-class`) inside a minimal host app. Publishes card identities **with the full certificate chain** to Keychain (C14 mitigation), so Safari, Chrome and WSurf both engines see them (C1–C3). PIN via `TKTokenAuthOperation` system prompts. OS-managed lifecycle (C5).
- **PKCS#11 module** — standard PKCS#11 v2.40 (OASIS) dylib over CardCore; a drop-in where `libCertiliaPkcs11.dylib` is used today (C4, C6): Firefox Security Devices, Java SunPKCS11, signing apps. `C_Login` PIN via host prompt.
- **Signer service** — localhost-only daemon implementing the **Certilia Signer-compatible protocol** (C6; exact protocol UNVERIFIED, §8 REA target) so existing portals work unmodified in any browser. Loopback bind, Origin validation, per-signature native confirmation showing origin + document hash. WSurf calls CardCore **in-process** instead (no loopback) through the integration layer.
- **WSurf integration layer** (§9) — challenge handling for both engines + Extensions-surface lifecycle. Not part of the middleware product; it consumes it.

FINA (§11 phase 3): token driver coverage via OpenSC's own PKCS#11 module for supported IDPrime tokens (C9) — **no OpenSC code copied**; compliance is "use their module as-is, dynamic, LGPL-honoured". The SignErgy-role portal bridge is per-portal and starts only from user-supplied failing scenarios (§12).

## 5. Card support strategy (DESIGN)

- Runtime ATR detection: CardCore holds a profile table `{ATR mask → profile}`; first card contact selects the profile; unknown ATR → explicit "unsupported card" state, no guessing, no probing APDUs beyond the profile's spec.
- Profile contents per card family: APDU command set, PIN layout/verify rules, key containers, certificate file paths, signing algorithms.
- Profile sources, in order: (a) public standards/docs (ISO 7816, PKCS#15, EN 14890 where applicable), (b) OpenSC driver knowledge for FINA IDPrime tokens (C9, licence-respecting), (c) **REA-derived facts** from Certilia's dylib for Certilia/eOI cards (§8), (d) confirmation against the user's real card (§10 G3).
- The table ships data, not vendor code: ATR byte patterns and command layouts are interoperability facts, not expression (§7).

## 6. Security and privacy model (DESIGN)

- Private keys exist only on the card; every sign/decrypt op is an APDU to the card. No key export path exists in any component (matches Certilia CPS, §1.6).
- PIN: entered only into native prompts (CTK system prompt, Firefox PKCS#11 prompt, or our signer confirmation dialog); never logged, never persisted, never sent to a page.
- Signer service: binds `127.0.0.1` only; validates `Origin`/`Referer` against the current portal's expected origin; every signature requires a native confirmation showing origin, certificate subject and content hash; cancel terminates the operation without retry side-effects.
- Credential Vault: stores only public certificate metadata + a stable card/key reference + per-origin policy (C12 extension); a card removal shows the identity as unavailable, never as a password/passkey.
- Code signing: all components built with WSurf's existing signing on `pro`, notarized; hardened runtime kept everywhere; `com.apple.security.smartcard` entitlement only where PC/SC is used (C13).
- Card removal: subsequent key operations fail closed; already-established TLS sessions are the website's concern, not invalidated locally (documented behaviour).

## 7. Legal and licensing compliance (DESIGN, grounded in C15)

- Implementation sources: public standards (PKCS#11 v2.40, ISO 7816, Apple CTK API docs), OpenSC under LGPL-2.1+ for FINA IDPrime (use-as-is or reimplementation from its published behaviour with LGPL honoured; no closed copying), and REA-derived interoperability facts (§8).
- REA-derived facts are limited to: supported-card ATR patterns, observable protocol behaviour, and — only if (and only where) not readily available otherwise — narrowly scoped decompiled interface information, used solely to make our independently created program interoperate (ZAPSP art. 209(1)-(2); 2009/24 art. 6). No substantially-similar reimplementation of AKD expression; no AKD bytes, resources, strings or tables copied.
- The AKD EULA's no-RE clause is void to the extent it contradicts art. 208/209 (C15); its **distribution** ban is unaffected — we ship zero AKD components, which §2 already guarantees.
- Prerequisite before any analysis beyond static metadata: documented lawful-use basis (user holds the card and the middleware copy as a Certilia customer) — recorded in the research doc before §8 step 3 runs. UNVERIFIED until the user confirms in review (§12).
- This document is engineering compliance hygiene, not legal advice; any doubt escalates to counsel before the affected step.

## 8. REA analysis plan (DESIGN, bounded)

Pinned `rea-agents@6.5.0`, isolated HOME/cache/TMPDIR under `build/research` (procedure already proven, EXISTING in `RES`):

1. **Done (EXISTING):** pkg signature/notarization, dylib architecture/dependencies/exports, `inspect-macho` on an owned probe.
2. **Next:** extract the supported-card ATR/profile evidence from `libCertiliaPkcs11.dylib` (strings/read-only sections via REA static inspection; no execution).
3. **Signer protocol:** observe the browser↔`localhost:55555` exchange during the user's own authorized use of their own portal session (art. 208 observation; the user performs the session, we record traffic). Output: protocol notes sufficient for an independent implementation.
4. **Decompilation** (Hopper/Ghidra providers; JDK not installed, EXISTING): only if steps 2–3 leave a specific interface question unanswered, and only after §7's lawful-use record exists. No blanket decompilation.
5. Hygiene: no `--snapshot`; evidence stays in `build/research`, never in shipped artifacts; REA never in product code or build pipeline.

## 9. WSurf integration (DESIGN)

### 9.1 Client-certificate consumption (both engines)

- **WebKit:** in `AuthChallenge.swift:17-31` / `BrowserTab+WebKitDelegates.swift:458-493`, handle `NSURLAuthenticationMethodClientCertificate`: query Keychain for identities published by our CTK extension (filtered by the challenge's acceptable issuers), show a native picker, return `URLCredential(identity:…)`; persist the choice as an identity preference per origin (mirrors C2's `SecIdentityCopyPreferred` model). Today returns no credential (C10) — this is real implementation work, not a free ride.
- **CEF:** implement `OnSelectClientCertificate` in `ChromiumClient.swift:752-870` with the same picker/policy, calling `callback->Select(...)`; `Select(nullptr)` on cancel.
- Certificate chain: CTK publishes intermediates (§4); G4 tests Chrome/CEF chain building explicitly (C14).

### 9.2 Credential Vault

New X.509 subject type in the store (extends C12's closed subjects): public cert + card/key reference + origin policy; visible as "smart card, physical card required"; excluded from passkey/password export formats.

### 9.3 Extensions-surface lifecycle

- New records for the smart-card components in the existing Extensions UI: Settings toggle = persisted Enable (`setEnabled` path, C11); context menu gains **Load** / **Unload** items.
- Semantics (approved 2026-10-14): Enable → load; Unload → stop our worker/signer processes, disconnect native messaging, keep the record enabled-but-unloaded and the toolbar entry visible; `start()` and page/window events must NOT auto-load an unloaded record (runtime-suppression set, cleared by Disable/uninstall/quit); Load → explicit user action only.
- **Honest limit (C5):** Load/Unload governs our processes. The CTK extension itself is OS-managed; the menu shows its state and deep-links to System Settings, never claims to unload it.

## 10. Verification plan (acceptance gates)

| Gate | What | Where |
|---|---|---|
| G1 | CardCore unit checks: ATR parsing, profile selection, PKCS#11 API surface responds to `pkcs11-tool --list-slots` with no card (clean empty state) | dev/CI on `pro` |
| G2 | CTK extension registers on the stage Mac (`pluginkit -m -p com.apple.ctk-tokens`), appears in System Settings, publishes a test identity to Keychain | stage Air (WSURF_STAGE=1) |
| G3 | Real card (user's reader+card): ATR detected → profile matched; cert chain read; PIN verify via native prompt; one signature over a throwaway challenge; removal mid-flow fails closed; PIN never touches logs. **User performs PIN steps; agents never handle the PIN** | user + agent on stage |
| G4 | Browser matrix against a local TLS server requiring client certs: Safari, Chrome, Firefox (module loaded), WSurf WebKit, WSurf CEF — picker appears, correct identity works, cancel path clean, **chain builds in Chrome/CEF** (C14 check) | stage |
| G5 | Certilia portal: login + one real signing flow (user's account, user performs) | user |
| G6 | FINA: per user-supplied scenarios (§12); each fixed scenario re-verified end-to-end | user |
| G7 | Lifecycle: Enable loads; Unload stops processes, icon stays, no auto-reload across new windows/tabs; Disable persists off; quit leaves no orphan processes | stage |

No gate is claimed from static analysis or another component's probe. Full-app builds run on `pro`; stage verification on the Air with `WSURF_STAGE=1` per repo rules.

## 11. Phasing

1. **CardCore + CTK + PKCS#11** for the Certilia/eOI card profile; WSurf §9.1 + §9.3. Gates G1–G4, G7.
2. **Signer service** (Certilia-compatible protocol) + Vault §9.2. Gates G5 + G4 re-run.
3. **FINA layer:** confirm the user's token against OpenSC IDPrime support (C9), decide use-OpenSC-module vs CardCore profile, then portal bridges per §12 scenarios. Gate G6.

Phase 3 portal work does not start without §12 inputs.

## 12. Open inputs required from the user

1. **Portals and failing scenarios** (blocks phase 2/3): exact URLs, the action that fails, and the observed error — for Certilia portal(s) and FINA/bank portal(s). No PINs, serials or personal data.
2. **Lawful-use confirmation** (blocks §8 step 3+): that the Certilia middleware copy and card are the user's own licensed copy used within its intended purpose.
3. **First-look card identification** (helps §5, not blocking): whatever is printed on the card (e.g. "Certilia", "eOI") — again no serial numbers.

These do not block phase 1 implementation planning; they gate the phases named above.
