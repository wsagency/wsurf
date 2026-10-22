#!/bin/sh
# Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
#
# Holds the budgeted performance cases to their budgets.
#
#   Tools/check-performance.sh [metrics.json]   judge build/performance-metrics.json (xcresulttool get test-results metrics)
#   Tools/check-performance.sh --self-test      check the statistics on fixed sample sets; reads no metrics file
#
# What a budget is compared with:
#   time    the MEAN of all samples (XCTMetric_Clock.time.monotonic). Unchanged.
#   memory  the MEDIAN of the samples after the first (XCTMetric_Memory.physical).
#
# Why the median: XCTMemoryMetric is the change of the host's physical footprint over one pass. In a long-running test host one
# sample swings by tens of MB either way (a spike, or the release of an earlier pass's garbage) while time and behavior are fine,
# so the mean of five flips sign on one outlier. 0.1.5, layout option sidebar: 3424/4129/4112/6275/21496 kB, mean 7887 against a
# budget of 7019, median 4129. A fresh host does not show it. The median ignores a lone spike or dip; it cannot rescue a case that
# is mostly high (0.1.6, autofilled password among 20,000: -1311/23478/-18743/20349/18580 kB, median 18580 against 4096). That was
# the measurement, not the budget: the step allocates and drops tens of MB of containers and the allocator kept or gave back the
# free pages at whim. VaultScalePerformanceTests.measureWrite now drops what a pass prepared and returns the free pages before the
# measurement starts and stops, so a sample is what the step retained. No budget is raised for it.
#
# Why the first sample is dropped: every budgeted case measures one pass more than it is judged on (XCTMeasureOptions.budgeted in
# WSurfTests/Helpers/BudgetedMeasureOptions.swift, six iterations), and the first pass is the warm-up that pays for lazy setup and
# caches. A single sample, as in an old metrics file, is kept. Keep the iteration count and this rule together.
#
# A real regression still fails: it lifts every sample, so it lifts the median.

set -eu

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required to read performance metrics" >&2
  exit 1
fi

memory_metric='com.apple.dt.XCTMetric_Memory.physical'

# summarize KIND: reads one sample per line and prints the mean (KIND mean), or the median of the samples after the first
# (KIND median), to six decimals.
summarize() {
  awk -v kind="$1" '
    { sample[NR] = $1 + 0 }
    END {
      if (kind == "mean") {
        for (i = 1; i <= NR; i++) { total += sample[i] }
        printf "%.6f", total / NR
        exit
      }
      n = 0
      for (i = (NR > 1 ? 2 : 1); i <= NR; i++) {
        value = sample[i]
        for (j = n; j > 0 && sorted[j] > value; j--) { sorted[j + 1] = sorted[j] }
        sorted[j + 1] = value
        n += 1
      }
      printf "%.6f", (n % 2 ? sorted[(n + 1) / 2] : (sorted[n / 2] + sorted[n / 2 + 1]) / 2)
    }'
}

# check_average TEST METRIC MAXIMUM LABEL UNIT: the name is historical (Tools/check-test-partition.py reads the calls). The
# statistic is the median for the memory metric and the mean for every other.
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

  kind=mean
  if [ "$metric_id" = "$memory_metric" ]; then
    kind=median
  fi
  statistic="$(printf '%s\n' "$values" | summarize "$kind")"
  if ! awk -v value="$statistic" -v maximum="$maximum" 'BEGIN { exit !(value <= maximum) }'; then
    echo "error: $label $kind $statistic $unit; budget is $maximum $unit (samples: $(printf '%s\n' "$values" | tr '\n' ' '))" >&2
    exit 1
  fi

  echo "$label: $statistic $unit ($kind; budget: $maximum $unit)"
  if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
    printf '%s: **%s %s** (%s; budget: %s %s)\n' \
      "$label" "$statistic" "$unit" "$kind" "$maximum" "$unit" >> "$GITHUB_STEP_SUMMARY"
  fi
}

