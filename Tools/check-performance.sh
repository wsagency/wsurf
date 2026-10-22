#!/bin/sh
# Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

set -eu

metrics_file="${1:-build/performance-metrics.json}"

if [ ! -f "$metrics_file" ]; then
  echo "error: performance metrics not found: $metrics_file" >&2
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required to read performance metrics" >&2
  exit 1
fi

check_average() {
  test_id="$1"
  metric_id="$2"
  maximum="$3"
  label="$4"
  unit="$5"

  values="$(jq -r \
    --arg test "$test_id" \
    --arg metric "$metric_id" \
    '.[]
      | select(.testIdentifier == $test)
      | .testRuns[].metrics[]
      | select(.identifier == $metric)
      | .measurements[]
      | select(type == "number")' \
    "$metrics_file")"

  if [ -z "$values" ]; then
    echo "error: missing $label metric for $test_id" >&2
    exit 1
  fi

  average="$(printf '%s\n' "$values" | awk '{ total += $1; count += 1 } END { printf "%.6f", total / count }')"
  if ! awk -v value="$average" -v maximum="$maximum" 'BEGIN { exit !(value <= maximum) }'; then
    echo "error: $label averaged $average $unit; budget is $maximum $unit" >&2
    exit 1
  fi

  echo "$label: $average $unit (budget: $maximum $unit)"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '%s: **%s %s** (budget: %s %s)\n' \
      "$label" "$average" "$unit" "$maximum" "$unit" >> "$GITHUB_STEP_SUMMARY"
  fi
}

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  printf '### Performance budgets\n\n' >> "$GITHUB_STEP_SUMMARY"
fi

check_average \
  'BrowserPerformanceTests/testCreatingAUsableStartPageTab()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.100' \
  'First usable start page tab' \
  's'
check_average \
  'BrowserPerformanceTests/testCreatingAUsableStartPageTab()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'Start page tab memory growth' \
  'kB'
check_average \
  'BrowserPerformanceTests/testSwitchingTabsInACrowdedSession()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.035' \
  '500 tab activations' \
  's'
check_average \
  'BrowserPerformanceTests/testSwitchingTabsInACrowdedSession()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '8192' \
  'Tab activation memory growth' \
  'kB'
# Five-sample Pro baseline: 0.123550 s to archive 50 stale tabs among 500; memory growth was not above zero.
check_average \
  'BrowserPerformanceTests/testSweepingACrowdedSessionForStaleTabs()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.250' \
  '500-tab sweep that archives 50 stale tabs' \
  's'
check_average \
  'BrowserPerformanceTests/testSweepingACrowdedSessionForStaleTabs()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'Stale tab sweep memory growth' \
  'kB'
# Five-sample Pro means in the app test host (2026-10-21): 0.000360 s, 0 kB. Budgets are twice the mean (memory at least 4096 kB).
check_average \
  'BrowserPerformanceTests/testArchivedTabSearchProjection()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.00072' \
  '30-entry archive search among 300 open tabs' \
  's'
check_average \
  'BrowserPerformanceTests/testArchivedTabSearchProjection()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'Archive search memory growth' \
  'kB'
check_average \
  'BrowserPerformanceTests/testCommandPaletteHistoryRanking()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.010' \
  '500-entry palette query' \
  's'
check_average \
  'BrowserPerformanceTests/testCommandPaletteHistoryRanking()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'Palette query memory growth' \
  'kB'
check_average \
  'BrowserPerformanceTests/testCommandPaletteResultProjection()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.020' \
  '500-history, 100-tab palette projection' \
  's'
check_average \
  'BrowserPerformanceTests/testCommandPaletteResultProjection()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'Full palette projection memory growth' \
  'kB'
check_average \
  'BrowserPerformanceTests/testStartPageFrequentSiteProjection()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.015' \
  '400-visit start page projection' \
  's'
check_average \
  'BrowserPerformanceTests/testStartPageFrequentSiteProjection()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'Start page projection memory growth' \
  'kB'
check_average \
  'BrowserPerformanceTests/testAskSurfaceResultProjection()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.010' \
  '500-entry ask surface projection' \
  's'
