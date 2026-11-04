#!/bin/bash
# SPDX-FileCopyrightText: 2026 wsagency
# SPDX-License-Identifier: BUSL-1.1
#
# prune-chromium-locales.sh RESOURCES_DIR LOCALES
#
# Removes every *.lproj directory of a Chromium Embedded Framework Resources directory whose name (without .lproj) is not in
# LOCALES, the lproj names separated by spaces ("en en_GB hr"). Blank LOCALES keeps every language. `en` must be in a non-empty
# list: it is Chromium's fallback when a language has no locale.pak. Used by Tools/embed-chromium.sh before the first signature.
set -euo pipefail

resources=${1:?usage: prune-chromium-locales.sh RESOURCES_DIR LOCALES}
locales=${2-}
if [[ ! -d "$resources" ]]; then
    echo "error: not a directory: $resources" >&2
    exit 1
fi
[[ -n "${locales// /}" ]] || exit 0
if [[ " $locales " != *" en "* ]]; then
    echo "error: WSURF_CEF_LOCALES must contain en (Chromium's fallback language): '$locales'" >&2
    exit 1
fi
while IFS= read -r -d '' lproj; do
    name=$(basename "$lproj" .lproj)
    [[ " $locales " == *" $name "* ]] || rm -rf "$lproj"
done < <(/usr/bin/find "$resources" -maxdepth 1 -type d -name '*.lproj' -print0)
