# Security policy

WebcamBright is a menu bar app that runs as your user, never as root. It records nothing and sends nothing about you or the camera anywhere. It reads camera frames only while another app has the camera on, measures the brightness of your face in memory, and changes the camera's own controls over USB.

Its only network access is the update check: an HTTPS request to GitHub's API for the latest release of this repository, 15 seconds after launch and then every 6 hours, and downloads from GitHub when there is an update. An update is installed only if `SHA256SUMS.sig` verifies against the Ed25519 public key built into the app and the download matches its checksum, bundle identifier and version. See [docs/RELEASING.md](docs/RELEASING.md).

## Reporting

Please report vulnerabilities privately via [GitHub security advisories](https://github.com/estevecastells/webcam-bright/security/advisories/new), not public issues.

## What it touches

- **Camera access**, which you grant in System Settings → Privacy & Security → Camera.
- **The camera's UVC controls** (auto exposure mode, exposure, gain, brightness, contrast, saturation, anti-flicker, backlight compensation), through IOKit. When WebcamBright is paused, turned off or quit, it sets them back to the camera's defaults and turns the camera's own auto exposure back on; anti-flicker stays as you set it. `build/uvcctl reset` restores every factory value.
- **The app bundle itself**, replaced in place when an update installs.
- **A Login Items entry**, which you can turn off from the menu or in System Settings → General → Login Items.
- **Its preferences** (`io.github.estevecastells.webcam-bright`) and its log, `~/Library/Logs/webcam-bright.log` (emptied above 1 MB).
