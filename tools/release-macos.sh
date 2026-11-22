#!/bin/sh
# macOS release: the universal bundle from build.sh, signed with a Developer
# ID, notarized and stapled, zipped for the GitHub release into
# dist/lzScope-CLAP-<version>-macos.zip. Also replaces the ad-hoc signed copy
# build.sh installed.
#
#   tools/release-macos.sh
#
# SIGN_IDENTITY   codesign identity; default: the first "Developer ID
#                 Application" one in the keychain
# NOTARY_PROFILE  notarytool keychain profile, made once with
#                 `xcrun notarytool store-credentials`; default "notary"

set -eu
cd "$(dirname "$0")/.."

NOTARY_PROFILE=${NOTARY_PROFILE:-notary}
SIGN_IDENTITY=${SIGN_IDENTITY:-$(security find-identity -v -p codesigning |
    sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)}
if [ -z "$SIGN_IDENTITY" ]; then
    echo 'No "Developer ID Application" identity in the keychain; set SIGN_IDENTITY.' >&2
    exit 1
fi

./build.sh

bundle=lzScope.clap
binary="$bundle/Contents/MacOS/lzScope"
archs=$(lipo -archs "$binary")
case "$archs" in
    *x86_64*arm64*|*arm64*x86_64*) ;;
    *)  echo "$binary is $archs only; run tools/setup-x86_64.sh for a universal build" >&2
        exit 1 ;;
esac

echo "signing with $SIGN_IDENTITY"
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$bundle"
codesign --verify --strict --verbose=2 "$bundle"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

echo 'notarizing (usually a few minutes)'
ditto -c -k --keepParent "$bundle" "$WORK/notarize.zip"
xcrun notarytool submit "$WORK/notarize.zip" --keychain-profile "$NOTARY_PROFILE" \
    --wait --output-format plist > "$WORK/result.plist"
status=$(plutil -extract status raw "$WORK/result.plist")
if [ "$status" != Accepted ]; then
    id=$(plutil -extract id raw "$WORK/result.plist")
    echo "notarization: $status" >&2
    xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2
    exit 1
fi

# the ticket travels with the bundle: no online check on first load
xcrun stapler staple "$bundle"
xcrun stapler validate "$bundle"

version=$(sed -n "s/.*PLUGIN_VERSION *= *'\(.*\)';.*/\1/p" src/dsp/scope_state.pas)
mkdir -p dist
zip="dist/lzScope-CLAP-$version-macos.zip"
rm -f "$zip"
ditto -c -k --keepParent "$bundle" "$zip"

dst="$HOME/Library/Audio/Plug-Ins/CLAP"
rm -rf "$dst/$bundle"
cp -R "$bundle" "$dst/"

echo "release -> $zip"
