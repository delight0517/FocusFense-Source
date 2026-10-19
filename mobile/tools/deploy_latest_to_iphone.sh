#!/bin/bash
set -euo pipefail

PROJECT_DIR="/Users/rogan/Desktop/appDev/6VPN_Image_Blocker/mobile"
LOG_DIR="$PROJECT_DIR/.launcher_logs"
LOG_FILE="$LOG_DIR/latest_deploy.log"
BUNDLE_ID="com.sixcleanroom.sixCleanRoom"

mkdir -p "$LOG_DIR"
exec > >(tee "$LOG_FILE") 2>&1

echo "=== 6 VPN Blocker deploy started: $(date) ==="
cd "$PROJECT_DIR"

DEVICE_ID="$(
  xcrun devicectl list devices 2>/dev/null | awk '
    NR > 4 && /iPhone/ {
      if ($4 != "unavailable") {
        print $3;
        exit;
      }
    }'
)"

if [[ -z "${DEVICE_ID}" ]]; then
  echo "No available iPhone device found."
  exit 1
fi

echo "Using device: $DEVICE_ID"

flutter build ios --debug --no-codesign

xcodebuild \
  -workspace ios/Runner.xcworkspace \
  -scheme Runner \
  -configuration Debug \
  -destination "id=$DEVICE_ID" \
  -allowProvisioningUpdates \
  install

xcrun devicectl device process launch --device "$DEVICE_ID" "$BUNDLE_ID"

echo "=== Deploy finished: $(date) ==="
