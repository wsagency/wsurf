<!-- Modified for WSurf by wsagency in 2026; based on Linen by Kavoye. -->
# Releasing WSurf

WSurf uses [Sparkle 2.10.1](https://sparkle-project.org) for updates. The app
does not show the Sparkle windows. The update interface is only the banner in
`WSurf/Updates/UpdateBanner.swift`.

No public signed WSurf release is available until WSurf's own Developer ID
certificate, profile, notarization credentials, and Sparkle key pair are
configured. Never turn a local unsigned build into a release.

Two files contain the hosting configuration. The values in these two files must
agree:

- `WSurf/Updates/UpdateFeed.swift` — the `owner` and `repository` values
- `WSurf/Info.plist` — the `SUFeedURL` value

The feed URL is
`https://github.com/<owner>/<repo>/releases/latest/download/appcast.xml`.
GitHub redirects that URL to the asset of the same name in the most recent
release, so you need no web server and no `gh-pages` branch. Attach
`appcast.xml` to each release to keep that URL working.

## Source and deployment policy

Develop changes in dedicated worktrees on feature branches, then merge them
through a PR targeting `main`; follow [Contributing](CONTRIBUTING.md#development-workflow).
Do not build release artifacts or deploy from feature branches, dirty working
trees, or changes committed directly to `main`. Local and PR validation builds
are not deployments.

Release and signed preview builds use a merged `main` commit after validation
passes on it. The preview workflow waits for CI on `main`. The release workflow
requires the tag on the first-parent history of `main` and then runs CI on that
commit. Both archive with the Xcode version pinned in `ci.yml`.

## The signing tools

Sparkle ships `generate_keys`, `sign_update` and `generate_appcast` in an
artifact bundle rather than as package products, so Swift Package Manager
downloads them without building them. Set a variable to their directory:

```bash
export SPARKLE_BIN=$(dirname "$(find ~/Library/Developer/Xcode/DerivedData -path '*artifacts/sparkle/Sparkle/bin/sign_update' -print -quit)")
```

The tools are stored in DerivedData. Cleaning the build folder removes them;
the next build restores them. You can also download the release tarball from
https://github.com/sparkle-project/Sparkle/releases.

## The WSurf update signing key

The WSurf release owner must create and control a new Sparkle EdDSA key pair.
Do not reuse, copy, or publish the upstream Kavoye key. `WSurf/Info.plist`
holds the matching public key as `SUPublicEDKey`; the private key belongs only
in the protected release environment as `WSURF_SPARKLE_PRIVATE_KEY`.

The release and preview workflows fail when that own private key is absent.
They must not publish unsigned artifacts or artifacts signed by an upstream
publisher key. Verify the embedded public key and the configured private key
match before enabling releases. Never commit the private key or print it in CI
logs; the public key belongs in `WSurf/Info.plist`.


## One-time: the Developer ID certificate

The workflow signs the app with a Developer ID Application certificate. Only the
Account Holder of the team can make this certificate. A Developer ID certificate
is valid for five years.

1. Open Xcode › Settings › Accounts.
2. Select your Apple ID, then the team.
3. Select Manage Certificates.
4. Select the add button, then Developer ID Application.
5. Run `security find-identity -v -p codesigning`. The output must contain
   `Developer ID Application`.

Then export the certificate for the workflow:

1. Open Keychain Access › login › My Certificates.
2. Select the Developer ID Application certificate. A private key must show
   below it. The Certificates category gives a file with no key, and the
   workflow then finds no signing identity.
3. Select File › Export Items. Save a `.p12` file. Set a password.
4. Put the file in the `DEVELOPER_ID_CERTIFICATE_P12` secret below.
5. Put the password in the `DEVELOPER_ID_CERTIFICATE_PASSWORD` secret.
6. Put a copy of the file and the password in a password manager. Then delete
   the file from the disk.

The portal permits a small number of these certificates. If the portal shows a
certificate that this Mac does not have, the private key is on a different Mac.
Export the key from that Mac, or revoke the certificate and make a new one. A
revoked certificate does not stop a release that is already public. The workflow
signs with `--timestamp`.

## One-time: the provisioning profile

`WSurf/WSurf.entitlements` declares restricted entitlements. Provider API keys,
MCP authorization tokens, and OAuth credentials use the encrypted classic
Keychain, with migration for legacy Data Protection Keychain entries. The
`keychain-access-groups` entitlement remains required for the separate Data
Protection Keychain used by the password/autofill/payment vaults and for legacy
migration. The app's `webcredentials:wsurf.app` associated domain supports
WSurf's own RP and PRF unlock. The credential-provider entitlement is declared
on both the app and exchange extension; each needs its own authorized profile.
WSurf deliberately does not declare Apple's managed
`com.apple.developer.web-browser.public-key-credential` entitlement. This does
not change routing: native system passkeys for arbitrary relying parties via
WebKit are not guaranteed: a normal tab reaches them only through its "Use
Another Device or Key…" hand-off, and a private tab uses them directly.
Vault-managed WebAuthn and Apple Passwords exchange use separate paths. A
Developer ID signature needs a profile authorizing the restricted entitlements
it declares. Gatekeeper refuses to launch an app that declares a restricted
entitlement without the profile.

The managed browser capability is not needed for WSurf's vault-managed WebAuthn,
`wsurf.app` PRF unlock, or Apple Passwords exchange. Signing still requires
profiles authorizing the remaining restricted entitlements: the release and tip
checks verify the credential-provider grant on the app and extension, the
`webcredentials:wsurf.app` associated domain, and the keychain access group.
Those checks also require the managed browser entitlement to be absent from
both signed bundles. Whether the host app, and not only the extension, needs
`autofill-credential-provider` for the system's credential import and export
calls is not established from documentation; it stays declared on both, and a
signed native run decides.

Once, in the Apple Developer portal:

1. Open Certificates, Identifiers & Profiles › Identifiers.
2. Select the `io.wsagency.wsurf` App ID, or register it. Enable Associated
   Domains and the credential provider capability on it. Do not enable the
   managed Web Browser Public Key Credential Requests capability; WSurf does
   not request it.
3. Open Profiles and add a Developer ID profile.
4. Select the `io.wsagency.wsurf` App ID and your Developer ID Application
   certificate.
5. Give the profile a name, for example `WSurf Developer ID`. Do not use the
   characters `&`, `<` or `>`. The export step puts the name in a plist.
6. Download the profile as `WSurf.provisionprofile`.
7. Run this command and confirm the profile grants `keychain-access-groups`,
   `com.apple.developer.associated-domains`, and
   `com.apple.developer.authentication-services.autofill-credential-provider`:

   ```bash
   security cms -D -i WSurf.provisionprofile | plutil -extract Entitlements xml1 -o - -
   ```

   Release and tip validation separately require the exported app and exchange
   extension's signed entitlements to omit the managed browser passkey
   entitlement.

8. Put the profile in the `DEVELOPER_ID_PROVISIONING_PROFILE` secret below.

The App ID prefix gives the access group. The portal has no Keychain Sharing
capability; that switch is in Xcode and writes the entitlements file. WSurf
deliberately omits the managed browser capability. The profile still must grant
the remaining restricted entitlements; release and tip checks fail if a grant
is missing or if either signed bundle includes the browser entitlement.

Make the profile again when it expires, and when you add a restricted
entitlement. The release then fails at the Install provisioning profile step,
and at the checks after the export.

## One-time: the credential exchange profile

`WSurfCredentialExchange` is embedded at
`Contents/PlugIns/WSurfCredentialExchange.appex` with its own bundle ID,
`io.wsagency.wsurf.CredentialExchange`, and needs its own profile with the
provider grant. It is exchange-only: `ProvidesPasswords`, `ProvidesPasskeys`,
and `ProvidesOneTimeCodes` are false, `SupportsCredentialExchange` is true, and
it publishes no identities and shares no store with the app.

No portal, App ID, or profile change has been made for this source feature. Once,
in the portal:

1. Register the `io.wsagency.wsurf.CredentialExchange` App ID with the credential
   provider capability.
2. Make a Developer ID profile for it with your Developer ID Application
   certificate. Do not use `&`, `<` or `>` in the name. Download it as
   `WSurf-CredentialExchange.provisionprofile`.
3. Run the command from the previous section. The output must contain
   `com.apple.developer.authentication-services.autofill-credential-provider`.
4. Put the profile in the `DEVELOPER_ID_CREDENTIAL_EXCHANGE_PROVISIONING_PROFILE`
   secret below. Regenerate the app profile after the App ID changes.

The two profile names reach the build as two target build settings:
`WSURF_PROFILE` for the app and `WSURF_EXCHANGE_PROFILE` for the extension. A
native manual debug build passes the same two. Do not use
`-allowProvisioningUpdates`, change the global `xcode-select`, or export a key.
Native profile and configuration checks, and Apple's participation in the
credential exchange, are separate blockers; neither has been verified.

## One-time: who can release

Pushing a tag starts the release workflow, which uses WSurf's Developer ID
certificate, notarization key, and own Sparkle private key. Only accounts with
write access can push tags. The Sparkle key authorizes updates for installed
copies. Set up all three controls below before enabling releases.

**1. The release environment.** The workflow jobs declare
`environment: release`, and the secrets live in that environment. Only a job
that runs from an approved ref can read them.

1. Open Settings › Environments. Add an environment. Name it `release`.
2. Find Deployment branches and tags. Select Selected branches and tags.
3. Select Add deployment branch or tag rule. Set the ref type to Tag. Enter
   the pattern `v*`.
4. Select Add deployment branch or tag rule again. Set the ref type to
   **Branch**. Enter `main`.
5. Make sure the list reads "1 branch and 1 tag allowed". A release comes from
   the tag. A preview build comes from the branch, because `workflow_run` runs
   from `main` and not from a tag. With no branch in the list, each preview
   build fails when it asks for the certificate.
6. Add the nine secrets from the next section as environment secrets.

Do not add a required reviewer. A reviewer stops the release until you come
back and approve it, and stops each preview build the same way. The tag ruleset
below controls who can start a release.

**2. A tag ruleset.** Restrict who can create, update or delete release tags.

1. Open Settings › Rules › Rulesets. Add a new tag ruleset.
2. Set Enforcement status to Active.
3. Under Target tags, add the pattern `v*`.
4. Select Restrict creations, Restrict updates and Restrict deletions.
5. Leave the bypass list empty, then add only yourself.

**3. A branch ruleset for `main`.** The release only builds a commit that is on
`main`, so protect changes to `main`.

1. Add a branch ruleset that targets the default branch.
2. Select Require a pull request before merging. Require one approval.
3. Select Require status checks to pass. Add the CI check.
4. Select Block force pushes. Select Restrict deletions.

The workflow refuses a tag that points at a commit that is not on `main`, but a
ruleset is what stops the commit getting to `main`.

## One-time: the release secrets

`.github/workflows/release.yml` needs nine secrets. Add them to the `release`
environment, in Settings › Environments › release › Environment secrets. Do not
add them in Settings › Secrets and variables › Actions: a repository secret is
available to every workflow run, with no approval:

| Secret | Description |
| --- | --- |
| `DEVELOPER_ID_CERTIFICATE_P12` | The `.p12` file from the certificate section above. Run `base64 -i cert.p12 \| pbcopy` |
| `DEVELOPER_ID_CERTIFICATE_PASSWORD` | The password that you set on the `.p12` file |
| `DEVELOPER_ID_PROVISIONING_PROFILE` | The WSurf Developer ID profile from the section above. Run `base64 -i WSurf.provisionprofile \| pbcopy` |
| `DEVELOPER_ID_CREDENTIAL_EXCHANGE_PROVISIONING_PROFILE` | The credential exchange profile from the section above. Run `base64 -i WSurf-CredentialExchange.provisionprofile \| pbcopy` |
| `AC_API_KEY_P8` | The full contents of the App Store Connect API key `.p8` file. Include the `BEGIN` and `END` lines |
| `AC_API_KEY_ID` | The ID of the key. This is the `ABCD1234EF` part of `AuthKey_ABCD1234EF.p8` |
| `AC_API_ISSUER_ID` | The issuer UUID. App Store Connect shows it above the list of keys |
| `WSURF_SPARKLE_PRIVATE_KEY` | WSurf's own EdDSA private key, matching the public key embedded in `WSurf/Info.plist`; never use an upstream key |
| `WSURF_SPARKLE_PUBLIC_KEY` | The non-secret public key embedded in `WSurf/Info.plist`; the workflows compare it before publishing |

Make the App Store Connect API key in Users and Access › Integrations › App
Store Connect API. Give the key the Developer role. App Store Connect downloads
the `.p8` file one time only. `notarytool` uses this key to authenticate. An app-specific
password also works, but you can revoke the API key on its own,
and the API key does not give access to all of your Apple ID.

The team ID is not a secret. The workflow contains WSurf's own team ID
`5X68L55TNU`. Do not configure the workflows until all nine own secrets exist
in the protected release environment.

## Each release

Merge the release changes through a PR targeting `main`, then tag the merged
commit. The release workflow validates that exact commit before signing.
Refresh `origin/main` before tagging:

```bash
git fetch origin main
git tag v1.1 origin/main && git push origin v1.1
```

The release uses the latest published stable WSurf version as its baseline.
A patch such as `0.1.28` → `0.1.29` runs quick validation for every change since
the previous release. A first release or a new major or minor version such as
`0.1.28` → `0.2.29` runs minor validation. From there the workflow:

1. Confirms the tag is on `main`.
2. Runs the selected CI tier on that commit and stops if it fails.
3. Builds an archive.
4. Installs the app and credential exchange profiles, then signs both with the
   Developer ID certificate. After export, it checks each embedded profile, each
   signature, and the provider entitlement in both bundles.
5. Sends the app to Apple for notarization.
6. Staples the notarization ticket to the app.
7. Builds a zip file.
8. Builds a disk image holding the app and a link to the Applications folder.
9. Signs the disk image.
10. Sends the disk image to Apple for notarization.
11. Staples the notarization ticket to the disk image.
12. Signs the app for Sparkle.
13. Writes `appcast.xml`.
14. Publishes the GitHub release with the three assets.

Signing and packaging take 20 to 40 minutes after validation. The
Apple notary service uses most of this time, and the workflow waits for it two
times.

If validation fails, correct the code through a PR and make the next tag.
Preserve existing published tags.

Release requirements:

- **Use the correct asset format.** Users download the disk image. Sparkle
  downloads the zip file. `appcast.xml` points only at the zip file. Keep the
  disk image out of the `dist` folder. `generate_appcast` reads a disk image
  also, and then the feed contains two items for one version.
- **Install in Applications.** A copy that runs from another folder cannot
  always update itself, so WSurf offers to move itself to the Applications
  folder at the first launch. `WSurf/App/InstallLocation.swift` makes that
  decision. WSurf asks one time only. Keep the Applications folder link in the
  disk image to show where to install the app.
- **The tag sets the version.** `MARKETING_VERSION` comes from the tag without
  the `v` character. `CURRENT_PROJECT_VERSION` comes from `git rev-list --count
  HEAD`, the number of commits, so the `CFBundleVersion` that Sparkle compares
  always increases, in both channels. Do not use the number of the
  workflow run: that counter restarts if the workflow file is replaced, and a
  build number that goes down stops every installed copy from updating. Do not
  change a version by hand in the Xcode project. The values in the Xcode project
  apply only to local builds.
- **Every candidate build has its own build number and changelog section.** A
  candidate is a local signed build, so it carries the Xcode project's values;
  this is the one place they change by hand. Each candidate build increments
  `CURRENT_PROJECT_VERSION` and sets `MARKETING_VERSION`: while the version is
  0.x, build N is `0.<minor>.N` (the 123rd build is `0.1.123`), and the
  orchestrator proposes a minor bump (0.1 to 0.2) at checkpoints. Each candidate
  adds its own `## <version> (build <n>) — <date>` section at the top of
  `CHANGELOG.md`. `Tools/check-changelog.sh` runs in the candidate gate and
  fails without that section, and for a 0.x version also when the patch number
  differs from the build number. The release workflow still finds the section
  by its `## <version>` prefix.
- **Every candidate build says which candidate it is.** The gate and the sign
  driver add two build settings to every `xcodebuild` call (build, test,
  archive): `WSURF_CANDIDATE=<label>`, the orchestrator's label (for now the
  version, such as `0.1.4`), and `WSURF_COMMIT=$(git rev-parse --short=8 HEAD)`. They become the
  `WSurfCandidate` and `WSurfCommit` keys in `WSurf/Info.plist`, and the About
  panel and Settings › About show `Candidate <label> · <commit>` under the
  version. The defaults are `dev` and empty; a `dev` or empty candidate shows no
  line. Pass them on the command line, as with `WSURF_BUNDLE_ID_SUFFIX`: the
  Xcode project keeps the defaults, so nothing changes by hand and the build
  stays reproducible from the commit and the label.
- **Candidates use the same two tiers as CI.** For an ordinary or patch
  candidate use `Tools/ci-local.sh --base <previous-candidate-commit>`. Both
  tiers use one `build-for-testing` per configuration, check the isolated test
  identity and verify that the selected tests appear in the result bundles.
  `Tools/ci-local.sh --tier minor` runs Serial-1, Serial-2, Serial-3 and Rest in
  separate hosts, checks their combined coverage and reads the speed and memory
  budgets from Rest. It then runs WebKit and Chromium resource benchmarks,
  first-tab timing, the soak case and the large-vault benchmarks in separate
  hosts. A skipped benchmark fails this tier. The Chromium XCTest load
  benchmark remains excluded due to its effect on later memory measurements.
  The minor tier runs the separate debug and debug-disabled Chromium service
  checks, CefKit tests and optimized Debug smoke. Run VoiceOver and other manual
  checks when relevant to the functionality being released.
- **Memory budgets are judged on the median, time budgets on the mean.**
  `XCTMemoryMetric` is the change of the test host's physical footprint over one
  pass, and in a long-running host a single sample swings by tens of MB either
  way while time and behavior are fine, so the mean of five flipped sign on one
  outlier (0.1.5, layout option sidebar: 3424, 4129, 4112, 6275 and 21496 kB,
  mean 7887 against a budget of 7019). `Tools/check-performance.sh` holds the
  median of the memory samples to the budget and the mean of all the time
  samples, as before. Every budgeted case measures six iterations
  (`XCTMeasureOptions.budgeted`), and the gate drops the first memory sample as
  the warm-up, so the median is taken over the other five. A real regression
  lifts every sample and still fails. No budget is raised for noise: a case
  whose samples are mostly high, such as the 0.1.6 autofilled password among
  20,000 credentials (median 18580 kB against 4096), is a measurement problem
  to fix in the test, not a budget to raise. That one (and 0.1.17 gate 4's
  18924 kB) was the allocator's large-block cache: freed large blocks stay in
  the footprint, `malloc_zone_pressure_relief` does not empty the cache, and
  the kernel takes them back only when the Mac is under memory pressure, at
  moments of its own. So `WSurf.xctestplan` sets `MallocLargeCache=0` for the
  test host, the large-vault write cases (`VaultScalePerformanceTests.measureWrite`)
  drop what a pass prepared and return the free pages just before the
  measurement starts and stops, and
  `VaultScalePerformanceTests.testFreedLargeBlocksLeaveTheFootprint` fails if
  the cache is on: a sample is what the step retained. If you change the iteration count, change the rule
  in the script with it. `Tools/check-performance.sh
  --self-test` checks the statistics on those sample sets and needs no metrics
  file.
- **The release body supplies the “What’s New” sheet.** The workflow makes the
  body from two parts. `CHANGELOG.md` is optional: make it only when a release
  needs notes of its own. If it contains a `## 1.1` section, that section comes
  first. GitHub then adds the list of the commits and the pull
  requests after the previous tag, and a New Contributors section, so every
  contributor gets credit with or without a changelog. The app reads the body
  from the API each time it shows the sheet, so you can edit a release later to
  correct the text without publishing a new one.
- **Give credit to a security reporter by hand.** [SECURITY.md](SECURITY.md)
  promises the reporter credit in the release notes. The workflow cannot know
  the name. Put the name in the `CHANGELOG.md` section before you make the tag.
  Do not use the name if the reporter asked you to keep it out.
- **Use a supported tag format.** The notes sheet finds the release with
  the name `v<version>`. If it does not find that name, it uses `<version>`.
  Only the formats `vX.Y` and `vX.Y.Z` start the workflow.
- **The workflow writes `appcast.xml` from the app bundle**, so the version,
  the minimum system version and the architectures in the feed always match the
  app. The feed contains only the most recent release. This is sufficient
  for Sparkle to offer the update to all users.

### Acknowledgements

The app shows the license of each open source package in Settings › About. The
list comes from `WSurf/Support/Acknowledgements.json`. A script makes this file
from `Package.resolved` and the resolved checkouts:

```bash
swift Tools/make-acknowledgements.swift
```

After you add, remove or update a package:

1. Resolve the packages one time, or build the app.
2. Run the command above.
3. Commit the file with the change to `Package.resolved`.

CI runs the same command and stops the build if the result is different. The
MIT and Apache licenses require their terms to be included with distributed
binaries, so this file is required.

CefSwift is vendored in `Packages/CefSwift`, so it is not in `Package.resolved`. The script
reads its license from that folder (`licenseDirectory` in the script's `vendored` list).
When you update the vendored copy, change the version there and in
`Packages/CefSwift/WSURF-PATCHES.md`.

### The disk image

The disk image contains `WSurf.app` and an `Applications` symlink. Finder
provides the native layout; WSurf does not copy upstream volume aliases or
window metadata into a release.

Optional brand artwork can be regenerated without mounting a volume or
controlling Finder:

```bash
sh Tools/make-dmg-artwork.sh
```


### Manual procedure

If the workflow fails, and you cannot wait, do these steps on your
Mac:

1. Make an archive and export it with the Developer ID method.
2. Notarize the app with `notarytool`.
3. Staple the ticket to the app with `staple`.
4. Make a zip file:
   `ditto -c -k --sequesterRsrc --keepParent WSurf.app WSurf-1.1.zip`
5. Make the appcast:

   ```bash
   "$SPARKLE_BIN/generate_appcast" \
     --download-url-prefix "https://github.com/wsagency/wsurf/releases/download/v1.1/" \
     /path/to/folder-with-the-zip
   ```

6. Make a folder that contains the app and a link to the Applications folder:

   ```bash
   mkdir -p dmg && ditto WSurf.app dmg/WSurf.app && ln -s /Applications dmg/Applications
   ```


7. Make the disk image:

   ```bash
   hdiutil create -volname WSurf -srcfolder dmg -fs HFS+ -format UDZO -ov WSurf-1.1.dmg
   ```

8. Sign the disk image:
   `codesign --force --sign "Developer ID Application" --timestamp WSurf-1.1.dmg`
9. Notarize the disk image with `notarytool`.
10. Staple the ticket to the disk image with `staple`.
11. Attach the disk image, the zip file **and** `appcast.xml` to the release.

## Local development-signed candidates

The candidates tried by hand on the owner's Macs (development-signed, `WSURF_BUNDLE_ID_SUFFIX` empty) are built in the configuration
that ships. A Debug app is 477 MB on disk (a 145 MB debug dylib, coverage counters, unoptimised code) and as slow as the code can be;
`release.yml` and `tip.yml` already archive Release, so the local candidate should too.

- **Build** with `xcodebuild archive -configuration Release -destination 'generic/platform=macOS' -IDEPackageEnablePrebuilts=NO`, the
  `release.yml` command with the development identity and profiles, and `ENABLE_DEBUG_DYLIB=NO ENABLE_PREVIEWS=NO`.
  `-IDEPackageEnablePrebuilts=NO` stops SwiftPM from downloading prebuilt swift-syntax (macro) binaries, so they are built from the
  pinned source. Sparkle is still a binary artifact, verified against the checksum in its own package manifest. An archive strips the executables and writes
  `dSYMs/`: keep them with the build's evidence, they are what symbolicates a crash of that exact build. A plain `xcodebuild build`
  of the scheme turns on code coverage, because the scheme's test action enables it, and leaves the debug map in the binary. An
  archive does neither, and `xcodebuild` refuses `-enableCodeCoverage` for it ("only supported when testing").
- **Assert the result** instead of trusting the settings: no `*.debug.dylib` or `__preview.dylib`, no `__llvm_prf` or `__LLVM_COV`
  section in any Mach-O, a host `__LINKEDIT` of a few MB (the Debug build's was 80 MB) and exactly the kept Chromium languages.
- **Chromium languages.** `Tools/embed-chromium.sh` keeps the locale paks named in `WSURF_CEF_LOCALES` (lproj names separated by
  spaces, default `en en_GB hr`, `en` required, set but empty keeps all) and removes the rest before the first signature: 217 of 220
  directories, 47 MB. The list is part of the embed fingerprint. Pages see the same languages with or without them: the app declares
  only `en`, so Chromium loads its en-US strings and CEF reports `en-US,en` whatever the system languages are
  (`ChromiumLanguageTests`).
- **Install copy.** Stage with `ditto --noclone --hfsCompression <verified unzipped app> <staged app>`: about 162 to 172 MB on disk instead of 316.
  `--noclone` is required on macOS 27: its `ditto` clones same-volume copies by default and `--hfsCompression` then compresses nothing (macOS 26 accepts the flag too).
  Never `ditto -x -k --hfsCompression`, which produced an incomplete tree. A later Finder or `cp -R` copy loses the compression
  (`ditto` and `cp -cR` keep it).
- **Tests stay Debug.** Never host tests in the Release configuration: its bundle identifier is fixed and Stage mode is compiled out.
  `CredentialStore` now isolates tests in every configuration, but nothing else promises that for a Release test host. The
  minor validation builds an optimised Debug host with `SWIFT_OPTIMIZATION_LEVEL=-O ENABLE_DEBUG_DYLIB=NO
  ENABLE_HARDENED_RUNTIME=NO` and runs the smoke tests again. Performance budgets stay on the measured Debug plan.
- **What differs at runtime**, from the `#if DEBUG` sites: Stage mode is gone (screenshot and staged-profile work needs a Debug build),
  extension contexts are not inspectable, WebAuthn counts and `AutofillDiagnostics.policyFailed` log less, Swift `assert`s are compiled
  out, and `MoveToApplications` offers to move a copy that does not run from `/Applications` (never launch a candidate from its
  staging path). A development-signed Release build is expected not to carry `com.apple.security.get-task-allow`: no lldb,
  Instruments or `sample` on the installed candidate. The candidate verifier reports that as a named entitlement difference that needs
  the owner's approval.

### Test iCloud with an Apple Development signature

The WSurf host can request its private CloudKit Development container for a specific
candidate. The host profile must grant `iCloud.io.wsagency.wsurf` in both container
lists, plus CloudKit, Development and development push. Apple's development list
identifies the containers available in that environment. Xcode places the standard
container-identifiers key in a CloudKit-only app's signature, and WSurf checks that
key before creating its container. The host also needs its existing associated
domain, Keychain group and credential-provider grants. [Development container
identifiers](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.icloud-container-development-container-identifiers)
· [Xcode iCloud configuration](https://developer.apple.com/documentation/xcode/configuring-icloud-services)
· [Provisioning profile grants](https://developer.apple.com/documentation/technotes/tn3125-inside-code-signing-provisioning-profiles)

Run the following in an owned checkout of the clean merged candidate after its CI
passes, using the installed host and exchange development profile UUIDs and that
candidate's label. This creates a fresh archive and checks its actual host and
extension before the device trial.

```sh
set -eu
: "${WSURF_PROFILE:?Set the installed WSurf host development profile UUID}"
: "${WSURF_EXCHANGE_PROFILE:?Set the installed credential exchange development profile UUID}"
: "${WSURF_CANDIDATE:?Set the approved candidate label}"
mkdir -p build
trial=$(mktemp -d "$PWD/build/icloud-development.XXXXXX")
profile_dir="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
python3 Tools/check-icloud-development-signing.py prepare \
  "$profile_dir/$WSURF_PROFILE.provisionprofile" > "$trial/WSurf.entitlements"
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild archive \
  -project WSurf.xcodeproj -scheme WSurf -configuration Release \
  -destination 'generic/platform=macOS' -archivePath "$trial/WSurf.xcarchive" \
  -derivedDataPath "$trial/DerivedData" -clonedSourcePackagesDirPath "$trial/SourcePackages" \
  -onlyUsePackageVersionsFromResolvedFile -IDEPackageEnablePrebuilts=NO \
  ENABLE_DEBUG_DYLIB=NO ENABLE_PREVIEWS=NO \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Apple Development" \
  WSURF_CANDIDATE="$WSURF_CANDIDATE" WSURF_COMMIT="$(git rev-parse --short=8 HEAD)" \
  WSURF_PROFILE="$WSURF_PROFILE" WSURF_EXCHANGE_PROFILE="$WSURF_EXCHANGE_PROFILE" \
  WSURF_HOST_ENTITLEMENTS="$trial/WSurf.entitlements"
python3 Tools/check-icloud-development-signing.py verify \
  "$trial/WSurf.xcarchive/Products/Applications/WSurf.app" "$WSURF_PROFILE"
```

`WSURF_HOST_ENTITLEMENTS` selects the host plist in Debug and Release. The extension
uses its own plist and profile. Ordinary builds use `WSurf/WSurf.entitlements`.
Developer ID release and tip use their regular profiles. Enabling CloudKit for those
exports requires Production grants, production push and deployment of the Production
schema. Signing permits access to CloudKit. The test user gives consent separately
with the launch-time feature preference and per-profile or per-vault switch below.

To check private CloudKit transport on Studio and Air, use the standalone probe
from the reviewed merge commit. Studio writes a synthetic marker, Air acknowledges
it, and Studio confirms the reply. Cleanup clears that record's encrypted payload
using its fetched change tag. The empty record remains in a dedicated Development zone.
[Two-Mac CloudKit transport trial](Tools/CloudKitTransportProbe/README.md)

For the tab-sharing trial, use two fresh macOS test users with the same dedicated
Apple Account. In each test user run
`defaults write io.wsagency.wsurf experiments.iCloudTabs -bool YES`, relaunch
WSurf and switch on **Settings → Profiles → Personal → Share tabs through iCloud**.
Open a test link on one Mac and open its remote sidebar entry on the other.
Only the Personal profile is eligible. Debug Stage and unsigned tests skip CloudKit.

For the vault trial use `experiments.iCloudVault` in place of `experiments.iCloudTabs`.
Relaunch, create and unlock a disposable vault with a synthetic entry, then select
**Settings → Autofill → Settings → Sync with iCloud** for that vault. On the other
Mac use **Add to This Mac** and the same synced unlock passkey. Compare key checks
and round-trip an edit to the test entry. These flags are read at launch. Each
profile or vault still needs its own opt-in.

## Preview builds

WSurf has two update channels. A release is the default. A preview build comes
from the newest commit on `main`, before a release.

To follow preview builds, open Settings › About and set Update channel to
Preview. Sparkle reads the other feed at the next check, with no restart.

### What the workflow does

`.github/workflows/tip.yml` runs each time CI passes on `main`. Main CI selects
changes since the last published preview. Before the first preview, it selects
tests for the mapped app and package areas. No manual trigger or tag is needed.
The workflow:

1. Reads the version: the last `v` tag, then the number of commits after it,
   such as `0.1.2 (4)`.
2. Uses the tag alone when that count is zero, such as `0.1.2`. The commit is
   the release itself.
3. Builds an archive, signs the app and credential exchange extension with their
   profiles, checks both after export, and sends the app to Apple for notarization.
4. Builds a zip file, and no disk image.
5. Signs the app for Sparkle and writes `appcast-tip.xml`.
6. Moves the `tip` tag to that commit.
7. Updates the `tip` pre-release with the two files.
8. Deletes every zip file outside the five most recent.

The workflow takes 20 to 30 minutes. Ten commits in ten minutes produce one
build: a new run cancels the one before it, and the last commit is what
builds.

### Where each feed is

| Channel | Tag | Pre-release | Feed asset |
| --- | --- | --- | --- |
| Release | `v0.1.2`, a new tag each time | No | `appcast.xml` |
| Preview | `tip`, one tag that moves | **Yes** | `appcast-tip.xml` |

`WSurf/Updates/UpdateFeed.swift` contains both URLs. The release feed is
`releases/latest/download/appcast.xml`. The preview feed is
`releases/download/tip/appcast-tip.xml`. The second URL is a permalink because
the tag name never changes.

### Rules to keep

- **The `tip` release must stay a pre-release.** GitHub makes the most recent
  release that is not a pre-release the “latest” release, and
  `releases/latest/download/` reads that release. A `tip` release that is not a
  pre-release takes the release feed URL. The workflow sets the flag on each
  run.
- **The two feed files must keep different names.** That is what makes the
  mistake above recoverable. With different names the release feed returns a
  404, update checks fail, and you can fix it. With the same name everyone moves
  to the preview channel, and since Sparkle never installs an older version, you
  cannot fix it.
- **The build number must always increase.** Both workflows use `git rev-list
  --count HEAD`. A release is always at or after the previews before it, so its
  number is never lower.
- **The `tip` tag is not a version tag.** The workflow reads the last version
  with `git describe --match 'v[0-9]*.[0-9]*'`. Without the pattern, `git
  describe` finds `tip`, and the count becomes zero at each build.
- **The commit a release tags still builds a preview.** A release writes to the
  release feed only. If the preview build stops at that commit, the preview
  channel stays on the release before it, and everything since sits in no
  preview feed until the next commit lands on `main`.
- **A preview build uses the signing keys.** The certificate, notarization
  key and Sparkle key are used for every commit on `main` that passes CI.

### Going back to releases

Set Update channel to Release, and WSurf reads the release feed again. Sparkle
never installs an older version, so the app stays on the preview build until a
release carries a higher build number. To go back at once, download the disk
image from the releases page and replace the app.

## Update behavior

- Sparkle checks for an update at launch, and then every four hours. If a
  background check fails, the app shows nothing.
- The feed that Sparkle reads depends on the Update channel setting. A change
  to the setting starts a check immediately.
- When Sparkle finds an update, the banner appears in two places: above the
  settings page, and in the sidebar below the media player.
- Install downloads the update, installs it, and opens
  WSurf again, without asking a second time. Nothing downloads before someone
  chooses Install.
- Dismissing the banner defers the update rather than skipping it, and a
  downloaded update carries on at the next launch.
- WSurf › Check for Updates… checks straight away, and the same banner shows
  the result.
