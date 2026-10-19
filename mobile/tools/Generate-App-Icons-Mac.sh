#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOBILE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

cd "${MOBILE_ROOT}"

echo "[icons] ensuring fallback master icon..."
python3 "scripts/generate_placeholder_icon.py"

echo "[icons] flutter pub get..."
flutter pub get

echo "[icons] generating iOS + macOS app icons..."
dart run flutter_launcher_icons

echo "[icons] done."
