#!/bin/bash
# SPDX-FileCopyrightText: 2026 WSurf Agency
# SPDX-License-Identifier: BUSL-1.1
#
# Reports, and with --apply removes, the regenerable WSurf leftovers that fill the Pro's disk (AGENTS.md, "Pro Disk
# Hygiene Rules"):
#
#   Tools/clean-pro-disk.sh              # dry run (the default): list candidates and their size
#   "$LOCK" Tools/clean-pro-disk.sh --apply
#
# Run --apply under the Pro lock, so no build or test is using a clone or temp directory while it goes.
#   1. Suffixed test identities' code_sign_clone directories in X/. Never io.wsagency.wsurf.code_sign_clone (the real
#      app) or a Stage identity (io.wsagency.wsurf.stage.*).
#   2. WSurf temp directories older than 24 hours at the top of the user temp directory and /private/tmp. Never
#      /tmp/wsurf-cvs, which holds the Pro lock.
#   3. .xcresult bundles older than 48 hours under each worktree's build/.
#   4. Worktrees: report only. A merged, clean worktree is listed with its removal command; nothing is removed.
# Deletes directly and prints the space freed: nothing goes to the Trash.
#
# Test overrides: WSURF_CODE_SIGN_CLONE_ROOT, WSURF_TMP_ROOTS (colon-separated), WSURF_REPO_ROOT.
set -euo pipefail

apply=
case "${1:-}" in
  --apply) apply=YES ;;
  ''|--dry-run) ;;
  *) echo "usage: $0 [--dry-run | --apply]" >&2; exit 2 ;;
esac

tools="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=Tools/disk-hygiene.sh
. "$tools/disk-hygiene.sh"
repo="${WSURF_REPO_ROOT:-$(dirname "$tools")}"
clone_root=$(wsurf_code_sign_clone_root)
tmp_roots="${WSURF_TMP_ROOTS:-$(getconf DARWIN_USER_TEMP_DIR):/private/tmp}"

total_kb=0
# Prints one candidate with its size and adds it to the total. The caller removes it.
candidate() {
  local path="$1" kb
  kb=$(du -sk "$path" 2>/dev/null | awk '{ print $1 }')
  kb=${kb:-0}
  total_kb=$((total_kb + kb))
  awk -v kb="$kb" -v path="$path" 'BEGIN { printf "  %8.2f GB  %s\n", kb / 1048576, path }'
}

echo "== code_sign_clone directories in $clone_root"
for path in "$clone_root/$WSURF_PRODUCTION_ID".*.code_sign_clone; do
  [ -d "$path" ] || continue
  id=$(basename "$path" .code_sign_clone)
  case "$id" in
    *.stage|*.stage.*|*.stage-*|"$WSURF_PRODUCTION_ID".CredentialExchange) continue ;;
  esac
  candidate "$path"
  [ -z "$apply" ] || wsurf_safe_remove_code_sign_clone "$id"
done

echo "== WSurf temp directories older than 24 hours"
IFS=: read -r -a roots <<< "$tmp_roots"
for root in "${roots[@]}"; do
  root="${root%/}"
  [ -d "$root" ] || continue
  while IFS= read -r path; do
    resolved=$(cd "$(dirname "$path")" && pwd -P)/$(basename "$path")
    case "$resolved" in
      /private/tmp/wsurf-cvs|/private/tmp/wsurf-cvs/*) continue ;;
    esac
    candidate "$path"
    [ -z "$apply" ] || { chmod -R u+w "$path" 2>/dev/null || true; rm -rf -- "$path"; }
  done < <(find "$root" -mindepth 1 -maxdepth 1 -mmin +1440 \( -name 'WSurf-private-*' -o -name 'wsurf-d4-*' \
             -o -name 'WSurf-tests-*' -o -name 'wsurf-chromium-*' -o -name 'wsurf-run-*' \) 2>/dev/null)
done

worktrees=()
while IFS= read -r line; do
  worktrees+=("${line#worktree }")
done < <(git -C "$repo" worktree list --porcelain | grep '^worktree ')

echo "== .xcresult bundles older than 48 hours in build/"
for tree in "${worktrees[@]}"; do
  [ -d "$tree/build" ] || continue
  while IFS= read -r path; do
    candidate "$path"
    [ -z "$apply" ] || rm -rf -- "$path"
  done < <(find "$tree/build" -type d -name '*.xcresult' -prune -mmin +2880 2>/dev/null)
done

echo "== worktrees (report only)"
git -C "$repo" fetch --quiet origin main 2>/dev/null || echo "  warning: could not fetch origin/main; merge status may be stale"
main_tree="${worktrees[0]:-}"
for tree in "${worktrees[@]}"; do
  [ "$tree" != "$main_tree" ] || continue
  if [ ! -d "$tree" ]; then
    echo "  prunable (directory gone): $tree  ->  git -C '$repo' worktree prune"
    continue
  fi
  branch=$(git -C "$tree" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')
  if [ -n "$(git -C "$tree" status --porcelain 2>/dev/null)" ]; then
    echo "  keep (uncommitted changes, owner review): $tree [$branch]"
  elif git -C "$tree" merge-base --is-ancestor HEAD origin/main 2>/dev/null; then
    echo "  merged and clean: $tree [$branch]  ->  git -C '$repo' worktree remove '$tree' && git -C '$repo' worktree prune"
  else
    echo "  keep (not merged into origin/main): $tree [$branch]"
  fi
done

verb='Would free (dry run; --apply removes)'
[ -z "$apply" ] || verb=Freed
awk -v kb="$total_kb" -v verb="$verb" 'BEGIN { printf "\n%s %.2f GB\n", verb, kb / 1048576 }'
