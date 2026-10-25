"""Prepare provisional collage pairs using reviewed similarity transforms only.

Does not declare alignment exact or targets artist-approved. A separate explicit
training mode is required for these noisy-label experiments. Never ships a model.
"""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

import cv2
import numpy as np
from PIL import Image

from training_data import digest, load_image


def checked_similarity(matrix):
    matrix = np.asarray(matrix, dtype=np.float64)
    if matrix.shape != (2, 3) or not np.isfinite(matrix).all():
        raise ValueError("Expected a finite 2 x 3 similarity matrix")
    a, minus_b, _ = matrix[0]
    b, second_a, _ = matrix[1]
    if abs(a - second_a) > 1e-6 or abs(minus_b + b) > 1e-6:
        raise ValueError("Only uniform scale, rotation and translation are allowed")
    scale = math.hypot(a, b)
    angle = math.degrees(math.atan2(b, a))
    if not 0.1 <= scale <= 10 or abs(angle) > 15:
        raise ValueError("Scale/rotation implausible for these upright reference panels")
    return matrix


def register_target(target, matrix, width, height, threshold=200):
    """3x coverage sampling retains thin downscaled lines; no gap filling.

    Coverage can thicken a label by one native pixel. These are explicitly noisy
    training labels, not exact geometry ground truth. No target line is redrawn.
    """
    matrix = checked_similarity(matrix)
    ink = (np.asarray(target) < threshold).astype(np.uint8)
    high_matrix = matrix * 3
    high_matrix[:, 2] += 1  # Match the centers of each 3 x 3 output-pixel block.
    high = cv2.warpAffine(ink, high_matrix, (width * 3, height * 3),
                          flags=cv2.INTER_NEAREST, borderValue=0)
    ink = high.reshape(height, 3, width, 3).max(axis=(1, 3))
    return np.uint8(255 - ink * 255)


def overlaps(first, second):
    return max(first[0], second[0]) < min(first[2], second[2]) and max(first[1], second[1]) < min(first[3], second[3])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("configuration", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    config = json.loads(args.configuration.read_text(encoding="utf-8"))
    if args.output.exists():
        parser.error("Use a new output directory")
    entries = []
    for pair in config["pairs"]:
        if overlaps(pair["sourceCrop"], pair["targetCrop"]):
            raise ValueError("Overlapping collage crops can leak stencil pixels into the model input")
        checked_similarity(pair["matrix"])
        if pair.get("reviewed") is not True:
            raise ValueError("Overlay must be visually inspected before preparing a provisional pair")
        if Path(pair["name"]).name != pair["name"] or pair["name"] in {".", ".."}:
            raise ValueError("Unsafe pair name")
    args.output.mkdir(parents=True)
    for pair in config["pairs"]:
        path = (args.configuration.parent / pair["path"]).resolve()
        original = load_image(path, "RGB")
        source = original.crop(pair["sourceCrop"])
        target = original.crop(pair["targetCrop"]).convert("L")
        registered = register_target(target, pair["matrix"], *source.size)
        folder = args.output / pair["name"]
        folder.mkdir()
        source.save(folder / "source.png")
        target.save(folder / "target-panel.png")
        Image.fromarray(registered).save(folder / "structure.png")
        overlay = np.array(source).copy()
        selected = registered == 0
        overlay[selected] = (overlay[selected] * 0.25 + np.array([255, 0, 0]) * 0.75).astype(np.uint8)
        Image.fromarray(overlay).save(folder / "alignment-overlay.png")
        entries.append({"name": pair["name"], "group": pair["name"], "split": pair["split"],
                        "source": f"{pair['name']}/source.png", "structure": f"{pair['name']}/structure.png",
                        "guides": None, "aligned": False, "artistApproved": False,
                        "targetProvidedAsExample": True,
                        "alignmentEstimate": {"method": "reviewed-similarity", "reviewed": True,
                                              "matrix": pair["matrix"], "uncertainty": "not exact ground truth"},
                        "regions": pair.get("regions", []),
                        "provenance": {"originalSHA256": digest(path), "sourceCrop": pair["sourceCrop"],
                                       "targetCrop": pair["targetCrop"], "targetThreshold": 200,
                                       "coverageSampling": 3, "registrationNotes": pair.get("notes", "")}})
    (args.output / "pairs.json").write_text(json.dumps({"version": 1,
        "scope": "provisional-registered-collages", "pairs": entries}, indent=2), encoding="utf-8")
    print(args.output / "pairs.json")


if __name__ == "__main__":
    main()
