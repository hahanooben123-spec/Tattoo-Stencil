"""Cached-model-output to source-coordinate curves and separate shadow guides.

No inference, downloads, face annotations, or gap filling. Outputs are a research
candidate, not tattoo-ready validation. All rendered strokes are opaque black.
"""
from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

import cv2
import numpy as np
from PIL import Image, ImageDraw, ImageFont, ImageOps

from compare import thin


def checked(values: np.ndarray) -> np.ndarray:
    values = np.asarray(values, dtype=np.float32)
    if values.ndim != 2 or min(values.shape) < 8 or not np.isfinite(values).all():
        raise ValueError("Expected a finite 2D image at least 8 x 8")
    if values.min() < 0 or values.max() > 1:
        raise ValueError("Image values must be in [0, 1]")
    return values


def connected_seed_mask(weak: np.ndarray, strong: np.ndarray, minimum: int) -> np.ndarray:
    count, labels, stats, _ = cv2.connectedComponentsWithStats(weak.astype(np.uint8), 8)
    keep = np.zeros(count, dtype=np.uint8)
    keep[np.unique(labels[strong & weak])] = 1
    keep[stats[:, cv2.CC_STAT_AREA] < minimum] = 0
    keep[0] = 0
    return keep[labels]


def structure_mask(confidence: np.ndarray) -> np.ndarray:
    """Follow supported ink crests with a tolerance for sampling at bends.

    A faint section can survive only inside an existing supported ribbon with a
    stronger seed. No morphological closing connects unrelated lines.
    """
    ink = cv2.GaussianBlur(checked(confidence), (0, 0), 0.55)
    prominence = np.maximum(0, ink - cv2.GaussianBlur(ink, (0, 0), 3))
    # A bright section can raise a Gaussian background estimate above its faint
    # continuation. A narrow-ribbon top-hat keeps that existing continuation
    # eligible without adding pixels across white gaps.
    ribbon = ink - cv2.morphologyEx(ink, cv2.MORPH_OPEN,
                                   cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (7, 7)))
    peak = cv2.dilate(prominence, np.ones((11, 11), np.uint8))
    xx = cv2.Sobel(ink, cv2.CV_32F, 2, 0, ksize=3)
    yy = cv2.Sobel(ink, cv2.CV_32F, 0, 2, ksize=3)
    xy = cv2.Sobel(ink, cv2.CV_32F, 1, 1, ksize=3)
    normal = 0.5 * np.arctan2(2 * xy, xx - yy) + np.pi / 2
    y, x = np.indices(ink.shape, dtype=np.float32)
    nx, ny = np.cos(normal), np.sin(normal)
    front = cv2.remap(ink, x + nx, y + ny, cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)
    back = cv2.remap(ink, x - nx, y - ny, cv2.INTER_LINEAR, borderMode=cv2.BORDER_REPLICATE)
    eigenvalue = 0.5 * (xx + yy - np.sqrt((xx - yy)**2 + 4 * xy**2))
    crest = (ink >= np.maximum(front, back) - 0.003) & (eigenvalue < -0.003)
    horizontal = cv2.dilate(ink, np.array([[1, 0, 1]], np.uint8))
    vertical = cv2.dilate(ink, np.array([[1], [0], [1]], np.uint8))
    hmin = cv2.erode(ink, np.array([[1, 0, 1]], np.uint8))
    vmin = cv2.erode(ink, np.array([[1], [0], [1]], np.uint8))
    cross_maximum = ((ink >= horizontal) & (ink > hmin)) | ((ink >= vertical) & (ink > vmin))
    ordinary = prominence >= np.maximum(0.007, peak * 0.12)
    # Rescue only the crest of a faint narrow stroke, never its whole support
    # ribbon: broad rescue regions create ladder-like skeleton artifacts.
    rescue = ~ordinary & cross_maximum & (ribbon >= np.maximum(0.012, peak * 0.12))
    weak = (ink >= 0.035) & ((ordinary & crest) | rescue)
    strong = weak & (prominence >= np.maximum(0.018, peak * 0.28))
    mask = connected_seed_mask(weak, strong, 3)
    return thin(mask)[0]


