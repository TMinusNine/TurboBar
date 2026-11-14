#!/bin/sh
# Builds TurboBar.app next to this script.
set -eu
cd "$(dirname "$0")"

APP=TurboBar.app
BIN="$APP/Contents/MacOS"
rm -rf "$APP"
mkdir -p "$BIN"
cp Info.plist "$APP/Contents/"

CFLAGS="-O2 -mmacosx-version-min=13.0 -Wall -Wextra -Wl,-dead_strip"

clang $CFLAGS -fobjc-arc -framework AppKit -framework IOKit -o "$BIN/TurboBar" main.m MenuPanel.m
clang $CFLAGS -framework IOKit -framework CoreFoundation -o "$BIN/turbofan" turbofan.c
strip -x "$BIN/TurboBar" "$BIN/turbofan"

# The helper is signed first because the app's signature covers it.
codesign --force --sign - "$BIN/turbofan"
codesign --force --sign - "$APP"

echo "Built $(pwd)/$APP"
