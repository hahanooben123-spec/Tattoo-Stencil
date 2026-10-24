# Stencil Studio — functional Phase 1

An offline, deterministic iPadOS 17+ tattoo stencil prototype. No models, inference, image-generation services, networking, or third-party runtime dependencies. Processing preserves the reference coordinate system and produces **paths**, not black shadow fills.

This is a development build, not a professionally validated tattoo tool. The artist must inspect every line before transfer.

## What is implemented

- Photos and Files import; EXIF orientation normalization; source aspect ratio retained.
- sRGB linearization and CIE L* luminance, a small bilateral filter, configurable contrast (Accelerate on Apple platforms, equivalent scalar code on Linux).
- Scharr gradients, directional non-maximum suppression, double-threshold hysteresis, connected contour tracing, short-contour rejection, bounded path simplification.
- Histogram-weighted tonal clustering with 3–10 requested levels, four-connected small-region merging, and shared-border tracing. Flat or limited-tone images can produce fewer occupied levels.
- Solid outline, dashed shadow, and optional experimental dotted highlight layers in shared pixel coordinates. Visibility, opacity and width controls; individual exports by hiding other layers.
- Six editable parameter presets, stage debugging, before/after comparison, pinch zoom, scroll-to-pan, fit/reset.
- Background processing, cancellation checkpoints, stale-result rejection, 280 ms parameter debounce, cached decoded reference and a preview limited to 900 pixels on its longest side.
- Native-resolution PNG (including transparent PNG) and vector PDF export, physical width in millimeters, locked aspect ratio. PNG includes DPI metadata; PDF uses exact page dimensions.

## Architecture

`StencilStudio.swiftpm/Core` contains the portable, independently testable `StencilCore` module. The root `Package.swift` uses these same sources, so there is no duplicate engine to maintain.

| Module | Responsibility |
| --- | --- |
| ImageImportService (app) | Orientation, decoding, color conversion and preview sampling |
| ImagePreprocessor | Bilateral filtering and contrast |
| StructuralEdgeDetector / StructuralContourTracer | Canny-style edges and continuous paths |
| TonalSegmentationEngine | Adaptive histogram clustering and connected regions |
| ShadowBoundaryGenerator / HighlightBoundaryGenerator | Distinct tonal and highlight paths |
| ContourOptimizer | Length rejection and geometry-bounded simplification |
| StencilProcessingCoordinator | Stage orchestration and progress |
| WorkspaceModel (app) | Job lifecycle, cached source, settings and layer state |
| StencilRenderer / ExportService (app) | Shared stroke rules, PNG/PDF and physical sizing |

Image processing is outside SwiftUI views. All core image arrays are row-major. Structural points use pixel centers; tonal points follow pixel-cell borders. Results span `[0,width] × [0,height]`. The renderer maps those coordinates directly, with no contour reconstruction or compositional changes. Stroke and dash controls use original-image pixels. Preview length and area thresholds scale with the preview image.

## Run on an iPad

1. Copy the **entire `StencilStudio.swiftpm` folder** into Files on the iPad, retaining its `.swiftpm` extension. It is self-contained and has no remote package dependencies.
2. Open it in Swift Playgrounds with an iPadOS 17+ deployment environment. Run the app.
3. Import a reference from Photos or Files. Adjust the preset and inspect the **Edges**, **Preprocessed**, and **Tonal regions** views.
4. Reveal the original using the comparison slider. Hide layers as required, select PNG/PDF and physical width, then generate the full-resolution export and choose **Save or share export**.

`AppleProductTypes` is an Apple app-package manifest module. It is not included in standalone Swift on Windows or Linux. Package recognition and Apple SDK compilation have **not been verified in this environment**.

For Xcode on a Mac, open the app package if your installation supports `AppleProductTypes`. If it reports that module unavailable, create a new **iOS App**, target iPadOS 17, add the root package as a local package dependency, link its `StencilCore` library, replace the generated app entry with the files in `StencilStudio.swiftpm/App`, and select a signing team. Do not also add the Core files directly to that app target. No camera or photo-library permission string is needed for the system Photos picker. Distribution, signing, Instruments, device debugging and conventional XCTest UI targets require Apple's tooling.

