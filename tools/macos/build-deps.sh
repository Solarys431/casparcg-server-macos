#!/usr/bin/env bash
#
# Builds the macOS dependencies of CasparCG Server from source, into one prefix.
#
# Nothing is installed system-wide and Homebrew is not needed: downloads, tools,
# build trees and the result all live under <work-dir>. Libraries are static
# where that is safe, the rest (TBB, OpenAL Soft, FFmpeg) are dylibs with an
# @rpath install name, so package.sh can copy them into CasparCG.app. The codecs
# and other libraries FFmpeg uses are static, inside the FFmpeg dylibs.
#
#   tools/macos/build-deps.sh <work-dir> [jobs]
#   FETCH_ONLY=1 tools/macos/build-deps.sh <work-dir>   downloads and checks every source, builds nothing
#
#   <work-dir>/dl      downloads, checked against tools/macos/deps.list
#   <work-dir>/tools   cmake, ninja, and the build tools of FFmpeg's libraries (build_buildtools)
#   <work-dir>/vulkan  the LunarG Vulkan SDK, see install_vulkan_sdk below
#   <work-dir>/prefix  the result, for -DCMAKE_PREFIX_PATH
#
# A finished step leaves <work-dir>/build/<name>.done; delete it to redo the step.
#
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
work="$(mkdir -p "$1" && cd "$1" && pwd)"
jobs="${2:-$(sysctl -n hw.perflevel0.physicalcpu)}"
export MACOSX_DEPLOYMENT_TARGET="${MACOSX_DEPLOYMENT_TARGET:-14.0}"

dl="$work/dl"
src="$work/src"
bld="$work/build"
prefix="$work/prefix"
tools="$work/tools"
export VULKAN_SDK="${VULKAN_SDK:-$work/vulkan/macOS}"
mkdir -p "$dl" "$src" "$bld" "$prefix" "$tools/bin"
export PATH="$tools/cmake/CMake.app/Contents/bin:$tools/bin:$PATH"
# Only the pkg-config files of this prefix: nothing from Homebrew or MacPorts gets into the build.
export PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig:$prefix/share/pkgconfig"

arch_flags="-arch arm64 -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET"

log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*"; }

# fetch <name>: downloads the deps.list entry if missing, checks its sha256 and prints its path
fetch() {
    local line url sha file got
    line="$(grep -E "^$1 +\|" "$here/deps.list")" || { echo "$1 is missing from deps.list" >&2; exit 1; }
    url="$(echo "$line" | cut -d'|' -f2 | xargs)"
    sha="$(echo "$line" | cut -d'|' -f3 | xargs)"
    file="$dl/$1--$(basename "${url//%2B/+}")"
    if [ ! -s "$file" ]; then
        log "download $1" >&2
        curl -fsSL --retry 3 -o "$file.part" "$url"
        mv "$file.part" "$file"
    fi
    got="$(shasum -a 256 "$file" | cut -d' ' -f1)"
    if [ -z "$sha" ]; then
        log "$1 is not pinned in deps.list: sha256 $got" >&2
    elif [ "$got" != "$sha" ]; then
        echo "$1: sha256 is $got, deps.list expects $sha" >&2
        exit 1
    fi
    echo "$file"
}

# unpack <name>: fresh sources in $src/<name>; prints the top-level source directory
unpack() {
    local file dir entries
    file="$(fetch "$1")"
    dir="$src/$1"
    rm -rf "$dir"
    mkdir -p "$dir"
    case "$file" in
        *.zip) unzip -q "$file" -d "$dir" ;;
        *) tar xf "$file" -C "$dir" ;;
    esac
    entries="$(ls -A "$dir")"
    if [ "$(echo "$entries" | wc -l | xargs)" = 1 ] && [ -d "$dir/$entries" ]; then
        echo "$dir/$entries"
    else
        echo "$dir"
    fi
}

# A library counts as built only with the patches it was built with: the marker holds the fingerprint of
# patches/<name>-*.patch, so a new or changed patch builds it again instead of keeping the one without it.
# FFmpeg's also says whether it has the Metal filters, so a build made with METAL=none is not kept for one
# that asks for them.
patches_sum() {
    local files=("$here"/patches/"$1"-*.patch)
    if [ -e "${files[0]}" ]; then cat "${files[@]}" | shasum -a 256 | cut -c1-16; fi
    if [ "$1" = ffmpeg ]; then
        if [ "${METAL:-}" = none ]; then echo "without Metal"; else echo "with Metal"; fi
    fi
}
done_already() { [ -f "$bld/$1.done" ] && [ "$(cat "$bld/$1.done")" = "$(patches_sum "$1")" ] && log "$1 already built" && true; }
mark_done() { patches_sum "$1" > "$bld/$1.done"; log "$1 done"; }

