#!/bin/sh

# SPDX-FileCopyrightText: 2026 WSurf Agency
# SPDX-License-Identifier: BUSL-1.1

# Render the three flat Dock finishes from the Tandem Icon Composer source:
#
#   AlternateIconLight  Tandem on the light tile (the Default appearance)
#   AlternateIconDark   Tandem on the dark tile (the Dark appearance)
#   AlternateIconMono   one ink (#F5F5F7, the brand's night ink) on the dark tile
#
# Each is an image set in WSurf/Assets.xcassets/AlternateIcons, 512 pt at 1x and
# 2x (512 and 1024 px). Re-run after changing the flat Tandem artwork:
#
#     sh Tools/make-alternate-icons.sh

set -eu

cd "$(dirname "$0")/.."
ictool="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}/../Applications/Icon Composer.app/Contents/Executables/ictool"
catalog=WSurf/Assets.xcassets/AlternateIcons
flat=branding/tandem/icon/Tandem.icon
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Mono: the night ink replaces both dark-appearance fills.
cp -R "$flat" "$work/Mono.icon"
sed -e 's/srgb:0.42745,0.33333,1.00000,1.00000/srgb:0.96078,0.96078,0.96863,1.00000/' \
    -e 's/srgb:0.18431,0.87843,0.69804,1.00000/srgb:0.96078,0.96078,0.96863,1.00000/' \
    "$flat/icon.json" > "$work/Mono.icon/icon.json"
if grep -q -e '0\.42745' -e '0\.18431' "$work/Mono.icon/icon.json"; then
  echo "error: Tandem.icon fills changed; update the mono colours in $0" >&2
  exit 1
fi

# render NAME DOCUMENT RENDITION
render() {
  set_dir="$catalog/$1.imageset"
  mkdir -p "$set_dir"
  for scale in 1 2; do
    suffix=""
    [ "$scale" = 1 ] || suffix="@${scale}x"
    out="$set_dir/$1$suffix.png"
    "$ictool" "$2" --export-image --output-file "$out" --platform macOS \
      --rendition "$3" --width 512 --height 512 --scale "$scale" > /dev/null
    [ -s "$out" ] || { echo "error: ictool wrote nothing to $out" >&2; exit 1; }
  done
  cat > "$set_dir/Contents.json" <<EOF
{
  "images" : [
    {
      "filename" : "$1.png",
      "idiom" : "universal",
      "scale" : "1x"
    },
    {
      "filename" : "$1@2x.png",
      "idiom" : "universal",
      "scale" : "2x"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
EOF
}

mkdir -p "$catalog"
cat > "$catalog/Contents.json" <<EOF
{
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
EOF

render AlternateIconLight "$flat" Default
render AlternateIconDark "$flat" Dark
render AlternateIconMono "$work/Mono.icon" Dark
echo "wrote $catalog"
