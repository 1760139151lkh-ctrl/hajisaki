"""Make the light web copies of her stickers and scene art used inside the phone app.

The large PNG masters in shared/assets stay the source (the iPad catalog uses them directly).
The phone shows them at small sizes, so it gets WebP copies:
  shared/assets/stickers-web  360 px stickers (快去睡觉 / 交给我吧 / 勉强夸你一句)
  shared/assets/scenes-web    the rainy piano room (offline), the streetlamp (no search results),
                              and the journal cover (memories)
Re-run after changing a master:  python assets_pipeline/web_art.py
"""
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "shared/assets"
COPIES = {
    "stickers-web/sleep.webp": ("stickers-youth/go-to-sleep.png", 360),
    "stickers-web/trust.webp": ("stickers-youth/leave-it-to-me.png", 360),
    "stickers-web/praise.webp": ("stickers-youth/reluctant-praise-v2.png", 360),
    "scenes-web/rainy-room.webp": ("scenes/rainy-piano-room.png", 1000),
    "scenes-web/streetlamp.webp": ("scenes/search-no-results-youth.png", 480),
    "scenes-web/journal.webp": ("scenes/weekly-journal-cover.png", 300),
}


def main() -> None:
    for target, (source, edge) in COPIES.items():
        image = Image.open(ASSETS / source)
        image = image.convert("RGBA" if image.mode in ("RGBA", "LA", "P") else "RGB")
        image.thumbnail((edge, edge), Image.LANCZOS)
        path = ASSETS / target
        path.parent.mkdir(exist_ok=True)
        image.save(path, "WEBP", quality=86, method=6)
        print(target, image.size, path.stat().st_size, "bytes")


if __name__ == "__main__":
    main()
