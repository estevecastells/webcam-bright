#!/bin/bash
# Builds the release artifacts into dist/:
#   WebcamBright-macos-arm64.zip   the menu bar app, with uvcctl inside
#   SHA256SUMS                     checksums (CI signs them into SHA256SUMS.sig for the in-app updater)
#
# Asset names carry no version so that .../releases/latest/download/<name> always works.
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

export MACOSX_DEPLOYMENT_TARGET=14.0
scripts/build-app.sh

rm -rf dist
mkdir -p dist
ditto -c -k --sequesterRsrc --keepParent build/WebcamBright.app dist/WebcamBright-macos-arm64.zip
(cd dist && shasum -a 256 WebcamBright-macos-arm64.zip > SHA256SUMS)

echo "==> Release artifacts (v$(tr -d '[:space:]' < VERSION)):"
ls -la dist
cat dist/SHA256SUMS
