#!/bin/sh

# SPDX-FileCopyrightText: 2026 Kavoye
# SPDX-License-Identifier: Apache-2.0
# Modified for WSurf by wsagency in 2026; based on Linen by Kavoye.

# Render optional WSurf artwork. Release DMGs use Finder's native layout.
# No volume aliases, temporary mounts, AppleScript or cleanup are required.
#
#     sh Tools/make-dmg-artwork.sh

set -eu

cd "$(dirname "$0")/.."
swift Tools/make-dmg-background.swift Tools/dmg
tiffutil -cathidpicheck Tools/dmg/background.png Tools/dmg/background@2x.png \
  -out Tools/dmg/background.tiff
