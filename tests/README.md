# Verification boundary

`test_capture_contract.py` provides portable model and source-integration checks for debounce/dedup rules, state-path separation, partial recovery, atomic-write/hash behavior, and ZIP integrity. These tests do **not** execute UIKit or prove the Objective-C recorder's device stability. The GitHub Actions job separately compiles the iOS arm64 dylib with Xcode. The physical-device procedure is in `DEVICE_TEST_STEPS.md` and remains NOT_TESTED until performed on an authorized device/IPA.
