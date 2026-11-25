#!/bin/bash
# Install or update WebcamBright from the latest GitHub release:
#
#   curl -fsSL https://raw.githubusercontent.com/estevecastells/webcam-bright/main/scripts/get.sh | bash
#
# Environment options:
#   WEBCAMBRIGHT_VERSION=v0.2.0   install a specific release (default: latest)
#   WEBCAMBRIGHT_DOWNLOAD_ONLY=1  download and verify into a temporary folder, then stop
#
# Downloads with curl don't get macOS's quarantine flag, so the app (signed, but not notarized)
# opens without a Gatekeeper prompt. The checksum is verified before anything is installed, and
# so is the build attestation when the GitHub CLI is installed and logged in.
set -euo pipefail

repo="estevecastells/webcam-bright"
asset="WebcamBright-macos-arm64.zip"
id="io.github.estevecastells.webcam-bright"
agents="$HOME/Library/LaunchAgents"

say() { printf '\033[1m==> %s\033[0m\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == Darwin ]] || die "WebcamBright only runs on macOS"
[[ "$(uname -m)" == arm64 ]] || die "release builds are for Apple silicon; on an Intel Mac, build from source (make install)"
major="$(sw_vers -productVersion | cut -d. -f1)"
(( major >= 14 )) || die "macOS 14 or later is required"

version="${WEBCAMBRIGHT_VERSION:-latest}"
if [[ "$version" == latest ]]; then
  base="https://github.com/${repo}/releases/latest/download"
else
  base="https://github.com/${repo}/releases/download/${version}"
fi

tmp="$(mktemp -d)"
[[ -n "${WEBCAMBRIGHT_DOWNLOAD_ONLY:-}" ]] || trap 'rm -rf "$tmp"' EXIT

say "Downloading WebcamBright (${version})"
for f in SHA256SUMS "$asset"; do
  curl -fsSL -o "${tmp}/${f}" "${base}/${f}" || die "download failed: ${base}/${f}"
done
(cd "$tmp" && grep " ${asset}\$" SHA256SUMS | shasum -a 256 -c -) >/dev/null || die "checksum mismatch; not installing"
say "Checksum verified"
# The checksum proves the file arrived whole; the attestation proves GitHub Actions built it from
# this repository. It needs the GitHub CLI.
if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  gh attestation verify "${tmp}/${asset}" --repo "$repo" >/dev/null \
    || die "the download's build attestation does not check out; not installing"
  say "Build attestation verified"
else
  say "Skipping the build attestation check (install and log in to the GitHub CLI to enable it)"
fi

if [[ -n "${WEBCAMBRIGHT_DOWNLOAD_ONLY:-}" ]]; then
  say "Downloaded and verified in ${tmp}"
  exit 0
fi

# Another helper running a webcam-bright program would fight this one over the camera.
for plist in "$agents"/*.plist; do
  [[ -e "$plist" && "$plist" != "$agents/$id.plist" ]] || continue
  if grep -q -i "webcam-bright" "$plist"; then
    die "another WebcamBright helper is installed ($plist). Remove it first, or the two would fight over the camera:
  launchctl bootout gui/$UID/$(basename "$plist" .plist) && rm $plist"
  fi
done
# Before the menu bar app, WebcamBright ran as a LaunchAgent with this same label.
if [[ -f "$agents/$id.plist" ]]; then
  say "Removing the old background helper ($id)"
  launchctl bootout "gui/$UID/$id" 2>/dev/null || true
  rm -f "$agents/$id.plist"
fi

# Quit a running copy the normal way, so it hands the camera back to its own auto exposure.
if pgrep -x WebcamBright >/dev/null; then
  osascript -e "quit app id \"$id\"" >/dev/null 2>&1 || true
  for _ in {1..20}; do pgrep -x WebcamBright >/dev/null || break; sleep 0.25; done
  pkill -x WebcamBright 2>/dev/null || true
fi

dest="/Applications"
[[ -w "$dest" ]] || dest="${HOME}/Applications"
mkdir -p "$dest"
say "Installing to ${dest}"
rm -rf "${dest}/WebcamBright.app"
ditto -x -k "${tmp}/${asset}" "$dest"
xattr -dr com.apple.quarantine "${dest}/WebcamBright.app" 2>/dev/null || true
open "${dest}/WebcamBright.app"
say "Done. WebcamBright is in the menu bar. The first time, allow camera access when macOS asks."
