#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
test_dir=$(mktemp -d /tmp/boring-now-playing-tests.XXXXXX)
trap 'rm -rf "$test_dir"' EXIT
xcrun swiftc -parse-as-library \
  boringNotch/MediaControllers/NowPlayingController.swift \
  boringNotch/MediaControllers/MediaControllerProtocol.swift \
  boringNotch/models/PlaybackState.swift \
  boringNotch/helpers/AppleScriptHelper.swift \
  boringNotch/helpers/MediaChecker.swift \
  Tests/NowPlayingRegressionTests.swift -o "$test_dir/checks"
"$test_dir/checks"