def trace(mask: np.ndarray) -> list[tuple[np.ndarray, bool]]:
    """Visit every skeleton edge once; preserve branches, loops and endpoints.

    A diagonal is omitted when an axial neighbor already connects its endpoints,
    avoiding artificial triangular junctions on staircase pixels.
    """
    pixels = set(zip(*np.nonzero(mask)))
    neighbors = {}
    for y, x in pixels:
        adjacent = []
        for dy, dx in ((-1, 0), (0, 1), (1, 0), (0, -1), (-1, -1), (-1, 1), (1, 1), (1, -1)):
            q = (y + dy, x + dx)
            if q not in pixels:
                continue
            if dy and dx and ((y + dy, x) in pixels or (y, x + dx) in pixels):
                continue
            adjacent.append(q)
        neighbors[(y, x)] = adjacent
    visited = set()
    paths = []

    def walk(start, following):
        points = [start]
        previous, current = start, following
        while True:
            visited.add(tuple(sorted((previous, current))))
            points.append(current)
            if current == start or len(neighbors[current]) != 2:
                break
            following = next(p for p in neighbors[current] if p != previous)
            if tuple(sorted((current, following))) in visited:
                break
            previous, current = current, following
        closed = points[-1] == start
        if closed:
            points.pop()
        if len(points) >= 2:
            paths.append((np.array([(x + 0.5, y + 0.5) for y, x in points], np.float32), closed))

    for start in sorted(pixels, key=lambda p: (len(neighbors[p]) == 2, p)):
        for following in neighbors[start]:
            if tuple(sorted((start, following))) not in visited:
                walk(start, following)
    return paths


def length(points: np.ndarray, closed: bool = False) -> float:
    p = np.vstack((points, points[:1])) if closed else points
    return float(np.linalg.norm(np.diff(p, axis=0), axis=1).sum())


def curves(mask: np.ndarray, minimum_length: float, preserve_junctions: bool = False) -> list[dict]:
    result = []
    padded = np.pad(mask.astype(np.uint8), 1)
    neighbor_count = cv2.filter2D(padded, cv2.CV_16U, np.ones((3, 3), np.uint8))[1:-1, 1:-1] - mask
    for points, closed in trace(mask):
        endpoints = np.floor(points[[0, -1]]).astype(int)
        connects_junctions = preserve_junctions and all(neighbor_count[y, x] >= 3 for x, y in endpoints)
        if length(points, closed) < minimum_length and not connects_junctions:
            continue
        # Simplification bounded by 0.45 input pixels. Open endpoints remain
        # fixed; no smoothing between independent components or branches.
        points = cv2.approxPolyDP(points.reshape(-1, 1, 2), 0.45, closed).reshape(-1, 2)
        if len(points) < 3:
            # Straight three-pixel strokes may reduce to two valid endpoints.
            if closed or len(points) < 2:
                continue
        result.append({"points": points.tolist(), "closed": closed})
    return result


def shadow_mask(luminance: np.ndarray, structural: np.ndarray) -> np.ndarray:
    """Experimental broad tonal boundaries; no claim of semantic shadow labels.

    Strong edge-preserving smoothing suppresses pores and microtexture. Canny
    chooses gradient ridges, not a stack of arbitrary luminance level contours.
    Structure proximity excludes duplicate outlines. Only long paths survive.
    """
    luminance = checked(luminance)
    unit = max(luminance.shape) / 768
    smooth = cv2.bilateralFilter(luminance, 0, 0.12, max(1.5, 3 * unit))
    smooth = cv2.GaussianBlur(smooth, (0, 0), max(1.2, 2 * unit))
    gray = np.uint8(np.clip(smooth * 255, 0, 255))
    candidates = cv2.Canny(gray, 8, 22, L2gradient=True)
    # Reject the outer soft fade into white paper. Require source darkness on
    # both sides in a local neighborhood, rather than outlining a background
    # halo. This is a photometric gate, not semantic subject segmentation.
    interior = cv2.erode((smooth < 0.82).astype(np.uint8),
                        np.ones((11, 11), np.uint8)) != 0
    candidates[~interior] = 0
    distance = cv2.distanceTransform((structural == 0).astype(np.uint8), cv2.DIST_L2, 5)
    candidates[distance < max(3, 4 * unit)] = 0
    candidates[:3] = candidates[-3:] = 0
    candidates[:, :3] = candidates[:, -3:] = 0
    return (candidates != 0).astype(np.uint8)


