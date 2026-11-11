#!/bin/bash
# SPDX-FileCopyrightText: 2026 WSurf Agency
# SPDX-License-Identifier: BUSL-1.1
#
# The out-of-process Chromium lane (D4, Packages/CefSwift/WSURF-PATCHES.md patch 3):
#
#   WSURF_BUNDLE_ID_SUFFIX=.dev-<name> "$LOCK" Tools/run-chromium-oop-tests.sh ChromiumServiceBundleTests ChromiumLoadTests
#   ... Tools/run-chromium-oop-tests.sh --build-only      (steps 1 and 2 only)
#
# 1. build-for-testing with WSURF_CHROMIUM_OOP_BUILD=YES into its own DerivedData (build/DD-oop; WSURF_OOP_DERIVED_DATA
#    overrides it), ad hoc, with the caller's WSURF_BUNDLE_ID_SUFFIX. Its own, because Tools/embed-chromium.sh only adds files:
#    a build without the switch in the same DerivedData would leave a stale service, and a build with it would find the
#    default layout's copy of CEF.
# 2. Tools/check-built-identity.py, which knows the service's id and the one-copy helper paths, and refuses a build without
#    the service.
# 3. test-without-building -parallel-testing-enabled NO, -only-testing for each suite named (a suite of WSurfTests).
#
# Like every build and test run it must hold the Pro lock: start it as above, detached. The lock is not taken here, so that a
# caller that holds it for several steps takes it once. It is not part of Tools/ci-local.sh or any test plan. Suites that need the
# service gate each test on ChromiumServiceBundle.isPresent, and are skipped in the default lane.
set -euo pipefail

cd "$(dirname "$0")/.."
buildOnly=
if [[ "${1:-}" == --build-only ]]; then
    buildOnly=YES
    shift
elif [[ "$#" -eq 0 ]]; then
    echo "usage: WSURF_BUNDLE_ID_SUFFIX=.dev-<name> $0 [--build-only | <Suite>...]" >&2
    exit 2
fi
: "${WSURF_BUNDLE_ID_SUFFIX:?set WSURF_BUNDLE_ID_SUFFIX to your own test identity suffix, as Tools/ci-local.sh does}"
export WSURF_BUNDLE_ID_SUFFIX
# The identity check refuses stage variables, and so does this lane: a test host must not inherit them.
for key in $(env | sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p'); do
    case "$key" in
        WSURF_STAGE*|TEST_RUNNER_WSURF_STAGE*|*WSURF_*LIVE_*|*WSURF_*FOREGROUND_TEST*)
            echo "error: refusing opt-in or Stage environment: $key" >&2; exit 2 ;;
    esac
done

DD="${WSURF_OOP_DERIVED_DATA:-$PWD/build/DD-oop}"
OUT="$PWD/build/oop-lane/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$OUT"
export WSURF_CI_RAW_LOG="$OUT/console.raw.log"

echo "=== resolve packages ($DD)"
xcodebuild -resolvePackageDependencies -project WSurf.xcodeproj -scheme WSurf -derivedDataPath "$DD" \
    -onlyUsePackageVersionsFromResolvedFile
echo "=== build-for-testing (WSURF_CHROMIUM_OOP_BUILD=YES, $DD)"
python3 Tools/run-xcodebuild-with-watchdog.py -- xcodebuild build-for-testing -quiet \
    -project WSurf.xcodeproj -scheme WSurf \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DD" \
    -skipMacroValidation \
    -disableAutomaticPackageResolution \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_ENTITLEMENTS= \
    WSURF_BUNDLE_ID_SUFFIX="$WSURF_BUNDLE_ID_SUFFIX" \
    WSURF_CHROMIUM_OOP_BUILD=YES

set -- "$DD"/Build/Products/*.xctestrun "$@"
xctestrun="$1"
shift
[[ -f "$xctestrun" && "$(ls "$DD"/Build/Products/*.xctestrun | wc -l)" -eq 1 ]] || {
    echo "error: expected exactly one generated .xctestrun in $DD/Build/Products" >&2; exit 1; }

echo "=== check-built-identity"
WSURF_CHROMIUM_OOP_BUILD=YES python3 -I Tools/check-built-identity.py "$DD" "$xctestrun"

if [[ -n "$buildOnly" ]]; then
    echo "=== OOP lane built: $DD"
    exit 0
fi
selection=()
for suite in "$@"; do
    selection+=("-only-testing:WSurfTests/$suite")
done
echo "=== test-without-building: $*"
code=0
python3 Tools/run-xcodebuild-with-watchdog.py -- xcodebuild test-without-building \
    -xctestrun "$xctestrun" \
    -destination 'platform=macOS,arch=arm64' \
    -resultBundlePath "$OUT/oop.xcresult" \
    -parallel-testing-enabled NO \
    "${selection[@]}" || code=$?
# The cases are exported also after a failed run: a caller that expects a failure reads them.
xcrun xcresulttool get test-results tests --path "$OUT/oop.xcresult" --compact > "$OUT/oop-tests.json" \
    || echo "warning: could not export the test cases"
echo "=== OOP lane done (exit $code): $OUT"
exit "$code"
