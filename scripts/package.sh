#!/bin/bash
# Builds a universal app and zips it for a GitHub release: build/NotificationLab-<version>.zip
set -euo pipefail
cd "$(dirname "$0")/.."
./build.sh --universal
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" Support/Info.plist)
ZIP="build/NotificationLab-$VERSION.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "build/Notification Lab.app" "$ZIP"
shasum -a 256 "$ZIP"
