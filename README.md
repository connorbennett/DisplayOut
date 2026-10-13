# DisplayOut

A macOS app that sends a Mac display to a Blackmagic DeckLink or UltraStudio video output.

It captures a display with ScreenCaptureKit and plays it out over SDI/HDMI through the Blackmagic DeckLink API, clocked by the output hardware.

## Features

- Capture any connected display
- Scale to fit (letterbox) or fill (crop) the output format
- Show or hide the cursor, and hide the app's own windows from the feed
- Any output format the device reports (defaults to 1080p59.94 where available)
- Test pattern generator: colour bars (75% / 100%), luma ramp, grid, white, black — switchable live
- Option to blank the output when stopping instead of holding the last frame
- Live preview, with late and dropped frame counts
- Handles devices being plugged in and unplugged

Video only: no audio is embedded in the output.

## Requirements

- macOS 14 or later, Apple silicon or Intel
- [Blackmagic Desktop Video](https://www.blackmagicdesign.com/support/family/capture-and-playback) installed
- A DeckLink or UltraStudio device with a video output
- Screen Recording permission (not needed for test patterns)

## Install

Download the latest zip from [Releases](https://github.com/connorbennett/DisplayOut/releases), unzip it, and move `DisplayOut.app` to Applications. Release builds are signed with a Developer ID and notarized.

## Usage

1. Choose **Display** or **Test Pattern** as the source.
2. Pick the output device and format.
3. Click **Start Output**.

The first time you start a display capture, macOS asks for Screen Recording permission. Grant it in System Settings → Privacy & Security → Screen & System Audio Recording, then relaunch the app.

If the device can't be enabled, check that no other application (DaVinci Resolve, Media Express, and so on) is using it.

## Building

Open `DisplayOut.xcodeproj` in Xcode 16 or later and run the `DisplayOut` scheme. Set your own development team under Signing & Capabilities.

There are no package dependencies. The DeckLink SDK headers the app needs are included in `DisplayOut/DeckLink/SDK`; the DeckLink framework itself is installed by Desktop Video and loaded at runtime from `/Library/Frameworks`.

The app is not sandboxed. It uses the hardened runtime with the `disable-library-validation` entitlement so it can load Blackmagic's framework.

## How it works

| File | Role |
| --- | --- |
| `ScreenCapturer.swift` | Captures the display as BGRA frames with ScreenCaptureKit |
| `TestPattern.swift` | Renders the test patterns |
| `DeckLink/DeckLinkBridge.mm` | Objective-C++ wrapper around the DeckLink API: device discovery and scheduled playback |
| `AppModel.swift` | App state, start/stop, settings |
| `ContentView.swift` | The window |

The output keeps a few frames queued in the hardware and refills the queue from a completion callback, always with the most recent frame. Screen capture only delivers frames when the picture changes, so a static screen is simply the same frame repeated at the output rate.

Frames are sent to the device as 8-bit BGRA where it accepts that, and converted to 8-bit YUV otherwise.

## Acknowledgements

The files in `DisplayOut/DeckLink/SDK` are from the Blackmagic DeckLink SDK, © Blackmagic Design, and are distributed under the licence at the top of each file.
