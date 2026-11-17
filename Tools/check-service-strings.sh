#!/bin/bash
# SPDX-FileCopyrightText: 2026 WSurf Agency
# SPDX-License-Identifier: BUSL-1.1
#
# D4-20 (the D4-S strings and symbol check, implemented early): a Chromium service built WITHOUT the debug ops (Package.swift's
# WSURF_SERVICE_DEBUG_OPS, which Tools/embed-chromium.sh leaves off for Release and for any real signing identity) must carry none
# of their strings or symbols. A signed service answering `debug.abort`, `debug.stats` or `debug.holdHistory` would be a back door.
#
#   Tools/check-service-strings.sh <service executable | WSurf Chromium.xpc | WSurf.app>
#       exit 0: none of the tokens below is in the file.  exit 1: some are (listed).  exit 2: usage, or no such file.
#   Tools/check-service-strings.sh --expect-debug <the same>
#       the checker's own proof, for a service built WITH the ops (the OOP lane's): exit 0 only if the sentinel strings are found,
#       so a checker that stopped seeing anything (a stripped binary, a changed tool) cannot pass the first mode for the wrong reason.
#
# A new debug op of phase 3-5 adds its token to TOKENS (a name or text that only the debug code has) in the PR that adds the op, and
# declares its protocol name in CefKit as `@_alwaysEmitIntoClient public static var name: String { "..." }`, never as a stored `let`:
# CefKit keeps every stored constant in a service that never reads it, so a stored name would fail this check for a service built
# without the ops.
set -euo pipefail

expectDebug=
if [[ "${1:-}" == --expect-debug ]]; then
    expectDebug=YES
    shift
fi
[[ "$#" -eq 1 ]] || { echo "usage: $0 [--expect-debug] <service executable | WSurf Chromium.xpc | WSurf.app>" >&2; exit 2; }

target="$1"
[[ ! -d "$target/Contents/XPCServices/WSurf Chromium.xpc" ]] || target="$target/Contents/XPCServices/WSurf Chromium.xpc"
[[ ! -d "$target/Contents/MacOS" ]] || target="$target/Contents/MacOS/WSurf Chromium"
[[ -f "$target" ]] || { echo "error: no service executable at $1" >&2; exit 2; }

# Texts of the service's debug code, and the op and flag names of the protocol that only it answers (CefKit's constants are
# unreferenced, and so left out by the linker, in a service that has no debug code).
TOKENS=(
    "create FAILED (debug)"
    "create held (debug)"
    "debug.abort"
    "debug.stats"
    "debug.exitOnHello"
    "debug.askHost"
    "debug.memoryPressure"
    "debug.stubBrowser"
    "debug.hangExit"
    "debug.holdHistory"
    "debug-exit-on-hello"
    "consumeExitOnHello"
    "writeExitOnHello"
    "hangExit"
    "closeFirst"
    "cpuPaint"
    "smallSourceCache"
    "handleDebug"
    "holdHistoryReads"
    "heldHistoryReads"
    "delayNextResult"
)
# Long literals that the service's debug code always has (not the CefKit names, nor a function the compiler may inline).
SENTINELS=("create FAILED (debug)" "create held (debug)")

# `strings` reads the literals, the symbol table and the metadata names alike.
contents=$(/usr/bin/strings -a "$target")
found=()
for token in "${TOKENS[@]}"; do
    if grep -q -F -- "$token" <<<"$contents"; then
        found+=("$token")
    fi
done

if [[ -n "$expectDebug" ]]; then
    for sentinel in "${SENTINELS[@]}"; do
        if ! printf '%s\n' "${found[@]+"${found[@]}"}" | grep -q -x -F -- "$sentinel"; then
            echo "FAIL: the service has no debug ops, but it was expected to: \"$sentinel\" is not in $target" >&2
            exit 1
        fi
    done
    echo "ok: $target has the debug ops (${#found[@]} of ${#TOKENS[@]} tokens found, the sentinels among them)"
    exit 0
fi

if [[ "${#found[@]}" -gt 0 ]]; then
    echo "FAIL: $target carries debug-op strings or symbols (a service without WSURF_SERVICE_DEBUG_OPS must carry none):" >&2
    printf '  %s\n' "${found[@]}" >&2
    exit 1
fi
echo "ok: $target carries none of the ${#TOKENS[@]} debug-op tokens"
