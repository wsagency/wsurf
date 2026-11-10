#!/bin/bash
# SPDX-FileCopyrightText: 2026 wsagency
# SPDX-License-Identifier: BUSL-1.1
#
# Tools/ci-local.sh: the "Build and test" job of .github/workflows/ci.yml, step for step, on this Mac.
# Exit 0 only if every step passed; a one-line PASS/FAIL/SKIP per step at the end.
#
# NOTE: the performance budgets in Tools/check-performance.sh are tuned for the CI runner. The Pro is faster, so a green
# run here does not guarantee a green run on GitHub (and the Xcode here may be newer than the pinned one).
#
# Differences from CI, on purpose:
#   - Runner-only steps are printed and skipped: actions caches, artifact uploads, the hosted Metal download, the SwiftLint
#     download (the pinned SwiftLint must already be on PATH, or set SWIFTLINT_BIN; otherwise lint is SKIPPED, not installed).
#   - The whole run holds the shared Pro lock (WSURF_PRO_LOCK, a with-pro-lock.sh; set it empty on a Mac without one).
#   - One fixed test identity (WSURF_BUNDLE_ID_SUFFIX, default .ci-local), reused run after run, so CI's last step, which
#     removes a per-run identity with rm -rf and defaults delete, is skipped.
#   - Each run writes to a fresh build/ci-local/<UTC stamp>/; build/DD is kept, so a rerun builds incrementally.
#   - A budgeted performance case that misses its budget by at most 25 % is measured once more, in the context it failed in: the
#     WSurf-Rest plan is run again in the same hold (perf_gate), and only the missed cases are judged on that rerun. A case that
#     meets the budget the second time passes; the step row reads "PASS (retried: ...)", the last line reads "ci-local: PASS
#     (performance retried: ...)" and $OUT/perf-retried.tsv holds both statistics. A miss of more than 25 %, a case that misses
#     twice, or a rerun that fails or yields no metric fails the step. The load averages during the first Rest run and the rerun
#     are printed. GitHub CI never retries.
#   - "Tools/ci-local.sh --perf-gate-only OUTDIR BUILD_DD" judges only the performance step on an existing run's metrics (and
#     reruns the WSurf-Rest plan from BUILD_DD's products if a case missed); it ends "ci-local: PERF-GATE-ONLY PASS (not a merge
#     gate)". It exists to prove the retry without a full run. WSURF_CI_PERF_GATE_ONLY and WSURF_CI_DD are refused in every run.
#   - Opt-in suites (live, foreground, microphone, Stage...) are refused through their environment, as the local gate does:
#     the default plans ask the system for no permission.
#   Set WSURF_CEF_PACKAGE only to a CefSwift package with the same sources; a fresh worktree otherwise downloads CEF once.
set -euo pipefail
cd "$(dirname "$0")/.."

LOCK="${WSURF_PRO_LOCK-/Users/klukacin/Library/Application Support/Claude/side-session-notes/local_a84c7367-175a-4e1d-8e46-7298dec65c7f/release-0-1-1/with-pro-lock.sh}"
if [ -n "$LOCK" ] && [ -z "${WSURF_CI_LOCAL_LOCKED:-}" ]; then
  [ -x "$LOCK" ] || { echo "error: Pro lock wrapper not found: $LOCK (set WSURF_PRO_LOCK= to run without one)" >&2; exit 2; }
  WSURF_CI_LOCAL_LOCKED=1 exec "$LOCK" "$0" "$@"
fi

PERF_ONLY=""
PERF_ONLY_DD=""
if [ "${1:-}" = "--perf-gate-only" ]; then
  [ "$#" -eq 3 ] || { echo "usage: Tools/ci-local.sh --perf-gate-only OUTDIR BUILD_DD" >&2; exit 2; }
  PERF_ONLY="$2"
  PERF_ONLY_DD="$3"
elif [ "$#" -gt 0 ]; then
  echo "error: unknown argument: $1" >&2; exit 2
fi

PROJECT=WSurf.xcodeproj
SCHEME=WSurf
XCODE=$(sed -n "s/^  XCODE: '\(.*\)'$/\1/p" .github/workflows/ci.yml)
SWIFTLINT=$(sed -n "s/^  SWIFTLINT: '\(.*\)'$/\1/p" .github/workflows/ci.yml)
export WSURF_BUNDLE_ID_SUFFIX="${WSURF_BUNDLE_ID_SUFFIX:-.ci-local}"
DD="$PWD/build/DD"
if [ -n "$PERF_ONLY" ]; then
  OUT="$PERF_ONLY"
  DD="$PERF_ONLY_DD"
  [ -f "$OUT/performance-metrics.json" ] || { echo "error: no performance-metrics.json in $OUT" >&2; exit 2; }
  mkdir -p "$OUT/results"
