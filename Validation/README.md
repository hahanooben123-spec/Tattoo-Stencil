# Reference-quality validation

The engine has synthetic algorithm tests, but **no artist-reviewed realism references have been validated**. Do not equate passing unit tests with tattoo-ready quality.

Keep your own licensed references locally in the gitignored `Validation/PrivateReferences` directory. Use six categories: human portrait, lion portrait, realistic rose, classical statue, black-and-grey skull, and complex animal fur. Include several exposures, backgrounds and resolutions for each. Avoid identifiable client photographs in public source control.

Run the validation CLI documented in the root README on grayscale P5 PGM copies. Save the original color file for iPad import tests. Record the image identifier, source dimensions, grayscale conversion method, preset, exact parameters, hardware, compiler/configuration and app revision alongside each results folder. CLI output uses the default parameters with experimental highlights enabled. Native processing duration excludes file reading and SVG writing; preview processing is reported separately. Linux peak RSS covers the complete process lifetime, including input/output and both resolutions. These are host measurements, not iPad benchmarks.

For each reference, review `combined.svg` against the original at identical size. Review all three layer SVGs separately and use `edges.pgm`, `preprocessed.pgm`, `tones.pgm`, and `metrics.json` to understand each generated line. Histogram thresholds explain tone transitions; the edge stage explains outlines. These debugging views do not yet provide per-path confidence or provenance IDs.

| Check | Evidence to record |
| --- | --- |
| Alignment | Overlay at 50% opacity; measure eye/nose/ear/leaf landmarks in source pixels; allow only configured simplification tolerance |
| Continuity | Inspect important structures for breaks and junction artifacts; count corrections required |
| Noise | Count unwanted isolated strokes and unnecessary micro-details; compare between presets |
| Tonal coherence | Check boundaries track major shadow masses; flag concentric or fragmented bands |
| Highlights | Check significant bright regions survive and small glare/noise is rejected |
| Performance | On-device release build; record processing and export durations separately for preview and native resolution |
| Memory | Instruments Allocations/VM Tracker peak, including decode, repeated imports and export; test memory pressure |
| Export | Inspect PNG pixel dimensions and alpha; compare layers and combined output; check PDF MediaBox points equal mm × 72 / 25.4 |

Do not use a single automatic score as acceptance. Have a realism tattoo artist judge tracing corrections and transfer usefulness. Agree on acceptance limits from those sessions rather than inventing universal thresholds.

## Apple-platform integration checklist (pending)

1. Import an asymmetric test reference with a labeled top-left corner using all eight EXIF orientations. Verify reference, outline, shadow, highlight, debug images, PNG and PDF remain aligned.
2. Test wide, tall, transparent, color-managed and high-resolution inputs. Inspect near-border geometry and aspect ratio. Confirm full-resolution PNG dimensions match the orientation-corrected source exactly.
3. Verify preview settings repeatedly cancel obsolete work and the last requested reference/settings win. Test switching references during import and cancelling export. Monitor memory across repeated operations.
4. Compare the Apple Accelerate contrast path with scalar test results within floating-point tolerance. Run `swift test` on macOS as well as Linux.
5. Export each layer separately and combined; inspect solid black ink, widths, shadow dash spacing and highlight dots. Transparent PNG corners must have zero alpha; white-background PNG must be opaque. All visible layers must use full-opacity black; there is no inversion or opacity control.
6. Export a 150 mm-wide PDF and check its MediaBox is 425.19685 points wide. Print at actual size on suitable paper and measure the result. Verify driver margins do not clip the design.
7. Verify Photos/Files/share-sheet flows on an actual iPad and run offline in airplane mode with locally stored images. Cloud-only Photos/Files items must be downloaded before offline import.
8. Record failures and artist feedback before claiming professional quality. Apple Pencil/manual edits and dedicated print UI are outside this first version.

## Quality and resource regression checks

The `QualityAndResourceTests` suite verifies texture suppression without deleting strong thin features, tone-aware merging, strong tonal boundary preservation, duplicate/concentric path removal, clipping without shortcuts, fractional preview spacing, memory rejection before work, region/path limits, pixel/area scaling, area resampling, preview agreement, and cancellation before and during processing. These are deterministic synthetic checks; they do not replace the six real-reference categories.

