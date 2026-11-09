#!/bin/sh
# Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.
#
# Holds the budgeted performance cases to their budgets.
#
#   Tools/check-performance.sh [metrics.json]   judge build/performance-metrics.json (xcresulttool get test-results metrics)
#   Tools/check-performance.sh --self-test      check the statistics on fixed sample sets; reads no metrics file
#
# What a budget is compared with:
#   time    the MEAN of the samples after the first (XCTMetric_Clock.time.monotonic).
#   memory  the MEDIAN of the samples after the first (XCTMetric_Memory.physical).
#
# Why the median: XCTMemoryMetric is the change of the host's physical footprint over one pass. In a long-running test host one
# sample swings by tens of MB either way (a spike, or the release of an earlier pass's garbage) while time and behavior are fine,
# so the mean of five flips sign on one outlier. 0.1.5, layout option sidebar: 3424/4129/4112/6275/21496 kB, mean 7887 against a
# budget of 7019, median 4129. A fresh host does not show it. The median ignores a lone spike or dip; it cannot rescue a case that
# is mostly high (0.1.6, autofilled password among 20,000: -1311/23478/-18743/20349/18580 kB, median 18580 against 4096; 0.1.17
# gate 4: -164/33718/-17744/18924/30097/-18711). That was the measurement, not the budget: the step allocates and drops about
# 100 MB, and by default the allocator keeps freed large blocks in a cache that stays in the footprint, which
# malloc_zone_pressure_relief does not empty and the kernel takes back only under memory pressure, whenever it likes. On a Mac
# under pressure a sample then moves by tens of MB either way; on a quiet one it does not, so 0.1.16's code is as noisy as 0.1.17's
# on the same Mac. WSurf.xctestplan turns the cache off for the test host (MallocLargeCache=0), VaultScalePerformanceTests.measureWrite
# returns the free pages before the measurement starts and stops, and testFreedLargeBlocksLeaveTheFootprint fails if the cache is
# back: a sample is what the step retained. No budget is raised for it.
#
# Why the first sample is dropped: every budgeted case measures one pass more than it is judged on (XCTMeasureOptions.budgeted in
# WSurfTests/Helpers/BudgetedMeasureOptions.swift, six iterations), and the first pass is the warm-up that pays for lazy setup and
# caches. A single sample, as in an old metrics file, is kept. Keep the iteration count and this rule together. Time drops it too:
# on the hosted runner (no GPU) the warm-up alone carried means over budget while the five judged passes were well inside it
# (CI 41766552499, first usable start page tab: first 0.128 s, mean 0.101903 against 0.100; CI 41799098958, four tab switches over
# 1,000 tabs: 0.393 0.048 0.039 0.061 0.049 0.045, mean 0.105643 against 0.102, 0.048 without the warm-up).
#
# A real regression still fails: it lifts every sample, so it lifts the mean and the median.

set -eu

if ! command -v jq >/dev/null 2>&1; then
  echo "error: jq is required to read performance metrics" >&2
  exit 1
fi

memory_metric='com.apple.dt.XCTMetric_Memory.physical'

