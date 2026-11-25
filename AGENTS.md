# Agent guide

WebcamBright is a small macOS menu bar app. The Swift package is in `app/`:

- `app/Sources/WebcamBrightKit/`: the engine, with no UI.
  - `Engine.swift`: call detection, the capture session, pause and quit.
  - `Levers.swift`: which camera control moves when, and the contrast/saturation tone. Pure logic, checked by KitChecks.
  - `Tuning.swift`: the camera's measured constants (exposure steps, gain limits, low-light mode).
  - `Settings.swift`: what the menu changes (target brightness, daylight contrast, anti-flicker), stored in UserDefaults.
  - `Face.swift`, `CMIO.swift`, `Log.swift`, `Status.swift`.
- `app/Sources/WebcamBrightUI/`: the SwiftUI panel, the menu bar icon and the app model.
- `app/Sources/WebcamBright/`: the app entry point, with `--measure` and `--login-item-status`.
- `app/Sources/CUVC/`: UVC camera controls over IOKit, in C. `app/Sources/uvcctl/` is the command line tool for them.
- `app/Sources/KitChecks/`: checks for the lever logic and the settings, run with `make check`.
- `app/Sources/RenderScreenshots/`: renders `docs/images/panel-*.png` from the real views (`make screenshots`).
- `scripts/build-app.sh` builds `build/WebcamBright.app` (Info.plist and camera permission text included). `scripts/install.sh` installs it into /Applications. The `Makefile` wraps them.

## Before you push

- `make build` must pass with no new warnings, and `make check` must pass.
- Behaviour changes need a test with a real camera during a call: follow `make log`, and check that the call app still gets 30 fps. Say in the pull request what you measured and how.
- If the panel changes, run `make screenshots` and commit the new images.
- Never run two copies of WebcamBright at once: they would fight over the camera. The app stands by while it sees another copy, and `scripts/install.sh` refuses to install next to an older LaunchAgent helper.

## Rules

- Quality comes first. Don't trade the call's frame rate, the speed of a correction or the accuracy of the face measurement for CPU.
- The values in `Tuning.swift` and the defaults in `Settings.swift` are measured. When you change one, write in its comment what you measured and the result, as the existing comments do.
- Paused, off or quit, the camera must get its own auto exposure back.
- No third-party dependencies: Apple frameworks only.
- Code and comments in English.