Run the reproducible geometry/texture fixture:

```sh
python Tools/make-validation-fixture.py Validation/Results/quality-reference.pgm
swift run -c release stencil-inspect Validation/Results/quality-reference.pgm Validation/Results/synthetic 450
```

`preview.svg` has a 450-pixel longest side. `combined.svg` retains the source's 1536 × 1024 coordinates. The JSON reports per-layer agreement with a two-preview-pixel tolerance; inspect both scores rather than treating the combined average as an acceptance criterion. Very thin lines, shadow threshold changes and conservative pixel spacing can differ with resolution. Always inspect verified native geometry in the app.

A release run in the local Linux/Docker environment on October 24, 2026 measured approximately 0.44 s native processing, 0.027 s preview processing, and 68 MiB process peak RSS for this fixture. Outline agreement was 97%; shadow agreement was 79%. These are one synthetic run's observations, not device performance targets or proof of realism quality. The earlier fractional mask leaked shadow duplicates; conservative cell coverage improved this fixture's shadow agreement from 46% to 79% without moving contour coordinates.

On an iPad, also test **Verify full resolution**, cache reuse during export, invalidation after detection changes, and memory warnings. A high-resolution file should still import a thumbnail even when native verification exceeds the budget. Verification/export must fail explicitly instead of silently exporting preview dimensions. The memory policy is conservative but cannot guarantee safety under all OS pressure; full tiling remains future work.

## Subject focus and outline hierarchy

The user authorized Apple's local Vision models after the original no-AI brief. The iPad app now uses `VNGenerateForegroundInstanceMaskRequest` on the decoded, orientation-corrected thumbnail. The portable engine does not require the model. Tests inject synthetic masks to validate downstream geometry separately from model quality; those are test inputs, not fake detections.

The eleven portable subject tests cover: a mask cannot invent lines on a flat image; unrelated background edges are suppressed; weaker subject edges can survive at their actual coordinates; an offset mask cannot move an edge; a low-resolution mask aligns in normalized coordinates; classification survives path simplification; clipping does not join across background gaps; primary/detail stroke hierarchy; coherent simple controls; zero shadow amount generates no shadow strokes; and mismatched aspect ratios are rejected. An additional Apple-only blank-image smoke test exercises the real request and safe fallback.

On an iPad, validate automatic largest-instance selection and tap selection using asymmetric references containing multiple foreground objects. Test every EXIF orientation and portrait/landscape aspect ratio, especially taps near the bottom of the image. Verify the chosen mask is reused for native verification/export, and that PNG and PDF preserve the same primary/detail emphasis. Try hair, animal fur, soft silhouettes and complex backgrounds; compare missed features against subject focus disabled. Confirm unavailable/no-subject cases show a fallback message and the image still processes. Compare preview agreement with focus on/off, and profile Vision separately from the deterministic engine.

Confirm that the normal workspace shows only Detaljer, Hovedkontur and Skygger for stencil tuning. Avanceret must start collapsed; adjusting Hovedkontur should preserve verified geometry and update line appearance immediately. Zero Skygger must remove actual generated shadow paths. Primary outlines must be visibly stronger than details and shadows at native export size, without moving any source landmarks.

## Continuous slider validation

Run `swift run -c release stencil-preview-bench 20` to measure the synthetic CPU sweeps. The local Linux run measured median/p95 of approximately 12.6/13.8 ms for 320-pixel detail changes, 6.4/7.3 ms for shadow changes, and 116/121 ms for fresh 900-pixel processing. These exclude Vision, facial guidance, UI scheduling, prepared-path generation and display rendering. They are not iPad FPS or end-to-end latency claims.

`InteractivePreviewTests` compares cached outputs against fresh processing across parameter changes; validates presentation-only reuse, shadow-stage reuse, full invalidation on preprocessing changes, mask/source/resolution isolation, cancellation/clear behavior, and the lookup filter against its exact numerical reference.

