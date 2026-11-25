#!/bin/bash
# Builds the menu bar app and the uvcctl tool with the Command Line Tools alone (no Xcode project).
#
#   scripts/build-app.sh   → build/WebcamBright.app and build/uvcctl
#
# The app is signed ad hoc. macOS ties camera access to the signature, so after a rebuild it may
# ask for camera access again.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

version="$(tr -d '[:space:]' < VERSION)"
app="build/WebcamBright.app"

echo "==> Building (release)"
(cd app && swift build -c release --product WebcamBright && swift build -c release --product uvcctl)
bin="$(cd app && swift build -c release --show-bin-path)"

echo "==> Assembling ${app}"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/WebcamBright" "$app/Contents/MacOS/WebcamBright"
cp app/Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp "$bin/uvcctl" build/uvcctl

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>io.github.estevecastells.webcam-bright</string>
  <key>CFBundleName</key><string>WebcamBright</string>
  <key>CFBundleDisplayName</key><string>WebcamBright</string>
  <key>CFBundleExecutable</key><string>WebcamBright</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleShortVersionString</key><string>${version}</string>
  <key>CFBundleVersion</key><string>${version}</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>LSAppNapIsDisabled</key><true/>
  <key>NSCameraUsageDescription</key><string>WebcamBright looks at your face while another app uses the camera, to keep the exposure right. Nothing is recorded or sent anywhere.</string>
  <key>NSHumanReadableCopyright</key><string>MIT License</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$app" >/dev/null
echo "==> Done: $root/$app and $root/build/uvcctl"
