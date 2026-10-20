#!/bin/sh
# Builds build/MaitreDAgent.app (release, ad-hoc signed for this Mac).
set -eu
cd "$(dirname "$0")/.."

swift build -c release

APP="build/MaitreDAgent.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/MaitreDAgent "$APP/Contents/MacOS/MaitreDAgent"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Resources/en.lproj "$APP/Contents/Resources/"

if [ ! -f build/AppIcon.icns ]; then
    rm -rf build/AppIcon.iconset
    swift scripts/make-icon.swift build/AppIcon.iconset
    iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

codesign --force --sign - "$APP"
echo "Built $APP"
