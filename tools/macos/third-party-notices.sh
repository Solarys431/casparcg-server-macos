#!/usr/bin/env bash
#
# Writes THIRD-PARTY-NOTICES.txt: the licence texts of what the app carries, taken from the sources build-deps.sh
# built it from, from this repository, and for the binary components from their projects. package.sh puts the file in Contents/Resources.
#
#   tools/macos/third-party-notices.sh <work-dir> <output> <build-dir>
#
# It stops when a licence is missing: an app without its notices must not be packaged.
#
# The build tools (cmake, meson, autoconf, automake, libtool, m4, pkgconf) are left out: they are not in the app.
#
set -euo pipefail

work="$(cd "$1" && pwd)"
out="$2"
build="$(cd "$3" && pwd)"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
src="$work/src"
log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
fail() { echo "third-party-notices: $*" >&2; exit 1; }
download() { curl -fsSL --retry 3 --max-time 30 "$1" || fail "could not download $1"; }

# library directory in $src, then what it is
libraries=(
    "boost:Boost" "tbb:oneTBB" "openal:OpenAL Soft" "glfw:GLFW" "freetype:FreeType" "glew:GLEW" "sfml:SFML"
    "ffmpeg:FFmpeg" "x264:x264" "x265:x265" "libvpx:libvpx" "aom:libaom" "dav1d:dav1d"
    "svtav1:SVT-AV1" "opus:Opus" "lame:LAME" "ogg:libogg" "vorbis:libvorbis" "theora:libtheora" "webp:libwebp"
    "openjpeg:OpenJPEG" "snappy:Snappy" "soxr:libsoxr" "zimg:zimg" "harfbuzz:HarfBuzz" "fribidi:FriBidi"
    "unibreak:libunibreak" "libass:libass" "openssl:OpenSSL" "mbedtls:Mbed TLS" "srt:SRT" "librist:librist"
    "zeromq:ZeroMQ" "xz:XZ Utils"
)

licence_files() {
    # The licence files at the top of a source tree, the usual names first.
    find "$1" -maxdepth 1 -type f \( -iname 'COPYING*' -o -iname 'LICENSE*' -o -iname 'LICENCE*' -o -iname 'NOTICE*' \) | sort
}

section() {
    printf '\n%s\n%s\n%s\n\n' "================================================================================" "$1" \
        "================================================================================"
}

