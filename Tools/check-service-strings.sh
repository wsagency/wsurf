#!/bin/bash
# SPDX-FileCopyrightText: 2026 WSurf Agency
# SPDX-License-Identifier: BUSL-1.1
#
# D4-20 (the D4-S strings and symbol check, implemented early): a Chromium service built WITHOUT the debug ops (Package.swift's
# WSURF_SERVICE_DEBUG_OPS, which Tools/embed-chromium.sh allows only for the OOP lane and staged DEBUG ad hoc builds) must carry
# none of them. A signed service answering `debug.abort`, `debug.stats` or `debug.holdHistory` would be a back door.
#
#   Tools/check-service-strings.sh <service executable | WSurf Chromium.xpc | WSurf.app>
#       exit 0: nothing of the debug ops is in the file.  exit 1: something is (listed).  exit 2: usage, or no such file.
#   Tools/check-service-strings.sh --expect-debug <the same>
#       the checker's own proof, for a service built WITH the ops: exit 0 only if EVERY text and EVERY short name is found, and
#       the ones it misses are named. A tool that stopped seeing something (a changed compiler, a stripped binary) fails here.
#   Tools/check-service-strings.sh --list
#       prints what is looked for (tests compare it with the sources).
#
# What is looked for, and why two kinds of evidence (measured on the service, review M1 of PR #153):
# 1. TEXTS. A Swift string literal of 15 bytes or fewer is not kept as text in the file: it is built from immediates in the code,
#    which a search for text cannot see. So every debug op and creation flag logs one text of 16 bytes or more from its
#    handler (`DebugOps.swift`), and those texts are what is searched for, in the bytes of the file. They are read from that file, the one place.
# 2. SHORT NAMES. A wire name of 8 to 15 bytes (`debug.stats`, `closeFirst`) is compared as immediates in the code
#    (`mov`/`movk` of 16 bits each), which `strings` cannot see (`Tools/check-service-immediates.py`). The names are read from CefKit's `@_alwaysEmitIntoClient` debug
#    names (`CefRemoteProtocol.swift`), and the disassembly (`otool -tV`, arm64) is searched for the run of immediates that builds
#    each. A name of fewer than 8 bytes (`fail`, `hold`) is too common to search for; its text (1) covers it.
# The extra names at the end of this file are looked for too in a service without the ops (symbol names, old log texts), but
# they are no proof: a build may not carry them even when it has the ops, so `--expect-debug` does not require them.
set -euo pipefail

repo="$(cd "$(dirname "$0")/.." && pwd)"
debugOps="$repo/Packages/CefSwift/Sources/wsurf-chromium-service/DebugOps.swift"
protocol="$repo/Packages/CefSwift/Sources/CefKit/CefRemoteProtocol.swift"

# Names of debug code that are no proof (see above): not required in a service that has the ops, forbidden in one that has not.
EXTRA=(
    "debug-exit-on-hello"
    "consumeExitOnHello"
    "writeExitOnHello"
    "handleDebug"
    "holdHistoryReads"
    "heldHistoryReads"
    "delayNextResult"
)

# The texts: the string literals of DebugOps.swift, one per line.
texts() {
    [[ -f "$debugOps" ]] || { echo "error: $debugOps not found" >&2; exit 2; }
    sed -n 's/^[[:space:]]*static let [A-Za-z0-9_]* = "\(.*\)"$/\1/p' "$debugOps"
}
# The wire names: the values of the `@_alwaysEmitIntoClient` names of the protocol file, one per line.
names() {
    [[ -f "$protocol" ]] || { echo "error: $protocol not found" >&2; exit 2; }
    sed -n 's/^[[:space:]]*@_alwaysEmitIntoClient public static var [A-Za-z0-9_]*: String { "\(.*\)" }$/\1/p' "$protocol"
}

if [[ "${1:-}" == --list ]]; then
    texts | sed 's/^/text: /'
    names | sed 's/^/name: /'
    exit 0
fi

expectDebug=
if [[ "${1:-}" == --expect-debug ]]; then
    expectDebug=YES
    shift
fi
[[ "$#" -eq 1 ]] || { echo "usage: $0 [--expect-debug] <service executable | WSurf Chromium.xpc | WSurf.app>   |   $0 --list" >&2; exit 2; }