else
  OUT="build/ci-local/$(date -u +%Y%m%dT%H%M%SZ)"
  mkdir -p "$OUT/results"
  OUT="$PWD/$OUT"
fi
# The watchdog appends every build and test output line, byte for byte, to this file and prints a compact console
# (host os_log mirror noise dropped, every result, failure, crash and time-limit line kept). WSURF_CI_VERBOSE=1 prints it all.
export WSURF_CI_RAW_LOG="$OUT/console.raw.log"

for key in $(env | sed -n 's/^\([A-Za-z_][A-Za-z0-9_]*\)=.*/\1/p'); do
  case "$key" in
    WSURF_STAGE*|TEST_RUNNER_WSURF_STAGE*|*WSURF_*LIVE_*|*WSURF_*FOREGROUND_TEST*|*WSURF_*VOICE_UI_TEST*|*WSURF_*OAUTH_UI_TEST*|\
    *WSURF_*MIC_CAPTURE_TEST*|*WSURF_*VAULT_BENCHMARK*|*WSURF_*REAL_FULLSCREEN*|WSURF_CI_PERF_GATE_ONLY|WSURF_CI_DD)
      echo "error: refusing opt-in or Stage environment: $key" >&2; exit 2 ;;
  esac
done

# Inside step, set -e is off (the command runs under ||), so the functions below return on failure explicitly.
SUMMARY=()
FAILED=0
STEP_NOTE=""
PERF_RETRIED=""
REST_LOAD="not measured (no WSurf-Rest run in this process)"
step() {  # step NAME COMMAND...: run, time and record one step
  local name="$1" start=$SECONDS code=0
  shift
  echo "=== $name"
  "$@" || code=$?
  local result=PASS
  [ "$code" -eq 0 ] || { result="FAIL (exit $code)"; FAILED=1; }
  # A step that only passed on a rerun says so, so it is never silent (perf_gate sets STEP_NOTE).
  [ "$code" -ne 0 ] || [ -z "$STEP_NOTE" ] || result="PASS (retried: $STEP_NOTE)"
  STEP_NOTE=""
  SUMMARY+=("$(printf '%-28s %-14s %5ss' "$name" "$result" $((SECONDS - start)))")
  return 0
}
skip() { echo "=== $1: SKIPPED ($2)"; SUMMARY+=("$(printf '%-28s %-14s %s' "$1" SKIP "$2")"); }
finish() {
  echo
  echo "=== ci-local summary ($(git rev-parse --short HEAD), $OUT)"
  printf '%s\n' "${SUMMARY[@]}"
  if [ -n "$PERF_ONLY" ]; then
    if [ "$FAILED" -eq 0 ]; then echo "ci-local: PERF-GATE-ONLY PASS (not a merge gate)"; else echo "ci-local: PERF-GATE-ONLY FAIL"; fi
  elif [ "$FAILED" -eq 0 ]; then
    echo "ci-local: PASS${PERF_RETRIED:+ (performance retried: $PERF_RETRIED)}"
  else
    echo "ci-local: FAIL"
  fi
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
    skip "Check format" "SwiftLint $SWIFTLINT not on PATH (found: ${bin:-none}${bin:+ $("$bin" version)}); set SWIFTLINT_BIN"
    return
  fi
  step "Check format" env PATH="$(dirname "$bin"):$PATH" Tools/check-format.sh
}

acknowledgements() {
  swift Tools/make-acknowledgements.swift "$DD/SourcePackages/checkouts" || return
  git diff --quiet -- WSurf/Support/Acknowledgements.json || {
    echo "error: WSurf/Support/Acknowledgements.json is out of date. Run: swift Tools/make-acknowledgements.swift" >&2
    git diff --stat -- WSurf/Support/Acknowledgements.json
    return 1
  }
}