{
    echo "CasparCG Server for macOS: notices"
    echo
    echo "This app is a modified version of CasparCG Server, by the Swedish Broadcasting Corporation (SVT) and its"
    echo "contributors. It starts from CasparCG master at f4d6970c (27 October 2026), with Niklas Andersson's Vulkan work"
    echo "on top, and carries the changes of the macOS port, made from October 2026. It is an unofficial port, not"
    echo "distributed by SVT. The source of each release is at https://github.com/Solarys431/casparcg-server-macos,"
    echo "under the tag of that release."
    echo
    echo "CasparCG Server is free software under the GNU General Public License version 3 or later (see LICENSE)."
    echo "The app also carries the software below, each under its own licence, reproduced here as it comes with"
    echo "its source. The exact sources and their SHA-256 checksums are in tools/macos/deps.list and in"
    echo "src/CMakeModules/Bootstrap_Mac.cmake."

    for entry in "${libraries[@]}"; do
        dir="${entry%%:*}"; name="${entry#*:}"
        top="$(find "$src/$dir" -mindepth 1 -maxdepth 1 -type d | head -1)"
        [ -n "$top" ] || fail "missing source: $dir"
        section "$name ($(basename "$top"))"
        files="$(licence_files "$top")"
        [ -n "$files" ] || fail "no licence file in $top"
        while IFS= read -r f; do
            echo "--- $(basename "$f")"
            cat "$f"
            echo
        done <<< "$files"
        if [ "$dir" = freetype ]; then
            # The licence of the project, and the ones of the two drivers that have their own.
            for f in docs/FTL.TXT src/bdf/README src/pcf/README; do
                [ -f "$top/$f" ] || fail "no $f in $top"
                echo "--- $f"
                cat "$top/$f"
                echo
            done
        fi
    done

    section "SIMDe"
    download https://raw.githubusercontent.com/simd-everywhere/simde/v0.8.2/COPYING
    echo

    section "oscpack, in src/protocol/osc/oscpack"
    sed -n '/oscpack -- Open Sound/,/DEALINGS IN THE SOFTWARE/p' "$root/src/protocol/osc/oscpack/OscTypes.h"
    echo

    section "Robert Penner's Easing Equations, in src/common/tweener.cpp"
    LC_ALL=C sed -n '/TERMS OF USE - EASING EQUATIONS/,/SUCH DAMAGE/p' "$root/src/common/tweener.cpp" |
        LC_ALL=C sed -e 's#^// \{0,1\}##' -e 's/^Copyright .* 2001 Robert Penner/Copyright (c) 2001 Robert Penner/'
    echo

    for dep in "vk_bootstrap:vk-bootstrap" "vma:VulkanMemoryAllocator"; do
        licence="$build/_deps/${dep%%:*}-src/LICENSE.txt"
        [ -f "$licence" ] || fail "no licence for ${dep#*:} at $licence"
        section "${dep#*:}"
        cat "$licence"
        echo
    done

    cef_licence="$(find "$build" -maxdepth 6 -path '*cef*' -name LICENSE.txt | head -1)"
    [ -n "$cef_licence" ] || fail "no CEF LICENSE.txt in $build"
    cef_version="$(sed -n 's/^#define CEF_VERSION "\(.*\)"/\1/p' "$(dirname "$cef_licence")/include/cef_version.h")"
    [ -n "$cef_version" ] || fail "no CEF version next to $cef_licence"
    section "Chromium Embedded Framework ($cef_version)"
    cat "$cef_licence"
    echo
    echo "Chromium and its third-party components carry their own licences, listed in full inside the app's"
    echo "Chromium Embedded Framework (chrome://credits)."

    section "Vulkan loader, MoltenVK and KosmicKrisp (Mesa)"
    for url in \
        "Vulkan loader|https://raw.githubusercontent.com/KhronosGroup/Vulkan-Loader/vulkan-sdk-1.4.363.0/LICENSE.txt" \
        "MoltenVK|https://raw.githubusercontent.com/KhronosGroup/MoltenVK/v1.4.2/LICENSE" \
        "SPIRV-Cross, inside MoltenVK|https://raw.githubusercontent.com/KhronosGroup/SPIRV-Cross/main/LICENSE" \
        "glslang, inside MoltenVK|https://raw.githubusercontent.com/KhronosGroup/glslang/main/LICENSE.txt" \
        "SPIRV-Tools, inside MoltenVK|https://raw.githubusercontent.com/KhronosGroup/SPIRV-Tools/main/LICENSE" \
        "cereal, inside MoltenVK|https://raw.githubusercontent.com/USCiLab/cereal/master/LICENSE" \
        "Mesa (KosmicKrisp), MIT licence|https://gitlab.freedesktop.org/mesa/mesa/-/raw/main/licenses/MIT" \
        "xxHash, inside KosmicKrisp|https://raw.githubusercontent.com/Cyan4973/xxHash/v0.8.3/LICENSE"; do
        echo "--- ${url%%|*} (${url#*|})"
        download "${url#*|}"
        echo
    done
    echo "--- cJSON, inside the Vulkan loader"
    download https://raw.githubusercontent.com/KhronosGroup/Vulkan-Loader/vulkan-sdk-1.4.363.0/loader/cJSON.c |
        sed -n '1,/\*\//p'
    echo
    echo "KosmicKrisp source files carry these notices: Copyright (c) 2022 Collabora Ltd. and Red Hat Inc.;"
    echo "Copyright 2025 LunarG, Inc.; Copyright 2025 Google LLC. Other Mesa files name other authors and may carry"
    echo "other licences, listed in the licenses directory of the Mesa source."
} > "$out"

log "written: $out ($(wc -l < "$out" | xargs) lines)"
