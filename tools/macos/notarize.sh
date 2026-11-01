#!/usr/bin/env bash
#
# Signs an already built "CasparCG Server.app" with a Developer ID, notarizes it and staples the ticket, then does the
# same for a DMG that carries it. Runs on the Mac that holds the identity in its keychain; the app can come from another
# Mac (package.sh signs ad hoc).
#
#   tools/macos/notarize.sh <app> <out-dir> <identity> <notarytool-profile>
#
#   <identity>            e.g. "Developer ID Application: Name (TEAMID)" (security find-identity -v -p codesigning)
#   <notarytool-profile>  a keychain profile made once with
#                         xcrun notarytool store-credentials <profile> --apple-id <id> --team-id <TEAMID>
#                         or "asc": the App Store Connect API key in ~/.appstoreconnect (config.env with ASC_KEY_ID
#                         and ASC_ISSUER_ID, the .p8 in private_keys/), never printed
#
# Run it in the foreground: notarytool started in the background has been seen to exit at once, saying nothing.
#
# Two rounds, so that the app is stapled too and opens offline after being copied out of the DMG: the app in a zip,
# notarized and stapled; then the DMG with the stapled app, signed, notarized and stapled.
#
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(cd "$here/../.." && pwd)"
source_app="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
out="$(mkdir -p "$2" && cd "$2" && pwd)"
identity="$3"
profile="$4"

name="CasparCG Server"
version_part() { sed -n "s/^set(CONFIG_VERSION_$1 \\([0-9]*\\)).*/\\1/p" "$root/src/CMakeLists.txt" | head -1; }
version="$(version_part MAJOR).$(version_part MINOR).$(version_part BUG)"
log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*"; }

if [ "$profile" = asc ]; then
    [ -f ~/.appstoreconnect/config.env ] || { echo "no ~/.appstoreconnect/config.env" >&2; exit 1; }
    # shellcheck disable=SC1090
    source ~/.appstoreconnect/config.env
    key=~/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8
    [ -f "$key" ] || { echo "no key file in ~/.appstoreconnect/private_keys" >&2; exit 1; }
    auth=(--key "$key" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
else
    auth=(--keychain-profile "$profile")
fi

app="$out/$name.app"
frameworks="$app/Contents/Frameworks"
cef="Chromium Embedded Framework.framework"
[ -e "$app" ] && { echo "$app is there already: move it away first" >&2; exit 1; }
log "copy of $source_app"
ditto "$source_app" "$app"

# The same order as package.sh: the libraries, CEF's libraries and the framework, the helper apps, the app.
sign_args=(--force --sign "$identity" --timestamp --options runtime --entitlements "$here/entitlements.plist")
log "signing with $identity"
find "$frameworks" -maxdepth 1 -name '*.dylib' -type f -print0 | xargs -0 codesign "${sign_args[@]}"
find "$frameworks/$cef" -name '*.dylib' -type f -print0 | xargs -0 codesign "${sign_args[@]}"
codesign "${sign_args[@]}" "$frameworks/$cef"
for helper in "$frameworks/$name Helper"*.app; do
    codesign "${sign_args[@]}" "$helper"
done
# Any other executable the app carries (the media scanner, ffmpeg and ffprobe in Contents/Helpers, when there are
# some): the hardened runtime, without the app's entitlements, which they do not need.
if [ -d "$app/Contents/Helpers" ]; then
    find "$app/Contents/Helpers" -type f -perm -u+x -print0 |
        xargs -0 codesign --force --sign "$identity" --timestamp --options runtime
fi
codesign "${sign_args[@]}" "$app"
codesign --verify --deep --strict "$app"
log "signature verified"

submit() {
    local file="$1" result id
    log "notarization of $(basename "$file") (it takes a few minutes)"
    result="$(xcrun notarytool submit "$file" "${auth[@]}" --wait --output-format json || true)"
    echo "$result"
    id="$(printf '%s' "$result" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("id",""))')"
    if ! printf '%s' "$result" | grep -q '"status" *: *"Accepted"'; then
        [ -n "$id" ] && xcrun notarytool log "$id" "${auth[@]}" || true
        echo "notarization of $file not accepted" >&2
        exit 1
    fi
}

zip="$out/$name.zip"
ditto -c -k --keepParent "$app" "$zip"
submit "$zip"
rm -f "$zip"
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute -vv "$app"

dmg="$out/CasparCG-Server-$version-macos-arm64.dmg"
stage="$out/dmg-stage"
rm -rf "$stage" "$dmg"
mkdir -p "$stage"
ditto "$app" "$stage/$name.app"
ln -s /Applications "$stage/Applications"
hdiutil create -quiet -volname "$name $version" -srcfolder "$stage" -ov -format UDZO "$dmg"
rm -rf "$stage"
codesign --force --sign "$identity" --timestamp "$dmg"
submit "$dmg"
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
spctl --assess --type open --context context:primary-signature -vv "$dmg"
log "done: $app and $dmg, signed, notarized and stapled"
