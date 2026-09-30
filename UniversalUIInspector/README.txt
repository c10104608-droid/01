UniversalUIInspector — UIKit/runtime inspection

This generic Objective-C inspector is built for iOS arm64 with Xcode on macOS. It keeps the passive startup/overlay architecture and existing staged legacy collectors. Runtime class/image collection remains user-triggered and governed by the existing warm-up/stability gates.

Build provenance
- The floating panel displays the embedded version, source revision, and UTC build timestamp.
- Text reports include a build banner. JSON/JSONL reports and summaries, session manifests, final logs, and snapshot indexes include build metadata.
- The macOS workflow packages both the arm64 dylib and its source snapshot with build logs, architecture/framework checks, and SHA-256.

Unity controls
- DETECT UNITY only checks loaded dyld image names for known Unity runtime markers. A marker is evidence of a loaded image, not proof that Unity initialized.
- CAPTURE UNITY SCREEN is explicit/user-triggered. If markers exist it records the existing UIKit host-window snapshot; Unity Metal content may not appear.
- The Unity screen action is limited to 12 snapshots per in-memory capture session to bound memory use.
- VIEW UNITY SNAPSHOTS lists the recorded status captures.
- EXPORT UNITY SESSION creates a ZIP marked PARTIAL. It does not claim or fabricate Unity Canvas/UI hierarchy nodes.
- No Unity private selectors, internal APIs, hooks, guessed data layouts, or target-app assumptions are used. A supported initialized runtime bridge and a Unity device fixture are required before hierarchy collection can be claimed.

Build and validation
Run GitHub Actions > Build UniversalUIInspector dylib on the `staged-collectors` branch, or push a reviewed change to that branch to trigger the workflow. The build script targets iOS 13.0+ arm64 and links UIKit, QuartzCore, and libz.

A successful macOS compile proves only that the dylib links. It is not evidence of device stability, Unity initialization, or Unity UI hierarchy coverage. Use only in applications you are authorized to test.
