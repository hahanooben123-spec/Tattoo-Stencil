"""Validate aligned artist-approved pairs before a local training experiment.

Manifest paths are relative to the JSON file. Collage references are deliberately
not converted into aligned supervision by resizing their two panels.
"""
from __future__ import annotations

import hashlib
import json
import re
from pathlib import Path

import numpy as np
from PIL import Image, ImageOps


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_image(path: Path, mode: str) -> Image.Image:
    with Image.open(path) as image:
        image = ImageOps.exif_transpose(image)
        if "A" in image.getbands() or "transparency" in image.info:
            rgba = image.convert("RGBA")
            if mode == "L" and rgba.getchannel("A").getextrema() != (255, 255):
                raise ValueError("Targets must be opaque; flatten transparency on white first")
            image = Image.alpha_composite(Image.new("RGBA", image.size, "white"), rgba)
        return image.convert(mode)


def validate(manifest: Path, allow_synthetic: bool = False) -> tuple[list[dict], dict]:
    content = json.loads(manifest.read_text(encoding="utf-8"))
    if content.get("version") != 1 or not isinstance(content.get("pairs"), list):
        raise ValueError("Expected version 1 and a pairs list")
    pairs, errors, warnings = [], [], []
    groups, fingerprints, names = {}, {}, set()
    synthetic = content.get("scope") == "synthetic-smoke-only"
    if synthetic and not allow_synthetic:
        errors.append("Synthetic data is only allowed in an explicit smoke run")
    for item in content["pairs"]:
        if not isinstance(item, dict):
            errors.append("Every pair must be an object")
            continue
        name = str(item.get("name", "unnamed"))
        problems = []
        if not isinstance(item.get("name"), str) or not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_-]{0,79}", name):
            problems.append("name must be a safe single folder name (letters, digits, hyphen, underscore)")
        if name in names:
            problems.append("duplicate name")
        names.add(name)
        split, group = item.get("split"), item.get("group")
        if split not in {"train", "validation", "test"} or not isinstance(group, str) or not group:
            problems.append("requires train/validation/test split and composition-family group")
        if item.get("aligned") is not True:
            problems.append("source and available target layers are not confirmed aligned")
        if item.get("artistApproved") is not True and not synthetic:
            problems.append("target has not been approved by the artist")
        files = {}
        for key in ("source", "structure", "guides"):
            value = item.get(key)
            if key == "guides" and value is None:
                warnings.append(f"{name}: no separate guide labels; guide head is not supervised or scored on this pair")
                continue
            if not isinstance(value, str) or not (manifest.parent / value).is_file():
                problems.append(f"missing {key} file")
            else:
                files[key] = (manifest.parent / value).resolve()
        sizes, hashes, pixels = {}, {}, {}
        try:
            for key, path in files.items():
                image = load_image(path, "RGB" if key == "source" else "L")
                sizes[key], hashes[key] = image.size, digest(path)
                pixels[key] = np.asarray(image)
            if len(sizes) >= 2 and len(set(sizes.values())) != 1:
                problems.append("layer dimensions differ; do not stretch targets to match")
            if sizes and min(sizes["source"]) < 64:
                problems.append("source shorter side must be at least 64 pixels")
            for key in ("structure", "guides"):
                if key in pixels and not set(np.unique(pixels[key])).issubset({0, 255}):
                    problems.append(f"{key} must be opaque black ink on white, without gray pixels")
            if "structure" in pixels and not np.any(pixels["structure"] < 128):
                problems.append("structure target has no ink")
        except (OSError, ValueError, KeyError) as error:
            problems.append(f"image read failed: {error}")
        rois = item.get("regions", [])
        if not isinstance(rois, list):
            problems.append("regions must be a list")
            rois = []
        for roi in rois:
            bounds = roi.get("box", []) if isinstance(roi, dict) else []
            if (not isinstance(roi, dict) or not isinstance(roi.get("name"), str)
                    or len(bounds) != 4 or not all(isinstance(v, (int, float)) for v in bounds)
                    or not (0 <= bounds[0] < bounds[2] <= 1 and 0 <= bounds[1] < bounds[3] <= 1)):
                problems.append("regions need a name and normalized [left,top,right,bottom] box")
        if isinstance(group, str) and group in groups and groups[group] != split:
            problems.append("composition family occurs in multiple splits")
        if isinstance(group, str):
            groups[group] = split
        # Hash decoded RGB pixels as well as files, to catch a renamed/re-encoded
        # duplicate. Crops and redraws still require honest family grouping.
        if "source" in pixels:
            fingerprint = (sizes["source"], hashlib.sha256(pixels["source"].tobytes()).hexdigest())
            if fingerprint in fingerprints and fingerprints[fingerprint] != split:
                problems.append("same decoded source occurs in multiple splits")
            fingerprints[fingerprint] = split
        if not rois and split in {"validation", "test"}:
            warnings.append(f"{name}: no critical-region metrics (e.g. eyes/mouth) will be available")
        errors.extend(f"{name}: {problem}" for problem in problems)
        pairs.append({**item, "files": files, "hashes": hashes, "size": sizes.get("source")})
    for split in ("train", "validation"):
        if not any(item.get("split") == split for item in pairs):
            errors.append(f"At least one independent {split} composition is required")
    if not any(item.get("split") == "test" for item in pairs):
        warnings.append("No held-out test set: cannot claim generalization")
    report = {"ready": not errors, "scope": content.get("scope", "artist-pairs"),
              "pairCount": len(pairs), "errors": errors, "warnings": warnings,
              "splits": {s: sum(p.get("split") == s for p in pairs) for s in ("train", "validation", "test")},
              "pairs": [{"name": p.get("name"), "group": p.get("group"), "split": p.get("split"),
                         "size": list(p["size"]) if p["size"] else None, "sha256": p["hashes"]} for p in pairs]}
    return pairs, report


def tensors(item: dict) -> tuple[np.ndarray, np.ndarray]:
    source = np.array(load_image(item["files"]["source"], "RGB"), dtype=np.float32) / 255
    targets = np.stack([1 - np.array(load_image(item["files"][key], "L"), dtype=np.float32) / 255
                        if key in item["files"] else np.zeros(source.shape[:2], np.float32)
                        for key in ("structure", "guides")])
    return source.transpose(2, 0, 1), targets
