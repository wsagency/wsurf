#!/bin/bash
# SPDX-FileCopyrightText: 2026 WSurf Agency
# SPDX-License-Identifier: Apache-2.0
#
# Dry run: lists io.wsagency.wsurf.profile.<UUID>.plist files that test runs left in ~/Library/Preferences.
# It never moves, edits or deletes anything. Profiles the real app still lists in its non-secret profile registry
# (Application Support/WSurf/profiles.json) are excluded; nothing else of the app's (vault, Keychain) is read.
#
# Usage: Tools/list-leaked-test-prefs.sh [preferences-dir] [profiles.json]

set -eu

prefs="${1:-$HOME/Library/Preferences}"
registry="${2:-$HOME/Library/Application Support/WSurf/profiles.json}"
sample=10
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

# One `stat` per batch of files, not per file: a leaking Mac can hold tens of thousands.
listing="$(
  find "$prefs" -maxdepth 1 -type f -name 'io.wsagency.wsurf.profile.*.plist' -print0 |
    xargs -0 stat -f '%z%t%Sm%t%N' -t '%Y-%m-%d %H:%M' 2>/dev/null |
    awk -F '\t' -v keep="$keep" -v pattern="^io\\.wsagency\\.wsurf\\.profile\\.$uuid\\.plist$" '
      BEGIN { n = split(keep, ids, " "); for (i = 1; i <= n; i++) real[ids[i]] = 1 }
      {
        name = $3; sub(/.*\//, "", name)
        if (name !~ pattern) next
        id = toupper(substr(name, 27, 36))
        if (id in real) next
        print $1 "\t" $2 "\t" name
      }' |
    sort -t "$(printf '\t')" -k2,2r
)"

count=0
bytes=0
if [ -n "$listing" ]; then
  count="$(printf '%s\n' "$listing" | wc -l | tr -d ' ')"
  bytes="$(printf '%s\n' "$listing" | awk -F '\t' '{ total += $1 } END { printf "%d", total }')"
fi

echo "Leaked test profile preference files in $prefs (dry run: nothing moved or deleted)"
echo "Count: $count"
echo "Total size: $bytes bytes ($(awk -v b="$bytes" 'BEGIN { printf "%.1f", b / 1048576 }') MiB)"
if [ "$count" -gt 0 ]; then
  echo "Newest $sample:"
  printf '%s\n' "$listing" | head -n "$sample" | awk -F '\t' '{ printf "  %s  %s  %d B\n", $2, $3, $1 }'
fi
