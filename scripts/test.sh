#!/usr/bin/env bash
# All client checks, run on a Mac with Xcode 27:
#   scripts/test.sh                  contracts, RHKit (swift test), app unit + UI tests (simulator)
#   RH_SIMULATOR="iPhone 17" RH_SIMULATOR_OS=27.1 scripts/test.sh   (default: newest installed iOS runtime)
#   RH_DEV_PORT=8790 scripts/test.sh   first port to try for the dev core (default 8787;
#                                      when it is taken, the next free one is used)
# The pairing UI test runs against the dev core from RHServer next to this repository
# (RH_SERVER_DIR to point elsewhere); without it that test is skipped.
set -euo pipefail
cd "$(dirname "$0")/.."
SIMULATOR="${RH_SIMULATOR:-iPhone 17 Pro}"
SIMULATOR_OS="${RH_SIMULATOR_OS:-latest}"
SERVER_DIR="${RH_SERVER_DIR:-../RHServer}"
DEV_DATA=/tmp/rh-dev-ui
PAIRING_FILE=/tmp/rh-dev-ui-pairing.txt
DEV_PORT="${RH_DEV_PORT:-8787}"

echo "== contracts/"
scripts/check-contracts.sh

echo "== RHKit: swift test"
swift test --package-path Packages/RHKit

UDID=$(python3 - "$SIMULATOR" "$SIMULATOR_OS" <<'PY'
import json, subprocess, sys
name, wanted = sys.argv[1], sys.argv[2]
data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"]))
best = None
for runtime, devices in data["devices"].items():
    if ".SimRuntime.iOS-" not in runtime:
        continue
    version = tuple(int(part) for part in runtime.rsplit("iOS-", 1)[1].split("-"))
    if wanted != "latest" and ".".join(map(str, version)) != wanted:
        continue
    for device in devices:
        if device["name"] == name and (best is None or version > best[0]):
            best = (version, device["udid"])
if best is None:
    sys.exit(f"no simulator named {name!r} with iOS {wanted}")
print(best[1])
PY
)

echo "== simulator: boot, reset keychain, enroll Face ID"
xcrun simctl boot "$UDID" 2>/dev/null || true
xcrun simctl bootstatus "$UDID" -b
xcrun simctl keychain "$UDID" reset
xcrun simctl spawn "$UDID" notifyutil -s com.apple.BiometricKit.enrollmentChanged 1
xcrun simctl spawn "$UDID" notifyutil -p com.apple.BiometricKit.enrollmentChanged

cleanup() {
    [[ -n "${MATCH_PID:-}" ]] && kill "$MATCH_PID" 2>/dev/null || true
    pkill -f "rhcore dev up --data $DEV_DATA" 2>/dev/null || true
}
trap cleanup EXIT

# Answer every Face ID prompt with a matching face (Features → Face ID → Matching Face).
(while true; do
    xcrun simctl spawn "$UDID" notifyutil -p com.apple.BiometricKit_Sim.pearl.match >/dev/null 2>&1 || true
    sleep 1
done) &
MATCH_PID=$!

if [[ -d "$SERVER_DIR" ]] && command -v uv >/dev/null; then
    # The app takes the core address from the pairing string, so any free port works.
    for _ in $(seq 20); do
        lsof -nP -iTCP:"$DEV_PORT" -sTCP:LISTEN >/dev/null 2>&1 || break
        echo "port $DEV_PORT is taken, trying $((DEV_PORT + 1))"
        DEV_PORT=$((DEV_PORT + 1))
    done
    echo "== dev core from $SERVER_DIR on 127.0.0.1:$DEV_PORT (log: $DEV_DATA.log)"
    rm -rf "$DEV_DATA" "$PAIRING_FILE"
    (cd "$SERVER_DIR" && exec uv run rhcore dev up --data "$DEV_DATA" --port "$DEV_PORT" --auto-pair \
        --pairing-file "$PAIRING_FILE") >"$DEV_DATA.log" 2>&1 &
    # A core before RHServer #8 writes the pairing file before it binds, so wait for both.
    for _ in $(seq 60); do
        [[ -s "$PAIRING_FILE" ]] && lsof -nP -iTCP:"$DEV_PORT" -sTCP:LISTEN >/dev/null 2>&1 && break
        sleep 1
    done
    lsof -nP -iTCP:"$DEV_PORT" -sTCP:LISTEN >/dev/null 2>&1 && [[ -s "$PAIRING_FILE" ]] \
        || { echo "dev core did not start:"; cat "$DEV_DATA.log"; exit 1; }
    export TEST_RUNNER_RH_PAIRING_FILE="$PAIRING_FILE"
else
    echo "== no RHServer at $SERVER_DIR (or no uv): the pairing UI test is skipped"
fi

echo "== RHClient: xcodebuild test ($SIMULATOR, iOS $SIMULATOR_OS)"
# No parallel testing: it runs the tests on clones of the simulator, where the Keychain
# reset, the Face ID enrollment and the matching-face loop above do not reach.
xcodebuild test \
  -project RHClient.xcodeproj \
  -scheme RHClient \
  -destination "id=$UDID" \
  -parallel-testing-enabled NO
echo "== all green"
