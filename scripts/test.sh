#!/usr/bin/env bash
# All client checks, run on a Mac with Xcode 27:
#   scripts/test.sh                  contracts, RHKit (swift test), app unit + UI tests (simulator)
#   RH_SIMULATOR="iPhone 17" scripts/test.sh
set -euo pipefail
cd "$(dirname "$0")/.."
SIMULATOR="${RH_SIMULATOR:-iPhone 17 Pro}"

echo "== contracts/"
scripts/check-contracts.sh

echo "== RHKit: swift test"
swift test --package-path Packages/RHKit

echo "== RHClient: xcodebuild test ($SIMULATOR)"
xcodebuild test \
  -project RHClient.xcodeproj \
  -scheme RHClient \
  -destination "platform=iOS Simulator,name=$SIMULATOR,OS=27.0" \
  -quiet
echo "== all green"
