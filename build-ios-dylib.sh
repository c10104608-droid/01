#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT_DIR"
LOG_FILE="${BUILD_LOG_FILE:-BUILD_LOG.txt}"
exec > >(tee "$LOG_FILE") 2>&1
SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
SDK_VERSION="$(xcrun --sdk iphoneos --show-sdk-version)"
XCODE_VERSION="$(xcodebuild -version | tr '\n' ' ')"
OUTPUT="${DYLIB_OUTPUT:-UniversalUIInspector.dylib}"
BRANCH="$(git branch --show-current 2>/dev/null || true)"
BRANCH="${BRANCH:-detached}"
BUILD_VERSION="${UUI_BUILD_VERSION:-2.3.0}"
BUILD_REVISION="${UUI_BUILD_REVISION:-$(git rev-parse --short=12 HEAD 2>/dev/null || echo unversioned)}"
BUILD_TIMESTAMP="${UUI_BUILD_TIMESTAMP_UTC:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}"
COMMIT="$(git rev-parse HEAD 2>/dev/null || echo unversioned)"
RUN_URL="${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-unknown}/actions/runs/${GITHUB_RUN_ID:-local}"
rm -f "$OUTPUT"
echo "UniversalUIInspector arm64 iOS build"
echo "sdk=$SDK sdk_version=$SDK_VERSION xcode=$XCODE_VERSION output=$OUTPUT"
echo "version=$BUILD_VERSION revision=$BUILD_REVISION timestamp_utc=$BUILD_TIMESTAMP"
echo "commit=$COMMIT run_url=$RUN_URL"
xcrun --sdk iphoneos clang \
  -dynamiclib -fobjc-arc -fblocks -fmodules -arch arm64 \
  -isysroot "$SDK" -miphoneos-version-min=13.0 \
  "-DUUI_BUILD_VERSION=\"${BUILD_VERSION}\"" \
  "-DUUI_SOURCE_REVISION=\"${BUILD_REVISION}\"" \
  "-DUUI_BUILD_TIMESTAMP_UTC=\"${BUILD_TIMESTAMP}\"" \
  -Wno-deprecated-declarations -Wno-unused-function -Wno-unused-variable \
  -framework UIKit -framework QuartzCore -lz \
  -install_name @rpath/UniversalUIInspector.dylib \
  UniversalUIInspector/UniversalUIInspector.m \
  UniversalUIInspector/LegacyCollectors.m \
  UniversalUIInspector/UnityInspection.m \
  UniversalUIInspector/VisitedScreenRecorder.m \
  -o "$OUTPUT"
file "$OUTPUT"
xcrun lipo "$OUTPUT" -verify_arch arm64
strings "$OUTPUT" > BUILD_STRINGS.txt
for marker in "$BUILD_VERSION" "$BUILD_REVISION" "$BUILD_TIMESTAMP" \
  "START SCREEN CAPTURE" "CAPTURE CURRENT SCREEN" "ANALYZE AND EXPORT" \
  "STOP / PAUSE CAPTURE" "SCREEN_INDEX.json" "uui-screen-index-1.0" \
  "controller_tree.json" "visible_elements.json" "MANIFEST.json" \
  "AUTO FULL CAPTURE remains disabled in this build" "DETECT UNITY" \
  "CAPTURE UNITY SCREEN" "VIEW UNITY SNAPSHOTS" "EXPORT UNITY SESSION"; do
  if ! grep -Fq -- "$marker" BUILD_STRINGS.txt; then echo "Missing expected build marker: $marker" >&2; exit 1; fi
done
rm -f BUILD_STRINGS.txt
xcrun otool -hv "$OUTPUT" | tee MACHO_HEADER.txt
xcrun otool -L "$OUTPUT" | tee LINKED_FRAMEWORKS.txt
shasum -a 256 "$OUTPUT" | tee SHA256.txt
SIZE="$(stat -f%z "$OUTPUT")"
cat > BUILD_INFO.txt <<EOF
version: $BUILD_VERSION
source revision: $BUILD_REVISION
build timestamp UTC: $BUILD_TIMESTAMP
branch: $BRANCH
commit: $COMMIT
run URL: $RUN_URL
runner: macos-14
xcode: $XCODE_VERSION
iOS SDK: $SDK_VERSION
architecture: arm64
platform: iOS device
deployment target: iOS 13.0
dylib size: $SIZE bytes
install name: @rpath/UniversalUIInspector.dylib
linked frameworks: UIKit, QuartzCore; library: libz
build script: build-ios-dylib.sh
source inputs: UniversalUIInspector.m, LegacyCollectors.m, UnityInspection.m, VisitedScreenRecorder.m
EOF
echo "Build succeeded: $OUTPUT"
