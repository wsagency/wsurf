<!-- Modified for WSurf by wsagency in 2026; based on Linen by Kavoye. -->
# Releasing WSurf

WSurf uses [Sparkle 2.10.0](https://sparkle-project.org) for updates. The app
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

Release and signed preview builds must use the merged `main` commit after its
CI checks pass. The preview workflow already waits for successful CI on `main`;
the release workflow checks that the tag is on `main` and waits for CI on that
commit. These gates must not be bypassed.

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

`WSurf/WSurf.entitlements` declares restricted entitlements. Provider API
keys, MCP authorization tokens, and OAuth credentials use the encrypted
classic Keychain, with migration for legacy Data Protection Keychain entries.
The `keychain-access-groups` entitlement remains required for the separate Data
Protection Keychain used by the password/autofill/payment vaults and for legacy
migration. The app also lets a website use a passkey, so the file declares
`com.apple.developer.web-browser.public-key-credential`, which stays declared and
is not stripped. The opt-in Credential Manager, WSurf's own store and relying
party, and its exchange extension use separate standard entitlements:
`com.apple.developer.associated-domains` (`webcredentials:wsurf.app`, see the
README's website section for the AASA team identity) and
`com.apple.developer.authentication-services.autofill-credential-provider`, on
both the app and the extension. None of that is managed browser approval; do not
claim the new store, own relying party, or exchange needs it. A Developer ID
signature can only carry a restricted entitlement when an embedded profile
authorizes it. Gatekeeper refuses to launch an app that declares an entitlement
without the profile.

Two things are separate here. What a feature needs: the new store, own relying
party, and exchange do not need the managed browser capability, so nothing
above asks Apple for more than the file already declares. What signing
requires: while `WSurf.entitlements` still declares
`com.apple.developer.web-browser.public-key-credential`, a signed build needs a
profile that authorizes it, and the release and tip checks enforce that. An
entitlement that no feature needs is still a signing requirement until someone
removes the declaration, which is a separate decision this document does not
make. Whether the host app, and not only the extension, needs
`autofill-credential-provider` for the system's credential import and export
calls is not established from documentation; it stays declared on both, and a
signed native run decides.

Once, in the Apple Developer portal:

1. Open Certificates, Identifiers & Profiles › Identifiers.
2. Select the `io.wsagency.wsurf` App ID, or register it. Also enable Associated
   Domains and the credential provider capability on it.
3. Enable the Web Browser Public Key Credential Requests capability. Apple
   assigns this capability to the account. You must also enable it on the
   App ID. This managed browser capability requires organization Account Holder
   review; see https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.web-browser.public-key-credential.
4. Open Profiles. Add a profile.
5. Select the Developer ID type, under Distribution.
6. Select the `io.wsagency.wsurf` App ID and your Developer ID Application
   certificate.
7. Give the profile a name, for example `WSurf Developer ID`. Do not use the
   characters `&`, `<` or `>`. The export step puts the name in a plist.
8. Download the profile as `WSurf.provisionprofile`.
9. Run this command. The output must contain `keychain-access-groups`,
   `com.apple.developer.web-browser.public-key-credential`,
   `com.apple.developer.associated-domains`, and
   `com.apple.developer.authentication-services.autofill-credential-provider`:

   ```bash
   security cms -D -i WSurf.provisionprofile | plutil -extract Entitlements xml1 -o - -
   ```

10. Put the profile in the `DEVELOPER_ID_PROVISIONING_PROFILE` secret below.

The App ID prefix gives the access group. The portal has no Keychain Sharing
capability. That switch is in Xcode, and it only writes the entitlements file.
The passkey capability is the opposite. Only the portal can enable it. A build
fails at the provisioning step until you do.

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
`5X68L55TNU`. Do not configure the workflows until the organization Account
Holder has approved the managed browser capability and all nine own secrets
exist in the protected release environment.

## Each release

The release does not run the tests. Merge the release changes through a PR
targeting `main`, then tag the merged commit. CI tests each push to `main`, and
the release workflow reads the result. Refresh `origin/main` before tagging:

```bash
git fetch origin main
git tag v1.1 origin/main && git push origin v1.1
```

Push the tag as soon as the commit is on `main`. You do not have to wait for
CI, because the `gate` job waits for you. From there the workflow:

1. Confirms the tag is on `main`.
2. Waits for the CI run on that commit, and stops if it fails.
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

The workflow takes 20 to 40 minutes, plus the time that CI still needs. The
Apple notary service uses most of this time, and the workflow waits for it two
times.

If CI fails on that commit, the `gate` job stops the release. No signing key is
used. Correct the code, push it, then make the next tag. Do not move a tag that
you already pushed.

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

## Preview builds

WSurf has two update channels. A release is the default. A preview build comes
from the newest commit on `main`, before a release.

To follow preview builds, open Settings › About and set Update channel to
Preview. Sparkle reads the other feed at the next check, with no restart.

### What the workflow does

`.github/workflows/tip.yml` runs each time CI passes on `main`. No manual trigger
or tag is needed. The workflow:

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