# cmake_build <name> <source-dir> [cmake args...]: configure, build, install into $prefix
cmake_build() {
    local name="$1" source="$2"
    shift 2
    rm -rf "$bld/$name"
    cmake -S "$source" -B "$bld/$name" -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$prefix" \
        -DCMAKE_PREFIX_PATH="$prefix" \
        -DCMAKE_FIND_FRAMEWORK=LAST \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" \
        -DCMAKE_INSTALL_NAME_DIR=@rpath \
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
        -DCMAKE_IGNORE_PREFIX_PATH="/opt/homebrew;/usr/local;/opt/local" \
        "$@"
    cmake --build "$bld/$name" -j "$jobs"
    cmake --install "$bld/$name"
}

# configure_build <source-dir> [configure args...]: an autotools package, static, built in its source
# tree and installed into $prefix. extra_cflags, when set, is added to CFLAGS.
configure_build() {
    local source="$1"
    shift
    (
        cd "$source"
        CFLAGS="$arch_flags -O2 ${extra_cflags:-}" CXXFLAGS="$arch_flags -O2" LDFLAGS="$arch_flags" \
            ./configure --prefix="$prefix" --disable-shared --enable-static --with-pic "$@"
        make -j"$jobs"
        make install
    )
}

# meson_build <name> <source-dir> [meson args...]: static, into $prefix. With nofallback a missing
# dependency stops the build instead of being downloaded as a subproject.
meson_build() {
    local name="$1" source="$2"
    shift 2
    rm -rf "$bld/$name"
    CFLAGS="$arch_flags" CXXFLAGS="$arch_flags" LDFLAGS="$arch_flags" \
        meson setup "$bld/$name" "$source" --prefix="$prefix" --libdir=lib --buildtype=release \
            --default-library=static -Db_staticpic=true --wrap-mode=nofallback \
            -Dcmake_prefix_path="$prefix" "$@"
    meson compile -C "$bld/$name" -j "$jobs"
    meson install -C "$bld/$name"
}

build_tools() {
    done_already tools && return
    log "tools: cmake, ninja"
    local d
    d="$(unpack cmake)"
    rm -rf "$tools/cmake"
    mv "$d" "$tools/cmake"
    unzip -q -o "$(fetch ninja)" -d "$tools/bin"
    cmake --version | head -1
    echo "ninja $(ninja --version)"
    mark_done tools
}

install_vulkan_sdk() {
    # The SDK is an installer app. copy_only=1 keeps it inside $work/vulkan: it does not
    # touch /usr/local. Its license file says it is made only of open-source components.
    done_already vulkan && return
    local zip app
    zip="$(fetch vulkan)"
    rm -rf "$src/vulkan" "$work/vulkan"
    mkdir -p "$src/vulkan"
    unzip -q "$zip" -d "$src/vulkan"
    app="$(find "$src/vulkan" -maxdepth 1 -name 'vulkansdk-macOS-*.app' | head -1)"
    "$app/Contents/MacOS/$(basename "$app" .app)" --root "$work/vulkan" \
        --accept-licenses --default-answer --confirm-command install com.lunarg.vulkan.core copy_only=1
    mark_done vulkan
}

build_boost() {
    done_already boost && return
    log "boost"
    local d
    d="$(unpack boost)"
    (
        cd "$d"
        ./bootstrap.sh --with-toolset=clang \
            --with-libraries=atomic,chrono,container,context,coroutine,date_time,filesystem,locale,log,program_options,regex,system,thread
        ./b2 -j"$jobs" -d1 --prefix="$prefix" --build-dir="$bld/boost" \
            toolset=clang variant=release link=static threading=multi runtime-link=shared \
            architecture=arm address-model=64 cxxstd=20 \
            cflags="$arch_flags" cxxflags="$arch_flags" linkflags="$arch_flags" \
            boost.locale.icu=off boost.locale.iconv=on \
            install
    )
    mark_done boost
}

build_tbb() {
    done_already tbb && return
    log "tbb"
    cmake_build tbb "$(unpack tbb)" \
        -DBUILD_SHARED_LIBS=ON -DTBB_TEST=OFF -DTBB_EXAMPLES=OFF -DTBB_STRICT=OFF \
        -DTBBMALLOC_PROXY_BUILD=OFF
    mark_done tbb
}

