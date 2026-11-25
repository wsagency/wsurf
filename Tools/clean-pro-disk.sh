#!/bin/bash
# SPDX-FileCopyrightText: 2026 WSurf Agency
# SPDX-License-Identifier: BUSL-1.1
#
# Reports, and with --apply removes, the regenerable WSurf leftovers that fill the Pro's disk (AGENTS.md, "Pro Disk
# Hygiene Rules"):
#
#   Tools/clean-pro-disk.sh              # dry run (the default): list candidates and their size
#   Tools/clean-pro-disk.sh --apply      # takes the Pro lock first
#
# --apply runs under the Pro lock (WSURF_PRO_LOCK, the with-pro-lock.sh wrapper Tools/ci-local.sh uses), so no build or
# test is using a clone or temp directory while it goes. --no-lock skips it: only when nothing else can build, such as
# below the wrapper's own 15 GiB floor, where it starts nothing.
#   1. Suffixed test identities' code_sign_clone directories in X/. Never io.wsagency.wsurf.code_sign_clone (the real
#      app) or a Stage identity (io.wsagency.wsurf.stage.*).
#   2. WSurf temp directories older than 24 hours at the top of the user temp directory and /private/tmp. Never a
#      wsurf-cvs directory (/tmp/wsurf-cvs holds the Pro lock), nor anything that resolves into one.
#   3. .xcresult bundles older than 48 hours under each worktree's build/.
#   4. Worktrees: report only. A merged, clean worktree with commits of its own is listed with its removal command;
#      nothing is removed.
# Deletes directly and prints the space freed: nothing goes to the Trash.
#
# Test overrides: WSURF_CODE_SIGN_CLONE_ROOT, WSURF_TMP_ROOTS (colon-separated), WSURF_REPO_ROOT.
set -euo pipefail

apply=
lock=YES
for arg in "$@"; do
  case "$arg" in
    --apply) apply=YES ;;
    --no-lock) lock= ;;
    --dry-run) ;;
    *) echo "usage: $0 [--dry-run | --apply [--no-lock]]" >&2; exit 2 ;;
  esac
done

tools="$(cd "$(dirname "$0")" && pwd)"
if [ -n "$apply" ] && [ -n "$lock" ] && [ -z "${WSURF_CI_LOCAL_LOCKED:-}" ]; then
  LOCK="${WSURF_PRO_LOCK-/Users/klukacin/Library/Application Support/Claude/side-session-notes/local_a84c7367-175a-4e1d-8e46-7298dec65c7f/release-0-1-1/with-pro-lock.sh}"
  [ -n "$LOCK" ] && [ -x "$LOCK" ] || {
    echo "error: Pro lock wrapper not found: '$LOCK'. Set WSURF_PRO_LOCK, or pass --no-lock when nothing else builds." >&2
    exit 2
  }
  WSURF_CI_LOCAL_LOCKED=1 exec "$LOCK" "$0" "$@"
fi
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
  case "$(printf '%s' "$id" | tr '[:upper:]' '[:lower:]')" in
    *.stage|*.stage.*|*.stage-*|"$WSURF_PRODUCTION_ID".credentialexchange) continue ;;
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
    # Resolves a symlink too, so a wsurf-run-* link into wsurf-cvs is skipped rather than followed.
    resolved=$(cd "$path" 2>/dev/null && pwd -P || printf '%s' "$path")
    case "$resolved" in
      */wsurf-cvs|*/wsurf-cvs/*) continue ;;
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
  elif [ "$(git -C "$tree" rev-parse HEAD 2>/dev/null)" = "$(git -C "$repo" rev-parse origin/main 2>/dev/null)" ]; then
    echo "  keep (no commits beyond origin/main yet, likely a new task): $tree [$branch]"
  elif git -C "$tree" merge-base --is-ancestor HEAD origin/main 2>/dev/null; then
    echo "  merged and clean: $tree [$branch]  ->  git -C '$repo' worktree remove '$tree' && git -C '$repo' worktree prune"
  else
    echo "  keep (not merged into origin/main): $tree [$branch]"
  fi
done

verb='Would free (dry run; --apply removes)'
[ -z "$apply" ] || verb=Freed
awk -v kb="$total_kb" -v verb="$verb" 'BEGIN { printf "\n%s %.2f GB\n", verb, kb / 1048576 }'
