# UniversalUIInspector

An Objective-C iOS arm64 runtime inspector with user-started automatic capture of screens actually visited. The intended flow is **START SCREEN CAPTURE → navigate normally → ANALYZE AND EXPORT**. Screens are persisted immediately under route/state directories; the export shares one validated `RuntimeDump.zip`.

## Build

On macOS with Xcode and an iOS SDK:

```bash
python3 -m unittest discover -s tests -v
./build-ios-dylib.sh
```

GitHub Actions runs the same portable checks and iOS arm64 build, then uploads `UniversalUIInspector.dylib` plus `UniversalUIInspector-arm64-BUILD.zip`. The build embeds the source revision and timestamp and verifies the arm64 Mach-O and feature markers.

## Runtime safeguards

Capture starts only after the user presses Start. Fingerprinting is bounded and debounced. Heavy existing runtime collectors remain behind the passive-startup and 120-second-plus-six-stable-samples gate. Earlier exports preserve available screens and are honestly marked `PARTIAL`. UIKit, SwiftUI, Unity, FLEX, and device-test scope are documented in `FEATURE_STATUS.md` and `FLEX_INTEGRATION.md`.
