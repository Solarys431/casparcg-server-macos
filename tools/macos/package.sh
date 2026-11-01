#!/usr/bin/env bash
#
# Builds "CasparCG Server.app" from the build tree and the dependency prefix, and a DMG.
#
#   tools/macos/package.sh <work-dir> [options]
#
#   <work-dir>          the folder given to build-deps.sh, with prefix/ and vulkan/
#   --build <dir>       the CMake build tree (default: <repo>/build)
#   --out <dir>         where the app and the DMG go (default: <repo>/dist)
#   --sign <identity>   codesign identity; "-", the default, signs ad hoc. A real identity
#                       also turns on the hardened runtime with tools/macos/entitlements.plist.
#   --ndi <dylib>       put this libndi.dylib in the app. Read the NDI SDK license before you
#                       distribute an app that carries it.
#   --scanner <binary>  put a media scanner, built from its own sources, in Contents/Helpers as media-scanner,
#                       with the prefix's ffmpeg and ffprobe made to load the app's libraries; the server starts
#                       it and ends it (start_media_scanner in src/shell/macos_specific.cpp)
#   --no-dmg            the app only
#
# The app carries everything it runs with: the server, CEF and its helper apps, FFmpeg, TBB,
# OpenAL Soft, the Vulkan loader and two Vulkan drivers, KosmicKrisp (macOS 26 and later) and
# MoltenVK (older macOS), chosen at startup (see select_vulkan_driver in src/shell/macos_specific.cpp).
#
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
work="$(cd "$1" && pwd)"
shift

build="$root/build"
out="$root/dist"
identity="-"
ndi=""
scanner=""
make_dmg=1
while [ $# -gt 0 ]; do
    case "$1" in
        --build) build="$(cd "$2" && pwd)"; shift 2 ;;
        --out) out="$2"; shift 2 ;;
        --sign) identity="$2"; shift 2 ;;
        --ndi) ndi="$2"; shift 2 ;;
        --scanner) scanner="$(cd "$(dirname "$2")" && pwd)/$(basename "$2")"; shift 2 ;;
        --no-dmg) make_dmg=0; shift ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

prefix="$work/prefix"
vulkan="${VULKAN_SDK:-$work/vulkan/macOS}"
name="CasparCG Server"
bundle_id="com.casparcg.server"
min_macos="${MACOSX_DEPLOYMENT_TARGET:-14.0}"

version_part() { sed -n "s/^set(CONFIG_VERSION_$1 \\([0-9]*\\)).*/\\1/p" "$root/src/CMakeLists.txt" | head -1; }
version="$(version_part MAJOR).$(version_part MINOR).$(version_part BUG)"
revision="$(git -C "$root" rev-parse --short HEAD 2>/dev/null || echo unknown)"

app="$out/$name.app"
contents="$app/Contents"
frameworks="$contents/Frameworks"
resources="$contents/Resources"
cef="Chromium Embedded Framework.framework"

log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*"; }

[ -x "$build/shell/casparcg" ] || { echo "no server in $build/shell: run tools/macos/build.sh first" >&2; exit 1; }
[ -d "$build/Frameworks/$cef" ] || { echo "no CEF in $build/Frameworks" >&2; exit 1; }

log "$name $version ($revision) -> $app"
mkdir -p "$out"
rm -rf "$app"
mkdir -p "$contents/MacOS" "$frameworks" "$resources/vulkan/icd.d"

log "server and CEF"
cp "$build/shell/casparcg" "$contents/MacOS/casparcg"
ditto "$build/Frameworks/$cef" "$frameworks/$cef"
# Some CEF files come read-only, which trips up codesign and file copies later.
chmod -R u+w "$frameworks/$cef"

