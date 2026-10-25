#!/bin/sh
# Downloads StikJIT 1.9.0 (MPL-2.0, https://github.com/StikDebug/StikJIT) into
# cpp/3rdparty/StikJIT. iPSX2's built-in JIT helper (PlugIns/iPSX2JITHelper.appex) is compiled
# from its Swift sources and links its prebuilt idevice library (MIT). CMake builds the helper
# only when this folder exists; without it iPSX2 still works with StikDebug.
#
# Built from source rather than from the release XCFramework because that framework's Swift
# interface needs Xcode 27 to import; the sources build with the Xcode iPSX2 uses.
set -eu

TAG="1.9.0"
COMMIT="32287268fa5824f9edce4cb359f5833ce0cf7b00"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$ROOT/cpp/3rdparty/StikJIT"

if [ -d "$DEST/.git" ] && [ "$(git -C "$DEST" rev-parse HEAD)" = "$COMMIT" ]; then
    echo "StikJIT $TAG is already in $DEST"
    exit 0
fi

rm -rf "$DEST"
git clone --quiet --depth 1 --branch "$TAG" https://github.com/StikDebug/StikJIT.git "$DEST"
ACTUAL="$(git -C "$DEST" rev-parse HEAD)"
if [ "$ACTUAL" != "$COMMIT" ]; then
    echo "StikJIT tag $TAG points at $ACTUAL, expected $COMMIT; refusing to build with it." >&2
    rm -rf "$DEST"
    exit 1
fi
echo "StikJIT $TAG ($COMMIT) is in $DEST"
