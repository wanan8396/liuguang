#!/usr/bin/env python3
"""Regenerate checked-in Windows/iOS brand icons (requires Pillow)."""
from __future__ import annotations

import json
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[2]
ICON = ROOT / "assets/brand/liuguang-icon.png"
MARK = ROOT / "assets/brand/liuguang-mark.png"
IOS = ROOT / "ios/Runner/Assets.xcassets"
WINDOWS_ICON = ROOT / "windows/runner/resources/app_icon.ico"


def inspect_existing(path: Path) -> None:
    if path.exists():
        with Image.open(path) as image:
            image.load()
            print(f"Replace {path.relative_to(ROOT)}: {image.format} {image.size}")


def main() -> None:
    with Image.open(ICON) as source:
        icon = source.convert("RGBA")
    with Image.open(MARK) as source:
        mark = source.convert("RGBA")

    # App Store icons must be opaque; iOS applies its own corner mask.
    opaque = Image.new("RGB", icon.size, "#102643")
    opaque.paste(icon, mask=icon.getchannel("A"))
    contents = json.loads((IOS / "AppIcon.appiconset/Contents.json").read_text(encoding="utf-8"))
    for entry in contents["images"]:
        size = round(float(entry["size"].split("x")[0]) * float(entry["scale"].rstrip("x")))
        destination = IOS / "AppIcon.appiconset" / entry["filename"]
        inspect_existing(destination)
        opaque.resize((size, size), Image.Resampling.LANCZOS).save(destination, format="PNG", optimize=True)

    for scale in (1, 2, 3):
        suffix = "" if scale == 1 else f"@{scale}x"
        destination = IOS / "LaunchImage.imageset" / f"LaunchImage{suffix}.png"
        inspect_existing(destination)
        mark.resize((168 * scale, 168 * scale), Image.Resampling.LANCZOS).save(destination, format="PNG", optimize=True)

    inspect_existing(WINDOWS_ICON)
    icon.save(WINDOWS_ICON, format="ICO", sizes=[(size, size) for size in (16, 24, 32, 48, 64, 128, 256)])
    print("Generated iOS opaque app icons, launch images and Windows multi-resolution ICO.")


if __name__ == "__main__":
    main()
