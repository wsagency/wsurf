# Two-Mac CloudKit transport trial

Studio creates a synthetic marker in the WSurf private CloudKit Development database.
Air reads and acknowledges the marker. Studio reads the acknowledgement and deletes
the trial's zone. Each operation addresses the record or zone directly by a random
nonce. The helper uses a separate executable inside a background-only app bundle.
It requests the WSurf app ID, development container and push entitlements for this trial.
Run it on two Macs covered by the development profile, using macOS users already
signed in to the same Apple Account for iCloud.

## Check offline

Run this from the project root on Pro. The offline checks cover marker ownership,
nonce validation and interrupted trials using local SDK objects and temporary files.

```sh
python3 -B Tools/CloudKitTransportProbe/build.py self-test
```

## Sign and transfer

Use the clean, reviewed merge commit after its CI passes. Refresh `origin/main` before
checking out that commit. Set `WSURF_PROFILE` to the installed host development
profile UUID and `WSURF_DEV_SIGN_IDENTITY` to its Apple Development signing identity.
The signing tool checks the certificate, restricted entitlements and embedded profile,
and records the source commit in the signed helper's Info.plist.

```sh
set -eu
: "${WSURF_PROFILE:?Set the approved host development profile UUID}"
: "${WSURF_DEV_SIGN_IDENTITY:?Set its Apple Development signing identity}"
profile_dir="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"
trial_dir="$PWD/build/icloud-transport/signed-$(git rev-parse --short=12 HEAD)"
python3 -B Tools/CloudKitTransportProbe/build.py sign \
  "$profile_dir/$WSURF_PROFILE.provisionprofile" "$WSURF_DEV_SIGN_IDENTITY" "$trial_dir"
ditto -c -k --sequesterRsrc --keepParent \
  "$trial_dir/WSurfCloudTransport.app" "$trial_dir/WSurfCloudTransport.zip"
shasum -a 256 "$trial_dir/WSurfCloudTransport.zip"
```

Transfer this same archive to Studio and Air. Match its SHA-256 on each Mac before
unpacking it. Use a private directory under `$TMPDIR`, invoke the executable directly,
and keep the working directory and output until cleanup completes. This avoids
installing the app or invoking LaunchServices. Run the following on each Mac with
`PROBE_ZIP` set to the absolute path of the verified archive.

```sh
umask 077
TRIAL_HOME=$(mktemp -d "${TMPDIR:-/tmp}/wsurf-development-trial.XXXXXX")
ditto -x -k "$PROBE_ZIP" "$TRIAL_HOME"
cd "$TRIAL_HOME"
PROBE="$TRIAL_HOME/WSurfCloudTransport.app/Contents/MacOS/WSurfCloudTransport"
printf 'Trial working directory: %s\n' "$TRIAL_HOME"
```

1. On **Studio**, run `"$PROBE" begin`. It refuses an existing zone, writes
   `wsurf-probe-<nonce>.receipt`, then prints `NONCE=<nonce>`. Once the marker is
   saved, copy that assignment into both shells. Keep Studio's working directory
   and the receipt until cleanup succeeds.
2. On **Air**, run `"$PROBE" answer "$NONCE"` with Studio's nonce. It checks the
   marker and uses its change tag to acknowledge that version.
3. In **Studio's original working directory**, run `"$PROBE" confirm "$NONCE"`.
   Success means Studio read Air's acknowledgement in the same private Development
   database.
4. On **Studio**, run `"$PROBE" cleanup "$NONCE"` with the creator's receipt. It
   accepts only this trial's marker. After interrupted setup, a confirmed creation
   receipt also permits cleanup of that trial's empty zone. Keep the receipt after
   an error and retry. If the output says the zone is absent, verify Studio is
   still using the trial's Apple Account before removing the private working directory.

If interrupted before copying the nonce, recover it from the receipt filename and
its second line in Studio's saved directory. A `pending` receipt means Studio
observed a fresh nonce and had not recorded confirmation of zone creation. If an
empty zone exists and creation is unconfirmed, the helper refuses to delete it.
Keep that receipt for investigation. Repeating `answer`, `confirm` or `cleanup`
addresses the same record or zone.

The marker uses the encrypted `payload` field on record type `Device` in a unique
probe zone. A first Development write can initialize this type in its schema.
A successful round trip verifies private CloudKit transport for the two Macs.
The WSurf tab-sharing and vault acceptance tests exercise separate UI and passkey
paths using disposable data. [WSurf signing and device trials](../../RELEASING.md#test-icloud-with-an-apple-development-signature)
