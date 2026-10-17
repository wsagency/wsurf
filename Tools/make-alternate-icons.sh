#!/bin/sh

# SPDX-FileCopyrightText: 2026 WSurf Agency
# SPDX-License-Identifier: Apache-2.0

# Render the alternate app icons for a future icon picker from
# WSurf/AppIcon.icon with Icon Composer's own renderer, so each one looks like
# what the system draws for the bundle icon:
#
#   AlternateIconLight  Tandem on the light tile (the Default appearance)
#   AlternateIconDark   Tandem on the dark tile (the Dark appearance)
#   AlternateIconMono   one ink (#F5F5F7, the brand's night ink) on the dark tile
#
# Each is an image set in WSurf/Assets.xcassets/AlternateIcons, 512 pt at 1x and
# 2x (512 and 1024 px). They are not the bundle icon; the app loads them by name
# at runtime. Re-run after changing AppIcon.icon:
#
#     sh Tools/make-alternate-icons.sh

set -eu

cd "$(dirname "$0")/.."
ictool="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}/../Applications/Icon Composer.app/Contents/Executables/ictool"
catalog=WSurf/Assets.xcassets/AlternateIcons
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Mono: the night ink replaces both dark-appearance fills.
cp -R WSurf/AppIcon.icon "$work/Mono.icon"
sed -e 's/srgb:0.42745,0.33333,1.00000,1.00000/srgb:0.96078,0.96078,0.96863,1.00000/' \
    -e 's/srgb:0.18431,0.87843,0.69804,1.00000/srgb:0.96078,0.96078,0.96863,1.00000/' \
    WSurf/AppIcon.icon/icon.json > "$work/Mono.icon/icon.json"
if grep -q -e '0\.42745' -e '0\.18431' "$work/Mono.icon/icon.json"; then
  echo "error: AppIcon.icon fills changed; update the mono colours in $0" >&2
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

render AlternateIconLight WSurf/AppIcon.icon Default
render AlternateIconDark WSurf/AppIcon.icon Dark
render AlternateIconMono "$work/Mono.icon" Dark
echo "wrote $catalog"
