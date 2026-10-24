"""Create procedural pairs for testing training plumbing, never tattoo quality."""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw


def create(output: Path, size=128):
    if output.exists():
        raise ValueError("Use a new directory; smoke data must not overwrite artist data")
    output.mkdir(parents=True)
    pairs = []
    for number, split in enumerate(("train", "train", "validation", "test")):
        rng = np.random.default_rng(300 + number)
        y, x = np.indices((size, size), dtype=np.float32)
        cx, cy = size * rng.uniform(0.42, 0.58, 2)
        rx, ry = size * rng.uniform(0.24, 0.34, 2)
        radius = np.sqrt(((x - cx) / rx)**2 + ((y - cy) / ry)**2)
        mass = 1 / (1 + np.exp(np.clip((radius - 1) * 30, -50, 50)))
        shade = np.clip(0.2 + 0.5 * (x / size) + 0.12 * np.sin(y / 15), 0, 0.9)
        luminance = np.clip(1 - mass * shade + rng.normal(0, 0.006, x.shape), 0, 1)
        structure, guides = Image.new("1", (size, size), 1), Image.new("1", (size, size), 1)
        draw = ImageDraw.Draw(structure)
        draw.ellipse((round(cx - rx), round(cy - ry), round(cx + rx), round(cy + ry)), outline=0, width=1)
        for delta in (-0.10, 0.10):
            ex, ey = cx + delta * size, cy - size * 0.06
            draw.ellipse((int(ex - 5), int(ey - 3), int(ex + 5), int(ey + 3)), outline=0, width=1)
            luminance[((x - ex) / 5)**2 + ((y - ey) / 3)**2 < 1] *= 0.35
        # Known geometric guide, not a claim about the correct artistic line.
        gd = ImageDraw.Draw(guides)
        for top in range(int(cy - ry * 0.5), int(cy + ry * 0.6), 9):
            gd.line((int(cx + rx * 0.35), top, int(cx + rx * 0.35), top + 3), fill=0)
        folder = output / f"sample-{number}"
        folder.mkdir()
        Image.fromarray(np.uint8(luminance * 255)).convert("RGB").save(folder / "source.png")
        structure.convert("L").save(folder / "structure.png")
        guides.convert("L").save(folder / "guides.png")
        pairs.append({"name": f"sample-{number}", "group": f"procedural-family-{number}", "split": split,
                      "source": f"sample-{number}/source.png", "structure": f"sample-{number}/structure.png",
                      "guides": f"sample-{number}/guides.png", "aligned": True, "artistApproved": False,
                      "regions": [{"name": "synthetic-detail-band", "box": [0.25, 0.25, 0.75, 0.6]}]})
    manifest = output / "pairs.json"
    manifest.write_text(json.dumps({"version": 1, "scope": "synthetic-smoke-only", "pairs": pairs}, indent=2), encoding="utf-8")
    return manifest


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    print(create(args.output))
