#!/bin/sh
# Runs the tests that need a logged-in, unlocked desktop session with WSurf in front: the native hover tests, which move the
# real pointer, and the Chromium viewport and device-profile cases, which need a window brought forward (a window behind
# another app keeps its renderer at the old size). The suites skip them unless WSURF_COMPUTER_FOREGROUND_TEST=1 reaches the test
# host, and xcodebuild passes only variables with the TEST_RUNNER_ prefix on to it.
#
# Run it from the repository root after `build-for-testing` (see CONTRIBUTING.md, "Test behavior"), from a desktop session
# where nothing else is in front and the display is awake:
#
#   WSURF_BUNDLE_ID_SUFFIX=.dev-<name> Tools/run-foreground-tests.sh
#
# WSURF_BUNDLE_ID_SUFFIX must be the suffix the build used; the identity check refuses an empty one.
# WSURF_DERIVED_DATA is the build's DerivedData path (default build/DD).
# WSURF_NATIVE_LOCK is an optional command prefix, such as a lock wrapper, that every native operation runs under.
set -eu

: "${WSURF_BUNDLE_ID_SUFFIX:?set WSURF_BUNDLE_ID_SUFFIX to the suffix of the build}"
export WSURF_BUNDLE_ID_SUFFIX
derived=${WSURF_DERIVED_DATA:-build/DD}
lock=${WSURF_NATIVE_LOCK:-}

set -- "$derived"/Build/Products/WSurf_*.xctestrun
if [ "$#" -ne 1 ] || [ ! -f "$1" ]; then
  echo "error: expected exactly one .xctestrun in $derived/Build/Products; run build-for-testing first" >&2
  exit 1
fi
xctestrun=$1

# shellcheck disable=SC2086 # $lock is a command prefix and may hold several words.
$lock /usr/bin/python3 -I Tools/check-built-identity.py "$derived" "$xctestrun"

mkdir -p build/results
result=build/results/foreground-$(date -u +%Y%m%dT%H%M%SZ).xcresult
# shellcheck disable=SC2086
TEST_RUNNER_WSURF_COMPUTER_FOREGROUND_TEST=1 $lock /usr/bin/python3 -I Tools/run-xcodebuild-with-watchdog.py -- \
  xcodebuild test-without-building \
  -xctestrun "$xctestrun" -destination 'platform=macOS,arch=arm64' \
  -resultBundlePath "$result" -parallel-testing-enabled NO \
  '-only-testing:WSurfTests/PageComputerInputTests/nativeHoverReachesPageHandlersAndCSS()' \
  '-only-testing:WSurfTests/PageComputerInputTests/hoverTriggersCssHover()' \
  '-only-testing:WSurfTests/PageComputerInputTests/hoverFailsWhenCoveredOrOffscreen()' \
  '-only-testing:WSurfTests/MCPDevelopmentOwnershipTests/viewportIsMeasuredInThePageAndResetRestoresIt(engine:)' \
  '-only-testing:WSurfTests/MCPDevelopmentOwnershipTests/phoneProfileAppliesDPRTouchAndMobileOnChromium()' \
  '-only-testing:WSurfTests/MCPDevelopmentOwnershipTests/elementScreenshotScaleAtPhoneDeviceScaleOnChromium()'
