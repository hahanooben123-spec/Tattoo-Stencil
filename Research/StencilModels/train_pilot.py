"""Bounded CPU fine-tuning pilot with separate structure/guide heads.

No downloads or paid compute. Refuses unaligned/unapproved artist pairs. A
synthetic smoke run establishes plumbing only, never tattoo-stencil quality.
"""
from __future__ import annotations

import argparse
import ast
import json
import random
import time
from pathlib import Path

import cv2
import numpy as np
import torch
from PIL import Image
from torch import nn

from fetch_models import DEFAULT_ASSETS, verify_assets
from training_data import digest, tensors, validate


class StencilModel(nn.Module):
    def __init__(self, generator):
        super().__init__()
        self.backbone = nn.Sequential(generator.model0, generator.model1,
                                      generator.model2, generator.model3)
        self.structure = generator.model4
        self.guides = nn.Sequential(nn.ReflectionPad2d(3), nn.Conv2d(64, 1, 7), nn.Sigmoid())
        # Start with no confident guides. This head has never seen tattoo targets.
        nn.init.zeros_(self.guides[1].weight)
        nn.init.constant_(self.guides[1].bias, -4)

    def forward(self, source):
        features = self.backbone(source)
        return torch.cat((1 - self.structure(features), self.guides(features)), dim=1)


def model_from_assets(assets: Path) -> StencilModel:
    verify_assets(assets)
    source = (assets / "drawings/model.py").read_text(encoding="utf-8")
    classes = [ast.get_source_segment(source, node) for node in ast.parse(source).body
               if isinstance(node, ast.ClassDef) and node.name in {"ResidualBlock", "Generator"}]
    namespace = {"torch": torch, "nn": nn, "norm_layer": nn.InstanceNorm2d}
    exec("\n\n".join(classes), namespace)
    generator = namespace["Generator"](3, 1, 3)
    generator.load_state_dict(torch.load(assets / "drawings/style1.pth", map_location="cpu", weights_only=True))
    return StencilModel(generator)


def balanced_loss(prediction, target, supervised=None):
    """Per-layer ink/background BCE plus soft Dice; blank guides are valid.

    Loss is a training surrogate. It does not establish acceptable anatomy or
    replace critical-region overlays and artist review.
    """
    prediction = prediction.clamp(1e-5, 1 - 1e-5)
    positive = target.sum(dim=(0, 2, 3))
    negative = (1 - target).sum(dim=(0, 2, 3))
    positive_loss = -(target * prediction.log()).sum(dim=(0, 2, 3)) / positive.clamp_min(1)
    negative_loss = -((1 - target) * (1 - prediction).log()).sum(dim=(0, 2, 3)) / negative.clamp_min(1)
    bce = 0.5 * (positive_loss + negative_loss)
    intersection = (prediction * target).sum(dim=(0, 2, 3))
    dice = 1 - (2 * intersection + 1) / (prediction.sum(dim=(0, 2, 3)) + positive + 1)
    if supervised is None:
        supervised = torch.ones_like(dice)
    return ((bce + 0.5 * dice) * supervised).sum() / supervised.sum().clamp_min(1)


def crop_pair(source, targets, size, rng, regions):
    _, height, width = source.shape
    if regions and rng.random() < 0.5:
        box = rng.choice(regions)["box"]
        cx, cy = (box[0] + box[2]) * width / 2, (box[1] + box[3]) * height / 2
    else:
        cx, cy = rng.uniform(0, width), rng.uniform(0, height)
    left = max(0, min(max(0, width - size), int(cx - size / 2)))
    top = max(0, min(max(0, height - size), int(cy - size / 2)))
    source, targets = source[:, top:top + size, left:left + size], targets[:, top:top + size, left:left + size]
    padding = ((0, 0), (0, size - source.shape[1]), (0, size - source.shape[2]))
    # White source; zero ink in both targets. Never stretch paired geometry.
    return (np.pad(source, padding, constant_values=1), np.pad(targets, padding, constant_values=0))


def metrics(prediction: np.ndarray, target: np.ndarray, tolerance=1.5) -> dict:
    selected, actual = prediction >= 0.5, target >= 0.5
    nselected, nactual = int(selected.sum()), int(actual.sum())
    if not nactual:
        return {"targetInkPixels": 0, "predictedInkPixels": nselected,
                "precision": 1.0 if not nselected else 0.0, "recall": None, "f1": None}
    to_target = cv2.distanceTransform((~actual).astype(np.uint8), cv2.DIST_L2, 5)
    to_prediction = (cv2.distanceTransform((~selected).astype(np.uint8), cv2.DIST_L2, 5)
                     if nselected else np.full(actual.shape, np.inf))
    precision = float((to_target[selected] <= tolerance).mean()) if nselected else 0.0
    recall = float((to_prediction[actual] <= tolerance).mean())
    return {"targetInkPixels": nactual, "predictedInkPixels": nselected,
            "precision": precision, "recall": recall,
            "f1": 2 * precision * recall / max(precision + recall, 1e-12)}