build_openal() {
    done_already openal && return
    log "openal-soft"
    # HAVE_WFUNCTION_EFFECTS=OFF: Apple clang 21 turns OpenAL Soft's -Werror=function-effects
    # into a hard error on the lambdas it hands to CoreAudio as render callbacks.
    cmake_build openal "$(unpack openal)" \
        -DHAVE_WFUNCTION_EFFECTS=OFF \
        -DALSOFT_UTILS=OFF -DALSOFT_EXAMPLES=OFF -DALSOFT_TESTS=OFF \
        -DALSOFT_INSTALL_EXAMPLES=OFF -DALSOFT_INSTALL_UTILS=OFF \
        -DALSOFT_REQUIRE_COREAUDIO=ON \
        -DALSOFT_BACKEND_PORTAUDIO=OFF -DALSOFT_BACKEND_SDL2=OFF -DALSOFT_BACKEND_SDL3=OFF \
        -DALSOFT_BACKEND_JACK=OFF -DALSOFT_BACKEND_PULSEAUDIO=OFF -DALSOFT_BACKEND_PIPEWIRE=OFF
    mark_done openal
}

build_freetype() {
    done_already freetype && return
    log "freetype"
    cmake_build freetype "$(unpack freetype)" \
        -DBUILD_SHARED_LIBS=OFF \
        -DFT_DISABLE_ZLIB=ON -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_PNG=ON \
        -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_BROTLI=ON
    mark_done freetype
}

build_glew() {
    # Headers and a static libGLEW for the diagnostics window (core/diagnostics/osd_graph), which draws with SFML.
    done_already glew && return
    log "glew"
    cmake_build glew "$(unpack glew)/build/cmake" \
        -DBUILD_SHARED_LIBS=OFF -DBUILD_UTILS=OFF -DGLEW_OSMESA=OFF -DGLEW_EGL=OFF -DGLEW_X11=OFF
    mark_done glew
}

build_sfml() {
    # Only sfml-system/window/graphics, for the diagnostics window (core/diagnostics/osd_graph).
    done_already sfml && return
    log "sfml"
    cmake_build sfml "$(unpack sfml)" \
        -DBUILD_SHARED_LIBS=OFF -DSFML_USE_SYSTEM_DEPS=ON \
        -DSFML_BUILD_AUDIO=OFF -DSFML_BUILD_NETWORK=OFF \
        -DSFML_BUILD_EXAMPLES=OFF -DSFML_BUILD_DOC=OFF \
        -DSFML_BUILD_FRAMEWORKS=OFF -DSFML_INSTALL_XCODE_TEMPLATES=OFF \
        -DSFML_MISC_INSTALL_PREFIX="$prefix/share/SFML"
    mark_done sfml
}

build_glfw() {
    # With a fix of ours: glfwInit could stop NSApp from inside -finishLaunching, and then the first
    # window crashed some launches ("NSApp with wrong _running count", glfw/glfw#2476).
    done_already glfw && return
    log "glfw"
    local d patch
    d="$(unpack glfw)"
    for patch in "$here"/patches/glfw-*.patch; do
        log "patch $(basename "$patch")"
        patch -d "$d" -p1 --forward < "$patch"
    done
    cmake_build glfw "$d" \
        -DBUILD_SHARED_LIBS=OFF -DGLFW_BUILD_EXAMPLES=OFF -DGLFW_BUILD_TESTS=OFF -DGLFW_BUILD_DOCS=OFF
    mark_done glfw
}

install_simde() {
    done_already simde && return
    log "simde (headers only)"
    local d
    d="$(unpack simde)"
    rm -rf "$prefix/include/simde"
    mkdir -p "$prefix/include"
    cp -R "$d" "$prefix/include/simde"
    mark_done simde
}

# --- FFmpeg's libraries -------------------------------------------------------------------------
# The external libraries of the FFmpeg that CasparCG ships on Windows (a full build), less those that
# only make sense on Windows or Linux, or not in a playout server: what changes which files CasparCG
# plays, records, streams and filters.

build_buildtools() {
    # pkgconf, meson and the GNU autotools, into $tools: FFmpeg's configure finds most libraries through
    # pkg-config, dav1d, HarfBuzz, FriBidi and librist build only with meson, and zimg's sources come
    # without a configure script. Meson 1.11 is the last that runs on the Python 3.9 of the Command Line
    # Tools. GNU libtool goes in as glibtool: plain libtool is Apple's, which build_x265 needs.
    done_already buildtools && return
    log "build tools: pkgconf, meson, m4, autoconf, automake, libtool"
    local d t
    d="$(unpack pkgconf)"
    (
        cd "$d"
        ./configure --prefix="$tools" --disable-shared --with-pkg-config-dir="$PKG_CONFIG_LIBDIR" \
            --with-system-libdir=/usr/lib --with-system-includedir="$(xcrun -sdk macosx --show-sdk-path)/usr/include"
        make -j"$jobs"
        make install
    )
    ln -sf pkgconf "$tools/bin/pkg-config"
    d="$(unpack meson)"
    rm -rf "$tools/meson"
    mv "$d" "$tools/meson"
    printf '#!/bin/sh\nexec python3 "%s" "$@"\n' "$tools/meson/meson.py" > "$tools/bin/meson"
    chmod +x "$tools/bin/meson"
    for t in m4 autoconf automake libtool; do
        d="$(unpack "$t")"
        (
            cd "$d"
            if [ "$t" = libtool ]; then
                ./configure --prefix="$tools" --program-prefix=g
            else
                ./configure --prefix="$tools"
            fi
            make -j"$jobs"
            make install
        )
    done
    log "pkgconf $(pkg-config --version), meson $(meson --version), $(autoconf --version | head -1)"
    mark_done buildtools
}

