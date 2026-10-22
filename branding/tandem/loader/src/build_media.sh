#!/bin/zsh
# SPDX-FileCopyrightText: 2026 WSurf Agency
# SPDX-License-Identifier: Apache-2.0
# Renders the loop with the SwiftUI view (ImageRenderer) and encodes video/gif/alpha-mov. Re-runnable.
set -e
cd "$(dirname $0)/.."
H=build/harness
xcrun --sdk macosx swiftc -O -parse-as-library app/TandemLoader.swift src/harness.swift -o $H
rm -rf build/seq build/gif; mkdir -p build/seq video
# 96 frames = 1.6 s at 60 fps = one exact loop. Opaque ground for the mp4s, transparent for the alpha movie.
$H frames build/seq/light 512 96 light ground
$H frames build/seq/dark 512 96 dark ground
$H frames build/seq/clear 512 96 light clear
$H frames build/seq/clear-dark 512 96 dark clear
$H frames build/gif 256 80 light clear   # 80 frames = 1.6 s at 50 fps
# three loops: sequence of symlinks 000..287
for set in light dark clear clear-dark; do
  rm -rf build/seq/$set-x3; mkdir -p build/seq/$set-x3
  for i in $(seq 0 287); do ln -s ../$set/$(printf 'f%03d.png' $((i % 96))) build/seq/$set-x3/$(printf 'g%03d.png' $i); done
done
for s in light dark; do
  ffmpeg -y -loglevel error -framerate 60 -i build/seq/$s-x3/g%03d.png \
    -vf "scale=out_color_matrix=bt709:out_range=tv,format=yuv420p" -c:v libx264 -preset veryslow -crf 14 \
    -colorspace bt709 -color_primaries bt709 -color_trc bt709 -movflags +faststart video/tandem-loader-$s.mp4
done
# transparent GIF, binary alpha, flat palette
ffmpeg -y -loglevel error -framerate 50 -i build/gif/f%03d.png \
  -vf "split[a][b];[a]palettegen=reserve_transparent=1:stats_mode=full[p];[b][p]paletteuse=alpha_threshold=128:dither=none:diff_mode=rectangle" \
  -loop 0 video/tandem-loader.gif
# HEVC with alpha (VideoToolbox; AYUV input keeps BT.709 tagging so colours survive)
ffmpeg -y -loglevel error -framerate 60 -i build/seq/clear-x3/g%03d.png \
  -vf "format=bgra,scale=in_range=full:out_color_matrix=bt709:out_range=tv,format=ayuv" -c:v hevc_videotoolbox -alpha_quality 0.9 -b:v 1500k \
  -tag:v hvc1 -colorspace bt709 -color_primaries bt709 -color_trc bt709 video/tandem-loader-alpha.mov
ls -la video