On a real iPad, continuously sweep Detaljer and Skygger for at least ten seconds. Intermediate 320-pixel frames must arrive while the finger is moving; the previous frame must remain visible. Verify the latest value wins on release, followed by a 900-pixel refinement. Resume dragging during refinement and confirm interactive feedback resumes promptly. Exercise VoiceOver/keyboard slider changes as well as touch. Inspect CPU/GPU and allocations in an optimized build. The old 280 ms pre-render debounce must not reappear.

Count actual Vision requests in Instruments: changing detail/shadow/line appearance must never rerun subject inference, including while the first request is in progress. Change the selected subject and verify exactly the new subject analysis is applied; previous-context frames must not publish. Check appearance-only controls update prepared paths immediately without CV. Memory warnings must cancel work and clear stage caches. Verify/export while a refined frame is visible, change parameters during native processing, and confirm obsolete results are discarded. PNG export dimensions must always match native source dimensions, never 320/900-pixel previews.

## Facial feature retention

The workspace photograph reported missing facial details amid many short tonal strokes. It is not the original reference, so the exact case has not been validated. Do not infer a successful before/after from synthetic tests. Keep the original private and compare the same parameters on device when it becomes available.

`VNDetectFaceLandmarksRequest` runs alongside subject analysis on the orientation-normalized thumbnail. Face-local bottom-left landmark coordinates become padded top-left image regions for eyes, brows, nose and lips. Regions outside the selected foreground mask are discarded. If foreground selection fails but valid facial landmarks exist, the whole frame is processed with those regions. If face detection fails, the existing source-edge pipeline remains usable. No landmark polyline is rendered.

The fifteen `FacialFeatureTests` verify coordinate conversion, source-aligned recovery of short weak strokes, preservation under strong smoothing, no invented lines on flat/smooth inputs, rejection of unrelated short noise, high-detail recovery without Vision, feature-map scaling, independent shadow-length controls, and preprocessing/outline cache invalidation for both region and detail changes. Near-neighbor contrast now supplements the wider contrast measurement, which could previously cancel across both sides of a thin line. Shadow fragments retain their own length floor when outline detail increases.

On device, test human portraits with weak eyelids/lips, masked or stylized faces, multiple faces, statues and non-face subjects. Record whether the status reports facial prioritization, compare focus enabled/disabled, inspect eye/nose/lip alignment at native resolution, and confirm background faces are excluded when selecting another subject. Review noise around skin and eyebrows and whether primary emphasis is useful. Repeat slider timing with facial guidance active; the existing CLI benchmark omits it. Confirm face inference occurs only once per source/selection and cached regions apply consistently to preview and export.

## Fur texture correction

The wolf workspace photograph showed dense fur strokes overwhelming the subject. Structural blur now follows image dimensions rather than native sampling scale, with a useful minimum for small previews. Repeated texture with little coarse support is rejected unless it is an isolated strong fine stroke, a guided facial feature or a subject boundary. Detail no longer weakens texture suppression. Ordinary contour length and simple-control denoising retain conservative floors even at maximum detail. Tone segmentation now operates on a separately smoothed image to avoid tracing each small fur fluctuation as a shadow guide.

A targeted regression reproduces the reported 2480 × 3508 import scale with maximum detail: repeated texture is reduced by more than 75% versus texture suppression disabled, while the strong source boundary remains. This is synthetic evidence, not a measured result on the wolf reference; the user will test the actual image on iPad. The historical geometry-fixture timings and agreement above predate this correction.

## Black ink and separating forms

All stencil render paths now use opaque black, with hierarchy expressed through width and dash patterns. The preview applies a 1.5-device-pixel minimum width to avoid disappearing subpixel strokes; PNG/PDF preserve native stroke widths. Antialiased edge coverage is retained.

Structural tracing continues through junctions only when opposing branch tangents form an unambiguous pair. It follows existing graph links and never draws across missing source pixels. Ambiguous junctions and tonal-region junctions remain separate strokes. Long coherent curves and significant enclosed source contours receive primary-width emphasis even at moderate contrast. This is geometric form prioritization, not general semantic object recognition. A regression checks a T junction continues along the main form while a separate nearby stroke remains disconnected.

