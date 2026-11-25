#!/bin/bash
# Installs build/WebcamBright.app into /Applications (or ~/Applications when /Applications isn't
# writable) and opens it. The app adds itself to Login Items the first time it runs.
#
#   scripts/install.sh             install (run scripts/build-app.sh first) and open
#   scripts/install.sh uninstall   quit and remove the app and its login item
#
# Settings stay in the app's preferences (io.github.estevecastells.webcam-bright) and the log in
# ~/Library/Logs/webcam-bright.log.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
id="io.github.estevecastells.webcam-bright"
built="$root/build/WebcamBright.app"
agents="$HOME/Library/LaunchAgents"

say() { printf '\033[1m==> %s\033[0m\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

installed() {
  for dir in /Applications "$HOME/Applications"; do
    [[ -d "$dir/WebcamBright.app" ]] && echo "$dir/WebcamBright.app"
  done
  return 0
}

# Quit the running app the normal way, so it hands the camera back to its own auto exposure.
quit_app() {
  pgrep -x WebcamBright >/dev/null || return 0
  osascript -e "quit app id \"$id\"" >/dev/null 2>&1 || true
  for _ in {1..20}; do pgrep -x WebcamBright >/dev/null || return 0; sleep 0.25; done
  pkill -x WebcamBright || true
}

# Before the menu bar app, WebcamBright was a LaunchAgent with this same label: remove it.
remove_old_agent() {
  if [[ -f "$agents/$id.plist" ]]; then
    say "Removing the old background helper ($id)"
    launchctl bootout "gui/$UID/$id" 2>/dev/null || true
    rm -f "$agents/$id.plist"
  fi
}

if [[ "${1:-}" == uninstall ]]; then
  quit_app
  remove_old_agent
  while IFS= read -r app; do
    [[ -n "$app" ]] || continue
    "$app/Contents/MacOS/WebcamBright" --remove-login-item || true
    rm -rf "$app"
    # A later install opens at login again, like a first install.
    defaults delete "$id" loginItemConfigured 2>/dev/null || true
    say "Removed $app"
  done < <(installed)
  exit 0
fi

[[ -d "$built" ]] || die "build the app first: scripts/build-app.sh (or make install)"

# Any other helper that runs a webcam-bright program would fight this one over the camera.
for plist in "$agents"/*.plist; do
  [[ -e "$plist" && "$plist" != "$agents/$id.plist" ]] || continue
  if grep -q -i "webcam-bright" "$plist"; then
    label="$(basename "$plist" .plist)"
    die "another WebcamBright helper is installed ($plist). Remove it first, or the two would fight over the camera:
  launchctl bootout gui/$UID/$label && rm $plist"
  fi
done

remove_old_agent
quit_app

dest="/Applications"
[[ -w "$dest" ]] || dest="$HOME/Applications"
mkdir -p "$dest"
while IFS= read -r app; do
  [[ -n "$app" && "$app" != "$dest/WebcamBright.app" ]] && rm -rf "$app"
done < <(installed)
say "Installing to $dest"
rm -rf "$dest/WebcamBright.app"
ditto "$built" "$dest/WebcamBright.app"
open "$dest/WebcamBright.app"
say "Done. WebcamBright is in the menu bar. The first time, allow camera access when macOS asks."
