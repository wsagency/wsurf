#!/bin/bash
# SPDX-FileCopyrightText: 2026 wsagency
# SPDX-License-Identifier: BUSL-1.1
#
# Shared native validation for local worktrees and the GitHub CI and release jobs.
#   Tools/ci-local.sh [--tier quick|minor] [--base REF] [--suite SUITE[/CASE] ...]
# Quick is the default. Minor is the complete functional and performance gate, followed by resource benchmarks.
# Exit 0 only if every step passed; a one-line PASS/FAIL/SKIP per step at the end.
#
# NOTE: the performance budgets in Tools/check-performance.sh are tuned for the CI runner. The Pro is faster, so a green
# run here does not guarantee a green run on GitHub (and the Xcode here may be newer than the pinned one).
#
# Differences from CI, on purpose:
#   - Runner-only steps are printed and skipped: actions caches, artifact uploads, the hosted Metal download, the SwiftLint
#     download (put the pinned SwiftLint on PATH or set SWIFTLINT_BIN).
#   - The whole run holds the shared Pro lock (WSURF_PRO_LOCK, a with-pro-lock.sh; set it empty on a Mac without one).
#   - One fixed test identity (WSURF_BUNDLE_ID_SUFFIX, default .ci-local), reused run after run, so CI's last step, which
#     removes a per-run identity with rm -rf and defaults delete, is skipped.
#   - Each run writes to a fresh build/ci-local/<UTC stamp>/; build/DD is kept, so a rerun builds incrementally.
#   - Pro disk hygiene (Tools/disk-hygiene.sh, AGENTS.md): the run aborts below 30 GB free, uses its own TMPDIR and removes
#     its identities' code_sign_clone on exit. After a PASS it deletes the .xcresult bundles (the JSON and checksum evidence
#     stays) and the one-off build/DD-oop and build/cefkit-tests, and build/DD too with WSURF_CLEAN_DERIVED_DATA=1;
#     WSURF_KEEP_XCRESULT=1 keeps all of it. Failed bundles older than 48 hours in build/ci-local go. GitHub keeps everything
#     for its uploads. WSURF_SOURCE_PACKAGES_CACHE names a shared, pinned SourcePackages directory to clone packages into.
#   - Opt-in suites (live, foreground, microphone, Stage...) are refused through their environment, as the local gate does:
#     the default plans ask the system for no permission.
#   Set WSURF_CEF_PACKAGE only to a CefSwift package with the same sources; a fresh worktree otherwise downloads CEF once.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ "${1:-}" == --help ]]; then
  python3 -B Tools/select-validation-tests.py plan --help
  exit 0
fi

LOCK="${WSURF_PRO_LOCK-/Users/klukacin/Library/Application Support/Claude/side-session-notes/local_a84c7367-175a-4e1d-8e46-7298dec65c7f/release-0-1-1/with-pro-lock.sh}"
if [ -n "$LOCK" ] && [ -z "${WSURF_CI_LOCAL_LOCKED:-}" ]; then
  [ -x "$LOCK" ] || { echo "error: Pro lock wrapper not found: $LOCK (set WSURF_PRO_LOCK= to run without one)" >&2; exit 2; }
  WSURF_CI_LOCAL_LOCKED=1 exec "$LOCK" "$0" "$@"
fi

PROJECT=WSurf.xcodeproj
SCHEME=WSurf
XCODE=$(sed -n "s/^  XCODE: '\(.*\)'$/\1/p" .github/workflows/ci.yml)
SWIFTLINT=$(sed -n "s/^  SWIFTLINT: '\(.*\)'$/\1/p" .github/workflows/ci.yml)
export WSURF_BUNDLE_ID_SUFFIX="${WSURF_BUNDLE_ID_SUFFIX:-.ci-local}"
DD="$PWD/build/DD"
# shellcheck source=Tools/disk-hygiene.sh
. Tools/disk-hygiene.sh
wsurf_preflight_disk_guard || exit 2
wsurf_setup_run_tmpdir
trap 'wsurf_exit_cleanup "io.wsagency.wsurf$WSURF_BUNDLE_ID_SUFFIX" "io.wsagency.wsurf$WSURF_BUNDLE_ID_SUFFIX-oop"' EXIT
SOURCE_PACKAGES="$DD/SourcePackages"
SPM_ARGS=()
if [ -n "${WSURF_SOURCE_PACKAGES_CACHE:-}" ]; then
  mkdir -p "$WSURF_SOURCE_PACKAGES_CACHE"
  SOURCE_PACKAGES="$(cd "$WSURF_SOURCE_PACKAGES_CACHE" && pwd -P)"
  export WSURF_SOURCE_PACKAGES_CACHE="$SOURCE_PACKAGES"
  SPM_ARGS=(-clonedSourcePackagesDirPath "$SOURCE_PACKAGES")