# summarize KIND: reads one sample per line and prints the mean (KIND mean) or the median (KIND median) of the samples after the
# first, to six decimals; a lone sample is kept.
summarize() {
  awk -v kind="$1" '
    { sample[NR] = $1 + 0 }
    END {
      if (kind == "mean") {
        for (i = (NR > 1 ? 2 : 1); i <= NR; i++) { total += sample[i] }
        printf "%.6f", total / (NR > 1 ? NR - 1 : 1)
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
  expect_statistic mean '0 3424 4129 4112 6275 21496' 7887.200000
  expect_statistic median '15000 3424 4129 4112 6275 21496' 4129.000000
  expect_verdict pass "$memory_metric" 7019 '15000 3424 4129 4112 6275 21496'
  # The 0.1.6 autofilled password, as measured before measureWrite trimmed the heap: mostly high samples, so the median is not
  # below the mean here. Recorded, not excused.
  expect_statistic mean '9 -1311 23478 -18743 20349 18580' 8470.600000
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
  # Time is the mean after the warm-up: CI 41799098958's tab switches pass, a lone sample is kept, and a judged pass still counts.
  expect_statistic mean '0.393 0.048 0.039 0.061 0.049 0.045' 0.048400
  expect_verdict pass "$clock_metric" 0.102 '0.393 0.048 0.039 0.061 0.049 0.045'
  expect_statistic mean '0.5' 0.500000
  expect_verdict fail "$clock_metric" 0.15 '0.5'
  expect_statistic mean '0.1 0.5 0.1 0.1 0.1 0.1' 0.180000
  expect_verdict fail "$clock_metric" 0.15 '0.1 0.5 0.1 0.1 0.1 0.1'
  expect_verdict fail "$clock_metric" 0.15 '0.1 0.2 0.2 0.2 0.2 0.2'

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
# D1 re-base (perf/w1-budgets, 2026-11-07): was 2.300 s; twice the larger of two whole-plan gate means (0.1146 / 0.1158 s, perf/bench-window).
check_average \
  'BrowserPerformanceTests/testSwitchingWindowStyles()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.232' \
  'Ten window style switches in a 300-tab window' \
  's'
check_average \
  'BrowserPerformanceTests/testSwitchingWindowStyles()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4457' \
  'Window style switching memory growth' \
  'kB'
# Cmd-T over a 300-tab Standard window, five opens and closes, drawn each time (perf audit 0.1.22, item 6). Pro, Debug, load 25-75,
# four six-sample runs each: before 1.406 / 1.456 / 0.689 / 1.364 s, after 0.960 / 0.966 / 1.033 / 1.052 s. One pass in most runs
# stalls 2-3 s in the run loop on the shared Pro (both builds), so the means overlap; per-cycle medians, 35 cycles a run, went from
# 95-102 ms to 66 ms to open and from 49-55 ms to 32 ms to close. Budget twice the after mean, against a gross regression; the win
# itself is held by SidebarRowStyleTests/onlyTheCurrentRowFollowsTheNewTabPalette and
# CommandPaletteRankingTests/anUnchangedContextReusesTheBuiltList.
check_average \
  'BrowserPerformanceTests/testOpeningTheNewTabPaletteInACrowdedWindow()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '2.100' \
  'Five Cmd-T opens and closes in a 300-tab window' \
  's'
check_average \
  'BrowserPerformanceTests/testOpeningTheNewTabPaletteInACrowdedWindow()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'Cmd-T palette memory growth' \
  'kB'
# Six-sample Pro baseline (Xcode 27.1, 0.1.7 targeted run): the Minimal bar with its tab list open over 300 tabs; time mean 1.1210 s,
# memory median of samples 2-6 6144 kB.
# D1 re-base (perf/w1-budgets, 2026-11-07): was 2.242 s; twice the larger of two whole-plan gate means (0.0836 / 0.0802 s, perf/bench-window).
check_average \
  'BrowserPerformanceTests/testLayingOutTheMinimalShell()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.167' \
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
# D1 re-base (perf/w1-budgets, 2026-11-07): was 0.010 s; twice the larger of two whole-plan gate means (0.0009 / 0.0009 s, perf/bench-window).
check_average \
  'BrowserPerformanceTests/testCommandPaletteHistoryRanking()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.0018' \
  '500-entry palette query' \
  's'
check_average \
  'BrowserPerformanceTests/testCommandPaletteHistoryRanking()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'Palette query memory growth' \
  'kB'
# D1 re-base (perf/w1-budgets, 2026-11-07): was 0.020 s; twice the larger of two whole-plan gate means (0.0024 / 0.0023 s, perf/bench-window).
check_average \
  'BrowserPerformanceTests/testCommandPaletteResultProjection()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.0048' \
  '500-history, 100-tab palette projection' \
  's'
check_average \
  'BrowserPerformanceTests/testCommandPaletteResultProjection()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'Full palette projection memory growth' \
  'kB'
# D1 re-base (perf/w1-budgets, 2026-11-07): was 0.015 s; twice the larger of two whole-plan gate means (0.0011 / 0.0010 s, perf/bench-window).
check_average \
  'BrowserPerformanceTests/testStartPageFrequentSiteProjection()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.0022' \
  '400-visit start page projection' \
  's'
check_average \
  'BrowserPerformanceTests/testStartPageFrequentSiteProjection()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'Start page projection memory growth' \
  'kB'
# D1 re-base (perf/w1-budgets, 2026-11-07): was 0.010 s; twice the larger of two whole-plan gate means (0.0011 / 0.0010 s, perf/bench-window).
check_average \
  'BrowserPerformanceTests/testAskSurfaceResultProjection()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.0022' \
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
# The real sidebar over 1,000 tabs in 25 open folders (Linen 0.9.3 e8362495, lazy rows), 280 x 700 window. Three-run Pro means after the
# change (2026-10-24, Debug): 0.2700 s to open it, 0.5661 s for four tab switches over it, 0.5260 s to scroll it in 30 steps of 300 pt; memory
# medians 327 to 393 kB, and below zero when scrolling. The list drew every row at once before: 7.1194 s, 14.9612 s and 2.8782 s. Budgets are
# twice the mean (memory at least 4096 kB), so the old list fails them.
check_average \
  'BrowserPerformanceTests/testLayingOutAThousandRowSidebar()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.540' \
  'Sidebar layout over 1,000 tabs in 25 folders' \
  's'
check_average \
  'BrowserPerformanceTests/testLayingOutAThousandRowSidebar()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'Thousand-tab sidebar layout memory growth' \
  'kB'
# WI-4 (2026-10-26): a row no longer reads the current tab in its context menu, so a switch draws the two rows that change. Two-run
# Pro mean 0.0511 s, interleaved with the old code's 0.5321 s; budget twice the mean.
check_average \
  'BrowserPerformanceTests/testSwitchingTabsOverAThousandRowSidebar()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.102' \
  'Four tab switches over a sidebar of 1,000 tabs' \
  's'
check_average \
  'BrowserPerformanceTests/testSwitchingTabsOverAThousandRowSidebar()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'Tab switching over the thousand-tab sidebar memory growth' \
  'kB'
# Perf audit 0.1.22 item 3 (2026-11-04): twelve switches among four loaded WebKit pages in the app's own window, laid out and drawn.
# Six-sample Pro means, Debug: 0.224 s before (the root re-ran on every switch, made a settings workspace and set the title twice),
# 0.190 and 0.192 s after. Budget twice the after mean. Clock only: a WebKit page's footprint swings by more than a budget could hold.
check_average \
  'BrowserPerformanceTests/testSwitchingLoadedTabsInAWindow()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.382' \
  'Twelve switches among four loaded pages in a window' \
  's'
# 0.1.23, a row builds its hover-only action button only while it shows and the list catches middle clicks for every row, so a
# scroll step no longer builds a hidden button and an AppKit view per row that comes in. Pro, Debug, same session: 0.479 s before
# (mean of six), 0.139 s after (-O host: 0.133 s); CI's last green run before it measured 0.644 s. Budget twice the new mean.
check_average \
  'BrowserPerformanceTests/testScrollingAThousandRowSidebar()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.280' \
  'Thirty scroll steps down a sidebar of 1,000 tabs' \
  's'
check_average \
  'BrowserPerformanceTests/testScrollingAThousandRowSidebar()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'Thousand-tab sidebar scrolling memory growth' \
  'kB'
# WI-4 (2026-10-26), two-run Pro means interleaved with the code before it, Debug. Budgets are twice the mean (memory at least
# 4096 kB, else twice the median), so the old code fails the sidebar ones.
# Ten clicks between two tabs over a 300-tab sidebar that draws every row: 0.4506 s (before 4.3661 s).
check_average \
  'SidebarPerformanceTests/testClickingBetweenTwoTabsOfASidebarThatDrawsEveryRow()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.901' \
  'Ten clicks over a 300-tab sidebar that draws every row' \
  's'
check_average \
  'SidebarPerformanceTests/testClickingBetweenTwoTabsOfASidebarThatDrawsEveryRow()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'Sidebar click memory growth' \
  'kB'
# 0.1.17, a row no longer reads every tab or the Command key. Pro, Debug, a sidebar of 1,000 tabs in 25 open folders with its first
# rows drawn, the old code's run and the new code's an hour apart (load average 20 to 130). Three background tabs opened and closed:
# 1.9498 s before, 0.2411 s and 0.2557 s after (alone, in the whole plan); the budget is twice the new mean. Command pressed and released
# five times: 0.1274 s before; after, five passes of six take 0.0003 s and one takes 0.06 to 0.13 s (cause not found), so the mean is
# 0.010 s to 0.026 s. The budget is half the old code's time: twice the new mean would be one stalled pass.
check_average \
  'SidebarPerformanceTests/testOpeningAndClosingBackgroundTabsOverAThousandRowSidebar()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.510' \
  'Three background tabs opened and closed over a sidebar of 1,000 tabs' \
  's'
check_average \
  'SidebarPerformanceTests/testOpeningAndClosingBackgroundTabsOverAThousandRowSidebar()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'Background tab churn memory growth' \
  'kB'
# D1 (perf/w1-budgets, 2026-11-07): the time budget (0.060 s) is gone. The case takes 0.3 ms, which is noise; what it guards is how much work
# a press does, and SidebarPerformanceTests/testPressingCommandOverAThousandRowSidebar now counts that.
check_average \
  'SidebarPerformanceTests/testPressingCommandOverAThousandRowSidebar()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'Command key memory growth' \
  'kB'
# A row dragged in place in 30 steps over 1,000 tabs: 0.3302 s (before 4.9937 s).
# D1 re-base (perf/w1-budgets, 2026-11-07): was 0.660 s; twice the larger of two whole-plan gate means (0.0460 / 0.0479 s, perf/bench-window).
check_average \
  'SidebarPerformanceTests/testDraggingARowInPlaceOverAThousandRowSidebar()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.0958' \
  'Thirty drag steps over a sidebar of 1,000 tabs' \
  's'
check_average \
  'SidebarPerformanceTests/testDraggingARowInPlaceOverAThousandRowSidebar()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'Sidebar drag memory growth' \
  'kB'
# A saved 300-tab window restored into the model: 0.0317 s (before 0.0315 s); 0.1.22 gate 0.032264 s, samples 0.0316-0.0328.
# The hosted runner (no GPU) is about twice that and steady, so twice the Pro has no room there: mean 0.057903 s on CI
# 41751273289, 0.065859 s on 41819810600 (judged samples 0.061-0.070). 0.072 is the runner's worst mean plus a tenth.
# The same with a 16 KB saved page state in each tab, left in the table until the tab is shown (optimised host on the Pro): 0.019 s
# (0.020 s when every tab's state was read at restore).
check_average \
  'LaunchPerformanceTests/testRestoringA300TabWindowIntoTheModel()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.072' \
  '300-tab window restored into the model' \
  's'
check_average \
  'LaunchPerformanceTests/testRestoringA300TabWindowIntoTheModel()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  '300-tab restore memory growth' \
  'kB'
# Every window of a four-window launch restored and drawn, which the first window waited for before: 1.0226 s, 71730 kB.
check_average \
  'LaunchPerformanceTests/testOpeningEveryWindowOfAFourWindowLaunch()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '2.045' \
  'Four-window launch, every window restored and drawn' \
  's'
check_average \
  'LaunchPerformanceTests/testOpeningEveryWindowOfAFourWindowLaunch()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '143460' \
  'Four-window launch memory growth' \
  'kB'
# The same launch to its first window, the one in front, restored and drawn before the others: 0.2877 s, 19743 kB.
check_average \
  'LaunchPerformanceTests/testOpeningTheFrontWindowOfAFourWindowLaunch()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.575' \
  'Four-window launch to the window in front' \
  's'
check_average \
  'LaunchPerformanceTests/testOpeningTheFrontWindowOfAFourWindowLaunch()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '39486' \
  'Launch to the window in front memory growth' \
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
# Typing in the Credential Manager search over a vault of 3,000 credentials (D5(b), plan 6.5): from "site1" (1,111 rows) to "site29" (111
# rows, none of them on screen before), steady state, the keystroke timed with the page's layout. Pro, Debug + coverage, whole Performance
# plan, runs: 0.0323 / 0.0349 / 0.0342 s with the "..." drawn, then 0.0374 / 0.0349 / 0.0376 s with it as a pull-down button (load 5 to 43,
# which does not move it). Before this change a first keystroke of
# the same kind on a fresh page took 0.142 s (K3 of CredentialListPerformanceTests, a different harness, so not the same measurement).
# Budget twice the larger mean. The keystroke that keeps every row (about 0.02 s) has no budget: a mean of five passes with a 0.0417 s
# budget fails on one stalled pass of 0.127 s, which this file records for other short cases; its test asserts instead that no row is
# evaluated again.
check_average \
  'CredentialListPerformanceTests/testNarrowingASearchOfThreeThousandCredentialsToOneHundredAndEleven()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.0748' \
  'Credential Manager search narrowing 1,111 rows to 111 in a vault of 3,000' \
  's'
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
# Six-sample Pro baseline (0.1.22 gate): 0.009934 s for 80 switches. 0.015 was set for 70 switches and kept when the eighth
# theme came; the hosted runner then measured 0.016211 (run 41751273289). Twice the Pro baseline, as for the budgets here.
check_average \
  'BrowserPerformanceTests/testSwitchingThemes()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.020' \
  'Eighty theme switches' \
  's'
check_average \
  'BrowserPerformanceTests/testSwitchingThemes()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'Theme switching memory growth' \
  'kB'

# Five-sample Pro baselines: 6.998171 s for 30 brightness steps; 0.109710 s for 20 themes.
# The brightness budget was 14 s while half of the 30 steps changed no color. Since 0.1.16 (the brightness rule of
# fix/theme-customize-0.1.16) every step changes the colors and repaints all rows: 8.1 to 8.6 s became 12.2 to 13.2 s, a factor of
# 1.50 in the same host, so the budget is 21 s (14 x 1.50).
# 0.1.17, a row no longer reads every tab: the same case, six samples, Pro, Debug, the code before and after that change an hour
# apart: 13.762 s and 5.381 s alone, 5.517 s in the whole plan. The budget is twice the new mean, 11 s.
# 0.1.23 (perf/theme-drag), a resting row no longer observes the sidebar's ground (SidebarGround): six samples, Pro, Debug, ThemePerformanceTests
# alone, 5.108 s before and 3.687 s after. In about 40% of the steps the guarded ink changes too, and those still draw every row. The
# budget is twice the new mean, 7.4 s.
check_average \
  'ThemePerformanceTests/testDraggingThemeBrightness()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '7.400' \
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
# Six-sample means on the Pro (2026-10-28, Debug, load average 60 to 140), before and after the gallery cards compared what they draw
# rather than their action, interleaved in one session: 0.522 / 0.530 / 0.531 s before, 0.299 / 0.291 / 0.350 s after (the last one at
# load 100). So the budget sits between the two, not at twice the after mean: a card that redraws with every step puts the case back
# at 0.53 s. The case hosts the Appearance pane's theme section alone, 17 ms a step before and 10 ms after. With the Settings page in
# a window of 300 sidebar rows the same drag costs 153 to 170 ms a step before and 154 to 163 ms after (probe PA08, three runs each).
check_average \
  'ThemePerformanceTests/testPreviewingBrightnessWithTheGalleryOnScreen()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.450' \
  'Thirty brightness preview steps with the twenty-card theme gallery on screen' \
  's'
check_average \
  'ThemePerformanceTests/testPreviewingBrightnessWithTheGalleryOnScreen()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'Theme gallery brightness preview memory growth' \
  'kB'

# Long lists outside the sidebar (ListPerformanceTests). Six-sample means on the Pro (2026-10-24), seconds, port of Linen 0.9.3 b44a8393:
# case                                   before      after   budget
# 600-site list, four screens deep       0.165-0.181 0.094-0.102  0.150 (a tight budget: the flat row surface is a 1.7x gain)
# three removals among 1,500 sites       0.402-0.427 0.289-0.325  0.650 (WebKit's own removal dominates; the case guards gross changes)
# the list shown again after a removal   0.121        0.0032       0.020 (a recount of 1,500 cookie-only sites; far more with data on disk)
# 10,000 icon lookups, sites with none   1.29-1.34    0.0031       0.015
# 1,000 sites with custom settings       0.67-0.68    0.0206       0.050
# 40 progress updates among 300 rows     0.245-0.269  0.147-0.164  0.220 (includes 0.040 s of run-loop turns; a tight budget)
# 40 release notes, four screens deep    0.245-0.258  0.055-0.059  0.120
# Memory growth is noisy (single samples between -43 and +16 MB, medians within 8 MB before and 1.2 MB after), so every memory budget
# is the usual 4096 kB. A budget twice the after mean could not tell the list rows apart from their old state, so the two row cases above
# sit between the two.
check_average \
  'ListPerformanceTests/testLayingOutALongListOfSites()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.150' \
  '600-site Website data list laid out four screens deep' \
  's'
check_average \
  'ListPerformanceTests/testLayingOutALongListOfSites()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'Website data list layout memory growth' \
  'kB'
check_average \
  'ListPerformanceTests/testRemovingASiteFromTheWebsiteDataList()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.650' \
  'Three removals from a 1,500-site Website data list' \
  's'
check_average \
  'ListPerformanceTests/testRemovingASiteFromTheWebsiteDataList()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'Website data removal memory growth' \
  'kB'
check_average \
  'ListPerformanceTests/testShowingTheListAgainAfterARemoval()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.020' \
  'Website data list shown again after a removal among 1,500 sites' \
  's'
check_average \
  'ListPerformanceTests/testShowingTheListAgainAfterARemoval()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'Website data refresh memory growth' \
  'kB'
check_average \
  'ListPerformanceTests/testAskingForTheIconsOfSitesThatHaveNone()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.015' \
  '10,000 icon lookups for sites that have none' \
  's'
check_average \
  'ListPerformanceTests/testAskingForTheIconsOfSitesThatHaveNone()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'Icon lookup memory growth' \
  'kB'
check_average \
  'ListPerformanceTests/testIndexingTheSitesWithCustomSettings()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.050' \
  'Websites list of 1,000 sites with custom settings' \
  's'
check_average \
  'ListPerformanceTests/testIndexingTheSitesWithCustomSettings()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'Websites list index memory growth' \
  'kB'
check_average \
  'ListPerformanceTests/testUpdatingOneDownloadInALongList()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.220' \
  '40 progress updates in a 300-download list' \
  's'
check_average \
  'ListPerformanceTests/testUpdatingOneDownloadInALongList()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'Download list update memory growth' \
  'kB'
check_average \
  'ListPerformanceTests/testLayingOutManyReleaseNotes()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.120' \
  '40 release notes laid out four screens deep' \
  's'
check_average \
  'ListPerformanceTests/testLayingOutManyReleaseNotes()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'Release notes layout memory growth' \
  'kB'
# 0.1.17, Chromium origin bookkeeping: 20 frame navigations whose origin and top-level site are listed, in a catalog of 2,000 sites. Debug on
# the Pro under a load average of 150 to 400, seconds. Before (read, decode, encode and rewrite the catalog file per navigation): 0.0771. After
# (a lookup in the kept catalog): 0.00087 and 0.00095 in two runs. The budget is about ten times the mean after, since a case this short is
# mostly scheduler noise on a shared runner, and about an eighth of the old cost.
# D1 re-base (perf/w1-budgets, 2026-11-07): was 0.010 s; twice the larger of two whole-plan gate means (0.0008 / 0.0008 s, perf/bench-window).
check_average \
  'ListPerformanceTests/testRecordingChromiumFramesAmongTwoThousandSites()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.0016' \
  '20 Chromium frame navigations recorded among 2,000 sites' \
  's'
check_average \
  'ListPerformanceTests/testRecordingChromiumFramesAmongTwoThousandSites()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'Chromium origin recording memory growth' \
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
# D1 (perf/w1-budgets, 2026-11-07): the time budget (0.220 s) is gone. The pass takes 2.3 ms, which is noise; the test now counts the work
# one pass does (reads, judgements, notifications, changes to the list).
check_average \
  'PageWatchPerformanceTests/testSchedulingTwentyDueWatches()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'Page watch scheduling memory growth' \
  'kB'

# Page-load overhead of the page scripts: five loads of a login page with ten srcdoc iframes (eleven frames) in an ordinary
# profile's tab, which installs every page script. Six-sample Pro baseline (2026-11-04, Debug gate configuration, two runs): mean
# 0.341 s and 0.338 s per pass (68 ms a load). A scriptless web view on the pool's process pool, loading the same pages back to back
# in the same host, took 68-70 ms a load: back to back, a new WebContent process per site dominates. Budget: twice the baseline.
check_average \
  'PageScriptPerformanceTests/testLoadingAPageWithTenFrames()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.682' \
  'Five loads of an eleven-frame page with the page scripts' \
  's'

# Page-load overhead with no iframe (the main frame alone): the same five-load pass as the ten-frame case. Six-sample Pro baseline
# (2026-11-06, Debug gate configuration, whole Performance plan, two runs): mean 0.330 s and 0.332 s per pass (66 ms a load; a bare
# web view in the same host 67-69 ms). Optimised host: mean 0.341 s per pass. Budget: twice the mean. Clock only, like the ten-frame case.
check_average \
  'PageScriptPerformanceTests/testLoadingAPageWithOneFrame()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.665' \
  'Five loads of a one-frame page with the page scripts' \
  's'

# Pages in the app's own window (WebPagePerformanceTests): a profile of its own on the shared test data store, pages from a loopback
# server, WebKit only. Clock only: a live page's footprint swings more than a budget can hold, as in testSwitchingLoadedTabsInAWindow.
# Six-sample Pro baselines (2026-11-06, Debug gate configuration, whole Performance plan, two runs: mean 1 / mean 2). Budget: twice
# the larger mean.
#   new tab to loaded, one tab per pass, window ordered in  0.0819 / 0.0778 s   (-O: 0.0796 s)   82 ms a tab
check_average \
  'WebPagePerformanceTests/testOpeningANewTabToFirstPaint()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.164' \
  'A new tab opened to its page loaded' \
  's'
#   16 switches among 8 loaded pages, 300 rows in 10 folders 0.3749 / 0.3764 s   (-O: 0.3300 s)   23 ms a switch
check_average \
  'WebPagePerformanceTests/testSwitchingLoadedTabsInACrowdedWindowWithFolders()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.753' \
  'Sixteen switches among loaded pages in a window with folders' \
  's'
#   Find: open, count 518 matches, 10 steps                 0.0292 / 0.0279 s   (-O: 0.0325 s)   2 ms a step
check_average \
  'WebPagePerformanceTests/testFindingInALongPage()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.0584' \
  'Find in a long page, open and ten steps' \
  's'
#   Zoom: 6 steps + reset, each applied by the page          0.0460 / 0.0459 s   (-O: 0.0476 s)   7 ms a step
check_average \
  'WebPagePerformanceTests/testZoomingALongPage()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.0920' \
  'Six zoom steps of a long page' \
  's'
#   Reader open + close for a 200 KB article                0.0889 / 0.0817 s   (-O: 0.0683 s)
check_average \
  'WebPagePerformanceTests/testShowingReaderForALongArticle()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.178' \
  'Reader opened and closed for a long article' \
  's'
#   20-page PDF opened to two drawn frames                  0.1189 / 0.0945 s   (-O: 0.0935 s)   samples 0.086-0.196
check_average \
  'WebPagePerformanceTests/testOpeningAPDF()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.238' \
  'A 20-page PDF opened' \
  's'


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

# Autofill reads (D5(a)), 20,000 credentials: the verified read (`snapshot`), and the autofill candidates projected from it on the
# vault actor (`autofillCandidates`). Pro, Debug + coverage, whole WSurf-Rest run, two runs (2026-11-08), time means (s) run1 / run2:
# read 0.608231 / 0.600344, candidates 0.622744 / 0.628505, so candidates took 1.024 / 1.047 times the read. Plan D5 P1 asks for at
# most 1.1: that ratio was measured by hand on these runs and is not gated here. The budgets are absolute, twice the larger mean, so
# they catch a gross regression only; the projection itself is held by the two blocks after them. Memory medians 0 / 0 kB. No -O run.
# Memory budgets at least 4096 kB.
check_average \
  'VaultScalePerformanceTests/testReadingTwentyThousandCredentials()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '1.22' \
  'Verified read of 20,000 credentials' \
  's'
check_average \
  'VaultScalePerformanceTests/testReadingTwentyThousandCredentials()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'Verified read of 20,000 credentials memory growth' \
  'kB'
check_average \
  'VaultScalePerformanceTests/testListingAutofillCandidatesAmongTwentyThousandCredentials()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '1.26' \
  'Autofill candidates of 20,000 credentials' \
  's'
check_average \
  'VaultScalePerformanceTests/testListingAutofillCandidatesAmongTwentyThousandCredentials()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'Autofill candidates of 20,000 credentials memory growth' \
  'kB'

# The same projection without the read or any I/O, over 20,000 in-memory credentials, 2,000 of them with a card (200 ended) and 2,000
# with a contact: the candidates alone (testProjectingTwentyThousandAutofillCandidates, the part every password field's focus runs),
# and the candidates with the card and contact rows (testProjectingTwentyThousandCredentialsForAutofill, through the store's own
# cardRows and contactRow). Pro, Debug + coverage, 2026-11-08. Timed apart once (targeted run), the three parts took: candidates
# 0.031 s, card rows 0.046 s, contact rows 0.100 s, most of that building Locale.Region.isoRegions anew twice per contact. With the
# region identifiers read once, contact rows take 0.038-0.039 s. Two targeted runs after that, time means: candidates 0.030639 /
# 0.030271 s, all three 0.117059 / 0.114968 s (whole WSurf-Rest runs before the change, at 6d86be46: 0.172575 / 0.172673 s). Memory
# medians 0 kB. Time budgets twice the larger mean; memory 4096 kB.
check_average \
  'VaultScalePerformanceTests/testProjectingTwentyThousandAutofillCandidates()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.0613' \
  'Autofill candidates of 20,000 in-memory credentials' \
  's'
check_average \
  'VaultScalePerformanceTests/testProjectingTwentyThousandAutofillCandidates()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'Autofill candidates of 20,000 in-memory credentials memory growth' \
  'kB'
check_average \
  'VaultScalePerformanceTests/testProjectingTwentyThousandCredentialsForAutofill()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.235' \
  'Autofill projection of 20,000 in-memory credentials' \
  's'
check_average \
  'VaultScalePerformanceTests/testProjectingTwentyThousandCredentialsForAutofill()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'Autofill projection of 20,000 in-memory credentials memory growth' \
  'kB'

# A pick (D5 PR-6, testPickingOneOfTwentyThousandCredentials): `autofillLogin` through `pickedAccount`, which authenticates the
# head (all 20,000 catalog entries) and then opens the picked row alone; before, every pick ran the verified read of all 20,000.
# Pro, Debug + coverage, whole WSurf-Rest run at 73b63986 (2026-11-09): time mean 0.021922 s, against 0.609428 s for the verified
# read (testReadingTwentyThousandCredentials) in the same run. Memory median 0 kB. Time budget twice the mean; memory 4096 kB.
check_average \
  'VaultScalePerformanceTests/testPickingOneOfTwentyThousandCredentials()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.0438' \
  'A pick of one of 20,000 credentials' \
  's'
check_average \
  'VaultScalePerformanceTests/testPickingOneOfTwentyThousandCredentials()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'A pick of one of 20,000 credentials memory growth' \
  'kB'

# History and database (HistoryPerformanceTests), six-sample means on the Pro (2026-10-27, Debug), seconds, before and after WI-3
# (an index on historyVisit.fromVisit, the schema defined by migrations instead of on every open, one and two letter queries answered
# from memory). Time budgets are twice the mean after, or a little more where the mean is a fraction of a millisecond; the old code
# fails each of them.
# case                                           before    after    budget
# clearing 6,000 pages and 9,400 visits           3.105    0.148-0.180  0.320 (50,000 pages took 7 minutes in sqlite3 before the index)
# opening a database of 50,000 pages              0.156    0.0085   0.020 (the full-text index was rebuilt from the pages at every open)
# ten 1-2 letter searches, 50 pages each          0.0400   0.0003   0.002
# ten 1-2 letter omnibox queries, ranking in      0.0517   0.0085   0.017 (the rest is Omnibox.relevance over 50 candidates)
# Memory growth is zero or noise at this size, so every memory budget is the usual 4096 kB.
check_average \
  'HistoryPerformanceTests/testClearingALargeHistory()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.320' \
  'Clear History over 6,000 pages and 9,400 visits' \
  's'
check_average \
  'HistoryPerformanceTests/testClearingALargeHistory()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'Clear History memory growth' \
  'kB'
check_average \
  'HistoryPerformanceTests/testOpeningAProfileDatabaseOfFiftyThousandPages()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.020' \
  'Opening a profile database of 50,000 history pages' \
  's'
check_average \
  'HistoryPerformanceTests/testOpeningAProfileDatabaseOfFiftyThousandPages()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'Opening a profile database memory growth' \
  'kB'
check_average \
  'HistoryPerformanceTests/testSearchingForTheFirstLettersOfAQueryOverFiftyThousandPages()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.002' \
  'Ten searches of one or two letters over 50,000 pages' \
  's'
check_average \
  'HistoryPerformanceTests/testSearchingForTheFirstLettersOfAQueryOverFiftyThousandPages()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'First-letter search memory growth' \
  'kB'
check_average \
  'HistoryPerformanceTests/testTypingTheFirstLettersOfAQueryOverFiftyThousandPages()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.017' \
  'Ten omnibox queries of one or two letters over 50,000 pages' \
  's'
check_average \
  'HistoryPerformanceTests/testTypingTheFirstLettersOfAQueryOverFiftyThousandPages()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'First-letter omnibox query memory growth' \
  'kB'

# The Start page address field (AskSurfaceModel.sections over 50,000 pages), six-sample means on the Pro (2026-10-28, Debug), seconds: the
# eight queries of three to ten letters, each read three times as the surface's body reads it. The rows were computed on every read; they
# are now computed once per change, so the old code runs three searches where the new runs one.
# case                                           before        after    budget
# eight 3-10 letter queries, three reads each    0.055-0.065   0.017-0.019  0.036
# Memory growth is zero at this size, so the memory budget is the usual 4096 kB.
check_average \
  'HistoryPerformanceTests/testTypingAWordIntoTheAddressFieldOverFiftyThousandPages()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.036' \
  'Eight address field queries of three to ten letters over 50,000 pages' \
  's'
check_average \
  'HistoryPerformanceTests/testTypingAWordIntoTheAddressFieldOverFiftyThousandPages()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'Address field query memory growth' \
  'kB'

# The same typing with the app's store, which reads the full-text index off the main thread (2026-11-04, Pro, Debug), seconds: the
# main thread's share of the eight queries of three to ten letters, each read three times. The read, 2.0 ms a query, is no longer on it.
# case                                           before (above)   after          budget
# eight 3-10 letter queries, main thread only    0.017            0.0037-0.0042  0.008
# Memory growth is zero at this size, so the memory budget is the usual 4096 kB.
check_average \
  'HistoryPerformanceTests/testTypingAWordWithTheSearchInTheBackgroundOverFiftyThousandPages()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.008' \
  'Eight address field queries over 50,000 pages, search in the background' \
  's'
check_average \
  'HistoryPerformanceTests/testTypingAWordWithTheSearchInTheBackgroundOverFiftyThousandPages()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'Background address field query memory growth' \
  'kB'

# Window and UI interaction cases (WindowPerformanceTests, 2026-11-06, perf/bench-window). Pro, Debug + coverage, whole Performance plan,
# two runs, mean of samples 2-6 in seconds. Budget twice the larger mean, three significant digits, up. Memory: the usual 4096 kB, since
# the median of every case stayed under 2048 kB. The -O column is the optimised host (SWIFT_OPTIMIZATION_LEVEL=-O, no coverage).
# case                                                  run 1    run 2    -O
# OpeningASecondWindow                                  0.1206   0.1156   0.1328
# ClosingBackgroundTabsInACrowdedWindow                 0.2002   0.1961   0.1619
# ClosingTheFrontTabInACrowdedWindow                    0.1199   0.1187   0.1002
# OpeningSettingsInACrowdedWindow                       0.6173   0.6135   0.5925
# SwitchingSettingsPanesInACrowdedWindow                0.5817   0.5439   0.5469
# PreviewingBrightnessWithSettingsOpenInACrowdedWindow  1.4745   1.4661   1.3879
# TypingInTheCommandPaletteOfACrowdedWindow             0.1539   0.1802   0.1331
# TypingInTheStartPageAddressFieldOverALargeHistory     0.1231   0.1211   0.1168
# ScrollingASidebarWithFoldersPinsAndSplits             0.1407   0.1475   0.1422
# ShowingTheHistoryPageOfALargeHistory                  0.3290   0.3111   0.3213
# Clock only, because a page's footprint swings by more than a budget could hold: the second window (makes a pooled WKWebView), the front
# tab close (activating a neighbour can make its page) and Settings (a page of its own: -967 to 3260 kB a pass in the alone runs).
check_average \
  'WindowPerformanceTests/testOpeningASecondWindow()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.242' \
  'Opening a second window' \
  's'
check_average \
  'WindowPerformanceTests/testClosingBackgroundTabsInACrowdedWindow()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.401' \
  'Ten background tab closes in a crowded window' \
  's'
check_average \
  'WindowPerformanceTests/testClosingBackgroundTabsInACrowdedWindow()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'Ten background tab closes in a crowded window memory growth' \
  'kB'
check_average \
  'WindowPerformanceTests/testClosingTheFrontTabInACrowdedWindow()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.240' \
  'Five front tab closes in a crowded window' \
  's'
check_average \
  'WindowPerformanceTests/testOpeningSettingsInACrowdedWindow()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '1.24' \
  'Three Settings opens and closes in a crowded window' \
  's'
check_average \
  'WindowPerformanceTests/testSwitchingSettingsPanesInACrowdedWindow()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '1.17' \
  'Five Settings pane switches in a crowded window' \
  's'
check_average \
  'WindowPerformanceTests/testSwitchingSettingsPanesInACrowdedWindow()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'Five Settings pane switches in a crowded window memory growth' \
  'kB'
check_average \
  'WindowPerformanceTests/testPreviewingBrightnessWithSettingsOpenInACrowdedWindow()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '2.95' \
  'Thirty brightness preview steps with Settings open' \
  's'
check_average \
  'WindowPerformanceTests/testPreviewingBrightnessWithSettingsOpenInACrowdedWindow()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'Thirty brightness preview steps with Settings open memory growth' \
  'kB'
check_average \
  'WindowPerformanceTests/testTypingInTheCommandPaletteOfACrowdedWindow()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.361' \
  'Eleven palette keystrokes in a crowded window' \
  's'
check_average \
  'WindowPerformanceTests/testTypingInTheCommandPaletteOfACrowdedWindow()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'Eleven palette keystrokes in a crowded window memory growth' \
  'kB'
check_average \
  'WindowPerformanceTests/testTypingInTheStartPageAddressFieldOverALargeHistory()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.247' \
  'Ten address field keystrokes over 50,000 pages' \
  's'
check_average \
  'WindowPerformanceTests/testTypingInTheStartPageAddressFieldOverALargeHistory()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'Ten address field keystrokes over 50,000 pages memory growth' \
  'kB'
check_average \
  'WindowPerformanceTests/testScrollingASidebarWithFoldersPinsAndSplits()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.296' \
  'Thirty scroll steps over a sidebar with folders, pins and splits' \
  's'
check_average \
  'WindowPerformanceTests/testScrollingASidebarWithFoldersPinsAndSplits()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'Thirty scroll steps over a sidebar with folders, pins and splits memory growth' \
  'kB'
check_average \
  'WindowPerformanceTests/testShowingTheHistoryPageOfALargeHistory()' \
  'com.apple.dt.XCTMetric_Clock.time.monotonic' \
  '0.659' \
  'Three History page opens over 50,000 pages' \
  's'
check_average \
  'WindowPerformanceTests/testShowingTheHistoryPageOfALargeHistory()' \
  'com.apple.dt.XCTMetric_Memory.physical' \
  '4096' \
  'Three History page opens over 50,000 pages memory growth' \
  'kB'