build_xz() {
    # liblzma, for the LZMA-compressed TIFFs FFmpeg reads: the macOS SDK has no liblzma to link against.
    done_already xz && return
    log "xz (liblzma)"
    configure_build "$(unpack xz)" --disable-xz --disable-xzdec --disable-lzmadec --disable-lzmainfo \
        --disable-lzma-links --disable-scripts --disable-doc --disable-nls
    mark_done xz
}

build_openssl() {
    # TLS for FFmpeg: https and rtmps with TLS 1.3, and the DTLS of the WHIP muxer, which Secure Transport
    # cannot give; and the encryption of SRT. OPENSSLDIR is the system's /etc/ssl, whose cert.pem is the
    # list of certificate authorities macOS keeps up to date, so tls_verify=1 works without a ca_file.
    # Only the libraries and headers are installed: install_dev writes nothing into OPENSSLDIR.
    done_already openssl && return
    log "openssl"
    local d
    d="$(unpack openssl)"
    (
        cd "$d"
        perl ./Configure darwin64-arm64-cc enable-ec_nistp_64_gcc_128 no-shared no-module no-tests no-docs \
            --prefix="$prefix" --libdir=lib --openssldir=/private/etc/ssl \
            -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET"
        make -j"$jobs" build_libs
        make install_dev
    )
    mark_done openssl
}

build_mbedtls() {
    # The encryption of librist, which works with Mbed TLS or Nettle, not with OpenSSL.
    done_already mbedtls && return
    log "mbedtls"
    cmake_build mbedtls "$(unpack mbedtls)" \
        -DENABLE_PROGRAMS=OFF -DENABLE_TESTING=OFF -DMBEDTLS_FATAL_WARNINGS=OFF \
        -DUSE_SHARED_MBEDTLS_LIBRARY=OFF -DUSE_STATIC_MBEDTLS_LIBRARY=ON
    mark_done mbedtls
}

build_x264() {
    # 8 and 10 bit in one library: --bit-depth=all is the default.
    done_already x264 && return
    log "x264"
    local d
    d="$(unpack x264)"
    (
        cd "$d"
        ./configure --prefix="$prefix" --enable-static --enable-pic --disable-cli \
            --disable-lsmash --disable-swscale --disable-ffms --disable-gpac --disable-avs \
            --extra-cflags="$arch_flags" --extra-ldflags="$arch_flags"
        make -j"$jobs"
        make install
    )
    mark_done x264
}

build_x265() {
    # 8, 10 and 12 bit in one library, as x265's build/linux/multilib.sh and Homebrew do it: the two high
    # bit depth builds become archives that the 8-bit build links in, and Apple's libtool merges the three.
    done_already x265 && return
    log "x265 (8, 10 and 12 bit)"
    local d b
    d="$(unpack x265)/source"
    b="$bld/x265"
    rm -rf "$b"
    local common=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX="$prefix"
        -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET"
        -DCMAKE_POLICY_VERSION_MINIMUM=3.5 -DENABLE_SHARED=OFF -DENABLE_CLI=OFF)
    cmake -S "$d" -B "$b/10bit" "${common[@]}" -DHIGH_BIT_DEPTH=ON -DEXPORT_C_API=OFF -DENABLE_HDR10_PLUS=ON
    cmake --build "$b/10bit" -j "$jobs"
    cmake -S "$d" -B "$b/12bit" "${common[@]}" -DHIGH_BIT_DEPTH=ON -DEXPORT_C_API=OFF -DMAIN12=ON
    cmake --build "$b/12bit" -j "$jobs"
    mkdir -p "$b/8bit"
    cp "$b/10bit/libx265.a" "$b/8bit/libx265_main10.a"
    cp "$b/12bit/libx265.a" "$b/8bit/libx265_main12.a"
    cmake -S "$d" -B "$b/8bit" "${common[@]}" -DLINKED_10BIT=ON -DLINKED_12BIT=ON \
        -DEXTRA_LINK_FLAGS=-L. -DEXTRA_LIB="x265_main10.a;x265_main12.a"
    cmake --build "$b/8bit" -j "$jobs"
    (
        cd "$b/8bit"
        mv libx265.a libx265_main.a
        /usr/bin/libtool -static -o libx265.a libx265_main.a libx265_main10.a libx265_main12.a
    )
    cmake --install "$b/8bit"
    mark_done x265
}