fi
OUT="${WSURF_CI_OUTPUT:-build/ci-local/$(date -u +%Y%m%dT%H%M%SZ)}"
[ ! -e "$OUT" ] || { echo "error: validation output already exists: $OUT" >&2; exit 2; }
mkdir -p "$OUT/results"
OUT="$(cd "$OUT" && pwd -P)"
manifest="$OUT/validation-plan.json"
python3 -B Tools/select-validation-tests.py plan --tier quick "$@" > "$manifest"
tier=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tier"])' "$manifest")
echo "Validation: $tier ($manifest)"
coverage=NO
[ "$tier" != minor ] || coverage=YES
# The watchdog appends every build and test output line, byte for byte, to this file and prints a compact console
# (host os_log mirror noise dropped, every result, failure, crash and time-limit line kept). WSURF_CI_VERBOSE=1 prints it all.
export WSURF_CI_RAW_LOG="$OUT/console.raw.log"

for key in $(env | sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p'); do
  case "$key" in
    WSURF_STAGE*|TEST_RUNNER_WSURF_STAGE*|*WSURF_*LIVE_*|*WSURF_*FOREGROUND_TEST*|*WSURF_*VOICE_UI_TEST*|*WSURF_*OAUTH_UI_TEST*|\
    *WSURF_*MIC_CAPTURE_TEST*|*WSURF_*VAULT_BENCHMARK*|*WSURF_*PERF_BENCH*|*WSURF_*PERF_SOAK*|*WSURF_*REAL_FULLSCREEN*)
      echo "error: refusing opt-in or Stage environment: $key" >&2; exit 2 ;;
  esac
done

