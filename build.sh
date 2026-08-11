#!/usr/bin/env bash
# Compiles SessionTracker.swift into a menu bar .app bundle and installs it.
# Usage: ./build.sh [install-dir]   (default: ~/Applications)
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="SessionTracker"
INSTALL_DIR="${1:-$HOME/Applications}"
BUNDLE="build/$APP_NAME.app"

rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
cp Info.plist "$BUNDLE/Contents/Info.plist"

echo "Compiling..."
swiftc -O -o "$BUNDLE/Contents/MacOS/$APP_NAME" "$APP_NAME.swift"

# Ad-hoc signature keeps the bundle identity stable across rebuilds.
codesign --force --sign - "$BUNDLE" 2>/dev/null || echo "warning: ad-hoc signing failed, continuing"

mkdir -p "$INSTALL_DIR"
rm -rf "${INSTALL_DIR:?}/$APP_NAME.app"
cp -R "$BUNDLE" "$INSTALL_DIR/"

echo "Installed to $INSTALL_DIR/$APP_NAME.app"
echo "Launch:  open \"$INSTALL_DIR/$APP_NAME.app\""
