#!/usr/bin/env bash
# Runs every test layer that does not need a phone, on macOS.
#
# The protocol and state-machine tests are a SwiftPM package, so this needs neither Xcode nor a
# simulator nor a device. The device tests (tools/cross_device_test.py) need two phones attached to
# this Mac; see docs/testing.md.
#
#   ./tools/run_tests.sh            # Swift tests only
#   ./tools/run_tests.sh --app      # also build the iOS app for a connected device
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(dirname "$here")"

echo "==> swift test (AirChatKit)"
cd "$repo/ios/AirChatKit"
swift test

if [[ "${1:-}" == "--app" ]]; then
  echo "==> xcodebuild AirChat.app"
  cd "$repo/ios"
  xcodegen generate
  xcodebuild -project AirChat.xcodeproj -scheme AirChat -configuration Debug \
    -destination "generic/platform=iOS" -derivedDataPath /tmp/airchat-dd build
fi

echo
echo "Swift suites passed. Still to run:"
echo "  two phones, device tests: python3 tools/cross_device_test.py [--reset]"
echo "  see docs/testing.md for what each layer proves."
