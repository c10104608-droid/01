# Device test procedure (not performed by CI)

Use only an IPA/device you are authorized to inspect. Install/inject the delivered arm64 dylib and launch the app. Keep the app usable; wait for the launcher, then tap **START SCREEN CAPTURE**. Navigate normally through at least Home → Search → Library (or equivalent), revisit one route after a meaningful content change, scroll to a distinct state, and open one app dialog. Confirm automatic captures appear after stable transitions without the inspector sheet or FLEX UI in the exported image. Use **CAPTURE CURRENT SCREEN** once to force a manual state. Tap **ANALYZE AND EXPORT** and choose a destination in the native share sheet.

Inspect the ZIP:

- `01_SCREENS/SCREEN_INDEX.json` lists observed route IDs and state variants.
- Each screen/state directory has `screenshot.png` or `screenshot_error.json`, JSON and TXT view/controller trees, `windows.json`, `visible_elements.json`, `screen_summary.txt`, and `metadata.json`.
- `MANIFEST.json`, `07_LOGS/FINAL_LOG.*`, and `07_LOGS/PHASE_EVENTS.jsonl` state PASS/PARTIAL honestly; validate the archive and hashes.
- Stop the app during a capture, relaunch, and select **RESUME LAST SESSION**. Verify prior complete captures remain and interrupted state is marked partial rather than complete.
- Repeat with FLEX open and with a different authorized IPA. Test responsiveness on an app with large view trees; note truncation and screenshot exclusion behavior.

Record device model, OS, app/IPA identity, navigation routes, count of screen/state folders, file/ZIP validation, share result, crash/responsiveness observations, recovery result, and any exclusions. Do not infer unvisited screens or claim SwiftUI source/Unity canvas reconstruction.
