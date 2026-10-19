#!/usr/bin/env bash
# Creates/refreshes Desktop launchers on macOS: Mac app + Deploy to iPhone.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOBILE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DESKTOP="${HOME}/Desktop"
DEPLOY_SH="$SCRIPT_DIR/deploy_latest_to_iphone.sh"

remove_legacy() {
  local name="$1"
  local p="$DESKTOP/$name"
  if [[ -e "$p" ]]; then
    rm -rf "$p"
    echo "Removed legacy: $p"
  fi
}

remove_legacy "Six VPN Blocker.app"
remove_legacy "6 VPN Blocker.app"
remove_legacy "Deploy 6 VPN to iPhone.command"

# --- Mac app launcher (.app bundle style via .command is OK; use open on built .app when present) ---
MAC_APP_NAME="6 VPN Blocker (Mac).command"
MAC_CMD="$DESKTOP/$MAC_APP_NAME"
cat >"$MAC_CMD" <<EOF
#!/bin/bash
set -e
cd "$MOBILE_ROOT"
if [[ -d "build/macos/Build/Products/Release/six_clean_room.app" ]]; then
  open "build/macos/Build/Products/Release/six_clean_room.app"
elif [[ -d "build/macos/Build/Products/Debug/six_clean_room.app" ]]; then
  open "build/macos/Build/Products/Debug/six_clean_room.app"
else
  echo "Mac build not found. Run: cd mobile && flutter build macos"
  echo "Or from repo: mobile/tools/Rebuild-6VPN-Mac.sh (if present)"
  read -r -p "Press Enter…"
fi
EOF
chmod +x "$MAC_CMD"
echo "Created: $MAC_CMD"

# --- iPhone deploy launcher ---
IPHONE_NAME="6 VPN Blocker — Deploy to iPhone.command"
IPHONE_CMD="$DESKTOP/$IPHONE_NAME"
cat >"$IPHONE_CMD" <<EOF
#!/bin/bash
set -e
if [[ ! -x "$DEPLOY_SH" ]]; then
  echo "Missing deploy script: $DEPLOY_SH"
  exit 1
fi
"$DEPLOY_SH"
EOF
chmod +x "$IPHONE_CMD"
echo "Created: $IPHONE_CMD"

echo "Done. Desktop: $MAC_APP_NAME , $IPHONE_NAME"
