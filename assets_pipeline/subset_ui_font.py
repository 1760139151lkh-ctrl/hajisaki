"""Build the two small typefaces both clients use for Saki's voice.

Sources (both SIL Open Font License 1.1):
- Noto Serif SC Medium — https://github.com/notofonts/noto-cjk/tree/main/Serif/SubsetOTF/SC
- Pinyon Script — https://github.com/google/fonts/tree/main/ofl/pinyonscript (Latin signatures only)

The subset keeps ASCII, common CJK punctuation, the 3,755 GB2312 level-1
characters, and every non-ASCII character that appears in the client sources,
so fixed UI copy never falls back to another font. Re-run after adding UI text:

    python -m pip install fonttools brotli
    python assets_pipeline/subset_ui_font.py path/to/NotoSerifSC-Medium.otf path/to/PinyonScript-Regular.ttf

Outputs:
    studio/src/fonts/haji-serif.woff2, haji-script.woff2          (phone, desktop console)
    ipad/App/Resources/Renderer/fonts/HajiSerif-Medium.otf, HajiScript.ttf (iPad, registered at launch)
    ...plus the licences next to each copy.
"""
from __future__ import annotations

import pathlib
import shutil
import sys

from fontTools import subset

ROOT = pathlib.Path(__file__).resolve().parents[1]
SOURCES = [
    *ROOT.glob("studio/src/*.ts"),
    ROOT / "studio/index.html",
    *ROOT.glob("ipad/App/Sources/**/*.swift"),
]
WEB_OUT = ROOT / "studio/src/fonts/haji-serif.woff2"
IPAD_OUT = ROOT / "ipad/App/Resources/Renderer/fonts/HajiSerif-Medium.otf"
SCRIPT_WEB_OUT = ROOT / "studio/src/fonts/haji-script.woff2"
SCRIPT_IPAD_OUT = ROOT / "ipad/App/Resources/Renderer/fonts/HajiScript.ttf"
LATIN = "".join(chr(c) for c in range(0x20, 0x7F)) + "’‘“”–—…·♥"


def gb2312_level1() -> set[str]:
    chars = set()
    for high in range(0xB0, 0xD8):
        for low in range(0xA1, 0xFF):
            try:
                chars.add(bytes([high, low]).decode("gb2312"))
            except UnicodeDecodeError:
                pass
    return chars


def wanted() -> str:
    chars = {chr(c) for c in range(0x20, 0x7F)}
    chars |= {chr(c) for c in range(0x3000, 0x3040)}  # CJK symbols and punctuation
    chars |= {chr(c) for c in range(0xFF01, 0xFF5F)}  # full-width forms
    chars |= set("·—–…‘’“”•※♡♥")
    chars |= gb2312_level1()
    for path in SOURCES:
        chars |= {ch for ch in path.read_text(encoding="utf-8") if ord(ch) > 0x7F and not ch.isspace()}
    return "".join(sorted(chars))


def build(source: pathlib.Path, target: pathlib.Path, flavor: str | None, text: str | None = None, licence_name: str = "OFL.txt") -> None:
    options = subset.Options()
    options.flavor = flavor
    options.layout_features = ["*"]
    options.name_IDs = ["*"]
    options.name_languages = ["*"]
    options.notdef_outline = True
    options.hinting = False
    font = subset.load_font(str(source), options)
    subsetter = subset.Subsetter(options)
    subsetter.populate(text=text if text is not None else wanted())
    subsetter.subset(font)
    target.parent.mkdir(parents=True, exist_ok=True)
    subset.save_font(font, str(target), options)
    for candidate in (source.with_name("LICENSE"), source.with_name("OFL-Pinyon.txt"), source.with_name("OFL.txt")):
        if candidate.is_file() and (candidate.name == "LICENSE") == (licence_name == "OFL.txt"):
            shutil.copyfile(candidate, target.parent / licence_name)
            break
    print(f"{target.relative_to(ROOT)}: {target.stat().st_size:,} bytes")


def main() -> None:
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    serif, script = (pathlib.Path(value).resolve() for value in sys.argv[1:3])
    build(serif, WEB_OUT, "woff2")
    build(serif, IPAD_OUT, None)
    build(script, SCRIPT_WEB_OUT, "woff2", LATIN, "OFL-Pinyon.txt")
    build(script, SCRIPT_IPAD_OUT, None, LATIN, "OFL-Pinyon.txt")


if __name__ == "__main__":
    main()
