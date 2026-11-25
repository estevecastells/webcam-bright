#!/bin/bash
# Builds the menu bar app and the uvcctl tool with the Command Line Tools alone (no Xcode project).
#
#   scripts/build-app.sh   → build/WebcamBright.app (uvcctl inside) and build/uvcctl
#
# Signed with WEBCAMBRIGHT_SIGN_IDENTITY, else "WebcamBright Release Signing" (the identity releases
# are signed with, docs/RELEASING.md), else "WebcamBright Local Signing" (scripts/make-signing-cert.sh),
# else ad hoc. macOS ties camera access to the signature: a stable identity keeps it across rebuilds
# and updates, while an ad-hoc signature changes with every build, so macOS may ask again.
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
cp "$bin/uvcctl" "$app/Contents/Resources/uvcctl"

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

identity="${WEBCAMBRIGHT_SIGN_IDENTITY:-}"
if [[ -z "$identity" ]]; then
  identity="-"
  for candidate in "WebcamBright Release Signing" "WebcamBright Local Signing"; do
    if security find-certificate -c "$candidate" >/dev/null 2>&1; then identity="$candidate"; break; fi
  done
fi
# Hardened runtime: other processes can't inject code to borrow the app's camera permission.
codesign --force --options runtime --sign "$identity" "$app/Contents/Resources/uvcctl" >/dev/null
codesign --force --options runtime --entitlements app/WebcamBright.entitlements --sign "$identity" "$app" >/dev/null
cp "$app/Contents/Resources/uvcctl" build/uvcctl
echo "==> Done: $root/$app and $root/build/uvcctl (signed: $identity)"