build_libvpx() {
    # VP8 and VP9. The FFmpeg producer decodes both with libvpx, the decoder that reads the alpha of a
    # WebM (get_decoder in av_producer.cpp), so vp9-highbitdepth keeps 10 and 12-bit VP9 playable.
    # The arm64-darwin20 to darwin25 targets differ only in name: the minimum macOS comes from arch_flags.
    done_already libvpx && return
    log "libvpx"
    local d
    d="$(unpack libvpx)"
    rm -rf "$bld/libvpx"
    mkdir -p "$bld/libvpx"
    (
        cd "$bld/libvpx"
        LDFLAGS="$arch_flags" "$d/configure" --prefix="$prefix" --target=arm64-darwin23-gcc \
            --enable-static --disable-shared --enable-pic --enable-runtime-cpu-detect --enable-vp9-highbitdepth \
            --disable-examples --disable-tools --disable-docs --disable-unit-tests \
            --extra-cflags="$arch_flags" --extra-cxxflags="$arch_flags"
        make -j"$jobs"
        make install
    )
    mark_done libvpx
}

build_aom() {
    done_already aom && return
    log "aom"
    cmake_build aom "$(unpack aom)" \
        -DBUILD_SHARED_LIBS=OFF -DENABLE_DOCS=OFF -DENABLE_EXAMPLES=OFF -DENABLE_TESTDATA=OFF \
        -DENABLE_TESTS=OFF -DENABLE_TOOLS=OFF
    mark_done aom
}

build_dav1d() {
    # AV1 decoding in software, for the Macs whose VideoToolbox has no AV1 decoder.
    done_already dav1d && return
    log "dav1d"
    meson_build dav1d "$(unpack dav1d)" -Denable_tools=false -Denable_tests=false -Denable_examples=false
    mark_done dav1d
}

build_svtav1() {
    done_already svtav1 && return
    log "svt-av1"
    cmake_build svtav1 "$(unpack svtav1)" -DBUILD_SHARED_LIBS=OFF -DBUILD_APPS=OFF -DBUILD_TESTING=OFF
    mark_done svtav1
}

build_opus() {
    done_already opus && return
    log "opus"
    configure_build "$(unpack opus)" --disable-doc --disable-extra-programs
    mark_done opus
}

build_lame() {
    # Only the encoder library. LAME still calls ID3 functions it does not declare, which C23 rejects
    # (https://sourceforge.net/p/lame/bugs/517/); the two settings below are Homebrew's workaround.
    done_already lame && return
    log "lame"
    ac_cv_prog_cc_c23=no extra_cflags=-Wno-implicit-function-declaration \
        configure_build "$(unpack lame)" --disable-frontend --disable-decoder --disable-gtktest
    mark_done lame
}

build_ogg() {
    done_already ogg && return
    log "libogg"
    cmake_build ogg "$(unpack ogg)" -DBUILD_SHARED_LIBS=OFF -DINSTALL_DOCS=OFF
    mark_done ogg
}

build_vorbis() {
    done_already vorbis && return
    log "libvorbis"
    cmake_build vorbis "$(unpack vorbis)" -DBUILD_SHARED_LIBS=OFF
    mark_done vorbis
}

build_theora() {
    done_already theora && return
    log "libtheora"
    configure_build "$(unpack theora)" --with-ogg="$prefix" \
        --disable-oggtest --disable-vorbistest --disable-examples --disable-doc --disable-spec
    mark_done theora
}

build_webp() {
    done_already webp && return
    log "libwebp"
    cmake_build webp "$(unpack webp)" -DBUILD_SHARED_LIBS=OFF -DWEBP_BUILD_LIBWEBPMUX=ON \
        -DWEBP_BUILD_ANIM_UTILS=OFF -DWEBP_BUILD_CWEBP=OFF -DWEBP_BUILD_DWEBP=OFF -DWEBP_BUILD_GIF2WEBP=OFF \
        -DWEBP_BUILD_IMG2WEBP=OFF -DWEBP_BUILD_VWEBP=OFF -DWEBP_BUILD_WEBPINFO=OFF -DWEBP_BUILD_WEBPMUX=OFF \
        -DWEBP_BUILD_EXTRAS=OFF
    mark_done webp
}