def commands(path: dict) -> list[tuple]:
    """Quadratic corner rounding limited to 0.65 input pixels from each vertex.

    Long straight segments stay straight. Avoid midpoint smoothing that could
    cut across a simplified corner by several pixels.
    """
    points = np.array(path["points"], dtype=float)
    closed = path["closed"]
    rounded = []
    for i, p in enumerate(points):
        if not closed and i in (0, len(points) - 1):
            rounded.append((p, p, p))
            continue
        before, after = points[(i - 1) % len(points)], points[(i + 1) % len(points)]
        incoming, outgoing = before - p, after - p
        a, b = np.linalg.norm(incoming), np.linalg.norm(outgoing)
        radius = min(0.65, a * 0.25, b * 0.25)
        rounded.append((p + incoming / max(a, 1e-9) * radius, p,
                        p + outgoing / max(b, 1e-9) * radius))
    start = rounded[0][2] if closed else points[0]
    output = [("M", *start)]
    for incoming, p, outgoing in rounded[1:] + (rounded[:1] if closed else []):
        output.append(("L", *incoming))
        if np.linalg.norm(incoming - outgoing) > 1e-8:
            output.append(("Q", *p, *outgoing))
    if closed:
        output.append(("Z",))
    return output


def sampled(path: dict) -> np.ndarray:
    output = []
    for command in commands(path):
        if command[0] in ("M", "L"):
            output.append(np.array(command[1:], dtype=float))
        elif command[0] == "Q":
            start, control, end = output[-1], np.array(command[1:3]), np.array(command[3:5])
            for t in np.linspace(0, 1, 7)[1:]:
                output.append((1 - t)**2 * start + 2 * (1 - t) * t * control + t*t * end)
        else:
            output.append(output[0])
    return np.array(output)


def dash_segments(points: np.ndarray, dash=3.0, gap=6.0):
    phase = 0.0
    for a, b in zip(points, points[1:]):
        segment = float(np.linalg.norm(b - a))
        at = 0.0
        while at < segment - 1e-8:
            ink = phase < dash
            step = min((dash if ink else dash + gap) - phase, segment - at)
            if ink and step > 1e-8:
                yield a + (b - a) * (at / segment), a + (b - a) * ((at + step) / segment)
            at += step
            phase = (phase + step) % (dash + gap)


def svg(width: int, height: int, structure: list, guides: list) -> str:
    layers = []
    for name, paths, stroke, dash in (("structure", structure, 0.85, ""),
                                      ("shadow-guides", guides, 0.65, ' stroke-dasharray="3 6"')):
        elements = []
        for path in paths:
            data = " ".join(c[0] + " ".join(f"{v:.3f}" for v in c[1:]) for c in commands(path))
            elements.append(f'<path d="{data}"/>')
        layers.append(f'<g id="{name}" fill="none" stroke="#000000" stroke-opacity="1" '
                      f'stroke-width="{stroke}" stroke-linecap="round" stroke-linejoin="round"{dash}>\n'
                      + "\n".join(elements) + "\n</g>")
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
            f'viewBox="0 0 {width} {height}">\n<rect width="100%" height="100%" fill="white"/>\n'
            + "\n".join(layers) + "\n</svg>")


