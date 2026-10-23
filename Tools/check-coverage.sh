#!/bin/sh
# Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
#
# usage: check-coverage.sh [RESULT_BUNDLE [MINIMUM [TARGET]]]
#
# With a TARGET, checks that one target against MINIMUM. Without one, reports and checks WSurf.app and the two shared
# package targets (WSurfVault, WSurfCore) against the same MINIMUM; every target is reported before the exit status is set.

set -eu

result_bundle="${1:-build/TestResults.xcresult}"
minimum="${2:-20.0}"
targets="${3:-WSurf.app WSurfVault WSurfCore}"

if [ ! -d "$result_bundle" ]; then
  echo "error: coverage result bundle not found: $result_bundle" >&2
  exit 1
fi

report="$(xcrun xccov view --report --only-targets "$result_bundle")"
printf '%s\n' "$report"

failed=0
summary_started=0

for target in $targets; do
  coverage="$(printf '%s\n' "$report" | awk -v target="$target" '$2 == target { value = $4; sub(/%.*/, "", value); print value }')"

  case "$coverage" in
    ''|*[!0-9.]*)
      echo "error: could not read coverage for $target" >&2
      failed=1
      continue
      ;;
  esac

  if awk -v coverage="$coverage" -v minimum="$minimum" 'BEGIN { exit !(coverage >= minimum) }'; then
    echo "$target coverage: $coverage% (minimum: $minimum%)"
  else
    echo "error: $target coverage is $coverage%; the minimum is $minimum%" >&2
    failed=1
  fi

  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    if [ "$summary_started" -eq 0 ]; then
      printf '### Test coverage\n\n' >> "$GITHUB_STEP_SUMMARY"
      summary_started=1
    fi
    printf '%s: **%s%%** (minimum: %s%%)\n\n' "$target" "$coverage" "$minimum" >> "$GITHUB_STEP_SUMMARY"
  fi
done

exit "$failed"