build_openjpeg() {
    # With the two fixes from openjpeg's master that 2.5.4 lacks and Homebrew applies: a heap overflow
    # reading a tile (OSV-2025-219) and an integer overflow in the encoder (CVE-2026-6192).
    done_already openjpeg && return
    log "openjpeg"
    local d patch
    d="$(unpack openjpeg)"
    for patch in "$here"/patches/openjpeg-*.patch; do
        log "patch $(basename "$patch")"
        patch -d "$d" -p1 --forward < "$patch"
    done
    cmake_build openjpeg "$d" -DBUILD_SHARED_LIBS=OFF -DBUILD_CODEC=OFF -DBUILD_DOC=OFF -DBUILD_TESTING=OFF
    mark_done openjpeg
}

build_snappy() {
    # For the HAP encoder; FFmpeg decodes HAP without it.
    done_already snappy && return
    log "snappy"
    cmake_build snappy "$(unpack snappy)" -DBUILD_SHARED_LIBS=OFF \
        -DSNAPPY_BUILD_TESTS=OFF -DSNAPPY_BUILD_BENCHMARKS=OFF
    mark_done snappy
}

build_soxr() {
    done_already soxr && return
    log "soxr"
    cmake_build soxr "$(unpack soxr)" -DBUILD_SHARED_LIBS=OFF -DBUILD_TESTS=OFF -DBUILD_EXAMPLES=OFF \
        -DWITH_OPENMP=OFF -DWITH_LSR_BINDINGS=OFF
    mark_done soxr
}

build_zimg() {
    # For the zscale filter. The release is a bare tag archive: autogen.sh makes the configure script.
    done_already zimg && return
    log "zimg"
    local d
    d="$(unpack zimg)"
    (cd "$d" && LIBTOOLIZE=glibtoolize ./autogen.sh)
    configure_build "$d"
    mark_done zimg
}

build_harfbuzz() {
    # Text shaping for the drawtext filter, which FFmpeg 8 builds only with HarfBuzz, and for libass.
    done_already harfbuzz && return
    log "harfbuzz"
    meson_build harfbuzz "$(unpack harfbuzz)" -Dfreetype=enabled \
        -Dglib=disabled -Dgobject=disabled -Dcairo=disabled -Dchafa=disabled -Dicu=disabled \
        -Dgraphite=disabled -Dgraphite2=disabled -Dcoretext=disabled -Dpng=disabled -Dzlib=disabled \
        -Draster=disabled -Dvector=disabled -Dgpu=disabled -Dgpu_demo=disabled -Dsubset=disabled \
        -Dtests=disabled -Dintrospection=disabled -Ddocs=disabled -Dutilities=disabled -Dbenchmark=disabled
    mark_done harfbuzz
}

build_fribidi() {
    done_already fribidi && return
    log "fribidi"
    meson_build fribidi "$(unpack fribidi)" -Ddocs=false -Dbin=false -Dtests=false
    mark_done fribidi
}

build_unibreak() {
    # Line breaking by the Unicode rules, for libass.
    done_already unibreak && return
    log "libunibreak"
    configure_build "$(unpack unibreak)"
    mark_done unibreak
}

build_libass() {
    # Subtitles, for the ass and subtitles filters. Fonts come from Core Text, as in Homebrew's build.
    done_already libass && return
    log "libass"
    configure_build "$(unpack libass)" --disable-fontconfig --enable-coretext --enable-libunibreak
    mark_done libass
}

build_srt() {
    done_already srt && return
    log "srt"
    cmake_build srt "$(unpack srt)" -DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DENABLE_APPS=OFF \
        -DENABLE_ENCRYPTION=ON -DUSE_ENCLIB=openssl-evp -DSRT_USE_OPENSSL_STATIC_LIBS=ON
    mark_done srt
}

build_librist() {
    # RIST, with Mbed TLS for the encryption and librist's own copies of cJSON and lz4.
    done_already librist && return
    log "librist"
    meson_build librist "$(unpack librist)" -Dbuilt_tools=false -Dtest=false \
        -Duse_mbedtls=true -Dbuiltin_mbedtls=false -Dbuiltin_cjson=true -Dbuiltin_lz4=true
    mark_done librist
}

build_zeromq() {
    # For the zmq and azmq filters, which take commands for a running filter graph over ZeroMQ.
    done_already zeromq && return
    log "zeromq"
    cmake_build zeromq "$(unpack zeromq)" -DBUILD_SHARED=OFF -DBUILD_STATIC=ON -DBUILD_TESTS=OFF \
        -DWITH_DOCS=OFF -DWITH_PERF_TOOL=OFF -DENABLE_CPACK=OFF -DENABLE_DRAFTS=OFF \
        -DWITH_LIBSODIUM=OFF -DENABLE_CURVE=OFF -DWITH_TLS=OFF -DWITH_LIBBSD=OFF
    mark_done zeromq
}

