#!/bin/sh
# One-time setup on an Apple Silicon Mac: builds the x86_64-darwin cross
# compiler and the units lzScope needs (RTL, univint, cocoaint) from the
# Free Pascal sources, so build.sh can make a universal binary.
#
#   tools/setup-x86_64.sh [fpc-source-dir]
#
# fpc-source-dir: sources of the same FPC version as the installed fpc.
# Without it, the usual places are searched: a Lazarus install (which ships
# them), Homebrew's fpc-src, /usr/local/share/fpcsrc. Installs into
# $X64_ROOT (default ~/.fpc/x86_64-darwin).

set -eu

FPC=${FPC:-$(command -v fpc || true)}
X64_ROOT=${X64_ROOT:-$HOME/.fpc/x86_64-darwin}

if [ -z "$FPC" ]; then
    echo 'fpc not found: brew install fpc' >&2
    exit 1
fi
VERSION=$("$FPC" -iV)

is_src() { [ -d "$1/compiler" ] && [ -d "$1/rtl" ] && [ -d "$1/packages/cocoaint" ]; }

if [ $# -ge 1 ]; then
    SRC=$1
else
    SRC=''
    for d in \
        "$HOME/lazarus/fpc/$VERSION/sources" \
        "/Applications/Lazarus/fpc/$VERSION/sources" \
        "/Applications/lazarus/fpc/$VERSION/sources" \
        "/usr/local/share/fpcsrc/$VERSION" \
        "/usr/local/share/fpcsrc" \
        "$(brew --prefix 2>/dev/null || echo /opt/homebrew)/share/fpcsrc"; do
        if is_src "$d"; then SRC=$d; break; fi
    done
fi
if [ -z "$SRC" ] || ! is_src "$SRC"; then
    echo "FPC $VERSION sources not found${SRC:+ in $SRC}; pass their directory:" >&2
    echo "  $0 /path/to/fpc-$VERSION-sources" >&2
    exit 1
fi
echo "FPC $VERSION, sources: $SRC"
HOST_PP=$("$FPC" -PB)
SDK=$(xcrun --show-sdk-path)

# the build writes into the tree: work on a copy
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
echo "copying sources to $WORK"
cp -R "$SRC" "$WORK/src"
cd "$WORK/src"

# The ARM host has no 80-bit float: the compiler must emulate x86's
# extended type, or it fails on the RTL's float constants.
echo 'building ppcx64'
mkdir -p "$WORK/softfpu"
"$HOST_PP" -O2 -Fi"$WORK/src/rtl/inc" -FU"$WORK/softfpu" rtl/inc/sfpux80.pp >/dev/null
make -C compiler x86_64 PP="$HOST_PP" \
    OPT="-XR$SDK -dFPC_SOFT_FPUX80 -Fu$WORK/softfpu" >/dev/null
PPC="$WORK/src/compiler/ppcx64"

echo 'building the RTL'
make -C rtl all CPU_TARGET=x86_64 OS_TARGET=darwin PP="$PPC" FPC="$PPC" OPT=-n >/dev/null

rtl="$X64_ROOT/units/rtl"
pkg="$X64_ROOT/units/packages"
rm -rf "$X64_ROOT"
mkdir -p "$X64_ROOT/bin" "$rtl" "$pkg"
cp "$PPC" "$X64_ROOT/bin/ppcx64"
cp rtl/units/x86_64-darwin/* "$rtl/"

# options from the packages' fpmake.pp
echo 'building univint'
(cd packages/univint/src &&
    "$PPC" -n -Tdarwin -Px86_64 -O2 -Mmacpas "-Fu$rtl" "-FU$pkg" MacOSAll.pas >/dev/null)
echo 'building cocoaint'
(cd packages/cocoaint/src &&
    "$PPC" -n -Tdarwin -Px86_64 -O2 -dMACOSALL -dCOCOAALL -dLEGACY_SETNEEDSDISPLAY \
        "-Fu$rtl" "-Fu$pkg" "-FU$pkg" CocoaAll.pas >/dev/null)

echo "installed -> $X64_ROOT"
