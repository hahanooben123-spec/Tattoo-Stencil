"""Evaluate a frozen pilot checkpoint; no optimizer or checkpoint selection."""
import argparse
import json
from pathlib import Path

import torch

from fetch_models import DEFAULT_ASSETS
from train_pilot import evaluate, model_from_assets, regressions
from training_data import digest, validate


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("experiment", type=Path)
    parser.add_argument("manifest", type=Path)
    parser.add_argument("output", type=Path)
    parser.add_argument("--assets", type=Path, default=DEFAULT_ASSETS)
    parser.add_argument("--split", choices=("validation", "test"), default="test")
    parser.add_argument("--synthetic-smoke", action="store_true")
    args = parser.parse_args()
    report = json.loads((args.experiment / "experiment.json").read_text(encoding="utf-8"))
    checkpoint = args.experiment / "candidate.pt"
    if digest(checkpoint) != report["candidateSHA256"] or digest(args.manifest) != report["manifestSHA256"]:
        parser.error("Checkpoint or manifest changed since training; do not silently reuse test results")
    if digest(args.assets / "drawings/style1.pth") != report["baseWeightsSHA256"]:
        parser.error("Base weights differ from the training run")
    pairs, readiness = validate(args.manifest, args.synthetic_smoke)
    if not readiness["ready"]:
        parser.error("Pair validation failed: " + "; ".join(readiness["errors"]))
    training_data = json.loads((args.experiment / "data-readiness.json").read_text(encoding="utf-8"))
    if readiness["pairs"] != training_data["pairs"]:
        parser.error("Source/target files or split provenance changed since training")
    selection = [p for p in pairs if p["split"] == args.split]
    if not selection:
        parser.error("No pairs in selected split")
    if args.output.exists():
        parser.error("Output directory already exists")
    torch.set_num_threads(report["threads"])
    model = model_from_assets(args.assets)
    baseline = evaluate(model, selection, args.output / "baseline", report["patchSize"])
    model.load_state_dict(torch.load(checkpoint, map_location="cpu", weights_only=True))
    results = evaluate(model, selection, args.output / "candidate", report["patchSize"])
    (args.output / "frozen-evaluation.json").write_text(json.dumps({
        "scope": readiness["scope"], "qualityAccepted": False, "checkpointSHA256": digest(checkpoint),
        "manifestSHA256": digest(args.manifest), "split": args.split,
        "threshold": 0.5, "tolerancePixels": 1.5, "baseline": baseline, "candidate": results,
        "diagnosticRegressions": regressions(baseline, results)}, indent=2), encoding="utf-8")
    print(f"Frozen {args.split} evaluation saved. Not artist approval.")


if __name__ == "__main__":
    main()
