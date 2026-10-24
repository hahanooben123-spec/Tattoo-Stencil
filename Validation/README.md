# Reference-quality validation

The engine has synthetic algorithm tests, but **no artist-reviewed realism references have been validated**. Do not equate passing unit tests with tattoo-ready quality.

Keep your own licensed references locally in the gitignored `Validation/PrivateReferences` directory. Use six categories: human portrait, lion portrait, realistic rose, classical statue, black-and-grey skull, and complex animal fur. Include several exposures, backgrounds and resolutions for each. Avoid identifiable client photographs in public source control.

Run the validation CLI documented in the root README on grayscale P5 PGM copies. Save the original color file for iPad import tests. Record the image identifier, source dimensions, grayscale conversion method, preset, exact parameters, hardware, compiler/configuration and app revision alongside each results folder. CLI output uses the default parameters with experimental highlights enabled. Its duration excludes file reading and SVG writing, and is a host measurement, not an iPad benchmark.

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