write_libxml2_pc() {
    # The DASH and IMF demuxers use libxml2, which macOS has: its SDK lacks only the pkg-config file.
    local sdk version
    sdk="$(xcrun -sdk macosx --show-sdk-path)"
    version="$(sed -n 's/^#define LIBXML_DOTTED_VERSION "\(.*\)"$/\1/p' "$sdk/usr/include/libxml2/libxml/xmlversion.h")"
    mkdir -p "$prefix/lib/pkgconfig"
    cat > "$prefix/lib/pkgconfig/libxml-2.0.pc" <<EOF
Name: libXML
Description: the libxml2 of macOS, from $sdk
Version: $version
Libs: -lxml2
Cflags: -I$sdk/usr/include/libxml2
EOF
}

# metal_compilers: sets metal_args, the --metalcc/--metallib arguments for FFmpeg's configure.
# (No namerefs and no empty-array expansion under set -u: macOS still ships bash 3.2.)
#
# The yadif_videotoolbox filter, VideoToolbox's deinterlacer and the one the VideoToolbox decoding
# strategy needs, is a Metal shader compiled at build time, and only Xcode has a Metal compiler:
# the Command Line Tools have none. Without one, METAL_PREBUILT may name a folder of shaders
# compiled on another Mac with tools/macos/prebuild-metal.sh. With neither the build stops: FFmpeg
# would go without the filter, VideoToolbox decoding would only be offered with auto-deinterlace
# set to none, and the default configuration would decode every clip on the CPU. METAL=none asks
# for that build on purpose.
metal_args=()
metal_compilers() {
    if [ "${METAL:-}" = none ]; then
        # Before the other two: FFmpeg would find the Xcode compiler on its own.
        metal_args=(--disable-metal)
        log "Metal: METAL=none, so FFmpeg has no yadif_videotoolbox"
    elif xcrun -sdk macosx metal -v > /dev/null 2>&1; then
        metal_args=(--metalcc="xcrun -sdk macosx metal -mmacosx-version-min=$MACOSX_DEPLOYMENT_TARGET")
        log "Metal: the toolchain on this Mac"
    elif [ -n "${METAL_PREBUILT:-}" ]; then
        # Not in one line with export, whose status would hide a folder that is not there.
        local dir
        dir="$(cd "$METAL_PREBUILT" && pwd)" || { echo "METAL_PREBUILT=$METAL_PREBUILT is not a folder" >&2; exit 1; }
        export METAL_PREBUILT="$dir"
        cat > "$tools/bin/metal-prebuilt" <<'EOF'
#!/usr/bin/env bash
# Stands in for "xcrun metal" with shaders compiled elsewhere (METAL_PREBUILT, prebuild-metal.sh).
set -euo pipefail
if [ "${1:-}" = "-v" ]; then echo "prebuilt Metal shaders in $METAL_PREBUILT"; exit 0; fi
src="" out=""
while [ $# -gt 0 ]; do
    case "$1" in -o) out="$2"; shift 2 ;; -*) shift ;; *) src="$1"; shift ;; esac
done
name="$(basename "$src")"
if [ "$(shasum -a 256 "$src" | cut -d' ' -f1)" != "$(cat "$METAL_PREBUILT/$name.sha256")" ]; then
    echo "$name is not the source $METAL_PREBUILT was built from" >&2
    exit 1
fi
cp "$METAL_PREBUILT/$name.air" "$out"
EOF
        cat > "$tools/bin/metallib-prebuilt" <<'EOF'
#!/usr/bin/env bash
# Stands in for "xcrun metallib": the library was linked with the shader (see metal-prebuilt).
set -euo pipefail
out=""
while [ $# -gt 0 ]; do
    case "$1" in -o) out="$2"; shift 2 ;; *) shift ;; esac
done
cp "$METAL_PREBUILT/$(basename "$out")" "$out"
EOF
        chmod +x "$tools/bin/metal-prebuilt" "$tools/bin/metallib-prebuilt"
        metal_args=(--metalcc="$tools/bin/metal-prebuilt" --metallib="$tools/bin/metallib-prebuilt")
        log "Metal: shaders prebuilt in $METAL_PREBUILT"
    else
        echo "No Metal compiler (it comes with Xcode) and no METAL_PREBUILT: FFmpeg would have no" >&2
        echo "yadif_videotoolbox, and with the default configuration every clip would decode on the CPU." >&2
        echo "Pass METAL_PREBUILT=<shaders from prebuild-metal.sh>, or METAL=none to build without it." >&2
        exit 1
    fi
}

