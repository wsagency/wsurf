#!/bin/bash
# SPDX-FileCopyrightText: 2026 WSurf Agency
# SPDX-License-Identifier: Apache-2.0
#
# Dry run: lists the preference files WSurf test runs left in ~/Library/Preferences. It never moves, edits or deletes
# anything. Three kinds, each with a count, total size and the newest few:
#   profile  io.wsagency.wsurf.profile.<UUID>.plist, minus every UUID in the app's non-secret profile registry
#            (Application Support/WSurf/profiles.json); nothing else of the app's (vault, Keychain) is read
#   suite    <prefix>...<UUID>....plist, for each AppDatabase.defaultsSuite("<prefix>... name in the test sources
#   bare     <UUID>.plist (VaultTestEnvironment and a few tests); other apps can name files this way too, so check first
# Tests now keep all of these under their per-process temporary folder (AppDatabase.defaultsSuite), so the counts must not
# grow across a run.
#
# Usage: Tools/list-leaked-test-prefs.sh [preferences-dir] [profiles.json]

set -eu

prefs="${1:-$HOME/Library/Preferences}"
registry="${2:-$HOME/Library/Application Support/WSurf/profiles.json}"
tests="$(cd "$(dirname "$0")/.." && pwd)/WSurfTests"
sample=5
uuid='[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}'

if [ ! -d "$prefs" ]; then
  echo "error: preferences folder not found: $prefs" >&2
  exit 1
fi

# Every UUID in the registry counts as a real profile; over-excluding is the safe direction.
keep=""
if [ -e "$registry" ]; then
  if [ ! -r "$registry" ]; then
    echo "error: cannot read the profile registry: $registry" >&2
    exit 1
  fi
  keep="$(grep -Eo "$uuid" "$registry" | tr '[:lower:]' '[:upper:]' | sort -u | tr '\n' ' ' || true)"
  echo "Real app profiles excluded: $(printf '%s' "$keep" | wc -w | tr -d ' ') (from $registry)"
else
  echo "Real app profiles excluded: 0 (no registry at $registry, so the app has no named profiles to protect)"
fi

# Suite name prefixes: the literal each test passes to AppDatabase.defaultsSuite, as one escaped alternation.
prefixes=""
if [ -d "$tests" ]; then
  prefixes="$(
    grep -rhoE 'defaultsSuite\("[A-Za-z][A-Za-z0-9._-]+' "$tests" --include='*.swift' |
      sed 's/^defaultsSuite("//' | sort -u | sed 's/\./\\./g' | paste -sd '|' -
  )"
fi
echo "Test suite prefixes: $(printf '%s' "$prefixes" | tr '|' '\n' | grep -c . || true) (from ${tests})"

# One `stat` per batch of files, not per file: a leaking Mac holds tens of thousands.
listing="$(
  find "$prefs" -maxdepth 1 -type f -name '*.plist' -print0 |
    xargs -0 stat -f '%z%t%Sm%t%N' -t '%Y-%m-%d %H:%M' 2>/dev/null |
    KEEP="$keep" UUID="$uuid" PREFIXES="$prefixes" awk -F '\t' '
      BEGIN {
        n = split(ENVIRON["KEEP"], ids, " "); for (i = 1; i <= n; i++) real[ids[i]] = 1
        id = ENVIRON["UUID"]
        profile = "^io\\.wsagency\\.wsurf\\.profile\\." id "\\.plist$"
        bare = "^" id "\\.plist$"
        suite = ENVIRON["PREFIXES"] == "" ? "" : "^(" ENVIRON["PREFIXES"] ")[^/]*" id "[^/]*\\.plist$"
        any = id
      }
      {
        name = $3; sub(/.*\//, "", name)
        if (match(name, any) && toupper(substr(name, RSTART, RLENGTH)) in real) next
        if (name ~ profile) kind = "profile"
        else if (name ~ bare) kind = "bare"
        else if (suite != "" && name ~ suite) kind = "suite"
        else next
        print kind "\t" $1 "\t" $2 "\t" name
      }' |
    sort -t "$(printf '\t')" -k3,3r
)"

echo "Leaked test preference files in $prefs (dry run: nothing moved or deleted)"
for kind in profile suite bare; do
  rows="$(printf '%s\n' "$listing" | awk -F '\t' -v k="$kind" '$1 == k')"
  count=0
  bytes=0
  if [ -n "$rows" ]; then
    count="$(printf '%s\n' "$rows" | wc -l | tr -d ' ')"
    bytes="$(printf '%s\n' "$rows" | awk -F '\t' '{ total += $2 } END { printf "%d", total }')"
  fi
  echo "$kind: $count files, $bytes bytes ($(awk -v b="$bytes" 'BEGIN { printf "%.1f", b / 1048576 }') MiB)"
  if [ "$count" -gt 0 ]; then
    printf '%s\n' "$rows" | head -n "$sample" | awk -F '\t' '{ printf "  %s  %s  %d B\n", $3, $4, $2 }'
  fi
done
