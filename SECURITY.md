# Security policy

WebcamBright runs as your user (a launchd agent, never root). It has no network code: it sends nothing anywhere and records nothing. It reads camera frames only while another app has the camera on, measures the brightness of your face in memory, and changes the camera's own controls over USB.

## Reporting

Please report vulnerabilities privately via [GitHub security advisories](https://github.com/estevecastells/webcam-bright/security/advisories/new), not public issues.

## What it touches

- **Camera access**, which you grant in System Settings → Privacy & Security → Camera.
- **The camera's UVC controls** (auto exposure mode, exposure, gain, brightness, contrast, saturation, anti-flicker, backlight compensation), through IOKit. They stay set in the camera after the helper stops; `build/uvcctl reset` restores the factory values.
- **One LaunchAgent**, `~/Library/LaunchAgents/io.github.estevecastells.webcam-bright.plist`, and its logs in `~/Library/Logs/webcam-bright.log` (emptied above 1 MB) and `~/Library/Logs/webcam-bright.err.log`.
