"""Read-only asset verification. Run with Python + Pillow; does not replace XCTest."""
import hashlib
import json
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
ASSETS = ROOT / "App/Assets/Village/final"
EXPECTED = {"adam", "atlas", "milo", "noah", "theo", "eva", "luna", "iris", "nova", "saga"}


def verify():
    records = json.loads((ROOT / "docs/village-art/final-package-manifest.json").read_text())
    assert {r["file"] for r in records} == {p.name for p in ASSETS.glob("*.png")}
    for record in records:
        path = ASSETS / record["file"]
        assert hashlib.sha256(path.read_bytes()).hexdigest() == record["sha256"], path
        with Image.open(path) as image:
            assert list(image.size) == record["size"], path
            image.verify()

    atlases = json.loads((ASSETS / "characters.json").read_text())
    assert set(atlases) == EXPECTED
    total = 0
    for name, atlas in atlases.items():
        with Image.open(ASSETS / f"walk-{name}.png") as image:
            assert image.mode == "RGBA", name
            assert image.getchannel("A").getextrema() == (0, 255), name
            assert 14 <= len(atlas["rows"]) <= 16, name
            heights = []
            for row in atlas["rows"]:
                assert 6 <= len(row) <= 8, (name, len(row))
                unique = set()
                for frame in row:
                    x, y, w, h = (frame[k] for k in ("x", "y", "width", "height"))
                    assert 0 <= x < x + w <= image.width, (name, frame)
                    assert 0 <= y < y + h <= image.height, (name, frame)
                    # Read the same source region the app draws; never save modified images.
                    cell = image.crop((x, y, x + w, y + h))
                    assert cell.getchannel("A").getbbox(), (name, frame)
                    unique.add(hashlib.sha256(cell.tobytes()).digest())
                    heights.append(h)
                    total += 1
                assert len(unique) == len(row), f"Repeated trial frames: {name}"
            assert atlas["maxHeight"] == max(heights), name
            print(f"{name}: {len(atlas['rows'])} measured rows, "
                  f"{min(map(len, atlas['rows']))}-{max(map(len, atlas['rows']))} frames/row")

    for name in ("harper", "lumi"):
        with Image.open(ASSETS / f"expressions-{name}.png") as image:
            assert image.size == (1024, 1536)
            expressions = {
                hashlib.sha256(image.crop((x, y, x + 512, y + 768)).tobytes()).digest()
                for y in (0, 768) for x in (0, 512)
            }
            assert len(expressions) == 4, name
    print(f"PASS: {len(records)} assets, {len(atlases)} characters, {total} nonempty distinct walk cells.")


if __name__ == "__main__":
    verify()