def tiled_prediction(model, source, tile=256, overlap=32) -> np.ndarray:
    """Bounded memory evaluation in native coordinates; no geometric resizing.

    Context-dependent tile seams remain possible and are visible in exports.
    This is not an iPad execution strategy or a measured latency optimization.
    """
    _, height, width = source.shape
    output, weights = np.zeros((2, height, width), np.float32), np.zeros((height, width), np.float32)
    def starts(size):
        return sorted(set(list(range(0, max(1, size - tile + 1), tile - overlap)) + [max(0, size - tile)]))
    window = np.maximum(np.outer(np.hanning(tile), np.hanning(tile)), 0.01).astype(np.float32)
    with torch.inference_mode():
        for top in starts(height):
            for left in starts(width):
                patch = source[:, top:top + tile, left:left + tile]
                h, w = patch.shape[1:]
                patch = np.pad(patch, ((0, 0), (0, tile - h), (0, tile - w)), constant_values=1)
                ink = model(torch.from_numpy(patch.copy())[None])[0, :, :h, :w].numpy()
                output[:, top:top + h, left:left + w] += ink * window[:h, :w]
                weights[top:top + h, left:left + w] += window[:h, :w]
    return output / weights


def evaluate(model, pairs, output, tile):
    model.eval()
    results = []
    for pair in pairs:
        source, target = tensors(pair)
        ink = tiled_prediction(model, source, tile)
        destination = output / pair["name"]
        destination.mkdir(parents=True, exist_ok=True)
        Image.fromarray(np.uint8(source.transpose(1, 2, 0) * 255)).save(destination / "source.png")
        item = {"name": pair["name"], "group": pair["group"], "split": pair["split"], "layers": {}}
        for layer, name in enumerate(("structure", "guides")):
            Image.fromarray(np.uint8((1 - ink[layer]) * 255)).save(destination / f"{name}-raw.png")
            Image.fromarray(np.where(ink[layer] >= 0.5, 0, 255).astype(np.uint8)).save(destination / f"{name}-black.png")
            if name not in pair["files"]:
                item["layers"][name] = {"supervised": False, "note": "No guide target; not scored"}
                continue
            Image.fromarray(np.uint8((1 - target[layer]) * 255)).save(destination / f"{name}-target.png")
            overlay = np.repeat(np.full((*target.shape[1:], 1), 255, np.uint8), 3, axis=2)
            overlay[target[layer] >= 0.5] = [220, 40, 50]
            overlay[ink[layer] >= 0.5] = [0, 120, 200]
            overlay[(target[layer] >= 0.5) & (ink[layer] >= 0.5)] = [0, 0, 0]
            Image.fromarray(overlay).save(destination / f"{name}-overlay.png")
            score = {"supervised": True, "fullImage": metrics(ink[layer], target[layer]), "regions": {}}
            for region in pair.get("regions", []):
                height, width = target.shape[1:]
                left, top, right, bottom = region["box"]
                ys, xs = slice(int(top * height), max(int(top * height) + 1, int(bottom * height))), slice(int(left * width), max(int(left * width) + 1, int(right * width)))
                score["regions"][region["name"]] = metrics(ink[layer, ys, xs], target[layer, ys, xs])
            item["layers"][name] = score
        np.savez_compressed(destination / "confidence.npz", structure=ink[0], guides=ink[1])
        results.append(item)
    return results


