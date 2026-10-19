#!/usr/bin/env bash
# All client checks, run on a Mac with Xcode 27:
#   scripts/test.sh                  contracts, RHKit (swift test), app unit + UI tests (simulator)
#   RH_SIMULATOR="iPhone 17" RH_SIMULATOR_OS=27.1 scripts/test.sh   (default: newest installed iOS runtime)
set -euo pipefail
cd "$(dirname "$0")/.."
SIMULATOR="${RH_SIMULATOR:-iPhone 17 Pro}"
SIMULATOR_OS="${RH_SIMULATOR_OS:-latest}"

echo "== contracts/"
scripts/check-contracts.sh

echo "== RHKit: swift test"
swift test --package-path Packages/RHKit

echo "== RHClient: xcodebuild test ($SIMULATOR, iOS $SIMULATOR_OS)"
xcodebuild test \
  -project RHClient.xcodeproj \
  -scheme RHClient \
  -destination "platform=iOS Simulator,name=$SIMULATOR,OS=$SIMULATOR_OS"
echo "== all green"
