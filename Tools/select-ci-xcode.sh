#!/bin/bash
# SPDX-FileCopyrightText: 2026 wsagency
# SPDX-License-Identifier: BUSL-1.1
set -euo pipefail
cd "$(dirname "$0")/.."

version=$(sed -n "s/^  XCODE: '\(.*\)'$/\1/p" .github/workflows/ci.yml)
[[ "$version" =~ ^[0-9]+\.[0-9]+$ ]] || { echo 'error: missing CI Xcode pin' >&2; exit 2; }
for dir in "/Applications/Xcode_$version.app" /Applications/Xcode.app; do
    [[ -d "$dir" ]] || continue
    actual=$(DEVELOPER_DIR="$dir/Contents/Developer" /usr/bin/xcodebuild -version)
    if [[ "${actual%%$'\n'*}" == "Xcode $version" ]]; then
        printf 'DEVELOPER_DIR=%s/Contents/Developer\n' "$dir"
        exit 0
    fi
done
echo "error: CI-pinned Xcode $version is unavailable" >&2
exit 1