# Inside step, set -e is off (the command runs under ||), so the functions below return on failure explicitly.
SUMMARY=()
FAILED=0
step() {  # step NAME COMMAND...: run, time and record one step
  local name="$1" start=$SECONDS code=0
  shift
  echo "=== $name"
  "$@" || code=$?
  local result=PASS
  [ "$code" -eq 0 ] || { result="FAIL (exit $code)"; FAILED=1; }
  SUMMARY+=("$(printf '%-28s %-14s %5ss' "$name" "$result" $((SECONDS - start)))")
  return 0
}
skip() { echo "=== $1: SKIPPED ($2)"; SUMMARY+=("$(printf '%-28s %-14s %s' "$1" SKIP "$2")"); }
finish() {
  echo
  echo "=== ci-local summary ($(git rev-parse --short HEAD), $OUT)"
  printf '%s\n' "${SUMMARY[@]}"
  if [ "$FAILED" -eq 0 ]; then
    xcodebuild -version > "$OUT/xcode-version.txt"
    shasum -a 256 "$manifest" "$OUT"/results/*-tests.json > "$OUT/verified-results.sha256"
    local intermediates=("$PWD/build/DD-oop" "$PWD/build/cefkit-tests")
    [ "${WSURF_CLEAN_DERIVED_DATA:-0}" != 1 ] || intermediates+=("$DD")
    wsurf_cleanup_pass_artifacts "$OUT" "${intermediates[@]}" || echo "warning: some build intermediates were kept"
    echo "ci-local: PASS"
  else
    echo "ci-local: FAIL"
  fi
  wsurf_prune_old_failed_xcresults "$PWD/build/ci-local"
  exit "$FAILED"
}
gate() { [ "$FAILED" -eq 0 ] || finish; }  # CI stops at a failed step before the tests

select_xcode() {
  local first
  first=$(xcodebuild -version | head -n 1)
  echo "$first at $(xcode-select -p)"
  case "$(xcode-select -p)" in *beta*) echo "error: the selected Xcode is a beta" >&2; return 1 ;; esac
  [ "$first" = "Xcode $XCODE" ] || echo "warning: CI pins Xcode $XCODE; this run uses $first"
}

lint() {
  local bin="${SWIFTLINT_BIN:-$(command -v swiftlint || true)}"
  if [ -z "$bin" ] || [ "$("$bin" version)" != "$SWIFTLINT" ]; then
    echo "error: put SwiftLint $SWIFTLINT on PATH or set SWIFTLINT_BIN" >&2
    return 1
  fi
  env PATH="$(dirname "$bin"):$PATH" Tools/check-format.sh
}

acknowledgements() {
  swift Tools/make-acknowledgements.swift "$SOURCE_PACKAGES/checkouts" || return
  git diff --quiet -- WSurf/Support/Acknowledgements.json || {
    echo "error: WSurf/Support/Acknowledgements.json is out of date. Run: swift Tools/make-acknowledgements.swift" >&2
    git diff --stat -- WSurf/Support/Acknowledgements.json
    return 1
  }
}

build_for_testing() {
  python3 Tools/run-xcodebuild-with-watchdog.py -- xcodebuild build-for-testing -quiet \
    -project "$PROJECT" -scheme "$SCHEME" \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DD" \
    ${SPM_ARGS[@]+"${SPM_ARGS[@]}"} \
    -skipMacroValidation \
    -enableCodeCoverage "$coverage" \
    -disableAutomaticPackageResolution \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_ENTITLEMENTS= \
    WSURF_BUNDLE_ID_SUFFIX="$WSURF_BUNDLE_ID_SUFFIX" "$@" || return
  set -- "$DD"/Build/Products/*.xctestrun
  [ "$#" -eq 1 ] && [ -f "$1" ] || { echo "error: expected exactly one generated .xctestrun in $DD/Build/Products" >&2; return 1; }
  xctestrun="$1"
  python3 Tools/check-built-identity.py "$DD" "$xctestrun" || return
}

run_test_plan() {
  local plan="$1" limit="$2"
  shift 2
  WSURF_CI_TEST_LIMIT_SECONDS="$limit" python3 Tools/run-xcodebuild-with-watchdog.py -- xcodebuild test-without-building \
    -xctestrun "$xctestrun" \
    -destination 'platform=macOS,arch=arm64' \
    -resultBundlePath "$OUT/results/$plan.xcresult" \
    "$@"
}

test_runs() {
  local total="${WSURF_CI_TEST_LIMIT_SECONDS:-5400}" start=$SECONDS failed="" plans plan remaining
  local default_run="$xctestrun" oop_mode="" debug_ops oop_dd="$PWD/build/DD-oop"
  plans=$(python3 -B Tools/select-validation-tests.py runs "$manifest") || return
  while IFS= read -r plan; do
    python3 -B Tools/select-validation-tests.py args "$manifest" "$plan" > "$OUT/results/$plan.args" || return
    local selection=()
    local line
    while IFS= read -r line; do selection+=("$line"); done < "$OUT/results/$plan.args"
    echo "--- $plan (${#selection[@]} selection arguments, $((SECONDS - start))s into the tests)"
    if [[ "$plan" != WSurf-* && -n "$failed" ]]; then break; fi
    case "$plan" in
      WSurf-*)
        remaining=$((total - (SECONDS - start)))
        [ "$remaining" -gt 0 ] || { echo "error: test budget of ${total}s spent before $plan started" >&2; return 124; }
        run_test_plan "$plan" "$remaining" -enableCodeCoverage "$coverage" "${selection[@]}" || failed="$failed $plan"
        ;;
      Vault-Scale)
        TEST_RUNNER_WSURF_VAULT_BENCHMARK=1 run_test_plan "$plan" 10800 -enableCodeCoverage NO \
          -default-test-execution-time-allowance 3600 -maximum-test-execution-time-allowance 3600 \
          "${selection[@]}" || failed="$failed $plan"
        ;;
      WebKit-Resources|Chromium-Resources|Chromium-First-Tab|Chromium-Engine)
        TEST_RUNNER_WSURF_PERF_BENCH=1 TEST_RUNNER_WSURF_PERF_SOAK=1 run_test_plan "$plan" 1800 -enableCodeCoverage NO \
          -default-test-execution-time-allowance 600 -maximum-test-execution-time-allowance 900 \
          "${selection[@]}" || failed="$failed $plan"
        ;;
      OOP-*)
        debug_ops=YES
        [ "$plan" != OOP-NoDebug ] || debug_ops=NO
        if [ "$oop_mode" != "$debug_ops" ]; then
          WSURF_BUNDLE_ID_SUFFIX="$WSURF_BUNDLE_ID_SUFFIX-oop" WSURF_OOP_DERIVED_DATA="$oop_dd" \
            WSURF_SERVICE_DEBUG_OPS="$debug_ops" Tools/run-chromium-oop-tests.sh --build-only || return
          local oop_runs=("$oop_dd"/Build/Products/*.xctestrun)
          [ "${#oop_runs[@]}" -eq 1 ] && [ -f "${oop_runs[0]}" ] || return 2
          oop_mode="$debug_ops"
        fi
        xctestrun="${oop_runs[0]}"
        WSURF_BUNDLE_ID_SUFFIX="$WSURF_BUNDLE_ID_SUFFIX-oop" WSURF_CHROMIUM_OOP_BUILD=YES \
          run_test_plan "$plan" 1800 -enableCodeCoverage NO "${selection[@]}" || failed="$failed $plan"
        xctestrun="$default_run"
        ;;
      Optimized-Smoke)
        coverage=NO build_for_testing SWIFT_OPTIMIZATION_LEVEL=-O ENABLE_DEBUG_DYLIB=NO ENABLE_HARDENED_RUNTIME=NO || return
        run_test_plan "$plan" 900 -enableCodeCoverage NO "${selection[@]}" || failed="$failed $plan"
        ;;
      *) echo "error: unknown run $plan" >&2; return 2 ;;
    esac
    if [ -f "$OUT/results/$plan.xcresult/Info.plist" ]; then
      xcrun xcresulttool get test-results tests --path "$OUT/results/$plan.xcresult" --compact \
        > "$OUT/results/$plan-tests.json" || echo "warning: could not export the test cases of $plan"
    fi
  done <<< "$plans"
  [ -z "$failed" ] || { echo "error: failed test runs:$failed" >&2; return 1; }
}

test_cefkit() {
  local framework="$DD/Build/Products/Debug/WSurf.app/Contents/Frameworks/Chromium Embedded Framework.framework"
  [ -d "$framework" ] || { echo "error: no Framework for CefKitTests at $framework" >&2; return 2; }
  CEF_FRAMEWORK_PATH="$framework" python3 Tools/run-xcodebuild-with-watchdog.py -- \
    swift test --package-path Packages/CefSwift --scratch-path "$PWD/build/cefkit-tests" --no-parallel
}

export_metrics() {
  [ -f "$OUT/results/WSurf-Rest.xcresult/Info.plist" ] || { echo "no WSurf-Rest result bundle" >&2; return 1; }
  xcrun xcresulttool get test-results metrics --path "$OUT/results/WSurf-Rest.xcresult" --compact > "$OUT/performance-metrics.json"
}

step "Select Xcode" select_xcode
step "Verify Metal toolchain" xcrun metal --version
step "Check format" lint
step "Check watchdog" python3 Tools/check-watchdog.py
step "Check coverage script" python3 Tools/check-coverage-script.py
step "Check validation selector" python3 -B Tools/check-validation-selection.py
step "Check development iCloud signing" python3 -B Tools/check-icloud-development-signing-tests.py
step "Check CloudKit transport probe" python3 -B Tools/CloudKitTransportProbe/build.py self-test
step "Check test partition" python3 Tools/check-test-partition.py
step "Check website design kit" python3 -B Tools/update-design-system.py --check
step "Check disk hygiene" python3 -B Tools/check-disk-hygiene.py
skip "Cache Swift packages/CEF" "runner cache; build/DD and Packages/CefSwift/.cef persist here"
gate
step "Resolve packages" xcodebuild -resolvePackageDependencies \
  -project "$PROJECT" -scheme "$SCHEME" -derivedDataPath "$DD" ${SPM_ARGS[@]+"${SPM_ARGS[@]}"} -onlyUsePackageVersionsFromResolvedFile
gate
step "Check acknowledgements" acknowledgements
gate
step "Build for testing" build_for_testing
gate
step "Test" test_runs
if python3 -c 'import json, sys; sys.exit(not json.load(open(sys.argv[1]))["cefkit"])' "$manifest"; then
  step "Test CefKit" test_cefkit
fi
# After the tests every check runs, so one run shows the test, coverage and performance verdicts together.
step "Check selected results" python3 -B Tools/select-validation-tests.py verify "$manifest" "$OUT/results"
if [ "$tier" = minor ]; then
  step "Merge test results" xcrun xcresulttool merge "$OUT/results/WSurf-Serial-1.xcresult" "$OUT/results/WSurf-Serial-2.xcresult" \
    "$OUT/results/WSurf-Serial-3.xcresult" "$OUT/results/WSurf-Rest.xcresult" --output-path "$OUT/TestResults.xcresult"
  step "Check coverage" Tools/check-coverage.sh "$OUT/TestResults.xcresult" 24.0
  step "Export performance metrics" export_metrics
  step "Check performance budgets" Tools/check-performance.sh "$OUT/performance-metrics.json"
else
  skip "Coverage and budgets" "minor validation"
fi
skip "Uploads" "artifacts stay in $OUT"
skip "Remove test identity" "fixed identity io.wsagency.wsurf$WSURF_BUNDLE_ID_SUFFIX is reused; only its code_sign_clone goes on exit"
finish