check_average \
  'BrowserPerformanceTests/testAskSurfaceResultProjection()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'Ask surface projection memory growth' \
  'kB'
check_average \
  'BrowserPerformanceTests/testLayingOutACrowdedSidebar()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '1.300' \
  '300-row sidebar layout with every tenth row marked' \
  's'
check_average \
  'BrowserPerformanceTests/testLayingOutACrowdedSidebar()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '8192' \
  'Crowded sidebar layout memory growth' \
  'kB'
# Five-sample Pro means (2026-10-21): 0.833475 s, 3509.45 kB. Budgets are twice the mean.
check_average \
  'BrowserPerformanceTests/testLayingOutACrowdedSidebarWithEveryLayoutOption()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '1.667' \
  '300-row sidebar layout with every layout option' \
  's'
check_average \
  'BrowserPerformanceTests/testLayingOutACrowdedSidebarWithEveryLayoutOption()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '7019' \
  'Layout option sidebar memory growth' \
  'kB'
check_average \
  'CredentialListPerformanceTests/testLayingOutThreeThousandCredentials()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.300' \
  '3,000-credential Credential Manager page layout' \
  's'
check_average \
  'CredentialListPerformanceTests/testLayingOutThreeThousandCredentials()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'Credential Manager page layout memory growth' \
  'kB'
check_average \
  'BrowserPerformanceTests/testResolvingThemeColorsForACrowdedSidebar()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.008' \
  '15,000 theme color lookups for a 300-row sidebar' \
  's'
check_average \
  'BrowserPerformanceTests/testResolvingThemeColorsForACrowdedSidebar()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'Theme color lookup memory growth' \
  'kB'
check_average \
  'BrowserPerformanceTests/testSwitchingThemes()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.015' \
  'Eighty theme switches' \
  's'
check_average \
  'BrowserPerformanceTests/testSwitchingThemes()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'Theme switching memory growth' \
  'kB'

# Five-sample Pro baselines: 6.998171 s for 30 brightness steps; 0.109710 s for 20 themes.
check_average \
  'ThemePerformanceTests/testDraggingThemeBrightness()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '14.000' \
  'Thirty brightness preview steps across 300 real sidebar rows' \
  's'
check_average \
  'ThemePerformanceTests/testDraggingThemeBrightness()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'Theme brightness preview memory growth' \
  'kB'
check_average \
  'ThemePerformanceTests/testRenderingTheThemeGallery()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.220' \
  'Eight built-in and twelve saved theme gallery layout' \
  's'
check_average \
  'ThemePerformanceTests/testRenderingTheThemeGallery()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'Theme gallery memory growth' \
  'kB'

# Five-sample Pro baselines: 0.009744 s for one extraction of a 200 KB article; memory growth between -33 and 246 kB.
check_average \
  'ReaderPerformanceTests/testExtractingALongArticle()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.020' \
  'Reader extraction of a 200 KB article' \
  's'
check_average \
  'ReaderPerformanceTests/testExtractingALongArticle()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'Reader extraction memory growth' \
  'kB'

# Five-sample Pro baseline in the app test host: 0.107897 s for one pass over twenty due watches (0.0028 s in a bare XCTest bundle).
check_average \
  'PageWatchPerformanceTests/testSchedulingTwentyDueWatches()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.220' \
  'One pass over twenty due page watches' \
  's'
check_average \
  'PageWatchPerformanceTests/testSchedulingTwentyDueWatches()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'Page watch scheduling memory growth' \
  'kB'

# Large vault (20,000 credentials, 25,000 for the merge case). Five-sample Pro means in the app test host (2026-10-21):
# edit 1.0926 s / -930.6 kB, whole-vault save 1.231078 s / 5292.04 kB, passkey merge targets 0.676352 s / -1821.9 kB,
# merge choice in a full review 0.7291 s / -5665.6 kB. Budgets are twice the mean (memory at least 4096 kB).
check_average \
  'VaultScalePerformanceTests/testEditingOneOfTwentyThousandCredentials()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '2.186' \
  'One saved edit of 20,000 credentials' \
  's'
