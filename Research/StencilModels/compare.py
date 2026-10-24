"""Offline CPU comparison of pretrained TEED and Informative Drawings.

No face annotations, prompts, hand tracing, or coordinate warping are used.
Postprocessing compares global thresholds with local ink-ridge extraction.
"""
from __future__ import annotations

import argparse
import ast
import hashlib
import json
import platform
import sys
import time
import types
from pathlib import Path

import cv2
import numpy as np
import torch
from PIL import Image, ImageDraw, ImageFont, ImageOps

from fetch_models import DEFAULT_ASSETS, verify_assets


def load_models(assets: Path) -> dict:
    verify_assets(assets)
    # Keep the published inference architecture; omit its unused training-metric
    # import so setup needs neither scikit-learn nor training dependencies.
    sys.path.insert(0, str(assets / "teed"))
    source = (assets / "teed/ted.py").read_text(encoding="utf-8")
    source = source.replace("from utils.img_processing import count_parameters", "")
    teed_module = types.ModuleType("stencil_teed")
    exec(compile(source, str(assets / "teed/ted.py"), "exec"), teed_module.__dict__)
    teed = teed_module.TED()
    teed.load_state_dict(torch.load(assets / "teed/model.pth", map_location="cpu", weights_only=True))
    # Extract only the upstream inference classes. Do not import torchvision's
    # training/backbone code or launch the author's online Gradio application.
    source = (assets / "drawings/model.py").read_text(encoding="utf-8")
    nodes = ast.parse(source).body
    classes = [ast.get_source_segment(source, node) for node in nodes
               if isinstance(node, ast.ClassDef) and node.name in {"ResidualBlock", "Generator"}]
    namespace = {"torch": torch, "nn": torch.nn, "norm_layer": torch.nn.InstanceNorm2d}
    exec("\n\n".join(classes), namespace)
    models = {"teed": teed.eval()}
    for name, filename in [("drawings-style1", "style1.pth"), ("drawings-style2", "style2.pth")]:
        model = namespace["Generator"](3, 1, 3)
        model.load_state_dict(torch.load(assets / "drawings" / filename, map_location="cpu", weights_only=True))
        models[name] = model.eval()
    return models


def thin(mask: np.ndarray) -> tuple[np.ndarray, int]:
    """Zhang-Suen thinning; endpoints are retained. No inferred gap filling."""
    data = np.pad(mask.astype(np.uint8), 1)
    for iteration in range(128):
        removed = 0
        for phase in (0, 1):
            p2, p3, p4 = data[:-2, 1:-1], data[:-2, 2:], data[1:-1, 2:]
            p5, p6, p7 = data[2:, 2:], data[2:, 1:-1], data[2:, :-2]
            p8, p9 = data[1:-1, :-2], data[:-2, :-2]
            neighbors = [p2, p3, p4, p5, p6, p7, p8, p9]
            count = sum(neighbors)
            turns = sum(((a == 0) & (b != 0)).astype(np.uint8)
                        for a, b in zip(neighbors, neighbors[1:] + neighbors[:1]))
            if phase == 0:
                separated = (p2*p4*p6 == 0) & (p4*p6*p8 == 0)
            else:
                separated = (p2*p4*p8 == 0) & (p2*p6*p8 == 0)
            delete = (data[1:-1, 1:-1] != 0) & (count >= 2) & (count <= 6) & (turns == 1) & separated
            removed += int(delete.sum())
            data[1:-1, 1:-1][delete] = 0
        if removed == 0:
            return data[1:-1, 1:-1], iteration + 1
    raise RuntimeError("Thinning did not converge; refusing to present an unfinished result")


def binary_stencil(confidence: np.ndarray, threshold: float) -> tuple[Image.Image, dict]:
    mask, iterations = thin(confidence >= threshold)
    count, labels, stats, _ = cv2.connectedComponentsWithStats(mask, connectivity=8)
    keep = np.zeros(count, dtype=np.uint8)
    if count > 1:
        keep[1:] = stats[1:, cv2.CC_STAT_AREA] >= 3
    selected = keep[labels]
    return Image.fromarray(np.uint8(255 - selected*255)), {
        "threshold": threshold, "minimumComponentPixels": 3, "thinningIterations": iterations,
        "retainedComponents": int(keep.sum()), "inkPixels": int(selected.sum()),
    }


