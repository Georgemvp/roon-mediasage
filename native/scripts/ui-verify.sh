#!/usr/bin/env bash
# Photograph the iOS app: boot a throwaway simulator, seed a demo library, run
# the XCUITest walk, and drop the screenshots in a folder you can look at.
#
# WHY THIS EXISTS
# Six UX batches shipped with "NIET geverifieerd: hoe het eruitziet" in the
# commit message. This machine cannot drive a GUI — the terminal has no
# Accessibility or Screen Recording TCC grant, so `osascript … System Events`
# and `screencapture -x` fail, and `xcrun simctl` takes screenshots but has no
# way to send a tap. XCUITest runs inside the simulator through the test harness
# and needs no system permission at all.
#
# THE SEED IS NOT DECORATION
# The connect screen only offers "Offline gebruiken" when a synced library
# exists (`RoonClient.hasLocalLibrary`), so on a fresh simulator there is no way
# past the gate at all. The app has to run once to create and migrate its
# database; only then can we insert rows into it.
#
# Usage:  native/scripts/ui-verify.sh [output-dir]
#         output-dir defaults to /tmp/roonsage-ui
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
IOS="$ROOT/native/iosapp"
OUT="${1:-/tmp/roonsage-ui}"
DERIVED="/tmp/roonsage-ui-dd"
BUNDLE_ID="com.roonsage.ios"
SIM_NAME="RoonSage-UX"
DEVICE_TYPE="${DEVICE_TYPE:-com.apple.CoreSimulator.SimDeviceType.iPhone-17}"

runtime=$(xcrun simctl list runtimes --json \
  | python3 -c 'import json,sys; rs=[r for r in json.load(sys.stdin)["runtimes"] if r["isAvailable"] and "iOS" in r["name"]]; print(rs[-1]["identifier"] if rs else "")')
[[ -n "$runtime" ]] || { echo "Geen iOS-simulatorruntime geïnstalleerd." >&2; exit 1; }

# Reuse a simulator of ours if one is lying around, so repeated runs are quick.
udid=$(xcrun simctl list devices --json \
  | python3 -c "import json,sys; ds=json.load(sys.stdin)['devices']; print(next((d['udid'] for v in ds.values() for d in v if d['name']=='$SIM_NAME'), ''))")
if [[ -z "$udid" ]]; then
    echo "── simulator aanmaken ($SIM_NAME)"
    udid=$(xcrun simctl create "$SIM_NAME" "$DEVICE_TYPE" "$runtime")
fi
xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || xcrun simctl boot "$udid" >/dev/null 2>&1 || true

echo "── bouwen voor de test"
xcodebuild build-for-testing \
    -project "$IOS/RoonSageiOS.xcodeproj" -scheme RoonSageiOS \
    -destination "id=$udid" -derivedDataPath "$DERIVED" \
    CODE_SIGNING_ALLOWED=NO >/dev/null

APP=$(find "$DERIVED/Build/Products" -maxdepth 2 -name 'RoonSage.app' | head -1)
[[ -n "$APP" ]] || { echo "RoonSage.app niet gevonden na de build." >&2; exit 1; }

echo "── demo-bibliotheek zaaien"
xcrun simctl install "$udid" "$APP"
# The database is created by the app itself, on its first run — hence the launch
# we immediately terminate again.
xcrun simctl launch "$udid" "$BUNDLE_ID" >/dev/null
sleep 6
xcrun simctl terminate "$udid" "$BUNDLE_ID" >/dev/null 2>&1 || true
container=$(xcrun simctl get_app_container "$udid" "$BUNDLE_ID" data)
db="$container/Library/Application Support/RoonSage/client-library.db"
[[ -f "$db" ]] || { echo "client-library.db is niet aangemaakt — startte de app wel?" >&2; exit 1; }
# Also seeds feature rows and real audio in the pinned-download directory:
# without those, every play verb filters the whole library out and the player
# can never be photographed with anything in it.
python3 "$(dirname "${BASH_SOURCE[0]}")/seed-demo-library.py" "$db" \
    --downloads "$container/Library/Application Support/RoonSageDownloads"

echo "── de app fotograferen"
rm -rf "$DERIVED/result.xcresult"
set +e
xcodebuild test-without-building \
    -project "$IOS/RoonSageiOS.xcodeproj" -scheme RoonSageiOS \
    -destination "id=$udid" -derivedDataPath "$DERIVED" \
    -resultBundlePath "$DERIVED/result.xcresult" \
    CODE_SIGNING_ALLOWED=NO 2>&1 | tail -25
status=${PIPESTATUS[0]}
set -e

echo "── schermafdrukken uitpakken → $OUT"
rm -rf "$OUT"; mkdir -p "$OUT"
python3 "$(dirname "${BASH_SOURCE[0]}")/extract-screenshots.py" "$DERIVED/result.xcresult" "$OUT"
ls -1 "$OUT" || true

echo
[[ $status -eq 0 ]] && echo "✓ Klaar. Bekijk: open $OUT" \
                    || echo "⚠ De testrun faalde (exit $status) — de afdrukken tot dat punt staan er wel."
exit $status