test_runs() {
  python3 Tools/run-xcodebuild-with-watchdog.py -- xcodebuild build-for-testing -quiet \
    -project "$PROJECT" -scheme "$SCHEME" \
    -destination 'platform=macOS,arch=arm64' \
    -derivedDataPath "$DD" \
    -skipMacroValidation \
    -enableCodeCoverage YES \
    -disableAutomaticPackageResolution \
    CODE_SIGN_STYLE=Manual \
    CODE_SIGN_IDENTITY=- \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_ENTITLEMENTS= \
    WSURF_BUNDLE_ID_SUFFIX="$WSURF_BUNDLE_ID_SUFFIX" || return
  set -- "$DD"/Build/Products/*.xctestrun
  [ "$#" -eq 1 ] && [ -f "$1" ] || { echo "error: expected exactly one generated .xctestrun in $DD/Build/Products" >&2; return 1; }
  local rest_load_start xctestrun="$1" total="${WSURF_CI_TEST_LIMIT_SECONDS:-5400}" start=$SECONDS failed="" plan remaining
  python3 Tools/check-built-identity.py "$DD" "$xctestrun" || return
  for plan in WSurf-Serial-1 WSurf-Serial-2 WSurf-Serial-3 WSurf-Rest; do
    remaining=$((total - (SECONDS - start)))
    [ "$remaining" -gt 0 ] || { echo "error: test budget of ${total}s spent before $plan started" >&2; return 124; }
    local selection=()
    while IFS= read -r line; do selection+=("$line"); done < <(python3 Tools/check-test-partition.py --args "$plan")
    echo "--- $plan (${#selection[@]} selection arguments, $((SECONDS - start))s into the tests)"
    [ "$plan" != WSurf-Rest ] || rest_load_start=$(load_average)
    WSURF_CI_TEST_LIMIT_SECONDS="$remaining" python3 Tools/run-xcodebuild-with-watchdog.py -- xcodebuild test-without-building \
      -xctestrun "$xctestrun" \
      -destination 'platform=macOS,arch=arm64' \
      -resultBundlePath "$OUT/results/$plan.xcresult" \
      -enableCodeCoverage YES \
      "${selection[@]}" || failed="$failed $plan"
    [ "$plan" != WSurf-Rest ] || REST_LOAD="$rest_load_start at start, $(load_average) at end"
    if [ -f "$OUT/results/$plan.xcresult/Info.plist" ]; then
      xcrun xcresulttool get test-results tests --path "$OUT/results/$plan.xcresult" --compact \
        > "$OUT/results/$plan-tests.json" || echo "warning: could not export the test cases of $plan"
    fi
  done
  [ -z "$failed" ] || { echo "error: failed test runs:$failed" >&2; return 1; }
}

export_metrics() {
  [ -f "$OUT/results/WSurf-Rest.xcresult/Info.plist" ] || { echo "no WSurf-Rest result bundle" >&2; return 1; }
  xcrun xcresulttool get test-results metrics --path "$OUT/results/WSurf-Rest.xcresult" --compact > "$OUT/performance-metrics.json"
}

load_average() { uptime | sed 's/.*load averages*: //'; }

# The performance budgets, with one rerun of the WSurf-Rest plan when cases missed by at most 25 % (see the header). Exit codes of
# check-performance.sh with WSURF_PERF_COLLECT: 0 all within budget, 3 budget misses listed in $OUT/perf-misses.tsv and closed by a
# "#complete" line, anything else an error, which is never retried.
perf_gate() {
  local misses="$OUT/perf-misses.tsv" code=0 judge=0 id statistic maximum label retry_load_start retry_load xctestrun
  local ids=() only=() selection=()
  : > "$misses"
  WSURF_PERF_COLLECT="$misses" Tools/check-performance.sh "$OUT/performance-metrics.json" || code=$?
  [ "$code" -eq 3 ] || return "$code"
  [ "$(tail -n 1 "$misses" | cut -f1)" = "#complete" ] || { echo "error: exit 3 without the #complete line: not a budget miss list" >&2; return 1; }
  while IFS=$'\t' read -r id _ statistic maximum label; do
    [ "${id#\#}" != "$id" ] && continue
    echo "first (load during WSurf-Rest: $REST_LOAD): $label $statistic (budget $maximum)"
    if awk -v value="$statistic" -v maximum="$maximum" 'BEGIN { exit !(value > maximum * 1.25) }'; then
      echo "error: $label missed by more than 25 %: not retried" >&2
      return 1
    fi
    ids+=("$id")
  done < "$misses"
  [ "${#ids[@]}" -gt 0 ] || { echo "error: a budget miss was reported but none was listed" >&2; return 1; }
  local unique=()
  while IFS= read -r id; do unique+=("$id"); only+=(--only "$id"); done < <(printf '%s\n' "${ids[@]}" | sort -u)
  ids=("${unique[@]}")
  echo "--- performance budget missed; running the WSurf-Rest plan once more and judging only: ${ids[*]}"
  set -- "$DD"/Build/Products/*.xctestrun
  [ "$#" -eq 1 ] && [ -f "$1" ] || { echo "error: expected exactly one generated .xctestrun in $DD/Build/Products" >&2; return 1; }
  xctestrun="$1"
  while IFS= read -r id; do selection+=("$id"); done < <(python3 Tools/check-test-partition.py --args WSurf-Rest)
  retry_load_start=$(load_average)
  WSURF_CI_TEST_LIMIT_SECONDS="${WSURF_CI_RETRY_LIMIT_SECONDS:-2700}" python3 Tools/run-xcodebuild-with-watchdog.py -- xcodebuild test-without-building \
    -xctestrun "$xctestrun" \
    -destination 'platform=macOS,arch=arm64' \
    -resultBundlePath "$OUT/results/WSurf-Rest-retry.xcresult" \
    -enableCodeCoverage YES \
    "${selection[@]}" || { echo "error: the WSurf-Rest rerun failed" >&2; return 1; }
  retry_load="$retry_load_start at start, $(load_average) at end"
  xcrun xcresulttool get test-results metrics --path "$OUT/results/WSurf-Rest-retry.xcresult" --compact \
    > "$OUT/performance-metrics-retry.json" || { echo "error: no metrics from the rerun" >&2; return 1; }
  echo "rerun, load during WSurf-Rest: $retry_load"
  Tools/check-performance.sh "${only[@]}" "$OUT/performance-metrics-retry.json" > "$OUT/perf-retry-judge.log" 2>&1 || judge=$?
  cat "$OUT/perf-retry-judge.log"
  [ "$judge" -eq 0 ] || { echo "error: missed again or no metric (load during the first run: $REST_LOAD; during the rerun: $retry_load)" >&2; return 1; }
  : > "$OUT/perf-retried.tsv"
  while IFS=$'\t' read -r id _ statistic maximum label; do
    [ "${id#\#}" != "$id" ] && continue
    printf '%s\tfirst %s\tbudget %s\tretry: %s\n' "$id" "$statistic" "$maximum" "$(grep -F "$label:" "$OUT/perf-retry-judge.log" | head -n 1)" >> "$OUT/perf-retried.tsv"
  done < "$misses"
  STEP_NOTE="${ids[*]}"
  PERF_RETRIED="${ids[*]}"
}

if [ -n "$PERF_ONLY" ]; then
  step "Check performance budgets" perf_gate
  finish
fi

step "Select Xcode" select_xcode
step "Verify Metal toolchain" xcrun metal --version
lint
step "Check watchdog" python3 Tools/check-watchdog.py
step "Check coverage script" python3 Tools/check-coverage-script.py
step "Check test partition" python3 Tools/check-test-partition.py
skip "Cache Swift packages/CEF" "runner cache; build/DD and Packages/CefSwift/.cef persist here"
gate
step "Resolve packages" xcodebuild -resolvePackageDependencies \
  -project "$PROJECT" -scheme "$SCHEME" -derivedDataPath "$DD" -onlyUsePackageVersionsFromResolvedFile
gate
step "Check acknowledgements" acknowledgements
gate
step "Test" test_runs
# After the tests every check runs, so one run shows the test, coverage and performance verdicts together.
step "Check runs cover every test" bash -c 'python3 Tools/check-test-partition.py --verify-results "$1"/results/*-tests.json' _ "$OUT"
step "Merge test results" xcrun xcresulttool merge "$OUT/results/WSurf-Serial-1.xcresult" "$OUT/results/WSurf-Serial-2.xcresult" \
  "$OUT/results/WSurf-Serial-3.xcresult" "$OUT/results/WSurf-Rest.xcresult" --output-path "$OUT/TestResults.xcresult"
step "Check coverage" Tools/check-coverage.sh "$OUT/TestResults.xcresult" 24.0
step "Export performance metrics" export_metrics
step "Check performance budgets" perf_gate
skip "Uploads" "artifacts stay in $OUT"
skip "Remove test identity" "fixed identity io.wsagency.wsurf$WSURF_BUNDLE_ID_SUFFIX is reused; no rm -rf or defaults delete"
finish