def ridge_stencil(confidence: np.ndarray) -> tuple[Image.Image, dict]:
    """Follow ink-intensity ridges so faint eyes survive global thresholding.

    This uses only the model output; there are no manually supplied face regions.
    Hysteresis retains weak connected line sections with a stronger local seed.
    """
    smooth = cv2.GaussianBlur(confidence, (0, 0), 0.6)
    background = cv2.GaussianBlur(smooth, (0, 0), 3)
    salience = np.maximum(0, smooth-background)
    xx = cv2.Sobel(smooth, cv2.CV_32F, 2, 0, ksize=3)
    yy = cv2.Sobel(smooth, cv2.CV_32F, 0, 2, ksize=3)
    xy = cv2.Sobel(smooth, cv2.CV_32F, 1, 1, ksize=3)
    normal = 0.5*np.arctan2(2*xy, xx-yy)+np.pi/2
    y, x = np.indices(smooth.shape, dtype=np.float32)
    nx, ny = np.cos(normal), np.sin(normal)
    front = cv2.remap(smooth, x+nx, y+ny, cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)
    back = cv2.remap(smooth, x-nx, y-ny, cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)
    minimum_eigenvalue = 0.5*(xx+yy-np.sqrt((xx-yy)**2+4*xy**2))
    maxima = (smooth >= front) & (smooth > back) & (minimum_eigenvalue < -0.003)
    weak = maxima & (salience >= 0.008) & (smooth >= 0.035)
    local_peak = cv2.dilate(salience, np.ones((11, 11), np.uint8))
    strong = weak & (salience >= np.maximum(0.02, local_peak*0.2))
    count, labels = cv2.connectedComponents(weak.astype(np.uint8), connectivity=8)
    accepted = np.zeros(count, dtype=np.uint8)
    accepted[np.unique(labels[strong])] = 1
    accepted[0] = 0
    selected, iterations = thin(accepted[labels])
    count, labels, stats, _ = cv2.connectedComponentsWithStats(selected, connectivity=8)
    keep = np.zeros(count, dtype=np.uint8)
    keep[1:] = stats[1:, cv2.CC_STAT_AREA] >= 3
    selected = keep[labels]
    return Image.fromarray(np.uint8(255-selected*255)), {
        "method": "local ink-ridge NMS and connected hysteresis; no face annotations",
        "weakSalience": 0.008, "seedSalience": 0.02, "minimumInkConfidence": 0.035,
        "localSeedFraction": 0.2, "minimumComponentPixels": 3,
        "retainedComponents": int(keep.sum()), "inkPixels": int(selected.sum()), "thinningIterations": iterations,
    }


def infer(model, image: Image.Image, name: str) -> tuple[np.ndarray, dict]:
    rgb = np.asarray(image, dtype=np.float32)
    h, w = rgb.shape[:2]
    if name == "teed" and min(h, w) < 512:
        # Match the author's standard small-image test proposal. Restore the
        # original input coordinates after inference, without an aspect warp.
        rgb = cv2.resize(rgb,None,fx=1.5,fy=1.5,interpolation=cv2.INTER_LINEAR)
    analysis_h, analysis_w = rgb.shape[:2]
    # Reflection padding to 8-pixel blocks instead of stretching anatomy.
    padded = np.pad(rgb, ((0, (-analysis_h) % 8), (0, (-analysis_w) % 8), (0, 0)), mode="reflect")
    if name == "teed":
        values = padded[:, :, ::-1] - np.array([104.007, 116.669, 122.679], dtype=np.float32)
    else:
        values = padded / 255
    tensor = torch.from_numpy(np.ascontiguousarray(values.transpose(2, 0, 1))).unsqueeze(0)
    start = time.perf_counter()
    with torch.inference_mode():
        prediction = model(tensor)
        output = torch.sigmoid(prediction[-1]) if name == "teed" else 1-prediction
        confidence = output[0, 0, :analysis_h, :analysis_w].cpu().numpy().clip(0, 1)
        raw_range = [float(confidence.min()),float(confidence.max())]
        if name == "teed":
            # The author's save_image_batch_to_disk applies per-image min/max
            # normalization after sigmoid. Fused TEED logits use Smish and are
            # not directly calibrated edge probabilities.
            confidence = (confidence-confidence.min())/max(float(confidence.max()-confidence.min()),1e-12)
        if confidence.shape != (h,w):
            confidence = cv2.resize(confidence,(w,h),interpolation=cv2.INTER_LINEAR)
    return confidence, {
        "inferenceSecondsCPU": time.perf_counter()-start,
        "parameters": sum(p.numel() for p in model.parameters()),
        "inputWidth": w, "inputHeight": h, "paddedWidth": padded.shape[1], "paddedHeight": padded.shape[0],
        "analysisWidth": analysis_w, "analysisHeight": analysis_h,
        "confidenceMin": float(confidence.min()), "confidenceMax": float(confidence.max()),
        "rawConfidenceRange": raw_range, "normalization": "per-image min/max after sigmoid" if name == "teed" else "one minus generator output",
    }


