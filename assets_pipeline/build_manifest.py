"""Build the client asset inventory from the selected, project-local PNG files."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import struct


ROOT = Path(__file__).resolve().parent.parent
PIPELINE = ROOT / "assets_pipeline"
PROVENANCE_FILES = (
    "user-reference-manifest.json",
    "youth-expression-manifest.json",
    "youth-extra-manifest.json",
    "icons-manifest.json",
    "scenes-manifest.json",
    "youth-scenes-manifest.json",
    "youth-reference-sheet-manifest.json",
)


def main() -> None:
    selection = json.loads((PIPELINE / "native-resources.json").read_text(encoding="utf-8"))
    provenance = {}
    for name in PROVENANCE_FILES:
        document = json.loads((PIPELINE / name).read_text(encoding="utf-8"))
        for asset in document["assets"]:
            relative_path = asset.get("path", asset.get("file"))
            provenance[relative_path] = {**asset, "provenance_file": name}

    assets = []
    for resource_name, relative_path in selection.items():
        path = (ROOT / relative_path).resolve()
        if not path.is_relative_to(ROOT) or not path.is_file():
            raise ValueError(f"Asset must be an existing project file: {relative_path}")
        data = path.read_bytes()
        if data[:8] != b"\x89PNG\r\n\x1a\n":
            raise ValueError(f"Expected PNG: {relative_path}")
        width, height = struct.unpack(">II", data[16:24])
        asset = {
            **provenance[relative_path],
            "id": resource_name,
            "path": relative_path,
            "width": width,
            "height": height,
            "bytes": len(data),
            "sha256": hashlib.sha256(data).hexdigest(),
        }
        assets.append(asset)

    manifest = {
        "schema_version": 1,
        "status": "selected_source_assets",
        "identity_reference": "shared/assets/avatars-youth/idle_gentle.png",
        "character_reference_sheet": provenance["shared/assets/reference-youth/character-sheet.png"],
        "identity_decision": "Use the user's selected youthful Sakiko portrait from 在场: amber eyes, silvery-blue hair, soft rounded face, navy school cardigan and simple bows.",
        "generation_tool": "built-in image_gen; no paid API fallback",
        "manual_visual_review": "Each selected full-resolution asset was read back and inspected. This is source-art review, not native device or 200% edge acceptance.",
        "pending_acceptance": [
            "Integrated day/night compositing and small-size readability on the native phone",
            "Native screen resolution and @3x/@4x delivery; splash is 752x2092",
            "200% zero-white-fringe criterion and reference-lock blind review",
            "Expression switching, animation, memory and performance on the device"
        ],
        "excluded_history": "provisional-gothic-manifest.json and unselected older stickers/scenes remain as provenance; clients use only native-resources.json.",
        "assets": assets,
    }
    (PIPELINE / "asset-manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print(f"Selected {len(assets)} PNG assets, {sum(a['bytes'] for a in assets):,} bytes")


if __name__ == "__main__":
    main()
