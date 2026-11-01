#!/usr/bin/env bash
#
# Configures and builds CasparCG Server for macOS against the dependencies
# from tools/macos/build-deps.sh. The build tree is <repo>/build, where
# tools/macos/package.sh expects it.
#
#   tools/macos/build.sh <work-dir> [jobs] [build-type]
#
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
work="$(cd "$1" && pwd)"
jobs="${2:-$(sysctl -n hw.perflevel0.physicalcpu)}"
build_type="${3:-RelWithDebInfo}"

export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"
export VULKAN_SDK="${VULKAN_SDK:-$work/vulkan/macOS}"
export PATH="$work/tools/cmake/CMake.app/Contents/bin:$work/tools/bin:$VULKAN_SDK/bin:$PATH"

log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*"; }

log "configure ($build_type, macOS $MACOSX_DEPLOYMENT_TARGET and later, Vulkan SDK $VULKAN_SDK)"
cmake -S "$root/src" -B "$root/build" -G Ninja \
    -DCMAKE_BUILD_TYPE="$build_type" \
    -DCMAKE_PREFIX_PATH="$work/prefix" \
    -DCMAKE_FIND_FRAMEWORK=LAST \
    -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
    -DCASPARCG_DOWNLOAD_CACHE="$work/dl/cmake"

log "build with $jobs jobs"
cmake --build "$root/build" -j "$jobs"
log "built: $root/build/shell/casparcg"
