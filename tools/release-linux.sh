#!/bin/sh
# Linux release: builds and tests with build.sh, then zips lzscope.clap for
# the GitHub release into dist/lzScope-CLAP-<version>-linux.zip.
#
#   tools/release-linux.sh
#
# The tests open X11 windows: run it in a desktop session (X11 or XWayland).
# Build on the oldest distro you support: the binary needs the glibc it was
# linked against or newer (Ubuntu 26.04: 2.34, for dlopen).

set -eu
cd "$(dirname "$0")/.."

./build.sh

version=$(sed -n "s/.*PLUGIN_VERSION *= *'\(.*\)';.*/\1/p" src/dsp/scope_state.pas)
if [ -z "$version" ]; then
    echo 'PLUGIN_VERSION not found in src/dsp/scope_state.pas' >&2
    exit 1
fi

mkdir -p dist
zip="dist/lzScope-CLAP-$version-linux.zip"
rm -f "$zip"
# keep the executable bit; zip's -X drops uid/gid and other extra fields
zip -X -q "$zip" lzscope.clap

echo "release -> $zip"