# copy_deps <binary>: copies the @rpath dylibs it needs, and theirs, into Frameworks
copy_deps() {
    local dep leaf src dir
    for dep in $(otool -L "$1" | tail -n +2 | awk '{print $1}' | grep '^@rpath/' || true); do
        leaf="${dep#@rpath/}"
        case "$leaf" in *.framework/*) continue ;; esac
        [ -e "$frameworks/$leaf" ] && continue
        src=""
        for dir in "$prefix/lib" "$vulkan/lib"; do
            if [ -e "$dir/$leaf" ]; then src="$dir/$leaf"; break; fi
        done
        [ -n "$src" ] || { echo "cannot find $dep, needed by $1" >&2; exit 1; }
        cp -L "$src" "$frameworks/$leaf"
        chmod 644 "$frameworks/$leaf"
        echo "  $leaf"
        copy_deps "$frameworks/$leaf"
    done
}
log "libraries"
copy_deps "$contents/MacOS/casparcg"

if [ -n "$scanner" ]; then
    [ -x "$scanner" ] || { echo "no media scanner at $scanner" >&2; exit 1; }
    log "media scanner, ffmpeg and ffprobe in Contents/Helpers"
    mkdir -p "$contents/Helpers"
    cp "$scanner" "$contents/Helpers/media-scanner"
    for tool in ffmpeg ffprobe; do
        cp "$prefix/bin/$tool" "$contents/Helpers/$tool"
        chmod 755 "$contents/Helpers/$tool"
        # Only the app's own libraries: the prefix's rpaths would point outside it.
        # "path <rpath> (offset 12)", spaces in the rpath included.
        otool -l "$contents/Helpers/$tool" |
            awk '/cmd LC_RPATH/ {getline; getline; sub(/^ *path /, ""); sub(/ \(offset [0-9]+\)$/, ""); print}' |
            while IFS= read -r rpath; do
                install_name_tool -delete_rpath "$rpath" "$contents/Helpers/$tool"
            done
        install_name_tool -add_rpath "@executable_path/../Frameworks" "$contents/Helpers/$tool"
        copy_deps "$contents/Helpers/$tool"
    done
fi

# Without yadif_videotoolbox (FFmpeg built with METAL=none, see build-deps.sh) VideoToolbox decoding is
# only offered with auto-deinterlace set to none, and the default configuration decodes on the CPU. The
# prefix's ffmpeg, made to load the app's own libraries, says whether they register it.
if [ "${METAL:-}" != none ]; then
    filters="$(DYLD_LIBRARY_PATH="$frameworks" "$prefix/bin/ffmpeg" -hide_banner -filters)" ||
        { echo "the FFmpeg libraries of the app do not load" >&2; exit 1; }
    case "$filters" in
        *" yadif_videotoolbox "*) log "FFmpeg: yadif_videotoolbox" ;;
        *)
            echo "the app's libavfilter has no yadif_videotoolbox: build FFmpeg with Metal, or pass METAL=none" >&2
            exit 1
            ;;
    esac
fi

log "Vulkan: loader, KosmicKrisp, MoltenVK"
cp -L "$vulkan/lib/libvulkan.1.dylib" "$frameworks/libvulkan.1.dylib"
cp -L "$vulkan/lib/libvulkan_kosmickrisp.dylib" "$frameworks/libvulkan_kosmickrisp.dylib"
cp -L "$vulkan/lib/libMoltenVK.dylib" "$frameworks/libMoltenVK.dylib"
chmod 644 "$frameworks"/libvulkan*.dylib "$frameworks/libMoltenVK.dylib"
# library_path is relative to the manifest: Resources/vulkan/icd.d -> Contents/Frameworks
cat > "$resources/vulkan/icd.d/kosmickrisp_icd.json" <<'EOF'
{
    "file_format_version": "1.0.0",
    "ICD": {
        "library_path": "../../../Frameworks/libvulkan_kosmickrisp.dylib",
        "api_version": "1.4.0"
    }
}
EOF
cat > "$resources/vulkan/icd.d/MoltenVK_icd.json" <<'EOF'
{
    "file_format_version": "1.0.0",
    "ICD": {
        "library_path": "../../../Frameworks/libMoltenVK.dylib",
        "api_version": "1.4.0",
        "is_portability_driver": true
    }
}
EOF

if [ -n "$ndi" ]; then
    log "NDI: $ndi"
    cp -L "$ndi" "$frameworks/libndi.dylib"
    chmod 644 "$frameworks/libndi.dylib"
fi

# CEF wants one helper app per process type. Each is a copy of the server, which hands its
# command line to CEF (intercept_command_line_args), so the renderers get CasparCG's own
# CefApp. From Contents/Frameworks/<helper>.app/Contents/MacOS, Contents/Frameworks is ../../..
log "CEF helper apps"
for variant in "" " (GPU)" " (Renderer)" " (Plugin)" " (Alerts)"; do
    helper="$name Helper$variant"
    suffix="$(echo "$variant" | tr -d ' ()' | tr '[:upper:]' '[:lower:]')"
    dir="$frameworks/$helper.app/Contents"
    mkdir -p "$dir/MacOS"
    cp "$contents/MacOS/casparcg" "$dir/MacOS/$helper"
    install_name_tool \
        -change "@executable_path/../Frameworks/$cef/Chromium Embedded Framework" \
                "@executable_path/../../../$cef/Chromium Embedded Framework" \
        -rpath "@executable_path/../Frameworks" "@executable_path/../../.." \
        "$dir/MacOS/$helper"
    cat > "$dir/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>$helper</string>
    <key>CFBundleIdentifier</key>
    <string>$bundle_id.helper${suffix:+.$suffix}</string>
    <key>CFBundleName</key>
    <string>$helper</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$version</string>
    <key>CFBundleVersion</key>
    <string>$version</string>
    <key>LSMinimumSystemVersion</key>
    <string>$min_macos</string>
    <key>LSUIElement</key>
    <true/>
    <key>LSFileQuarantineEnabled</key>
    <true/>
</dict>
</plist>
EOF
    echo "  $helper.app"
done

log "resources"
cp "$root/src/shell/casparcg.config" "$resources/casparcg.config"
cp "$root/LICENSE" "$resources/LICENSE"
bash "$here/third-party-notices.sh" "$work" "$resources/THIRD-PARTY-NOTICES.txt" "$build"
# The Mac port's own icon (three layers and a play sign) when it is there; the upstream one otherwise. The file in
# the app keeps the name CasparCG.icns, which Info.plist points to.
if [ -f "$root/tools/macos/CasparCG-Mac.icns" ]; then
    cp "$root/tools/macos/CasparCG-Mac.icns" "$resources/CasparCG.icns"
elif [ -f "$root/tools/macos/CasparCG.icns" ]; then
    cp "$root/tools/macos/CasparCG.icns" "$resources/CasparCG.icns"
fi

cat > "$contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleExecutable</key>
    <string>casparcg</string>
    <key>CFBundleIdentifier</key>
    <string>$bundle_id</string>
    <key>CFBundleName</key>
    <string>$name</string>
    <key>CFBundleDisplayName</key>
    <string>$name</string>
    <key>CFBundleIconFile</key>
    <string>CasparCG</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$version</string>
    <key>CFBundleVersion</key>
    <string>$version.$revision</string>
    <key>LSMinimumSystemVersion</key>
    <string>$min_macos</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.video</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHumanReadableCopyright</key>
    <string>CasparCG Server, GNU General Public License v3</string>
    <key>NSLocalNetworkUsageDescription</key>
    <string>CasparCG Server sends and receives NDI video and talks to control clients on the local network.</string>
    <key>NSBonjourServices</key>
    <array>
        <string>_ndi._tcp</string>
    </array>
    <key>NSCameraUsageDescription</key>
    <string>CasparCG Server can play the live picture of a camera or capture device.</string>
    <key>NSMicrophoneUsageDescription</key>
    <string>CasparCG Server can play the live sound of an audio or capture device.</string>
    <key>NSDocumentsFolderUsageDescription</key>
    <string>CasparCG Server plays and records media, templates and data in the folders its configuration names.</string>
    <key>NSDesktopFolderUsageDescription</key>
    <string>CasparCG Server plays and records media, templates and data in the folders its configuration names.</string>
    <key>NSDownloadsFolderUsageDescription</key>
    <string>CasparCG Server plays and records media, templates and data in the folders its configuration names.</string>
    <key>NSRemovableVolumesUsageDescription</key>
    <string>CasparCG Server plays and records media on the drives its configuration names.</string>
    <key>NSNetworkVolumesUsageDescription</key>
    <string>CasparCG Server plays and records media on the network shares its configuration names.</string>
</dict>
</plist>
EOF

# Inside out: libraries, CEF, helpers, then the app, which seals all of them.
log "signing ($identity)"
sign_args=(--force --sign "$identity")
if [ "$identity" = "-" ]; then
    sign_args+=(--timestamp=none)
else
    sign_args+=(--timestamp --options runtime --entitlements "$here/entitlements.plist")
fi
find "$frameworks" -maxdepth 1 -name '*.dylib' -type f -print0 | xargs -0 codesign "${sign_args[@]}"
find "$frameworks/$cef" -name '*.dylib' -type f -print0 | xargs -0 codesign "${sign_args[@]}"
codesign "${sign_args[@]}" "$frameworks/$cef"
for helper in "$frameworks/$name Helper"*.app; do
    codesign "${sign_args[@]}" "$helper"
done
# The executables in Contents/Helpers get the hardened runtime, not the app's entitlements: they need none.
if [ -d "$contents/Helpers" ]; then
    tool_args=("${sign_args[@]}")
    [ "$identity" = "-" ] || tool_args=(--force --sign "$identity" --timestamp --options runtime)
    find "$contents/Helpers" -type f -perm -u+x -print0 | xargs -0 codesign "${tool_args[@]}"
fi
codesign "${sign_args[@]}" "$app"
codesign --verify --deep --strict "$app"
log "signature verified"

if [ "$make_dmg" = 1 ]; then
    dmg="$out/CasparCG-Server-$version-macos-arm64.dmg"
    stage="$out/dmg-stage"
    log "DMG: $dmg"
    rm -rf "$stage" "$dmg"
    mkdir -p "$stage"
    ditto "$app" "$stage/$name.app"
    ln -s /Applications "$stage/Applications"
    hdiutil create -quiet -volname "$name $version" -srcfolder "$stage" -ov -format UDZO "$dmg"
    rm -rf "$stage"
fi

log "done: $(du -sh "$app" | cut -f1) $app"
