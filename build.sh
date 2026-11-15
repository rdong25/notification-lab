#!/bin/bash
# Builds "Notification Lab.app" into ./build and ad-hoc signs it.
#   ./build.sh               native architecture
#   ./build.sh --universal   Apple Silicon + Intel
#   ./build.sh --open        build, then launch
set -euo pipefail
cd "$(dirname "$0")"

ARCH_FLAGS=()
OPEN=0
for arg in "$@"; do
  case "$arg" in
    --universal) ARCH_FLAGS=(--arch arm64 --arch x86_64) ;;
    --open) OPEN=1 ;;
  esac
done

APP="build/Notification Lab.app"
swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c release ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

# Icon (generated once)
if [ ! -f build/AppIcon.icns ]; then
  mkdir -p build/AppIcon.iconset
  swift scripts/make_icon.swift build/icon_1024.png
  for s in 16 32 128 256 512; do
    sips -z $s $s build/icon_1024.png --out build/AppIcon.iconset/icon_${s}x${s}.png >/dev/null
    sips -z $((s*2)) $((s*2)) build/icon_1024.png --out build/AppIcon.iconset/icon_${s}x${s}@2x.png >/dev/null
  done
  iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN_DIR/NotificationLab" "$APP/Contents/MacOS/"
cp "$BIN_DIR/notiflab" "$APP/Contents/Helpers/"
cp Support/Info.plist "$APP/Contents/"
cp build/AppIcon.icns "$APP/Contents/Resources/"
# Sign the nested CLI first, then the app (which seals it).
codesign --force --sign - "$APP/Contents/Helpers/notiflab" >/dev/null
codesign --force --sign - "$APP" >/dev/null
echo "Built $APP ($(lipo -archs "$APP/Contents/MacOS/NotificationLab"))"

if [ "$OPEN" = 1 ]; then open "$APP"; fi
