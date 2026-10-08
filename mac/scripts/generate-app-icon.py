"""Regenerate macOS icon assets: uv run scripts/generate-app-icon.py."""

import json
import subprocess
from pathlib import Path


def main():
    mac_dir = Path(__file__).resolve().parents[1]
    source = mac_dir / "Artwork/AppIcon.png"
    catalog = mac_dir / "FeishuChat/Assets.xcassets"
    icon_set = catalog / "AppIcon.appiconset"
    icon_set.mkdir(parents=True, exist_ok=True)
    info = {"author": "xcode", "version": 1}
    (catalog / "Contents.json").write_text(json.dumps({"info": info}, indent=2) + "\n")
    images = []
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            pixels = size * scale
            filename = f"icon_{size}x{size}@{scale}x.png"
            subprocess.run(
                ["sips", "-z", str(pixels), str(pixels), str(source), "--out", str(icon_set / filename)],
                check=True,
                stdout=subprocess.DEVNULL,
            )
            images.append({"idiom": "mac", "size": f"{size}x{size}", "scale": f"{scale}x", "filename": filename})
    (icon_set / "Contents.json").write_text(json.dumps({"images": images, "info": info}, indent=2) + "\n")


if __name__ == "__main__":
    main()
