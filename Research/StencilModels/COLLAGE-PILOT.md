# Provisional real-image pilot — 25 October 2026

The user supplied five further motif/stencil examples. This batch was used for
an explicitly provisional noisy-label experiment. User images, crops,
registration matrices and weights stay in ignored local folders. No image or
model checkpoint is published with this code. No paid compute was used.

## Preparation

Source and stencil panels were separated for the crying portrait, eye, spider,
skull in a glass, and hands. Native source sizes are eye 973 x 608, spider
270 x 337, glass 425 x 483 and hands 676 x 230. Enlargement adds no detail.

SIFT correspondences on Canny edge images provided candidate similarity
transforms for spider (5 inliers), glass (5) and hands (6). Their overlays were
visually inspected. Only scale, rotation and translation were permitted; no
nonlinear warp or anatomical reshaping was used. Small match counts and source
resolution limit reliability. Inlier agreement is not independent alignment
validation.

Automatic eye registration produced an implausible rotation and was rejected.
A manually located correspondence fit was used only for inspection; additional
check points differed by approximately 9–17 native pixels. The eye was not
used for training or pixel-quality scoring. Those points align panels; they are
not drawn repairs or predicted eye landmarks.

An early portrait crop intersected the neighboring stencil panel and produced
false matches from shared pixels. These matches were rejected. The neighboring
panel was masked out of the portrait input. The portrait on curved skin remains
visual-only. The preparer now rejects intersecting collage crop rectangles.

`register_pair.py` accepts private crop/transform configuration after overlay
inspection. Target coverage is sampled at 3x with pixel-center correction and
reduced to black/white labels at native source size. This retains thin downscaled
strokes without morphological gap filling. Coverage can thicken a label by one
native pixel; the declared 200/255 target cutoff can omit faint marks. This is
label preparation with uncertainty, not exact geometry ground truth.

## Data status

`--provisional-pairs` explicitly permits reviewed similarity estimates with
`targetProvidedAsExample: true`. It does not declare artist approval of the
registration: `aligned` and `artistApproved` remain false, and reports set
`qualityEligible: false`. The normal strict artist-pair requirements remain.

Spider and glass are training compositions; hands are a separate validation
composition. Eye and portrait are visual-only, never contributing gradients
or numeric quality claims. They have already been inspected and cannot later
be called a blind test set. There is no independent test set in this tiny pilot.
Separate guide labels were absent, so guides were not supervised or scored.

## Runs and decision

Two final candidates used the same data, 60 steps, native-coordinate 256-pixel
patches, four CPU threads, seed, learning rate and fixed 0.5 ink threshold:

| Candidate | Adaptation | Outcome |
| --- | --- | --- |
| Full | Backbone and structural head | Darker output and excessive extra ink; rejected |
| Head-only | Frozen backbone, final structural convolution adapted | Smaller change, but incomplete eye/lid/lash curves remain; rejected |

An intermediate run used labels before the supersampling center correction.
It is superseded by the final full/head-only runs. No model was selected by
training loss alone.

Hands diagnostics illustrate why average F1 alone is insufficient: baseline
precision is approximately 0.806, full tuning 0.515, and head-only 0.789, even
though F1 increases. These are **approximate-registration diagnostics**, not
tattoo-quality scores. Visual inspection confirms broad black texture in the
full candidate and missing strokes in the head-only candidate. The untrained
eye reference still lacks the clean, continuous selection of the user's stencil.
Both remain `qualityAccepted: false`. Neither has entered the iPad app.

Raw grayscale sketches were also inspected: full tuning strengthens texture
along with outlines, while head-only leaves much of that texture in place.
The fixed-threshold black diagnostic is not the previous ridge/curve renderer
or the iPad engine, and should not be represented as a before/after app test.

Private final artifacts:

- `Validation/PrivateReferences/provisional-pairs-v2/pairs.json`
- `Validation/Results/provisional-pilot-v2/experiment.json` and `review.html`
- `Validation/Results/provisional-pilot-head-only/experiment.json` and `review.html`
- `Validation/Results/new-pair-registration/` for overlays and rejected attempts

The head-only checkpoint is checked against verified baseline tensors: backbone
weights must be identical and structural head weights must change. That verifies
adaptation scope, not quality. Black outputs contain only 0/255 pixels; raw
grayscale output is separately inspectable.

## Reproduction

Use the documented isolated Python environment:

```powershell
python Research/StencilModels/register_pair.py <private-registration-config.json> <new-private-pairs-folder>
python Research/StencilModels/train_pilot.py <private-pairs.json> <new-full-run> --provisional-pairs --steps 60 --patch-size 256 --threads 4
python Research/StencilModels/train_pilot.py <private-pairs.json> <new-head-only-run> --provisional-pairs --adaptation head-only --steps 60 --patch-size 256 --threads 4
python Research/StencilModels/inspect_pilot.py <run-folder> <private-visual-inputs.json>
python Research/StencilModels/review_pilot.py <run-folder>
```

Registration configuration supplies `pairs` with name, path, sourceCrop,
targetCrop, reviewed similarity matrix, split and optional region boxes.
`inspect_pilot.py` exports models in the same source coordinates without line
repairs and distinguishes training examples from other visual references.
Reviews embed images and make no external requests. Preparation, training and
inference have no network operations.

This establishes that the supplied examples can support an exploratory run.
It does not establish that more steps or similar collages will reach the target.
Better registered, higher-resolution supervision and a stroke-selection method
that succeeds on unseen anatomy remain open work.
