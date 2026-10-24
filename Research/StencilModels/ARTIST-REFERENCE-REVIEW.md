# Tattoo stencil reference review — 24 October 2026

Five user-supplied collages were inspected and all three pinned models were run
on the source-art panels alone. Crops, source hashes, targets and outputs remain
in ignored private validation folders. No user images are included here.
These are visual style references, not assumed to be authored by the user.
They have not been approved as training data.

## Observed target rules

- Preserve visible eyelids, iris boundaries, gaze, selected lashes and brows.
  Do not draw anatomy that is hidden by hair, fragments or other objects.
- Describe lips, mouth opening, visible teeth, nostrils and nose shape with
  selected curves. Avoid tracing every highlight inside these features.
- Use continuous, deliberate boundaries for overlapping objects, cracks,
  ornament, fingers and hair masses. A dark region is not automatically an
  outline; a bright separator can still be an important structural boundary.
- Hair uses long directional strands and grouped locks rather than a texture
  mesh. Repeated structural patterns such as snake scales remain meaningful.
- Facial volume is recorded with sparse, lighter-looking or broken guides.
  In the product these must still use black ink: spacing and dash pattern
  should distinguish guides, rather than gray output pixels.
- Preserve the source geometry. The target stencil can simplify details, but
  its artistic decisions are not interchangeable with generic edge strength.

## Comparison findings

| Reference | Desired decisions | Style 1 prototype shortfall |
| --- | --- | --- |
| Snake / cracked portrait | Scale network, cracks, lashes, tongue; restrained facial volume guides | Broad composition captured, but nose/cheek guides missing; small lines fragment after binarization; frame/signature also traced |
| Makeup portrait | Eye geometry, clean graphic borders, lip/teeth separation; cheek/chin guides | Eyes retained visibly but lashes/mouth crowded; paired borders and highlight clutter; sparse volume information |
| Tattoo photographed on skin | Flowing grouped hair, selective facial features, clear hand/nails | Extra irregular facial lines and hair clutter; skin/arm boundary traced; curved skin prevents direct geometry scoring |
| Fragmented faces | Sharp overlapping fragments and distinct visible eyes | Tiny source (188 x 394 crop) limits precision; sketch follows broad layout but eyes and black output remain coarse |
| Laurel / armor portrait | Eye detail, directional hair, ornament and selected shading guides | Raw drawing gives a useful structural start; fewer facial guides and ornament details; black conversion breaks/splits curves and retains UI icon |

These observations are qualitative. Targets differ in placement, scale and
occasionally geometry, so pixel similarity would be misleading. Their faint
gray appearance is also not a suitable black-output target without preparation.
The fifth composition repeats an earlier reference; it is not a new independent
held-out example. None is evidence of artist approval of the generated output.

## Implementation priorities

1. Repair sketch-to-black conversion first. Compare raw drawing against black
   output at native resolution and in eye crops. Preserve line centers and
   supported curve continuity without blind gap filling or doubled boundaries.
   Do not integrate this model into the app on the strength of raw sketches.
2. Treat structural curves and sparse volume guides as separate targets. Current
   drawing outputs omit useful guides before binarization; postprocessing alone
   cannot recover their intended placement reliably.
3. Keep source-coordinate eye/mouth inspection as an acceptance gate. Visible
   anatomy must remain precise at the intended print size. The user, a tattoo
   artist, determines whether those choices are usable.
4. For custom training, collect rights-cleared originals with corresponding
   artist-approved stencils; align or explicitly annotate their correspondence.
   Separate artist/style and composition families across training/evaluation.
   Do not train on these collages by default or use them for numeric claims.
5. Only after line quality passes review, evaluate CoreML conversion and actual
   iPad latency. Cache expensive image analysis; slider changes should reuse
   it. CPU desktop inference is not proof of real-time iPad performance.

Private review: `Validation/Results/artist-examples/review.html`.
Private provenance: `Validation/PrivateReferences/artist-example-pairs.json`.
The initial comparison used the unchanged model pipeline from commit 2138d35.
A subsequent `layers-v2/` comparison adds supported-crest curve extraction and
separate experimental source-gradient guides. It improves curve representation
and some continuity, but still shows eye/lip clutter and paired sketch lines.
Guide placement is not artist-equivalent. No fine-tuning, paid job or app
integration has been performed. The review defaults to structural curves with
experimental guides off, and keeps the previous black output available.
