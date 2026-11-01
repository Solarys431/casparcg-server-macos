#!/usr/bin/env bash
#
# Compiles FFmpeg's Metal shaders on a Mac that has the Metal toolchain (it comes with Xcode),
# for build-deps.sh on a Mac that has only the Command Line Tools. Hand the output folder to
# build-deps.sh as METAL_PREBUILT; each shader carries the sha256 of the source it was built
# from, and build-deps.sh refuses one that does not match.
#
#   tools/macos/prebuild-metal.sh <ffmpeg-source-dir> <out-dir>
#
set -euo pipefail

src="$(cd "$1" && pwd)"
out="$(mkdir -p "$2" && cd "$2" && pwd)"
target="${MACOSX_DEPLOYMENT_TARGET:-14.0}"

for metal in "$src"/libavfilter/metal/*.metal; do
    name="$(basename "$metal")"
    # The same two steps as FFmpeg's ffbuild/common.mak.
    xcrun -sdk macosx metal -mmacosx-version-min="$target" "$metal" -o "$out/$name.air"
    xcrun -sdk macosx metallib --split-module-without-linking "$out/$name.air" -o "$out/${name%.metal}.metallib"
    shasum -a 256 "$metal" | cut -d' ' -f1 > "$out/$name.sha256"
    echo "$name -> $out"
done
