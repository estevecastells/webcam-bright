# Agent guide

WebcamBright is a small macOS helper:

- `src/main.swift`: the controller (call detection, face measurement, camera adjustments). Settings are at the top.
- `src/uvc.c`, `src/uvc.h`: UVC camera controls over IOKit.
- `src/uvcctl.c`: command line tool for those controls.
- `src/Info.plist`: app bundle info, including the camera permission text.
- `scripts/install.sh`: build, install and uninstall. The `Makefile` wraps it.

## Before you push

- `make build` must pass with no new warnings.
- Behaviour changes need a test with a real camera during a call: follow `make log`, and check that the call app still gets 30 fps. Say in the pull request what you measured and how.
- Don't run `make install` on a Mac where another copy of the helper is installed under a different label: two helpers would fight over the same camera.

## Rules

- Quality comes first. Don't trade the call's frame rate, the speed of a correction or the accuracy of the face measurement for CPU.
- The values in the settings block are measured. When you change one, write in its comment what you measured and the result, as the existing comments do.
- No third-party dependencies: Apple frameworks only.
- Code and comments in English.