target="$1"
[[ ! -d "$target/Contents/XPCServices/WSurf Chromium.xpc" ]] || target="$target/Contents/XPCServices/WSurf Chromium.xpc"
[[ ! -d "$target/Contents/MacOS" ]] || target="$target/Contents/MacOS/WSurf Chromium"
[[ -f "$target" ]] || { echo "error: no service executable at $1" >&2; exit 2; }

textList=()
while IFS= read -r line; do textList+=("$line"); done < <(texts)
nameList=()
while IFS= read -r line; do nameList+=("$line"); done < <(names)
[[ "${#textList[@]}" -gt 0 && "${#nameList[@]}" -gt 0 ]] || { echo "error: no debug texts or names read from the sources" >&2; exit 2; }
for text in "${textList[@]}"; do
    [[ "${#text}" -ge 16 ]] || { echo "error: the debug text \"$text\" in DebugOps.swift is shorter than 16 bytes: strings cannot see it" >&2; exit 2; }
done

# The file must be a Mach-O program (thin or universal): anything else cannot be judged, and a file that is not one would pass.
magic=$(/usr/bin/head -c 4 "$target" | /usr/bin/xxd -p)
case "$magic" in
    cffaedfe|feedfacf|cafebabe|bebafeca) ;;
    *) echo "error: $target is not a Mach-O program" >&2; exit 2 ;;
esac

# 1. texts, anywhere in the file's bytes (not only where `strings` looks: it skips bytes that no section covers).
foundTexts=()
missingTexts=()
for text in "${textList[@]}"; do
    if LC_ALL=C /usr/bin/grep -a -q -F -- "$text" "$target"; then foundTexts+=("$text"); else missingTexts+=("$text"); fi
done

# 2. short names, from the code: the immediates a name is built from, in a run of instructions.
shortNames=()
for name in "${nameList[@]}"; do
    if [[ "${#name}" -ge 8 && "${#name}" -le 15 ]]; then shortNames+=("$name"); fi
done
foundNames=()
missingNames=()
if [[ "${#shortNames[@]}" -gt 0 ]]; then
    disassembly=$(/usr/bin/otool -tV "$target" 2>/dev/null || true)
    [[ -n "$disassembly" ]] || { echo "error: no disassembly of $target (otool -tV printed nothing)" >&2; exit 2; }
    while IFS= read -r name; do
        if [[ "$name" == FOUND:* ]]; then foundNames+=("${name#FOUND:}"); else missingNames+=("${name#MISSING:}"); fi
    done < <(printf '%s\n' "$disassembly" | /usr/bin/python3 -I "$repo/Tools/check-service-immediates.py" /dev/stdin "${shortNames[@]}")
fi

extraFound=()
for extra in "${EXTRA[@]}"; do
    if LC_ALL=C /usr/bin/grep -a -q -F -- "$extra" "$target"; then extraFound+=("$extra"); fi
done

if [[ -n "$expectDebug" ]]; then
    if [[ "${#missingTexts[@]}" -gt 0 || "${#missingNames[@]}" -gt 0 ]]; then
        echo "FAIL: the service was expected to have every debug op, but $target is missing:" >&2
        [[ "${#missingTexts[@]}" -eq 0 ]] || printf '  text: %s\n' "${missingTexts[@]}" >&2
        [[ "${#missingNames[@]}" -eq 0 ]] || printf '  short name (as code immediates): %s\n' "${missingNames[@]}" >&2
        exit 1
    fi
    echo "ok: $target has every debug op: ${#foundTexts[@]} of ${#textList[@]} texts and ${#foundNames[@]} of ${#shortNames[@]} short names found (${#extraFound[@]} of ${#EXTRA[@]} extra names, which are no proof)"
    exit 0
fi

if [[ "${#foundTexts[@]}" -gt 0 || "${#foundNames[@]}" -gt 0 || "${#extraFound[@]}" -gt 0 ]]; then
    echo "FAIL: $target carries debug ops (a service without WSURF_SERVICE_DEBUG_OPS must carry none):" >&2
    [[ "${#foundTexts[@]}" -eq 0 ]] || printf '  text: %s\n' "${foundTexts[@]}" >&2
    [[ "${#foundNames[@]}" -eq 0 ]] || printf '  short name (as code immediates): %s\n' "${foundNames[@]}" >&2
    [[ "${#extraFound[@]}" -eq 0 ]] || printf '  name: %s\n' "${extraFound[@]}" >&2
    exit 1
fi
echo "ok: $target carries none of ${#textList[@]} debug texts, ${#shortNames[@]} short names or ${#EXTRA[@]} extra names"
