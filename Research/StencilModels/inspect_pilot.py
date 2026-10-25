"""Source-coordinate before/after pictures only; no scoring or line repairs."""
import argparse
import json
import time
from pathlib import Path

import numpy as np
import torch
from PIL import Image, ImageDraw, ImageFont, ImageOps

from fetch_models import DEFAULT_ASSETS
from train_pilot import model_from_assets, tiled_prediction
from training_data import digest, load_image


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("experiment", type=Path)
    parser.add_argument("inputs", type=Path)
    parser.add_argument("--assets", type=Path, default=DEFAULT_ASSETS)
    args = parser.parse_args()
    report = json.loads((args.experiment / "experiment.json").read_text(encoding="utf-8"))
    readiness = json.loads((args.experiment / "data-readiness.json").read_text(encoding="utf-8"))
    checkpoint = args.experiment / "candidate.pt"
    if digest(checkpoint) != report["candidateSHA256"]:
        parser.error("Checkpoint changed")
    output = args.experiment / "visual-only"
    if output.exists():
        parser.error("Visual outputs already exist")
    torch.set_num_threads(report["threads"])
    base = model_from_assets(args.assets).eval()
    candidate = model_from_assets(args.assets).eval()
    candidate.load_state_dict(torch.load(checkpoint, map_location="cpu", weights_only=True))
    train_hashes = {p["sha256"]["source"] for p in readiness["pairs"] if p["split"] == "train"}
    for item in json.loads(args.inputs.read_text(encoding="utf-8")):
        name = item["name"]
        if Path(name).name != name or name in {".", ".."}:
            raise ValueError("Unsafe input name")
        source_path = (args.inputs.parent / item["source"]).resolve()
        target_path = (args.inputs.parent / item["target"]).resolve()
        folder = output / name
        folder.mkdir(parents=True)
        image = load_image(source_path, "RGB")
        image.save(folder / "source.png")
        load_image(target_path, "RGB").save(folder / "target-reference.png")
        source = np.array(image, dtype=np.float32).transpose(2, 0, 1) / 255
        metadata = {"note": item["note"], "scored": False, "qualityAccepted": False,
                    "usedForTraining": digest(source_path) in train_hashes,
                    "sourceSHA256": digest(source_path), "targetSHA256": digest(target_path),
                    "checkpointSHA256": digest(checkpoint), "tileSize": report["patchSize"],
                    "overlap": 32, "threshold": 0.5, "secondsCPU": {}}
        for label, model in (("before", base), ("after", candidate)):
            start = time.perf_counter()
            ink = tiled_prediction(model, source, report["patchSize"])[0]
            metadata["secondsCPU"][label] = time.perf_counter() - start
            if not np.isfinite(ink).all():
                raise ValueError("Non-finite model output")
            Image.fromarray(np.uint8((1 - ink) * 255)).save(folder / f"{label}-raw.png")
            Image.fromarray(np.where(ink >= 0.5, 0, 255).astype(np.uint8)).save(folder / f"{label}-black.png")
            np.savez_compressed(folder / f"{label}-confidence.npz", confidence=ink)
        (folder / "metadata.json").write_text(json.dumps(metadata, indent=2), encoding="utf-8")
        sheet = Image.new("RGB", (1600, 435), "#eeeeee")
        draw, font = ImageDraw.Draw(sheet), ImageFont.load_default(size=20)
        for i, (filename, label) in enumerate((("source.png", "Source"), ("target-reference.png", "Example stencil"),
                                              ("before-black.png", "Before training"), ("after-black.png", "After training"))):
            preview = ImageOps.contain(Image.open(folder / filename).convert("RGB"), (390, 370))
            draw.text((i * 400 + 8, 8), label, font=font, fill="black")
            sheet.paste(preview, (i * 400 + (400 - preview.width) // 2, 50 + (370 - preview.height) // 2))
        sheet.save(folder / "comparison.png")
        print(name, "saved", flush=True)


if __name__ == "__main__":
    main()
