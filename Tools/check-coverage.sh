#!/bin/sh
# Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
#
# usage: check-coverage.sh [RESULT_BUNDLE [MINIMUM [TARGETS]]]
#
# Reports and checks every target in TARGETS (default: WSurf.app WSurfVault WSurfCore) against MINIMUM, and reports all of
# them before the exit status is set.
#
# WSurf.app is required: a missing or unreadable app target, or one below MINIMUM, fails. The other targets are the two
# static targets of Packages/WSurfCore. Xcode decides per build which of its static package targets the generated
# .xctestrun lists for coverage (three identical rebuilds of one commit listed WSurfVault in two of them), and a target
# that is not listed is not in the result bundle; the test plans pin the targets to report but cannot make Xcode list one
# it left out. So a package target that is missing from the report is a WARNING naming the target and the bundle and does
# not fail; a package target that is in the report and below MINIMUM fails like the app.
#
# Path-based coverage (summing the files under Packages/WSurfCore/Sources/<target>/) would not help: the files of a target
# Xcode did not list are not in the bundle either.

set -eu

result_bundle="${1:-build/TestResults.xcresult}"
minimum="${2:-20.0}"
targets="${3:-WSurf.app WSurfVault WSurfCore}"
required_target="WSurf.app"

if [ ! -d "$result_bundle" ]; then
  echo "error: coverage result bundle not found: $result_bundle" >&2
  exit 1
fi

report="$(xcrun xccov view --report --only-targets "$result_bundle")"
printf '%s\n' "$report"

failed=0
summary_started=0

summary() {
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] || return 0
  if [ "$summary_started" -eq 0 ]; then
    printf '### Test coverage\n\n' >> "$GITHUB_STEP_SUMMARY"
    summary_started=1
  fi
  printf '%s\n\n' "$1" >> "$GITHUB_STEP_SUMMARY"
}

for target in $targets; do
  coverage="$(printf '%s\n' "$report" | awk -v target="$target" '$2 == target { value = $4; sub(/%.*/, "", value); print value }')"

  case "$coverage" in
    ''|*[!0-9.]*)
      if [ "$target" = "$required_target" ]; then
        echo "error: could not read coverage for $target in $result_bundle" >&2
        failed=1
      else
        echo "WARNING: $target is not in the coverage report of $result_bundle (Xcode left it out of this build's coverage targets); its coverage was not checked" >&2
        [ -z "${GITHUB_ACTIONS:-}" ] || echo "::warning title=Coverage::$target is not in the coverage report; its coverage was not checked"
        summary "$target: **not in the report**, not checked (Xcode left it out of this build's coverage targets)"
      fi
      continue
      ;;
  esac

  if awk -v coverage="$coverage" -v minimum="$minimum" 'BEGIN { exit !(coverage >= minimum) }'; then
    echo "$target coverage: $coverage% (minimum: $minimum%)"
  else
    echo "error: $target coverage is $coverage%; the minimum is $minimum%" >&2
    failed=1
  fi
  summary "$target: **$coverage%** (minimum: $minimum%)"
done

exit "$failed"
