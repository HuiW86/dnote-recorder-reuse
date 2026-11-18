#!/usr/bin/env bash
# Screenshots of every main page on the iOS Simulator, light and dark, with the made-up demo
# library (DEBUG launch argument -demoLibrary; no card, no network). For #89 / #74 evidence.
#   scripts/shots.sh [output-dir]      default: app/build/shots (ignored by git)
# Needs Xcode, XcodeGen and an "iPhone 17 Pro" simulator (override with SIM="iPhone 16 Pro").
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
out="${1:-$root/app/build/shots}"
sim="${SIM:-iPhone 17 Pro}"
bundle="com.huiw86.revive"
derived="$root/app/build/shots-derived"
mkdir -p "$out"

(cd "$root/app" && xcodegen generate >/dev/null)
xcodebuild build -project "$root/app/Revive.xcodeproj" -scheme Revive -configuration Debug \
  -destination "platform=iOS Simulator,name=$sim" -derivedDataPath "$derived" CODE_SIGNING_ALLOWED=NO -quiet
app="$derived/Build/Products/Debug-iphonesimulator/Revive.app"

udid="$(xcrun simctl list devices available | grep -F "$sim (" | head -1 | sed -E 's/.*\(([0-9A-F-]{36})\).*/\1/')"
[[ -n "$udid" ]] || { echo "no simulator named $sim" >&2; exit 1; }
xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl bootstatus "$udid" -b >/dev/null
xcrun simctl install "$udid" "$app"
# Bluetooth would ask on first launch; the demo library never starts it, but grant what can be.
xcrun simctl privacy "$udid" grant microphone "$bundle" 2>/dev/null || true

shot() {
  local name="$1"; shift
  xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
  xcrun simctl launch "$udid" "$bundle" -demoLibrary YES "$@" >/dev/null
  sleep "${WAIT:-3}"
  xcrun simctl io "$udid" screenshot "$out/$name.png" >/dev/null 2>&1
  echo "$out/$name.png"
}

for appearance in light dark; do
  # Preferences reads revive.appearance; a launch argument overrides it for this run only.
  a=(-revive.appearance "$appearance")
  shot "$appearance-overview" "${a[@]}" -startTab overview
  shot "$appearance-recordings" "${a[@]}" -startTab recordings
  shot "$appearance-knowledge" "${a[@]}" -startTab knowledge
  shot "$appearance-card" "${a[@]}" -startTab card
  shot "$appearance-detail-summary" "${a[@]}" -startTab recordings -openRecording first -startPane summary
  shot "$appearance-detail-transcript" "${a[@]}" -startTab recordings -openRecording first -startPane transcript
  shot "$appearance-detail-rewrite" "${a[@]}" -startTab recordings -openRecording first -startPane rewrite
done
xcrun simctl terminate "$udid" "$bundle" >/dev/null 2>&1 || true