build_ffmpeg() {
    # GPL v3 build, like CasparCG itself; no nonfree parts, so the result can be redistributed.
    # The external libraries are the static ones built above; --pkg-config-flags=--static brings in
    # their own dependencies (libc++ for x265, OpenSSL for SRT, and so on).
    # Vulkan is needed for libavutil/hwcontext_vulkan.h (the Vulkan and VideoToolbox strategies).
    # The Objective-C classes of the avfoundation device get our own names: the NDI runtime loads its
    # NDI|HX driver, which carries another libavdevice, into the process, and two classes with one
    # name make the Objective-C runtime pick either of them.
    done_already ffmpeg && return
    log "ffmpeg"
    local d
    d="$(unpack ffmpeg)"
    metal_compilers
    (
        cd "$d"
        # Fixes FFmpeg 8.1 lacks: those taken from its master name their commit, ours say why.
        for patch in "$here"/patches/ffmpeg-*.patch; do
            [ -f "$patch" ] || continue
            log "patch $(basename "$patch")"
            patch -p1 --forward < "$patch"
        done
        ./configure --prefix="$prefix" --install-name-dir='@rpath' \
            ${metal_args[@]+"${metal_args[@]}"} \
            --enable-shared --disable-static --enable-pic \
            --arch=aarch64 --cc=clang --cxx=clang++ \
            --pkg-config-flags=--static \
            --extra-cflags="$arch_flags -I$prefix/include -I$VULKAN_SDK/include" \
            --extra-ldflags="$arch_flags -L$prefix/lib" \
            --extra-objcflags="-DAVFFrameReceiver=CasparCGAVFFrameReceiver -DAVFAudioReceiver=CasparCGAVFAudioReceiver" \
            --enable-gpl --enable-version3 \
            --disable-doc --disable-debug \
            --enable-videotoolbox --enable-audiotoolbox --enable-vulkan \
            --enable-openssl --enable-libxml2 --enable-lzma \
            --enable-libx264 --enable-libx265 --enable-libvpx --enable-libaom --enable-libdav1d --enable-libsvtav1 \
            --enable-libopus --enable-libmp3lame --enable-libvorbis --enable-libtheora \
            --enable-libwebp --enable-libopenjpeg --enable-libsnappy --enable-libsoxr --enable-libzimg \
            --enable-libfreetype --enable-libharfbuzz --enable-libfribidi --enable-libass \
            --enable-libsrt --enable-librist --enable-libzmq \
            --disable-sdl2 --disable-xlib --disable-libxcb
        make -j"$jobs"
        make install
    )
    # The libraries are @rpath for the app; the tools find them in ../lib, so they run from the prefix as they are.
    local tool
    for tool in ffmpeg ffprobe; do
        install_name_tool -add_rpath @executable_path/../lib "$prefix/bin/$tool"
        codesign --force -s - "$prefix/bin/$tool"
    done
    # What the server asks, avfilter_get_by_name(), and not what was asked of configure.
    local filters
    filters="$("$prefix/bin/ffmpeg" -hide_banner -filters)" || { echo "the ffmpeg just built does not run" >&2; exit 1; }
    case "$filters" in
        *" yadif_videotoolbox "*) log "ffmpeg has yadif_videotoolbox" ;;
        *)
            if [ "${METAL:-}" != none ]; then
                echo "FFmpeg was built without yadif_videotoolbox although Metal was asked for" >&2
                exit 1
            fi
            ;;
    esac
    mark_done ffmpeg
}

if [ "${FETCH_ONLY:-}" = 1 ]; then
    for name in $(grep -E '^[a-z0-9]' "$here/deps.list" | cut -d' ' -f1); do
        fetch "$name" > /dev/null
    done
    log "every source is in $dl and matches deps.list"
    exit 0
fi

log "dependencies for CasparCG on macOS: $work, $jobs jobs, macOS $MACOSX_DEPLOYMENT_TARGET and later"
build_tools
install_vulkan_sdk
build_boost
build_tbb
build_openal
build_freetype
build_glew
build_sfml
build_glfw
install_simde
build_buildtools
build_xz
build_openssl
build_mbedtls
build_x264
build_x265
build_libvpx
build_aom
build_dav1d
build_svtav1
build_opus
build_lame
build_ogg
build_vorbis
build_theora
build_webp
build_openjpeg
build_snappy
build_soxr
build_zimg
build_harfbuzz
build_fribidi
build_unibreak
build_libass
build_srt
build_librist
build_zeromq
write_libxml2_pc
build_ffmpeg
fetch cef > /dev/null
log "all done: $prefix"
