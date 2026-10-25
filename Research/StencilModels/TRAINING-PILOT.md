# Local training pilot — 25 October 2026

The previous extraction/postprocessing candidates did not meet the tattoo
artist's quality target. This pilot moves the experiment to supervised stroke
selection rather than further tuning those filters. It is a bounded research
workflow, outside the iPad app. It is not a trained professional stencil model.

The initial training run used procedurally generated smoke images only.
The subsequent [collage pilot](COLLAGE-PILOT.md) explicitly experiments with
approximately registered user examples; it is ineligible for quality acceptance.
No paid compute was used in either stage.

## What is implemented

The verified Informative Drawings style-1 generator supplies its existing
encoder/decoder and structural output. A second head predicts guide ink. The
structural head starts with exactly the pretrained behavior; the new guide head
starts below the fixed 0.5 ink threshold. The shared backbone can be fine-tuned.
The existing MIT license and asset hashes still apply.

Training uses paired source/target crops without stretching. Per-layer,
class-balanced BCE and soft Dice penalize both missing and extra ink; tiny guide
targets do not disappear behind background-pixel counts. The learning rates are
1e-5 for pretrained parameters and 1e-4 for the new head. Gradient clipping,
explicit seeds, deterministic CPU execution and a step limit bound the run.
This loss is a starting hypothesis, not a claim of correct topology or anatomy.

A separate guide target is optional. If missing, that head receives **no** loss
or score for that pair. A missing label is never silently treated as a blank
guide image. An explicitly provided blank guide image is a valid label.

Before training, the data validator checks alignment/artist-approval metadata,
matching image dimensions, opaque black-on-white prepared targets, file hashes
and composition-family splits. Decoded identical sources in multiple splits are
rejected even when their PNG encoding differs. Group labels must still account
for crops, redraws, derivatives and repeated compositions; hashes cannot identify
all such relationships automatically. A checked flag cannot prove alignment.
The separate `--provisional-pairs` mode allows reviewed similarity estimates
only for `provisional-registered-collages`. It preserves `aligned: false` and
`artistApproved: false`, records `qualityEligible: false`, and must not be
represented as exact, artist-approved pairs. Normal strict validation remains.

Validation compares the pretrained baseline and candidate at a frozen threshold
of 0.5 and a declared 1.5-native-pixel match tolerance. Precision, recall and F1
are recorded per layer and per named critical region. A lost eye is flagged even
when the full-image score improves. Blank/unknown targets have explicit handling.
Colored diagnostic overlays show missing red, extra blue and exact-overlap black
pixels. Those overlay colors are not product stencil output.

The trainer leaves the test split unscored. The separate frozen evaluator checks
checkpoint, base-weight, manifest and source/target hashes, loads tensors with
`weights_only=True`, and compares that exact candidate against the baseline on
the selected split. A test set must not subsequently be used to choose model
settings. Metrics never set `qualityAccepted` to true.

Native-coordinate overlapping tiles bound evaluation memory. InstanceNorm can
produce context-dependent tile seams; native resolution and overlays must be
inspected. This implementation is not a CoreML port or an iPad speed benchmark.

## Data needed for the real pilot

Start with separate original art and its corresponding finished stencil. A pair
must use matching geometry; clean exports from the same canvas are preferable.
We can inspect alignment and prepare binary labels from those originals. Do not
stretch a collage's two panels to equal size and assume they now correspond.

One pair is enough to prepare and inspect the first example. The trainer requires
at least one training composition and a **different** validation composition.
That is a technical minimum, not enough evidence of generalization. Additional
untouched compositions are needed for a credible test. Critical eye/mouth boxes
should be annotated on the actual source when present. Guides can be labeled
separately later, without blocking a first structural-line experiment.

`training-pairs.example.json` is intentionally not marked approved or aligned.
Copy it to the ignored private-reference folder and fill paths and verified
metadata when actual pairs exist. Each region is `{"name":"left-eye",
"box":[left,top,right,bottom]}` in normalized source coordinates. Coordinates
must be measured for that source; no generic face boxes are supplied.

```powershell
# Readiness only; exits nonzero if pairs are unsuitable. Use a new output folder.
.\.tools\stencil-models\venv\Scripts\python.exe Research/StencilModels/train_pilot.py Validation/PrivateReferences/ArtistPairs/pairs.json Validation/Results/pilot-readiness --check-only

# A bounded paired pilot; no downloads or hosted service.
.\.tools\stencil-models\venv\Scripts\python.exe Research/StencilModels/train_pilot.py Validation/PrivateReferences/ArtistPairs/pairs.json Validation/Results/paired-pilot-01 --steps 50 --patch-size 256 --threads 4

# Only after choosing a frozen candidate using training/validation, evaluate test.
.\.tools\stencil-models\venv\Scripts\python.exe Research/StencilModels/evaluate_pilot.py Validation/Results/paired-pilot-01 Validation/PrivateReferences/ArtistPairs/pairs.json Validation/Results/paired-pilot-01-test
```

## Work actually executed

The five private collage references were audited. All have different source and
target crop sizes; exact registration is unconfirmed and their photographed or
compressed targets need preparation. They remain style references. The private
readiness report rejects them for direct paired training. The same laurel
composition also appeared earlier and must never count as independent evidence.

A procedural smoke dataset has two training images, one validation image and
one test image. Its generic ellipses/detail marks are not artist-designed tattoo
stencils, and its families do not demonstrate realistic distribution variation.
Sixty CPU steps completed and a tensor checkpoint was written/reloaded for
frozen evaluation. Training loss fell, but the candidate still overpredicted
guides and structural precision regressed on validation. **It is rejected as a
quality candidate.** Even a successful synthetic score would not prove tattoo
quality. We did not continue tuning the toy data to manufacture a passing score.

Private artifacts are under `Validation/Results/training-smoke-v3/`,
`training-smoke-v3-frozen-review/`, and `artist-training-readiness-v2/`.
The data, weights and generated images stay ignored by Git.

Run the integrity/geometry tests with:

```powershell
.\.tools\stencil-models\venv\Scripts\python.exe -m unittest discover -s Research/StencilModels -p 'test_*.py'
```

Next quality decision: train on correctly prepared artist-approved pairs, then
inspect unseen motifs and critical anatomy with the artist. Require useful
stroke selection before any CoreML/iPad integration. No result here establishes
that the reference quality has been achieved or guarantees it can be achieved.