def render(width: int, height: int, structure: list, guides: list, scale=3) -> Image.Image:
    # Binary canvas: no gray or translucent stroke pixels. Export scale improves
    # curve sampling only; it does not create new source detail.
    image = Image.new("1", (width * scale, height * scale), 1)
    draw = ImageDraw.Draw(image)
    for paths, stroke, dashed in ((structure, 0.85, False), (guides, 0.65, True)):
        for path in paths:
            points = sampled(path)
            segments = dash_segments(points) if dashed else [points]
            for segment in segments:
                coords = [(float(p[0] * scale), float(p[1] * scale)) for p in segment]
                draw.line(coords, fill=0, width=max(1, round(stroke * scale)), joint="curve")
    return image.convert("L")


def process(confidence: np.ndarray, luminance: np.ndarray) -> tuple[list, list, dict]:
    confidence, luminance = checked(confidence), checked(luminance)
    if confidence.shape != luminance.shape:
        raise ValueError("Source and model output must share coordinates")
    start = time.perf_counter()
    mask = structure_mask(confidence)
    structure = curves(mask, 2.8, preserve_junctions=True)
    guides = curves(shadow_mask(luminance, mask), max(16, max(mask.shape) * 0.025))
    return structure, guides, {"structurePaths": len(structure), "guidePaths": len(guides),
        "processingSecondsCPU": time.perf_counter() - start,
        "method": "supported ink crests; bounded quadratic curves; separate broad-gradient guides",
        "simplificationTolerancePixels": 0.45, "cornerRadiusMaxPixels": 0.65,
        "guideMeaning": "experimental broad tonal boundaries, not learned semantic labels",
        "gapFilling": False, "faceAnnotations": False, "rasterExportScale": 3}


def comparison(folder: Path) -> None:
    sheet = Image.new("RGB", (1440, 830), "#eeeeee")
    draw = ImageDraw.Draw(sheet)
    font = ImageFont.load_default(size=19)
    first = "artist-target.png" if (folder / "artist-target.png").exists() else "reference.png"
    panels = [(first, "Example stencil" if first.startswith("artist") else "Source"),
              ("drawings-style1/stencil.png", "Previous black"),
              ("layers-v2/structure.png", "New structure"),
              ("layers-v2/combined.png", "New + experimental guides")]
    for column, (filename, label) in enumerate(panels):
        draw.text((column * 360 + 8, 8), label, font=font, fill="black")
        preview = ImageOps.contain(Image.open(folder / filename).convert("RGB"), (344, 780))
        sheet.paste(preview, (column * 360 + (360 - preview.width) // 2,
                             42 + (780 - preview.height) // 2))
    sheet.save(folder / "layers-v2/comparison.png")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("results", type=Path, help="Existing compare.py output; no inference is repeated")
    args = parser.parse_args()
    report = json.loads((args.results / "report.json").read_text(encoding="utf-8"))
    metrics = {"scope": "Research postprocessing candidate; no app integration or artist approval", "images": []}
    for item in report["images"]:
        folder = args.results / item["name"]
        luminance = np.array(Image.open(folder / "reference.png").convert("L"), dtype=np.float32) / 255
        confidence = np.load(folder / "drawings-style1/confidence.npz")["confidence"]
        structure, guides, record = process(confidence, luminance)
        destination = folder / "layers-v2"
        destination.mkdir(exist_ok=True)
        h, w = luminance.shape
        for name, s, g in (("structure", structure, []), ("guides", [], guides), ("combined", structure, guides)):
            (destination / f"{name}.svg").write_text(svg(w, h, s, g), encoding="utf-8")
            render(w, h, s, g).save(destination / f"{name}.png")
        (destination / "paths.json").write_text(json.dumps({"width": w, "height": h,
            "structure": structure, "guides": guides}), encoding="utf-8")
        comparison(folder)
        metrics["images"].append({"name": item["name"], **record})
        print(item["name"], record, flush=True)
    (args.results / "layers-v2-report.json").write_text(json.dumps(metrics, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
