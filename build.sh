#!/bin/sh
# Build lzScope CLAP plugin on macOS, run the smoke tests and install the
# .clap bundle. Uses lazbuild (validates the .lpi files) with a plain-fpc
# fallback.
#
# Toolchain lookup: $LAZBUILD / $FPC if set, then PATH. A Lazarus that is
# not on PATH, e.g. in your shell profile:
#   export LAZBUILD="$HOME/lazarus/lazbuild"

set -eu
cd "$(dirname "$0")"

FPC=${FPC:-$(command -v fpc || true)}
LAZBUILD=${LAZBUILD:-$(command -v lazbuild || true)}

if [ -z "$LAZBUILD" ] && [ -z "$FPC" ]; then
    echo 'Neither lazbuild nor fpc found. Install Free Pascal (brew install fpc) or set LAZBUILD / FPC.' >&2
    exit 1
fi

# build_project <lpi> <lpr> <unit dirs...>
build_project() {
    lpi=$1; lpr=$2; shift 2
    if [ -n "$LAZBUILD" ]; then
        "$LAZBUILD" ${FPC:+--compiler="$FPC"} --build-mode= "$lpi"
    else
        out="$(dirname "$lpr")/lib/$(uname -m)-darwin"
        mkdir -p "$out"
        fu=''
        for d in "$@"; do fu="$fu -Fu$d"; done
        # shellcheck disable=SC2086  # paths without spaces
        "$FPC" -B -O2 -CX -XX -Xs "-FU$out" $fu "$lpr"
    fi
}

build_project lzscope.lpi lzscope.lpr src/clap src/dsp src/gui src/plugin
build_project tests/testhost.lpi tests/testhost.lpr src/clap src/dsp

if ! ./tests/testhost; then
    echo 'tests failed, not installing'
    exit 1
fi

# lzScope.clap/Contents/{Info.plist, MacOS/lzScope}
version=$(sed -n "s/.*PLUGIN_VERSION *= *'\(.*\)';.*/\1/p" src/dsp/scope_state.pas)
bundle=lzScope.clap
rm -rf "$bundle"
mkdir -p "$bundle/Contents/MacOS"
cp liblzscope.dylib "$bundle/Contents/MacOS/lzScope"
cat > "$bundle/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>  <string>en</string>
  <key>CFBundleExecutable</key>         <string>lzScope</string>
  <key>CFBundleIdentifier</key>         <string>com.dsgdnb.lzscope</string>
  <key>CFBundleInfoDictionaryVersion</key> <string>6.0</string>
  <key>CFBundleName</key>               <string>lzScope</string>
  <key>CFBundlePackageType</key>        <string>BNDL</string>
  <key>CFBundleShortVersionString</key> <string>$version</string>
  <key>CFBundleVersion</key>            <string>$version</string>
  <key>CFBundleSignature</key>          <string>????</string>
</dict>
</plist>
EOF
# ad-hoc: enough to load on this Mac; other Macs need a Developer ID
codesign --force --sign - "$bundle"

dst="$HOME/Library/Audio/Plug-Ins/CLAP"
mkdir -p "$dst"
rm -rf "$dst/$bundle"
cp -R "$bundle" "$dst/"
echo "installed -> $dst/$bundle"
