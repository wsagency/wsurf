#!/bin/bash
# SPDX-FileCopyrightText: 2026 WSurf Agency
# SPDX-License-Identifier: Apache-2.0
#
# Fails unless CHANGELOG.md has a "## <version> (build <n>)" section for the MARKETING_VERSION and CURRENT_PROJECT_VERSION
# the project sets. Every candidate build bumps the build number and adds its section (RELEASING.md).
set -euo pipefail
cd "$(dirname "$0")/.."

setting() { sed -n "s/^[[:space:]]*$1 = \([^;]*\);/\1/p" WSurf.xcodeproj/project.pbxproj | sort -u; }
version=$(setting MARKETING_VERSION)
build=$(setting CURRENT_PROJECT_VERSION)
if [[ -z $version || -z $build || $version == *$'\n'* || $build == *$'\n'* ]]; then
  echo "error: WSurf.xcodeproj needs one MARKETING_VERSION and one CURRENT_PROJECT_VERSION, found '${version//$'\n'/ }' and '${build//$'\n'/ }'" >&2
  exit 1
fi

heading="## $version (build $build)"
if ! awk -v heading="$heading" 'index($0, heading) == 1 { found = 1 } END { exit !found }' CHANGELOG.md; then
  echo "error: CHANGELOG.md has no '$heading' section" >&2
  exit 1
fi
echo "changelog: $heading"