## Test the core

From the repository root with Swift 5.9+ installed:

```sh
swift test
swift build -c release
```

On this Windows workspace, with Docker Desktop running:

```powershell
docker run --rm --mount 'type=bind,source=C:\Users\Chris\Documents\Stencil Creator,target=/workspace' --workdir /workspace swift:6.0 swift test
```

The root manifest deliberately builds only the portable engine, tests and validation CLI, not UIKit/SwiftUI. Linux tests exercise the scalar contrast path; the Apple Accelerate branch needs an Apple-platform test run.

### Recorded verification

- Swift 6.0.3 on Linux in the official `swift:6.0` Docker image: **13 tests passed, zero failures** on October 24, 2026.
- Tests cover invalid inputs, uniform-image behavior, bilateral preservation, step-edge alignment, histogram thresholds, region suppression, shared borders, closed contours, diagonal connectivity, simplification, deterministic output and cancellation.
- All Swift files passed a Tree-sitter syntax parse. A syntax parse is not an Apple SDK compilation.
- The release CLI processed an asymmetric synthetic geometry fixture; exported SVGs passed dimension, nonempty-layer, coordinate-bound and dash-style checks. This is a geometry smoke test, not a realism-quality evaluation.
- No iPad performance or professional-quality claims are made. See [Validation/README.md](Validation/README.md) for representative-reference and export checks.

## Validation CLI

Provide an 8-bit binary **P5 PGM** reference (max value 255, interpreted as sRGB grayscale):

```sh
swift run -c release stencil-inspect reference.pgm Validation/Results/portrait
```

The CLI runs the real engine and writes separate and combined SVGs, stage PGM images, and JSON with measured processing duration, pixel dimensions, path counts and thresholds. It performs no downloads. Use your own licensed photographs; this repository contains no patient/client photographs or borrowed reference artwork.

## Limits and next phases

**Phase 1 is implemented; later phases remain open.** Full-resolution export does not silently fall back to preview resolution. Large images can be expensive: full-image float buffers, graph dictionaries and component queues can consume substantial memory, and allocation exhaustion can terminate the process. The prototype is not tiled and has not been profiled on iPad. Cancellation applies throughout engine loops; platform image decoding and final image/PDF encoding may finish before cancellation takes effect. Debounced previews are approximations; reduced sampling and filter radius can change paths compared with final processing.

The native alternative avoids OpenCV: explicit Swift Scharr/Canny, histogram clustering and graph tracing, plus Accelerate contrast on Apple. Core Image, guided filtering, Metal, multiscale fusion, local-contrast ranking, gap bridging, minimum spacing, inter-layer duplicate suppression and sophisticated concentric-contour reduction are **not yet implemented**. Strong outlines can overlap shadow boundaries. The tonal method adapts globally to the histogram, not locally to semantic anatomy. Small-region suppression is a deterministic single pass and may need stronger adjacency-based merging for complex images.

Highlights are opt-in, use luminance thresholding and size filtering, and do not yet have local-contrast screening. The UI inversion setting reverses stencil/background colors; it does not invert the analysis luminance. Transparent PNG uses the chosen stroke color; the preview uses an opaque inspection background. PDF always has an opaque background.

There is no Apple Pencil editing, selection, undo/redo, project persistence, independent single-layer regeneration, automated real-photo quality scoring or dedicated print controller yet. Layer settings affect rendering immediately; detection parameter changes rerun the pipeline. Sharing a PDF lets the system offer printing where available. Physical-size metadata does not force a printer to use 100% scaling or prevent printable-margin clipping; verify a proof with a ruler.

1. **Phase 2:** validate the six reference categories with an artist, improve multiscale/local-contrast selection, region coherence, highlight significance and cross-layer spacing; add stage protocols and independent regeneration.
2. **Phase 3:** persist generated vector paths separately from manual edits; implement Pencil/custom dashed paths, selection, per-layer undo and redo, direct printing, calibrated physical output and export integration tests.
3. **Phase 4:** profile on actual iPads; introduce bounded/tiled processing and memory preflight, then Accelerate/Metal only where measurements justify it. Revalidate tiled seams and full-resolution geometry.
