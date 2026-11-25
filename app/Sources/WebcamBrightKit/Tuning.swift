// The camera's measured behaviour. The settings people change from the menu (target brightness,
// daylight contrast, anti-flicker) are in Settings.swift.
//
// What the Logitech C920 really does (measured 2026-11-25):
//  - exposure only takes the values in `exposureLadder`; anything else falls back to 15.6 ms,
//    and from 3.9 ms up the camera evens the picture out itself, so exposure is a coarse lever;
//  - gain is the reliable lever: face 104 / 150 / 184 / 208 at gain 0 / 10 / 20 / 30;
//  - brightness is a gentle offset, used here to darken in small steps;
//  - 31.2 ms exposure drops the camera to about 25 fps, so it is a last resort;
//  - in a dark room lit only by the screen it depends on the screen: with light content gain 100
//    at 15.6 ms reached the target at 30 fps, with dark content the face stayed near 50 even at
//    31.2 ms; past ~100 more gain makes the picture darker, and contrast/saturation 140 look less flat.

import Foundation

public let deadband = 8.0                // leave the camera alone when this close to the target
public let exposureLadder = [3, 9, 19, 39, 78, 156, 312]  // 0.1 ms units
public let normalTopRung = 5             // 15.6 ms: the longest exposure that still gives 30 fps
public let lowLightGain = 100            // only past this gain at 15.6 ms switch to 31.2 ms (about 25 fps)
public let lowLightOffset = 10           // what 31.2 ms adds, in gain units: the camera evens most of it out
                                         // (gain 100: face 127 at 31.2 ms, 117 at 15.6 ms, ~13 units; measured)
public let lowLightExitGain = 40         // at 31.2 ms, below this gain there is light enough for 15.6 ms and 30 fps
                                         // again (about gain 50 there, well below where low-light mode starts)
public let maxGain = 100                 // above ~100 the C920 gets darker again (gain 160 < gain 100, measured)
public let darkTone = 140                // contrast and saturation in a room lit only by the screen, which
                                         // alone looks grey and flat (saturation is 128 in daylight)
public let toneFrom = 60, toneFull = 100 // how dark the room is, as the gain it needs at 15.6 ms: daylight,
                                         // even against a window, needed 20-50; screen light alone 100 or more
public let analysisWidth = 640           // frames we analyse are scaled down to this width
public let analysisFPS: Int32 = 4        // and delivered at this rate (we sample twice a second)
public let gainPerUnitStart = 2.0        // face brightness per gain unit; it varies with the light
                                         // (4.6 and 0.75 measured on the same day), so it is learned live
public let brightnessRange = 80...128    // 128 is neutral; lower values darken gently
public let brightnessStep = 4
public let releaseCheckEvery = 6.0       // seconds between checks that the call app still has the camera

/// Controls set back to the camera's own defaults when WebcamBright pauses or quits, before
/// auto exposure goes back on. Anti-flicker stays as set: it matters as much for the camera's
/// own auto exposure.
let handBackControls = ["gain", "brightness", "contrast", "saturation", "backlight"]
