# UniversalUIInspector Feature Status

## Visited-screen capture

Implementation adds user-started foreground observation, three consecutive one-second stable fingerprint samples, disk-backed per-route/state directories, atomic files, an index, manual capture variants, and a resume option for recoverable sessions. Each capture contains a UIKit view tree, controller tree, eligible windows, visible elements, screenshot or screenshot-error metadata, and capture/build/app/device summaries. Inspector/FLEX/system-share windows are excluded; screenshots are scoped to the primary eligible app window.

Validation is designed to check required per-state files, JSON and JSONL parsing, text newline termination, PNG signature/IHDR/dimensions, archive structure, file sizes, SHA-256, missing files, and capture counters. Capture, runtime, export, and overall status are separate. `CAPTURE_COMPLETE_OBSERVED_SCREENS_ONLY` never asserts completeness of an IPA or of unvisited screens.

## Existing collectors and safeguards

Existing class index/details, protocol, image, controller/view hierarchy, manual diagnostics, and Unity status functions remain in the source/build inputs. Full runtime collectors stay behind passive startup plus the existing 120-second lightweight warm-up and six consecutive stable samples. Capture does not start automatically at dylib load. If Analyze and Export runs before the gate passes, saved screens are exported as `PARTIAL` with an explicit skip reason. After the gate passes, the pre-existing collector phases still run sequentially.

## Scope and limitations

FLEX remains an optional, separately injected dylib; no private FLEX API or FLEX source is linked/bundled. UIKit snapshots do not reconstruct original SwiftUI declarations. Unity Metal/Canvas hierarchy remains unavailable without a supported, initialized bridge. See `FLEX_INTEGRATION.md` and `DEVICE_TEST_STEPS.md`.

## Verification boundary

The GitHub Actions workflow is configured to run portable contract checks and build an arm64 iOS device dylib on macOS/Xcode. A successful build proves compilation, embedded markers, architecture, and framework linkage only. **Physical-device injection/navigation, recovery after a real process kill, FLEX overlay behavior, and app responsiveness remain NOT TESTED** until exercised on an authorized device and IPA.