def regressions(baseline, candidate):
    """Flag layer/region regressions separately; do not hide a lost eye in a mean.

    No regressions is not an acceptance criterion. Artist review is still needed.
    """
    problems = []
    for before, after in zip(baseline, candidate):
        for layer, first in before["layers"].items():
            if not first.get("supervised"):
                continue
            second = after["layers"][layer]
            regions = [("full-image", first["fullImage"], second["fullImage"])]
            regions += [(key, value, second["regions"][key]) for key, value in first["regions"].items()]
            for region, a, b in regions:
                location = f"{before['name']}/{layer}/{region}"
                if b["targetInkPixels"] and b["predictedInkPixels"] == 0:
                    problems.append(f"{location}: target ink is entirely missing")
                for score in ("precision", "recall", "f1"):
                    if a[score] is not None and b[score] is not None and b[score] < a[score] - 1e-6:
                        problems.append(f"{location}: {score} decreased ({a[score]:.4f} -> {b[score]:.4f})")
    return problems


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--assets", type=Path, default=DEFAULT_ASSETS)
    parser.add_argument("--steps", type=int, default=50)
    parser.add_argument("--patch-size", type=int, default=256)
    parser.add_argument("--threads", type=int, default=4)
    parser.add_argument("--seed", type=int, default=73)
    parser.add_argument("--adaptation", choices=("full", "head-only"), default="full")
    parser.add_argument("--synthetic-smoke", action="store_true")
    parser.add_argument("--provisional-pairs", action="store_true",
                        help="Noisy-label experiment only; not exact registration or quality validation")
    parser.add_argument("--check-only", action="store_true")
    args = parser.parse_args()
    if not (1 <= args.steps <= 2000 and 64 <= args.patch_size <= 512 and args.patch_size % 8 == 0
            and 1 <= args.threads <= 16):
        parser.error("steps: 1..2000; patch-size: multiple of 8 in 64..512; threads: 1..16")
    pairs, readiness = validate(args.manifest, args.synthetic_smoke, args.provisional_pairs)
    if args.output.exists():
        parser.error("Output directory already exists; use a new experiment name")
    args.output.mkdir(parents=True)
    (args.output / "data-readiness.json").write_text(json.dumps(readiness, indent=2), encoding="utf-8")
    if args.check_only or not readiness["ready"]:
        print(json.dumps(readiness, indent=2))
        if not readiness["ready"]:
            raise SystemExit(2)
        return
    torch.set_num_threads(args.threads)
    torch.manual_seed(args.seed)
    torch.use_deterministic_algorithms(True)
    rng = random.Random(args.seed)
    model = model_from_assets(args.assets)
    if args.adaptation == "head-only":
        model.backbone.requires_grad_(False)
    validation = [p for p in pairs if p["split"] == "validation"]
    baseline = evaluate(model, validation, args.output / "baseline", args.patch_size)
    training = [(p, *tensors(p)) for p in pairs if p["split"] == "train"]
    optimizer = torch.optim.Adam([
        {"params": list(model.backbone.parameters()) + list(model.structure.parameters()), "lr": 1e-5},
        {"params": model.guides.parameters(), "lr": 1e-4}])
    losses = []
    start = time.perf_counter()
    model.train()
    for step in range(args.steps):
        pair, source, target = training[step % len(training)]
        source, target = crop_pair(source, target, args.patch_size, rng, pair.get("regions", []))
        optimizer.zero_grad(set_to_none=True)
        prediction = model(torch.from_numpy(source.copy())[None])
        supervised = torch.tensor([1., float("guides" in pair["files"])])
        loss = balanced_loss(prediction, torch.from_numpy(target.copy())[None], supervised)
        if not torch.isfinite(loss):
            raise RuntimeError("Non-finite loss; no candidate checkpoint saved")
        loss.backward()
        nn.utils.clip_grad_norm_(model.parameters(), 1, error_if_nonfinite=True)
        optimizer.step()
        losses.append(float(loss.detach()))
        if step == 0 or (step + 1) % 10 == 0 or step + 1 == args.steps:
            print(f"step {step + 1}/{args.steps} loss={losses[-1]:.5f}", flush=True)
    elapsed = time.perf_counter() - start
    checkpoint = args.output / "candidate.pt"
    torch.save(model.state_dict(), checkpoint)
    candidate = evaluate(model, validation, args.output / "candidate", args.patch_size)
    report = {"scope": readiness["scope"], "qualityAccepted": False,
              "qualityEligible": readiness["qualityEligible"],
              "adaptation": args.adaptation,
              "trainableParameters": sum(p.numel() for p in model.parameters() if p.requires_grad),
              "statement": "Metrics are geometry diagnostics, not artist approval. Test set was not evaluated.",
              "seed": args.seed, "steps": args.steps, "patchSize": args.patch_size,
              "threads": args.threads, "learningRate": {"pretrained": 1e-5, "newGuideHead": 1e-4},
              "trainingSecondsCPU": elapsed,
              "guideSupervisionPairs": sum("guides" in p["files"] for p, _, _ in training),
              "torch": torch.__version__, "manifestSHA256": digest(args.manifest),
              "baseWeightsSHA256": digest(args.assets / "drawings/style1.pth"),
              "candidateSHA256": digest(checkpoint), "losses": losses,
              "diagnosticRegressions": regressions(baseline, candidate), "testWasEvaluated": False,
              "evaluation": {"threshold": 0.5, "tolerancePixels": 1.5,
                             "nativeCoordinates": True, "tileOverlap": 32},
              "baseline": baseline, "candidate": candidate}
    (args.output / "experiment.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(f"Saved {checkpoint}. Candidate is NOT artist-approved.")


if __name__ == "__main__":
    main()
