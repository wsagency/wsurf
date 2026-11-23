#!/bin/zsh
# SPDX-FileCopyrightText: 2026 WSurf Agency
# SPDX-License-Identifier: BUSL-1.1
#
# Re-runnable builder for WSurf's illustrated product walkthroughs (wsurf.app/media/demos/).
# Writes all build intermediates strictly under <repo>/build/motion-demos/.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
BUILD_DIR="$REPO_ROOT/build/motion-demos"
OUT_DIR="$REPO_ROOT/wsurf.app/media/demos"

mkdir -p "$BUILD_DIR" "$OUT_DIR"

BIN="$BUILD_DIR/motion-demos"
echo "Compiling MotionDemos.swift..."
xcrun --sdk macosx swiftc -O -parse-as-library "$SCRIPT_DIR/MotionDemos.swift" -o "$BIN"

FPS=60
WORKERS=6

render_scene() {
  local name="$1"
  local total_frames="$2"
  local poster_sec="$3"
  local crf="$4"
  local seq_dir="$BUILD_DIR/seq-$name"

  rm -rf "$seq_dir"
  mkdir -p "$seq_dir"

  echo "Rendering $name ($total_frames frames @ ${FPS}fps across $WORKERS workers)..."
  local chunk=$(( (total_frames + WORKERS - 1) / WORKERS ))
  local pids=()
  for (( w = 0; w < WORKERS; w++ )); do
    local s=$(( w * chunk ))
    local e=$(( s + chunk ))
    if (( s >= total_frames )); then
      break
    fi
    if (( e > total_frames )); then
      e=$total_frames
    fi
    "$BIN" "$name" frames "$seq_dir" "$FPS" "$s" "$e" &
    pids+=($!)
  done
  for pid in "${pids[@]}"; do
    wait "$pid"
  done

  echo "Encoding $OUT_DIR/$name.mp4 (1280x800, H.264/yuv420p, bt709, faststart, muted)..."
  ffmpeg -y -loglevel error \
    -framerate "$FPS" -i "$seq_dir/f%04d.png" \
    -an \
    -vf "scale=1280:800:flags=lanczos:out_color_matrix=bt709:out_range=tv,setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709,format=yuv420p" \
    -c:v libx264 -profile:v high -level:v 4.0 -preset slow -crf "$crf" \
    -g 120 -bf 2 \
    -colorspace bt709 -color_primaries bt709 -color_trc bt709 \
    -movflags +faststart \
    "$OUT_DIR/$name.mp4"

  echo "Rendering poster $OUT_DIR/$name.jpg (at t=${poster_sec}s)..."
  local poster_png="$BUILD_DIR/poster-$name.png"
  "$BIN" "$name" still "$poster_png" "$poster_sec"
  ffmpeg -y -loglevel error \
    -i "$poster_png" \
    -vf "scale=1280:800:flags=lanczos" \
    -q:v 2 \
    "$OUT_DIR/$name.jpg"
}

# Spaces: 8.00s (480 frames @ 60fps); poster at t=3.55s (mid-delivery across the bridge A -> B)
render_scene "spaces" 480 "3.55" 21

# Micro Window: 8.50s (510 frames @ 60fps); poster at t=5.95s (floating Micro Window + revealed bar + return action)
render_scene "micro" 510 "5.95" 21

echo "Done:"
ls -lh "$OUT_DIR/spaces.mp4" "$OUT_DIR/spaces.jpg" "$OUT_DIR/micro.mp4" "$OUT_DIR/micro.jpg"
