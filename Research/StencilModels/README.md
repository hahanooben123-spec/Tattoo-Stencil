# Local stencil model prototype

This is a separate research prototype. It does not replace the iPad app's engine.
Inference runs entirely on the local CPU. There is no paid API, image upload,
training job or hosted inference. Setup downloads public code/weights once.

## Reproduce on Windows

Use Python 3.12. The isolated environment and downloaded weights live under the
gitignored `.tools/` directory. Inputs and generated private images must stay in
`Validation/PrivateReferences/` and `Validation/Results/`.

```powershell
python -m venv .tools/stencil-models/venv
.\.tools\stencil-models\venv\Scripts\python.exe -m pip install -r Research/StencilModels/requirements.txt
.\.tools\stencil-models\venv\Scripts\python.exe Research/StencilModels/fetch_models.py
.\.tools\stencil-models\venv\Scripts\python.exe Research/StencilModels/compare.py Validation/PrivateReferences/model-inputs.json Validation/Results/model-prototype
.\.tools\stencil-models\venv\Scripts\python.exe Research/StencilModels/make_review.py Validation/Results/model-prototype
```

The input JSON is an array of objects with `name`, local `path`, and optional
`crop: [left, top, right, bottom]` in orientation-corrected original pixels. No
face/eye annotations or manual traces are accepted. Every model receives exactly
the same cropped/resized RGB input. Inputs are limited to a 768-pixel longest side
by default and never stretched; reflection padding handles network block sizes.

The setup manifest pins source revisions, SHA-256 hashes and weight URLs. Every
run verifies the hashes and loads state dictionaries with `weights_only=True`.
The inference runner has no network operations. Upstream inference classes are
loaded without training imports, torchvision backbones or the online Gradio app.

## Models and licenses

* [TEED](https://github.com/xavysp/TEED), revision
  `40fa4b1391dc6424f88989d0ca75d5b592c8681d`, BIPED epoch-7 weights.
  Source/weights come from that MIT-licensed repository.
* [Informative Drawings](https://github.com/carolineec/informative-drawings),
  revision `2349aee4daf7cb01d8de645b0bbb4f4392fd1395`. Inference architecture
  `Generator(3, 1, 3)` and both weights from the author's
  [official demo](https://huggingface.co/spaces/carolineec/informativedrawings),
  revision `bd4b4299be505803e036203a39c02024b4cfee11`. The repository license and
  demo metadata both state MIT. Their notices are included alongside this file.

The prototype uses no license service or metered inference. Future custom
training and Apple distribution are separate decisions, not costs incurred here.

## Processing and output

TEED follows the author's 1.5x small-image upsampling proposal when the shorter side is below 512 pixels, then restores the original coordinates. It uses BGR pixels minus the author's CLASSIC-test mean, sigmoid of its fused
output and the author's per-image min/max normalization. These scores are not
calibrated probabilities. Informative Drawings uses RGB in [0,1], with ink
confidence equal to one minus the generator's output.

Each model writes its raw drawing, float confidence map, declared global-threshold
variants, and a black-only candidate. A global threshold of 0.5 erased faint eyes
from the drawing model, so the candidate follows local ink ridges using Hessian
normals, non-maximum suppression and connected hysteresis. It retains components
with at least three pixels and thins without filling gaps. There is no hand-drawn
repair, face annotation or geometry warping. All thresholds are recorded.

`report.json` records inputs' hashes/crops, dimensions, runtime versions, model
parameter counts, normalization, processing settings and single-run CPU times.
`review.html` embeds local images for offline inspection, with raw/binary views,
an optional baseline and full-size inspection. It makes no external requests.

For a baseline, run the existing Swift `stencil-inspect` tool on each generated
`reference.pgm`, using `768 studio-detailed`. Render the resulting SVG to
`baseline.png` beside `reference.png`, then rebuild the review. This baseline
does **not** invoke Apple Vision; it is not the complete current iPad pipeline.

## First observations — October 24, 2026

Two private inputs were used: a crop of the user's masked-portrait screen photo,
and the artwork-only right side of the paired style example. The target stencil
on the left was excluded from the model input. Source crops and exact dimensions
are recorded in the private report. Screen reflections and embedded UI marks
remain in the source and may be traced by any model.

Informative Drawings style 1 is the most promising visual candidate on the target
artwork: it captures facial features, hair and ornament structure closer to the
desired line-drawing style. TEED still follows many broad tonal boundaries.
Style 2 loses facial detail and introduces loose crossing sketch lines. Style 1
also has broken/noisy strokes; its raw drawing and black candidate must both be
reviewed. This is a qualitative observation on two examples, not tattoo-ready
validation or evidence that all eyes are retained automatically.

Observed single-pass inference on the local Windows CPU with four PyTorch threads
was approximately 0.12–0.23 seconds for TEED and 0.5–1.0 seconds for either drawing
model. Loading, cleanup and writing images are excluded. These are not iPad/CoreML
benchmarks. No CoreML conversion or new iPad integration has been performed.

The next decision is which candidate the artist considers worth continuing.
Any chosen model still needs source-overlay review, vector-path extraction,
separate sparse shadow guides, CoreML conversion and on-device measurements.

## Curve and guide candidate

`stencil_layers.py` reuses saved style-1 confidence maps and source pixels;
it does not reload or rerun any model. Run it after `compare.py`, then rebuild
the review page:

```powershell
.\.tools\stencil-models\venv\Scripts\python.exe Research/StencilModels/stencil_layers.py Validation/Results/artist-examples
.\.tools\stencil-models\venv\Scripts\python.exe Research/StencilModels/make_review.py Validation/Results/artist-examples
.\.tools\stencil-models\venv\Scripts\python.exe -m unittest discover -s Research/StencilModels -p test_stencil_layers.py
```

The candidate follows ink crests with a small sampling tolerance at bends. A
narrow-stroke top-hat can retain existing faint continuations only at a local
cross-section maximum; it does not close white gaps. Whole-ribbon thinning was
rejected during visual review because it created ladder-like connections around
eyes and lips. The graph tracer retains loops, branches and short links between
junctions. Source-coordinate polylines are simplified within 0.45 pixels and
rounded with quadratic corners of at most 0.65 pixels. Open endpoints stay fixed.

Shadow guides are a separate, **experimental** layer derived from broad source
luminance gradients after bilateral/Gaussian smoothing. Proximity to structural
ink, short fragments and light-background fades are rejected. They are not
learned semantic shadow labels and still miss artist-selected volume guides.
They are off by default in the review, and can be inspected without altering the
structural layer. No extra controls have been added to the iPad app.

Each `layers-v2/` folder contains `structure`, `guides` and `combined` SVG/PNG,
source-coordinate `paths.json`, and a comparison sheet. SVG uses only opaque
black strokes and a white background. PNG is strictly binary black/white,
sampled at 3x analysis resolution; this is curve rendering, not new image detail.
Guides are distinguished by dashes rather than gray pixels. The report records
postprocessing CPU time separately; model inference and raster/vector export
are excluded. This is still not an iPad latency measurement.

Synthetic checks cover faint eyes, supported faint continuations, unsupported
gaps, separate parallel strokes, loops, junction links, fixed endpoints, invalid
inputs, blank sources, duplicate guides and binary/dashed output. They establish
geometry invariants, not professional tattoo quality.

Visual review on the five supplied collages shows more connected, scalable
curves, but also remaining eye/lip clutter and paired sketch lines. Guide
placement is not yet equivalent to the examples. This candidate remains outside
the iPad app; it is not a release-quality stencil engine. The collages were used
for local inference/comparison only, not training or numeric quality scoring.
