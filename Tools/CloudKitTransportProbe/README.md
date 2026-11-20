# Two-Mac CloudKit transport trial

Studio creates a synthetic marker in the WSurf private CloudKit Development database.
Air acknowledges it. Studio reads the reply and clears the marker's encrypted payload.
Each trial addresses one UUID-named `Device` record in the reusable private zone
`wsurf-development-transport-v2`. The helper runs as a background-only bundle with
the WSurf app ID, Development container and development push entitlements.

Use the physical Studio and Air covered by the selected profile, with users already
signed in to the same Apple Account for iCloud. The helper hashes the Mac product
model (`hw.model`) with the trial nonce. The two models must differ. A second
directory, user or invocation on Studio produces the same tag and cannot acknowledge
Studio's marker. Tags vary between trials. The payload contains the tags, protocol
version and nonce. The tool reads the model class without accessing a serial number or
hardware UUID.

## Check offline

Run this from the project root on Pro. The offline tests use an in-memory database and
synthetic Mac models. They cover neighboring records, concurrent changes, lost replies,
same-Mac acknowledgements, and publishing the signed bundle only after verification.

```sh
python3 -B Tools/CloudKitTransportProbe/build.py self-test
```

## Sign and transfer

Use the clean, reviewed merge commit after its CI passes. Refresh `origin/main` before
checking out that commit. Set `WSURF_PROFILE` to the installed host development
profile UUID and `WSURF_DEV_SIGN_IDENTITY` to its Apple Development signing identity.
The tool stages the build in a temporary sibling directory. It checks the signature,
entitlements and embedded profile, runs the offline self-test, and publishes the
verified bundle atomically. A failed check leaves the requested destination available
for retry. The signed Info.plist contains the source commit.

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

1. On **Studio**, run `"$PROBE" begin`. It writes `wsurf-probe-<nonce>.receipt`
   before contacting CloudKit and prints `NONCE=<nonce>`. Once the marker is saved,
   copy that assignment into both shells. Keep Studio's directory and receipt until
   cleanup succeeds.
2. On **Air**, run `"$PROBE" answer "$NONCE"` with Studio's nonce. It checks the
   marker, requires a different model tag and uses the record's change tag to
   acknowledge that version. Repeating the command accepts Air's existing reply.
3. In **Studio's original working directory**, run `"$PROBE" confirm "$NONCE"`.
   Success means Studio read Air's acknowledgement in the same private Development
   database.
4. On **Studio**, run `"$PROBE" cleanup "$NONCE"` from the original directory.
   It checks the receipt and marker, empties the encrypted payload, and saves the
   fetched record with `.ifServerRecordUnchanged`. A conflicting change fails and
   preserves the server version. Cleanup leaves the shared probe zone, the record
   ID with its nonce, an empty payload, and CloudKit system metadata. No device
   tag remains in the current payload. Other records in the zone are untouched.

If an operation is interrupted, recover the nonce from the receipt filename
in Studio's saved directory. Verify Studio still uses the trial's Apple Account.
Run `"$PROBE" resume "$NONCE"` there to finish setup after a lost zone or marker
save response. It reuses the original record and preserves any acknowledgement.
To end an interrupted trial, use `cleanup` with the same receipt. If it reports an
absent marker, retain the receipt and check the original account before retrying.
After a lost cleanup response, a second cleanup accepts the empty payload.

The marker uses the encrypted `payload` field on record type `Device`. A first
Development write can initialize this type in its schema.
A successful round trip verifies private CloudKit transport for the two Macs.
The WSurf tab-sharing and vault acceptance tests exercise separate UI and passkey
paths using disposable data. [WSurf signing and device trials](../../RELEASING.md#test-icloud-with-an-apple-development-signature)
