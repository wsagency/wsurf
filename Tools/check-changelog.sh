#!/bin/bash
# SPDX-FileCopyrightText: 2026 WSurf Agency
# SPDX-License-Identifier: BUSL-1.1
#
# Fails unless CHANGELOG.md has a "## <version> (build <n>)" section for the MARKETING_VERSION and CURRENT_PROJECT_VERSION
# the project sets. Candidate build numbers keep increasing across minor releases (RELEASING.md).
set -euo pipefail
cd "$(dirname "$0")/.."

setting() { sed -n "s/^[[:space:]]*$1 = \([^;]*\);/\1/p" WSurf.xcodeproj/project.pbxproj | sort -u; }
version=$(setting MARKETING_VERSION)
build=$(setting CURRENT_PROJECT_VERSION)
if [[ -z $version || -z $build || $version == *$'\n'* || $build == *$'\n'* ]]; then
  echo "error: WSurf.xcodeproj needs one MARKETING_VERSION and one CURRENT_PROJECT_VERSION, found '${version//$'\n'/ }' and '${build//$'\n'/ }'" >&2
  exit 1
fi

# The 0.1.x candidates used their patch as the build number.
if [[ $version =~ ^0\.1\.([0-9]+)$ && ${BASH_REMATCH[1]} != "$build" ]]; then
  echo "error: version $version needs build ${BASH_REMATCH[1]} (for 0.1.x the patch number equals CURRENT_PROJECT_VERSION), found build $build" >&2
  exit 1
fi

heading="## $version (build $build)"
if ! [[ $build =~ ^[1-9][0-9]*$ ]]; then
  echo "error: CURRENT_PROJECT_VERSION must be a positive integer, found '$build'" >&2
  exit 1
fi

# The app displays the newest WSurf section first. Upstream Linen headings have no build.
if ! awk -v heading="$heading" -v build="$build" '
  /^## .* \(build [0-9]+\)/ {
    if (++sections == 1) current = (index($0, heading) == 1)
    else {
      sub(/^.* \(build /, "")
      previous = $0 + 0
      exit
    }
  }
  END { exit !(current && build + 0 > previous + 0) }
' CHANGELOG.md; then
  echo "error: CHANGELOG.md must start its releases with '$heading' and a build newer than the previous release" >&2
  exit 1
fi
echo "changelog: $heading"
