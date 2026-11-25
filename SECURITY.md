# Security policy

WebcamBright is a menu bar app that runs as your user, never as root. It has no network code: it sends nothing anywhere and records nothing. It reads camera frames only while another app has the camera on, measures the brightness of your face in memory, and changes the camera's own controls over USB.

## Reporting

Please report vulnerabilities privately via [GitHub security advisories](https://github.com/estevecastells/webcam-bright/security/advisories/new), not public issues.

## What it touches

- **Camera access**, which you grant in System Settings → Privacy & Security → Camera.
- **The camera's UVC controls** (auto exposure mode, exposure, gain, brightness, contrast, saturation, anti-flicker, backlight compensation), through IOKit. When WebcamBright is paused, turned off or quit, it sets them back to the camera's defaults and turns the camera's own auto exposure back on; anti-flicker stays as you set it. `build/uvcctl reset` restores every factory value.
- **A Login Items entry**, which you can turn off from the menu or in System Settings → General → Login Items.
- **Its preferences** (`io.github.estevecastells.webcam-bright`) and its log, `~/Library/Logs/webcam-bright.log` (emptied above 1 MB).