def contact_sheet(folder: Path, image: Image.Image, labels: list[str]) -> None:
    cell_w, cell_h, header = 360, 760, 58
    sheet = Image.new("RGB", (cell_w*len(labels), cell_h+header), "#ececec")
    draw = ImageDraw.Draw(sheet)
    font = ImageFont.truetype("DejaVuSans.ttf", 15) if Path("/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf").exists() else ImageFont.load_default(size=15)
    for index, label in enumerate(labels):
        if label == "Reference":
            current = image
        elif label.startswith("Current engine"):
            current = Image.open(folder / "baseline.png")
        else:
            current = Image.open(folder / label / "stencil.png")
        preview = ImageOps.contain(current.convert("RGB"), (cell_w-16, cell_h-16))
        x = index*cell_w
        draw.text((x+10, 10), label, fill="black", font=font)
        draw.text((x+10, 30), "Local prototype / not validated", fill="#555555", font=font)
        sheet.paste(preview, (x+(cell_w-preview.width)//2, header+(cell_h-preview.height)//2))
    sheet.save(folder / "comparison.png")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("inputs", type=Path, help="JSON list: name, path, optional crop in original pixels")
    parser.add_argument("output", type=Path)
    parser.add_argument("--assets", type=Path, default=DEFAULT_ASSETS)
    parser.add_argument("--longest-side", type=int, default=768)
    parser.add_argument("--threads", type=int, default=4)
    args = parser.parse_args()
    if not 128 <= args.longest_side <= 1200 or not 1 <= args.threads <= 16:
        parser.error("Use longest-side 128..1200 and threads 1..16")
    torch.set_num_threads(args.threads)
    models = load_models(args.assets)
    report = {"scope": "Offline CPU prototype; no iPad/CoreML timing or artist validation", "torch": torch.__version__,
              "platform": platform.platform(), "threads": args.threads, "images": []}
    for item in json.loads(args.inputs.read_text(encoding="utf-8")):
        if Path(item["name"]).name != item["name"] or item["name"] in {".", ".."}:
            raise ValueError("Input names must be a single folder name")
        source = Path(item["path"])
        image = ImageOps.exif_transpose(Image.open(source)).convert("RGB")
        original_size = image.size
        if "crop" in item:
            image = image.crop(tuple(item["crop"]))
        image.thumbnail((args.longest_side, args.longest_side), Image.Resampling.LANCZOS)
        folder = args.output / item["name"]
        folder.mkdir(parents=True, exist_ok=True)
        image.save(folder / "reference.png")
        image.convert("L").save(folder / "reference.pgm")
        record = {"name": item["name"], "sourceSHA256": hashlib.sha256(source.read_bytes()).hexdigest(),
                  "originalSize": original_size, "crop": item.get("crop"), "analysisSize": image.size, "models": {}}
        for name, model in models.items():
            start = time.perf_counter()
            confidence, metrics = infer(model, image, name)
            destination = folder / name
            destination.mkdir(exist_ok=True)
            Image.fromarray(np.uint8((1-confidence)*255)).save(destination / "raw.png")
            np.savez_compressed(destination / "confidence.npz", confidence=confidence)
            default = 0.2 if name == "teed" else 0.5
            for threshold in sorted({default, 0.15, 0.35, 0.65}):
                stencil, settings = binary_stencil(confidence, threshold)
                stencil.save(destination / f"threshold-{threshold:.2f}.png")
                if threshold == default:
                    stencil.save(destination / "global-threshold-default.png")
                    metrics["globalThresholdDefault"] = settings
            stencil, settings = ridge_stencil(confidence)
            stencil.save(destination / "stencil.png")
            metrics["postprocess"] = settings
            metrics["inferenceAndOutputsSeconds"] = time.perf_counter()-start
            record["models"][name] = metrics
            print(item["name"], name, round(metrics["inferenceSecondsCPU"], 3), metrics["postprocess"], flush=True)
        report["images"].append(record)
        labels = ["Reference"] + (["Current engine (no Vision)"] if (folder / "baseline.png").is_file() else []) + list(models)
        contact_sheet(folder, image, labels)
        (args.output / "report.json").write_text(json.dumps(report, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