# --self-test: the statistics and the verdicts on fixed sample sets. A set of six is a warm-up sample and the five that are judged.
self_test() {
  unset GITHUB_STEP_SUMMARY
  fixture="$(mktemp "${TMPDIR:-/tmp}/check-performance.XXXXXX")"
  metrics_file="$fixture"
  clock_metric='com.apple.dt.XCTMetric_Clock.time.monotonic'
  failures=0

  # expect_statistic KIND SAMPLES EXPECTED
  expect_statistic() {
    actual="$(echo "$2" | tr ' ' '\n' | summarize "$1")"
    if [ "$actual" != "$3" ]; then
      echo "self-test FAILED: $1 of [$2] is $actual, expected $3" >&2
      failures=$((failures + 1))
    fi
  }

  # expect_verdict pass|fail METRIC MAXIMUM SAMPLES
  expect_verdict() {
    jq -n --arg metric "$2" --arg samples "$4" \
      '[{testIdentifier: "Fixture/test()", testRuns: [{metrics: [{identifier: $metric, measurements: ($samples | split(" ") | map(tonumber))}]}]}]' \
      > "$fixture"
    if (check_average 'Fixture/test()' "$2" "$3" fixture kB) >/dev/null 2>&1; then
      actual=pass
    else
      actual=fail
    fi
    if [ "$actual" != "$1" ]; then
      echo "self-test FAILED: $2 [$4] against $3 is $actual, expected $1" >&2
      failures=$((failures + 1))
    fi
  }

  # The 0.1.5 layout option sidebar: the mean flips on the spike, the median does not.
  expect_statistic mean '3424 4129 4112 6275 21496' 7887.200000
  expect_statistic median '15000 3424 4129 4112 6275 21496' 4129.000000
  expect_verdict pass "$memory_metric" 7019 '15000 3424 4129 4112 6275 21496'
  # The 0.1.6 autofilled password, as measured before measureWrite trimmed the heap: mostly high samples, so the median is not
  # below the mean here. Recorded, not excused.
  expect_statistic mean '-1311 23478 -18743 20349 18580' 8470.600000
  expect_statistic median '9 -1311 23478 -18743 20349 18580' 18580.000000
  # An even count, a lone sample and the warm-up drop.
  expect_statistic median '0 1 2 3 10' 2.500000
  expect_statistic median '7' 7.000000
  expect_statistic median '999999 -5 -5 -5 -5 -5' -5.000000
  # A quiet host passes; growth that lifts every sample still fails.
  expect_verdict pass "$memory_metric" 4096 '0 100 -200 300 50 -50'
  expect_verdict fail "$memory_metric" 4096 '0 5000 5100 4900 5050 5200'
  expect_verdict pass "$memory_metric" 4096 '100'
  expect_verdict fail "$memory_metric" 4096 '5000'
  # Time stays on the mean of every sample: the first counts, and a median would have passed.
  expect_statistic mean '0.5 0.1 0.1 0.1 0.1 0.1' 0.166667
  expect_verdict fail "$clock_metric" 0.15 '0.5 0.1 0.1 0.1 0.1 0.1'
  expect_verdict pass "$clock_metric" 0.2 '0.5 0.1 0.1 0.1 0.1 0.1'

  rm -f "$fixture"
  if [ "$failures" -ne 0 ]; then
    exit 1
  fi
  echo "check-performance self-test: ok"
}

if [ "${1:-}" = "--self-test" ]; then
  self_test
  exit 0
fi

metrics_file="${1:-build/performance-metrics.json}"

if [ ! -f "$metrics_file" ]; then
  echo "error: performance metrics not found: $metrics_file" >&2
  exit 1
fi

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
# Six-sample Pro baseline (Xcode 27.1, 0.1.7 targeted run): time mean 0.10585 s, memory median of samples 2-6 49.152 kB. Budgets are twice
# the time mean; memory is the larger of 4096 kB and twice the median.
check_average \
  'BrowserPerformanceTests/testSwitchingSpacesInACrowdedSession()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.212' \
  '50 space switches among 300 tabs' \
  's'
check_average \
  'BrowserPerformanceTests/testSwitchingSpacesInACrowdedSession()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'Space switching memory growth' \
  'kB'
# Six-sample Pro baseline (Xcode 27.1, 0.1.7 targeted run): ten Standard/Minimal window style switches in a 300-tab window; time mean
# 1.1497 s, memory median of samples 2-6 2228.224 kB.
check_average \
  'BrowserPerformanceTests/testSwitchingWindowStyles()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '2.300' \
  'Ten window style switches in a 300-tab window' \
  's'
check_average \
  'BrowserPerformanceTests/testSwitchingWindowStyles()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4457' \
  'Window style switching memory growth' \
  'kB'
# Six-sample Pro baseline (Xcode 27.1, 0.1.7 targeted run): the Minimal bar with its tab list open over 300 tabs; time mean 1.1210 s,
# memory median of samples 2-6 6144 kB.
check_average \
  'BrowserPerformanceTests/testLayingOutTheMinimalShell()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '2.242' \
  'Minimal shell layout with its tab list open' \
  's'
check_average \
  'BrowserPerformanceTests/testLayingOutTheMinimalShell()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '12288' \
  'Minimal shell layout memory growth' \
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
