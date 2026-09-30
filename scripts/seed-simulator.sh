#!/bin/bash
# Re-seed the MangaCarta container on the project's simulator with the fixture.
#
# The simulator's on-device state is a fixture, not scratch data: works.json, the
# reading history and the upgrade-attempt memory are what the recommender and the
# ADR verification runs read. `simctl erase` destroyed it once already, and nothing
# reconstructed it. This script is that reconstruction.
#
# It does NOT write the fixture itself. The seeding is a *test*
# (SimulatorSeedTests.testSeedTheSimulatorInPlace), because only a test can drive
# the app's real stores — a shell script writing works.json by hand would be a second
# definition of the on-disk shape, drifting silently the day `Work` changes. The unit
# test target is hosted by the app, so that test already runs inside the very container
# being seeded and writes in place.
#
# This script's whole job is the part a test cannot do: find the container, back it up,
# and arm the run by dropping the marker file the test looks for. Without the marker the
# test skips, so an ordinary `xcodebuild test` and CI never touch the container.
#
# Usage: ./scripts/seed-simulator.sh [--force]
#
#   --force   seed even though the container already holds a fixture
#
# The device is `iPhone 17 Pro`, the project's simulator; override with
# SEED_SIMULATOR_DEVICE if you need another one.
#
# This script never calls `simctl erase`.

set -euo pipefail

BUNDLE_ID="Elias-Magdaleno.Manga-Reader"
SCHEME="MangaCarta"
DEVICE_NAME="${SEED_SIMULATOR_DEVICE:-iPhone 17 Pro}"
FORCE=0

for arg in "$@"; do
  case "$arg" in
    --force) FORCE=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

cd "$(dirname "$0")/.."

# **Resolve the device by name, never by `booted`.** `simctl ... booted` answers about
# whichever device happens to be booted, and Xcode boots others on its own schedule. The
# ADR-0020 AniList-arm run lost two launches to this: an iPhone 17 Pro was up alongside the
# seeded device, so every container inspection read an unseeded container on the wrong
# machine while looking entirely normal.
UDID=$(xcrun simctl list devices available -j \
       | python3 -c 'import json,sys
name = sys.argv[1]
for runtime, devices in json.load(sys.stdin)["devices"].items():
    for d in devices:
        if d["name"] == name:
            print(d["udid"]); raise SystemExit
raise SystemExit("no such device")' "$DEVICE_NAME" 2>/dev/null) || {
  echo "no available simulator named \"$DEVICE_NAME\"." >&2
  echo "set SEED_SIMULATOR_DEVICE to one from: xcrun simctl list devices available" >&2
  exit 1
}
DESTINATION="platform=iOS Simulator,id=$UDID"
echo "device: $DEVICE_NAME ($UDID)"

# Boot it if it is not already up — the container only exists on a device that has run the
# app, and every step below addresses this device by id regardless of what else is booted.
xcrun simctl bootstatus "$UDID" -b >/dev/null 2>&1 || xcrun simctl boot "$UDID" >/dev/null 2>&1 || true

# The app must be installed for the container to exist; a fresh clone or a post-erase
# simulator has neither. Building the test bundle installs it, so say so rather than
# failing with simctl's own opaque error.
if ! CONTAINER=$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data 2>/dev/null); then
  echo "no container for $BUNDLE_ID on $DEVICE_NAME." >&2
  echo "run the app there once (or xcodebuild test against it) to install it first." >&2
  exit 1
fi

SUPPORT="$CONTAINER/Library/Application Support"
MARKER="$CONTAINER/Documents/seed-simulator.marker"

if [ -f "$SUPPORT/works.json" ] && [ "$FORCE" -eq 0 ]; then
  WORK_COUNT=$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("works", [])))' \
               "$SUPPORT/works.json" 2>/dev/null || echo "?")
  echo "the container already holds a fixture ($WORK_COUNT works)." >&2
  echo "seeding replaces it. re-run with --force if that is what you want." >&2
  echo "  $SUPPORT/works.json" >&2
  exit 1
fi

# Back up before arming, not after: once the marker is written the next test run
# clobbers the container, and a backup taken afterwards would back up the fixture.
BACKUP="$PWD/.simulator-backups/$(date +%Y-%m-%d-%H%M%S)"
mkdir -p "$BACKUP"
[ -d "$SUPPORT" ] && cp -R "$SUPPORT" "$BACKUP/Application Support" 2>/dev/null || true
# `-` rather than a path: the spawned process writes into the simulator's own filesystem
# view, so a host path would not land where you expect.
xcrun simctl spawn "$UDID" defaults export "$BUNDLE_ID" - > "$BACKUP/defaults.plist" 2>/dev/null || true
echo "backed up the container to $BACKUP"

mkdir -p "$CONTAINER/Documents"
touch "$MARKER"

echo "seeding..."
set +e
xcodebuild -scheme "$SCHEME" -destination "$DESTINATION" -parallel-testing-enabled NO \
  test -only-testing:MangaCartaTests/SimulatorSeedTests/testSeedTheSimulatorInPlace \
  2>&1 | tee /tmp/seed-simulator.log | grep -E "^Test Case|seeded |error:"
STATUS=${PIPESTATUS[0]}
set -e

# The test consumes the marker on the way in. A marker still sitting there means the run
# never reached it — a build failure, the wrong simulator — and leaving it armed would
# fire the destructive path on somebody's next ordinary test run.
rm -f "$MARKER" "$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)/Documents/seed-simulator.marker"

# A skipped test exits 0. Without the marker the run skips, so success alone does not
# mean anything was written — the test prints this line only after the bytes have landed.
if [ "$STATUS" -eq 0 ] && ! grep -q "seeded " /tmp/seed-simulator.log; then
  echo "the seeding test did not run (it skipped, or never reached the container)." >&2
  echo "full log in /tmp/seed-simulator.log" >&2
  exit 1
fi

if [ "$STATUS" -ne 0 ]; then
  echo "seeding failed; full log in /tmp/seed-simulator.log" >&2
  echo "the container is unchanged unless the test got past its marker check." >&2
  echo "restore from $BACKUP if needed." >&2
  exit "$STATUS"
fi

# Re-resolve: CoreSimulator rotates the data container's UUID when xcodebuild reinstalls
# the app, carrying the contents across. The path from before the run is stale — reporting
# against it says "no such works.json" about a container that was just seeded correctly.
CONTAINER=$(xcrun simctl get_app_container "$UDID" "$BUNDLE_ID" data)
SUPPORT="$CONTAINER/Library/Application Support"

# Unit tests remove their defaults suites, but cfprefsd can write an emptied plist back
# afterwards (see MangaCartaTests/TestDefaults.swift). Harmless, but the fixture should not
# ship the test runner's litter.
rm -f "$CONTAINER"/Library/Preferences/MangaCartaTests.*.plist 2>/dev/null || true
# Likewise any test directory a crashed test left behind (MangaCartaTests/TestDirectory.swift).
rm -rf "$CONTAINER/tmp/MangaCartaTests" 2>/dev/null || true

echo
echo "done. container: $CONTAINER"
./scripts/queue-status.sh "$SUPPORT/works.json" 2>/dev/null || true
