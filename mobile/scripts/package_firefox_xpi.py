#!/usr/bin/env python3
"""Pack firefox_blocker folder into sixvpn-blocker@sixvpnblocker.app.xpi (ZIP)."""

from __future__ import annotations

import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SRC = ROOT / "assets" / "browser_extensions" / "firefox"
OUT = (
    Path(__file__).resolve().parents[1].parent
    if False
    else Path(__file__).resolve().parents[1]
)

def main() -> int:
    src = Path(sys.argv[1]) if len(sys.argv) > 1 else DEFAULT_SRC
    dest = (
        Path(sys.argv[2])
        if len(sys.argv) > 2
        else ROOT / "build" / "sixvpn-blocker@sixvpnblocker.app.xpi"
    )
    if not src.is_dir():
        print(f"[xpi] source missing: {src}", file=sys.stderr)
        return 1
    dest.parent.mkdir(parents=True, exist_ok=True)
    if dest.exists():
        dest.unlink()
    exclude_names = {"sixvpn_blocker_signed.xpi", "signed_source_snapshot.json"}
    with zipfile.ZipFile(dest, "w", zipfile.ZIP_DEFLATED) as zf:
        for path in sorted(src.rglob("*")):
            if path.is_file() and path.name not in exclude_names:
                zf.write(path, path.relative_to(src).as_posix())
    print(f"[xpi] wrote {dest} ({dest.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
