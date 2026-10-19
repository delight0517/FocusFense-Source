#!/usr/bin/env python3
"""Generate a fallback 1024x1024 app icon if missing.

Design persona: Warmth within Firmness.
"""

from __future__ import annotations

import sys
from pathlib import Path


def _fatal(msg: str, code: int = 1) -> int:
    print(f"[icon-gen] {msg}", file=sys.stderr)
    return code


def main() -> int:
    root = Path(__file__).resolve().parents[1]
    output = root / "assets" / "icons" / "master_icon.png"
    if output.exists():
        print(f"[icon-gen] exists, skip: {output}")
        return 0

    try:
        from PIL import Image, ImageDraw, ImageFilter
    except Exception:
        return _fatal("Pillow is required. Install with: python3 -m pip install Pillow")

    output.parent.mkdir(parents=True, exist_ok=True)

    size = 1024
    bg = (30, 30, 36, 255)  # #1E1E24
    accent = (230, 95, 43, 255)  # #E65F2B
    accent_soft = (230, 95, 43, 120)
    border = (60, 64, 74, 255)

    img = Image.new("RGBA", (size, size), bg)
    draw = ImageDraw.Draw(img, "RGBA")

    # Outer structured boundary (firmness).
    margin = 150
    corner = 140
    outer = (margin, margin, size - margin, size - margin)
    draw.rounded_rectangle(outer, radius=corner, outline=border, width=34)

    # Warm inner glow.
    glow = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    glow_draw = ImageDraw.Draw(glow, "RGBA")
    glow_draw.ellipse((340, 330, 684, 674), fill=accent_soft)
    glow = glow.filter(ImageFilter.GaussianBlur(28))
    img.alpha_composite(glow)

    # Minimal lock/shield motif (warmth inside structure).
    lock_body = (390, 470, 634, 730)
    draw.rounded_rectangle(lock_body, radius=68, fill=accent)
    draw.arc((420, 330, 604, 520), start=200, end=340, fill=accent, width=46)

    # Keyhole cutout.
    draw.ellipse((496, 552, 528, 584), fill=bg)
    draw.rounded_rectangle((504, 578, 520, 652), radius=8, fill=bg)

    # Slight inner frame accent.
    draw.rounded_rectangle((210, 210, 814, 814), radius=112, outline=(255, 255, 255, 26), width=8)

    try:
        img.convert("RGB").save(output, format="PNG")
    except Exception as exc:
        return _fatal(f"Failed to write icon: {exc}")

    print(f"[icon-gen] generated: {output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
