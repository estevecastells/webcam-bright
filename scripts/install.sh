#!/bin/zsh
# Builds WebcamBright and (re)installs it as a LaunchAgent that starts at login.
#
#   scripts/install.sh             build + install + start
#   scripts/install.sh build       build only: build/WebcamBright.app and build/uvcctl
#   scripts/install.sh uninstall   stop and remove the LaunchAgent
#
# The LaunchAgent runs the app from build/ in this folder, so uninstall before you move or
# delete the folder. A rebuild changes the app's ad-hoc signature, so macOS may ask for camera
# access again. Settings (target brightness, camera name...) are at the top of src/main.swift.

set -euo pipefail
ROOT="${0:A:h:h}"
SRC="$ROOT/src"
OUT="$ROOT/build"
APP="$OUT/WebcamBright.app"
LABEL=io.github.estevecastells.webcam-bright
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

if [[ "${1:-}" == uninstall ]]; then
  launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
  rm -f "$PLIST"
  echo "Stopped and removed $LABEL. Delete $ROOT to remove the files too."
  exit 0
fi

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$APP/Contents/MacOS"
clang -O2 -Wall -c "$SRC/uvc.c" -o "$TMP/uvc.o"
clang -O2 -Wall "$SRC/uvcctl.c" "$TMP/uvc.o" -framework IOKit -framework CoreFoundation -o "$OUT/uvcctl"
cp "$SRC/Info.plist" "$APP/Contents/Info.plist"
swiftc -O -import-objc-header "$SRC/uvc.h" "$SRC/main.swift" "$TMP/uvc.o" \
  -framework IOKit -o "$APP/Contents/MacOS/webcam-bright"
codesign --force --sign - "$APP"
echo "Built $APP and $OUT/uvcctl"
[[ "${1:-}" == build ]] && exit 0

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>$APP/Contents/MacOS/webcam-bright</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <true/>
    <key>ThrottleInterval</key>
    <integer>30</integer>
    <key>StandardErrorPath</key>
    <string>$HOME/Library/Logs/webcam-bright.err.log</string>
</dict>
</plist>
EOF

# bootout returns before the old process is gone; bootstrap fails (error 5) until it is.
launchctl bootout "gui/$UID/$LABEL" 2>/dev/null || true
for i in {1..20}; do launchctl print "gui/$UID/$LABEL" >/dev/null 2>&1 || break; sleep 0.5; done
for i in {1..5}; do launchctl bootstrap "gui/$UID" "$PLIST" 2>/dev/null && break; sleep 1; done
launchctl print "gui/$UID/$LABEL" >/dev/null 2>&1 || { echo "Could not start $LABEL" >&2; exit 1; }
echo "Installed and started $LABEL. Log: ~/Library/Logs/webcam-bright.log"
