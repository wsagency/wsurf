# shellcheck shell=bash
# SPDX-FileCopyrightText: 2026 WSurf Agency
# SPDX-License-Identifier: BUSL-1.1
#
# Pro disk hygiene, sourced by the native build and test runners (AGENTS.md, "Pro Disk Hygiene Rules"):
#
#   . Tools/disk-hygiene.sh
#   wsurf_preflight_disk_guard || exit 2
#   wsurf_setup_run_tmpdir
#   trap 'wsurf_exit_cleanup "io.wsagency.wsurf$WSURF_BUNDLE_ID_SUFFIX"' EXIT
#
# The library sets no trap itself, so it never replaces a caller's. Every function is safe under `set -euo pipefail`
# and macOS bash 3.2. Test overrides: WSURF_CODE_SIGN_CLONE_ROOT (the X directory), WSURF_FREE_DISK_GB_OVERRIDE (the
# measured free space) and WSURF_TMP_ROOT (where /private/tmp/wsurf-* offenders are looked for).
#
# Never touched: /tmp/wsurf-cvs (the Pro lock lives there), io.wsagency.wsurf.code_sign_clone (the real app) and every
# Stage identity (io.wsagency.wsurf.stage.*).

WSURF_PRODUCTION_ID=io.wsagency.wsurf

wsurf_code_sign_clone_root() {
  if [ -n "${WSURF_CODE_SIGN_CLONE_ROOT:-}" ]; then
    printf '%s\n' "$WSURF_CODE_SIGN_CLONE_ROOT"
  else
    printf '%s/X\n' "$(dirname "$(getconf DARWIN_USER_TEMP_DIR)")"
  fi
}

# Free space in GiB on the data volume (where builds, temp files and clones land on macOS).
wsurf_free_disk_gb() {
  if [ -n "${WSURF_FREE_DISK_GB_OVERRIDE:-}" ]; then
    printf '%s\n' "$WSURF_FREE_DISK_GB_OVERRIDE"
    return
  fi
  local volume=/
  [ ! -d /System/Volumes/Data ] || volume=/System/Volumes/Data
  df -Pk "$volume" | awk 'NR == 2 { print int($4 / 1048576) }'
}

# Prints the largest known WSurf leftovers, biggest first. Read-only.
wsurf_print_disk_offenders() {
  local clone_root tmp_root
  clone_root=$(wsurf_code_sign_clone_root)
  tmp_root="${WSURF_TMP_ROOT:-/private/tmp}"
  echo "Largest WSurf leftovers (clean them with Tools/clean-pro-disk.sh; see AGENTS.md, Pro Disk Hygiene Rules):"
  {
    for path in "$clone_root"/*.code_sign_clone "$PWD"/build/DD* "$tmp_root"/wsurf-* "$tmp_root"/WSurf-* "${N:-}"; do
      [ -n "$path" ] && [ -e "$path" ] || continue
      du -sk "$path" 2>/dev/null || true
    done
  } | sort -rn | head -n 20 | awk -F '\t' '{ printf "  %8.1f GB  %s\n", $1 / 1048576, $2 }'
}

# Aborts (returns 1) when fewer than WSURF_MIN_FREE_DISK_GB (default 30) GiB are free. A GitHub-hosted runner has a
# smaller disk, so there it only warns, down to 10 GiB.
wsurf_preflight_disk_guard() {
  local min="${WSURF_MIN_FREE_DISK_GB:-30}" free
  free=$(wsurf_free_disk_gb)
  if [ "$free" -ge "$min" ]; then
    echo "disk: ${free} GB free (minimum ${min} GB)"
    return 0
  fi
  if [ "${RUNNER_ENVIRONMENT:-}" = github-hosted ] && [ "$free" -ge 10 ]; then
    echo "warning: only ${free} GB free on this GitHub-hosted runner (minimum ${min} GB on Pro); continuing"
    return 0
  fi
  echo "error: only ${free} GB free, below the ${min} GB minimum. Free space before building." >&2
  wsurf_print_disk_offenders >&2
  return 1
}

# Removes the code-signing clone macOS keeps for one suffixed test identity. Refuses the production app, every Stage
# identity and anything that is not one plain bundle identifier.
wsurf_safe_remove_code_sign_clone() {
  local id="${1:-}" root
  case "$id" in
    "$WSURF_PRODUCTION_ID".?*) ;;
    *) echo "error: refusing code_sign_clone removal for '$id': not a suffixed $WSURF_PRODUCTION_ID identity" >&2; return 1 ;;
  esac
  case "$id" in
    *..*|*/*|*[[:space:]]*|*'*'*|*'?'*|*'['*)
      echo "error: refusing code_sign_clone removal for '$id': not a plain bundle identifier" >&2; return 1 ;;
    *.stage|*.stage.*|*.stage-*)
      echo "error: refusing code_sign_clone removal for Stage identity '$id'" >&2; return 1 ;;
    "$WSURF_PRODUCTION_ID".CredentialExchange)
      echo "error: refusing code_sign_clone removal for the production extension '$id'" >&2; return 1 ;;
  esac
  root=$(wsurf_code_sign_clone_root)
  [ -n "$root" ] && [ "$root" != / ] || { echo "error: no code_sign_clone root" >&2; return 1; }
  rm -rf -- "$root/$id.code_sign_clone"
}

