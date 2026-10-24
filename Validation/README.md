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
5. Export each layer separately and combined; inspect opacity, widths, shadow dash spacing and highlight dots. Transparent PNG corners must have zero alpha; white-background PNG must be opaque. Test color inversion separately.
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