check_average \
  'VaultScalePerformanceTests/testEditingOneOfTwentyThousandCredentials()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'One saved edit of 20,000 credentials memory growth' \
  'kB'
check_average \
  'VaultScalePerformanceTests/testSavingOneEditOfTwentyThousandCredentialsAsAWholeVault()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '2.463' \
  'One edit of 20,000 credentials saved as a whole vault' \
  's'
check_average \
  'VaultScalePerformanceTests/testSavingOneEditOfTwentyThousandCredentialsAsAWholeVault()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '10585' \
  'One edit of 20,000 credentials saved as a whole vault memory growth' \
  'kB'
check_average \
  'VaultScalePerformanceTests/testListingMergeTargetsForPasskeysAmongTwentyThousandCredentials()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '1.353' \
  'Merge targets of 20 passkeys among 20,000 credentials' \
  's'
check_average \
  'VaultScalePerformanceTests/testListingMergeTargetsForPasskeysAmongTwentyThousandCredentials()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'Merge targets of 20 passkeys among 20,000 credentials memory growth' \
  'kB'
check_average \
  'VaultScalePerformanceTests/testChoosingAMergeInAReviewThatFillsTheVault()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '1.459' \
  'One merge choice in a review that fills a 25,000-credential vault' \
  's'
check_average \
  'VaultScalePerformanceTests/testChoosingAMergeInAReviewThatFillsTheVault()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'One merge choice in a review that fills a 25,000-credential vault memory growth' \
  'kB'

# Whole-vault cases of the 0.1.5 build (20,000 credentials). Two five-sample runs on the Pro (2026-10-21), time means (s) run1 / run2:
# editor 1.7201 / 1.6935, autofilled 1.0595 / 1.0818, passkey 1.0661 / 1.0457, undo 1.1041 / 1.0934, restore 1.0174 / 1.0171.
# Time budgets are twice the mean of the ten samples. Memory growth is noisy (single samples between -19 and +22 MB), so
# each memory budget is at least 4096 kB and otherwise twice the larger of the two run means (editor 7471 kB, restore 3319 kB).
check_average \
  'VaultScalePerformanceTests/testSavingOneEditInTheCredentialEditorAmongTwentyThousandCredentials()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '3.414' \
  'Credential Editor save among 20,000 credentials' \
  's'
check_average \
  'VaultScalePerformanceTests/testSavingOneEditInTheCredentialEditorAmongTwentyThousandCredentials()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '14943' \
  'Credential Editor save among 20,000 credentials memory growth' \
  'kB'
check_average \
  'VaultScalePerformanceTests/testSavingAnAutofilledPasswordAmongTwentyThousandCredentials()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '2.142' \
  'Autofilled password saved among 20,000 credentials' \
  's'
check_average \
  'VaultScalePerformanceTests/testSavingAnAutofilledPasswordAmongTwentyThousandCredentials()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'Autofilled password saved among 20,000 credentials memory growth' \
  'kB'
check_average \
  'VaultScalePerformanceTests/testSigningInWithAPasskeyAmongTwentyThousandCredentials()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '2.112' \
  'Passkey sign-in among 20,000 credentials' \
  's'
check_average \
  'VaultScalePerformanceTests/testSigningInWithAPasskeyAmongTwentyThousandCredentials()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'Passkey sign-in among 20,000 credentials memory growth' \
  'kB'
check_average \
  'VaultScalePerformanceTests/testUndoingOneEditAmongTwentyThousandCredentials()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '2.198' \
  'Undo of one edit among 20,000 credentials' \
  's'
check_average \
  'VaultScalePerformanceTests/testUndoingOneEditAmongTwentyThousandCredentials()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'Undo of one edit among 20,000 credentials memory growth' \
  'kB'
check_average \
  'VaultScalePerformanceTests/testRestoringOneOfTwentyThousandCredentialsFromTheTrash()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '2.035' \
  'Restore of one credential from the Trash among 20,000' \
  's'
check_average \
  'VaultScalePerformanceTests/testRestoringOneOfTwentyThousandCredentialsFromTheTrash()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '6639' \
  'Restore of one credential from the Trash among 20,000 memory growth' \
  'kB'