# Gives this run its own temp directory: TMPDIR points into it until wsurf_cleanup_run_tmpdir removes it.
wsurf_setup_run_tmpdir() {
  local base="${TMPDIR:-/tmp/}"
  base="${base%/}/"
  WSURF_RUN_TMP=$(mktemp -d "${base}wsurf-run-XXXXXX") || return
  export WSURF_RUN_TMP
  export TMPDIR="$WSURF_RUN_TMP/"
}

# Removes WSURF_RUN_TMP. Refuses anything that is not a wsurf-run-* directory, and anything under /tmp/wsurf-cvs.
wsurf_cleanup_run_tmpdir() {
  local dir="${WSURF_RUN_TMP:-}" resolved
  [ -n "$dir" ] && [ -d "$dir" ] || return 0
  resolved=$(cd "$dir" && pwd -P) || return 1
  case "$resolved" in
    /private/tmp/wsurf-cvs|/private/tmp/wsurf-cvs/*|/tmp/wsurf-cvs|/tmp/wsurf-cvs/*)
      echo "error: refusing to remove $resolved: the Pro lock lives there" >&2; return 1 ;;
  esac
  case "${resolved##*/}" in
    wsurf-run-??????) ;;
    *) echo "error: refusing to remove $resolved: not a wsurf-run-* directory" >&2; return 1 ;;
  esac
  chmod -R u+w "$resolved" 2>/dev/null || true
  rm -rf -- "$resolved"
  unset WSURF_RUN_TMP
}

# For an EXIT trap: removes each named identity's code_sign_clone (skipping the unsuffixed production id), then the
# run's temp directory. Never fails, so it cannot change the caller's exit status.
wsurf_exit_cleanup() {
  local id
  for id in "$@"; do
    [ "$id" = "$WSURF_PRODUCTION_ID" ] || wsurf_safe_remove_code_sign_clone "$id" || true
  done
  wsurf_cleanup_run_tmpdir || true
}

# Removes .xcresult bundles older than 48 hours under DIR: failed runs' evidence, kept for triage, then dropped.
wsurf_prune_old_failed_xcresults() {
  local dir="${1:-}"
  [ -n "$dir" ] && [ -d "$dir" ] || return 0
  find "$dir" -type d -name '*.xcresult' -prune -mmin +2880 -exec rm -rf -- {} +
}

# After a local PASS: removes the .xcresult bundles under OUT_DIR (the JSON and checksum evidence stays) and each
# DIR given (isolated DerivedData or other build intermediates). A pinned WSURF_SOURCE_PACKAGES_CACHE directly inside a
# DIR is kept. Does nothing on GitHub Actions, which uploads the bundles, or with WSURF_KEEP_XCRESULT=1.
wsurf_cleanup_pass_artifacts() {
  local out="${1:-}" dir cache="" entry
  [ -n "$out" ] || { echo "error: wsurf_cleanup_pass_artifacts needs an output directory" >&2; return 1; }
  shift
  [ -z "${GITHUB_ACTIONS:-}" ] && [ "${WSURF_KEEP_XCRESULT:-0}" != 1 ] || return 0
  [ ! -d "$out" ] || find "$out" -type d -name '*.xcresult' -prune -exec rm -rf -- {} +
  if [ -n "${WSURF_SOURCE_PACKAGES_CACHE:-}" ] && [ -d "$WSURF_SOURCE_PACKAGES_CACHE" ]; then
    cache=$(cd "$WSURF_SOURCE_PACKAGES_CACHE" && pwd -P)
  fi
  for dir in "$@"; do
    [ -d "$dir" ] || continue
    dir=$(cd "$dir" && pwd -P)
    case "$cache" in
      "$dir"|"$dir"/*/*) echo "warning: keeping $dir: it holds the pinned SourcePackages cache $cache" >&2 ;;
      "$dir"/*)
        for entry in "$dir"/* "$dir"/.[!.]*; do
          [ -e "$entry" ] && [ "$entry" != "$cache" ] || continue
          rm -rf -- "$entry"
        done ;;
      *) rm -rf -- "$dir" ;;
    esac
  done
}
