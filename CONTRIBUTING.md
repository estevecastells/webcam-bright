# Contributing

Thanks for helping. WebcamBright changes how you look in every call, so changes need to be measured, not guessed.

## Before you open a pull request

- For bigger changes, such as a new control strategy, support for another family of cameras or new files, open an issue first so we can agree on the approach.
- `make build` passes with no new warnings, and `make check` passes.
- You tested the change in a real call, and the pull request says how: your camera model, Mac, macOS version, the light (daylight, a window behind you, a lamp, a dark room) and the relevant lines of `~/Library/Logs/webcam-bright.log`.
- Measured values (exposure steps, gain limits, targets) come with the measurement in the code comment.
- No new dependencies.

## Other cameras

Measurements from other UVC webcams are the most useful contribution. Follow [Other cameras](README.md#other-cameras) in the README and include the output of `build/uvcctl list`.

## Code style

Match the surrounding code. Swift follows the standard Swift API guidelines; C is plain C, built with `-Wall`. Comments explain why, in English. Lever logic goes in `Levers.swift`, where `make check` can cover it without a camera.
