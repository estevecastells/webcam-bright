## What and why

<!-- What does this change, and what problem does it solve? Link the issue. -->

## How it was tested

<!-- Camera model, Mac, macOS version, the light (daylight, window behind you, lamp, dark room), the call's frame rate, and the relevant lines of ~/Library/Logs/webcam-bright.log. -->

## Checklist

- [ ] `make build` passes with no new warnings, and `make check` passes
- [ ] Lever changes are covered in `KitChecks`
- [ ] Tested in a real call; the call app still gets 30 fps
- [ ] Measured values come with the measurement in their comment
- [ ] Paused, off and quit still hand the camera back to its own auto exposure
- [ ] No new dependencies
