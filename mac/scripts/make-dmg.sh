#!/bin/bash
set -euo pipefail

app=${1:?Usage: make-dmg.sh APP DIST}
dist=${2:?Usage: make-dmg.sh APP DIST}
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
mkdir -p "$dist"
staging=$(mktemp -d)
trap 'rm -rf "$staging"' EXIT
ditto "$app" "$staging/FeishuChat.app"
ln -s /Applications "$staging/Applications"
hdiutil create -volname FeishuChat -srcfolder "$staging" -ov -format UDZO "$dist/FeishuChat-$version.dmg"