The Gaussian filter bounds both passes to normalized luminance. Float accumulation at sigma 3 could otherwise turn a white margin into 1.0000002, causing strict GrayImage validation to reject an otherwise valid reference during tonal processing. The regression reproduces this failure before the fix and checks white margins across preview/native filter scales. Input validation remains strict.

## Reducing contour clutter

Facial priority now uses corridors along the model's eye/brow/nose/lip landmarks, rather than granting extra sensitivity to the entire enclosing rectangle. Landmarks guide source-edge selection only; they never become rendered geometry. Source detail preservation and seed thresholds are more conservative within these corridors.

`ContourInkSelector` ranks complete source paths using contrast, length and form coherence, with facial/primary priority. It rejects densely winding paths and paths with at least 35% overlap with stronger paths' ink space. Crossings remain possible. It does not clip accepted outlines or bridge gaps. The occupancy grid is capped at a 900-pixel longest side even for native processing. Shadow guides group the tonal labels into one dark/light boundary instead of emitting every tonal transition, preventing nested tonal rings by construction. The shadow control still changes the extent of dark masses, region filtering and spacing.

Before/after inspection used a private, 900-pixel grayscale conversion of the user's second screen photograph with identical `studio-detailed` parameters (detail 1, shadows 0.8). The old engine produced 385 outlines and 55 shadow paths; the revised non-Vision pipeline produced 375 outlines and 13 shadow paths. The local inspection shows fewer nested shadow contours. The CLI omits Vision, and the photograph contains screen borders/reflections; these results do not validate native-reference fidelity, actual facial model guidance or transfer usefulness. The photos and generated results remain gitignored. Artist/device validation remains the user's next step.

Targeted regressions cover landmark-corridor priority without invented geometry, complete-path duplicate rejection with crossing preservation and exact coordinates, and a single shadow-mass boundary across a four-tone reference.

## Fine-line target reference

The user supplied a paired realism image/fine-line stencil as the intended visual style. It establishes continuous fine form outlines, selective broken tonal guides, open areas of skin, and restrained line-weight differences. The reference is a target, not an output or a validated automatic result.

`StencilPath` rounds shallow polyline turns and tiny staircase corners into quadratic curves inside adjacent source-segment hulls. Open endpoints remain fixed; long-segment sharp corners remain sharp. The deviation limit is max(0.5, 0.6 × longest side / 900) image pixels, and rounding is bounded by the adjacent segment lengths. Prepared Core Graphics paths and the CLI SVG exporter share these commands. Geometry agreement statistics still measure traced polylines, not rasterized rounded curves.

Simple-control shadow dashes now use image-relative 4-unit marks and 8-unit gaps, instead of unscaled native-pixel lengths. Preview rendering enforces visible gaps when line widths hit the device-pixel minimum. Primary/detail width differences are reduced; opacity remains 1. Tests verify curve deviation, endpoint preservation, deliberate graphic corners and resolution-relative dash spacing. The supplied screen photograph was also rendered through the SVG path for visual inspection; actual iPad/native-reference quality still needs the user's judgment.

## Eye retention correction

Three failing regressions reproduced loss of a weak eye stroke under high texture suppression, exclusion of the iris inside a closed eyelid polygon, and rejection of a nearby iris/lid by generic ink spacing. Eye priority now includes the eye aperture interior and its perimeter corridor; skin outside the eye remains excluded. Source preservation within that aperture is stronger and its fine-gradient texture penalty is reduced. Protected facial contours are selected before ordinary paths and use near-exact duplicate spacing, retaining adjacent anatomical contours. The uniform/smooth-reference checks still reject invented geometry.

A local before/after probe used the private screen photograph and two explicitly hand-annotated eye polygons at identical parameters. Retained paths within those annotations changed from 5/7 to 8/8; enlarged visual inspection shows additional iris structure. This probe validates the downstream guided pipeline only. It does not test Apple's automatic face/eye localization, and the annotations are not presented as model predictions. Both the probe and photos remain gitignored. Actual automatic-eye placement and native iPad output still require device testing.
