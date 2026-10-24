# Stencil Studio — offline stencil engine and iPad workspace

An offline iPadOS 17+ tattoo stencil prototype. The stencil engine uses deterministic traditional computer vision. With the user's revised requirements, **Apple Vision's on-device foreground model** now optionally guides subject selection; there is no generative AI, cloud processing, image upload, external model download code or third-party runtime dependency. Processing preserves the reference coordinate system and produces **paths**, not black shadow fills.

This is a development build, not a professionally validated tattoo tool. The artist must inspect every line before transfer.

## What is implemented

- A simplified workspace with three artist-facing controls: **Detaljer**, **Hovedkontur**, **Skygger**. Technical thresholds, layers, presets, diagnostics and optional highlights live under a collapsed **Avanceret** section. The controls map to real, resolution-aware algorithm parameters; zero shadows skips shadow generation.
- Local Apple Vision subject detection on the orientation-normalized thumbnail. The largest detected instance is selected automatically; **Vælg hovedmotiv** lets the artist select another instance by tapping the reference. The full frame and aspect ratio remain unchanged. A visible fallback uses the whole reference if Vision is unavailable or finds no subject. It can also be disabled under Avanceret.
- Subject guidance suppresses unrelated background edges and lowers detection thresholds near the subject boundary. The mask's perimeter is **never traced into the stencil**. Main-contour classification emphasizes actual source edges with stronger, opaque strokes while internal detail remains finer and shadows are subdued. The same stroke rules apply in the canvas, PNG and PDF.
- Photos and Files import; EXIF orientation normalization; source aspect ratio retained.
- sRGB linearization and CIE L* luminance, a small bilateral filter, configurable contrast (Accelerate on Apple platforms, equivalent scalar code on Linux).
- Fine Scharr gradients ranked by coarse Gaussian-scale support and local contrast; configurable texture suppression, directional non-maximum suppression, double-threshold hysteresis, connected contour tracing, short-contour rejection, bounded path simplification. Coarse evidence ranks edges without moving their fine coordinates.
- Histogram-weighted tonal clustering with 3–10 requested levels, ambiguity-limited local coherence, four-connected region adjacency, tone-aware merging of small components, and shared-border tracing. Flat or limited-tone images can produce fewer occupied levels.
- Shadow-to-outline duplicate suppression and shadow-to-shadow spacing, including crowded concentric bands. Longest paths receive spacing priority; clipped paths become separate strokes without shortcuts. Controls can disable overlap suppression or all spacing.
- Solid outline, dashed shadow, and optional experimental dotted highlight layers in shared pixel coordinates. Visibility, opacity and width controls; individual exports by hiding other layers.
- Six editable parameter presets, stage debugging, before/after comparison, pinch zoom, scroll-to-pan, fit/reset.
- Background processing in a serial actor lane, cancellation checkpoints, stale-result rejection, 280 ms parameter debounce, retained compressed source, and thumbnail-only import limited to 900 pixels on its longest side.
- Memory preflight before native decode, bounded region/graph/sample counts, and memory-pressure cancellation. No automatic reduction of final resolution.
- Full-resolution verification and caching; the canvas then shows the actual final paths. Preview/final agreement is measured separately for outlines and shadows within two preview pixels.
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
| ShadowBoundaryCleaner | Inter-layer duplicate suppression and minimum shadow spacing |
| ProcessingLimits / ProcessingLane | Allocation policy, hard complexity bounds and serial execution |
| PreviewFidelity / ScaleSpace | Measured preview agreement, scale-space filters and area resampling |
| AppleSubjectDetector / SubjectGuidance | Optional Apple-only subject model, cached low-resolution mask, normalized guidance and safe clipping |
| MainContourSelector / OutlineStroke / StencilControls | Main/detail classification, shared stroke hierarchy and three coherent artist controls |
| StencilProcessingCoordinator | Stage orchestration and progress |
| WorkspaceModel (app) | Job lifecycle, cached source, settings and layer state |
| StencilRenderer / ExportService (app) | Shared stroke rules, PNG/PDF and physical sizing |

Image processing is outside SwiftUI views. All core image arrays are row-major. Structural points use pixel centers; tonal points follow pixel-cell borders. Results span `[0,width] × [0,height]`. The renderer maps those coordinates directly, with no contour reconstruction or compositional changes. Stroke and dash controls use original-image pixels. Preview length and area thresholds scale with the preview image.

## Run on an iPad

1. Copy the **entire `StencilStudio.swiftpm` folder** into Files on the iPad, retaining its `.swiftpm` extension. It is self-contained and has no remote package dependencies.
2. Open it in Swift Playgrounds with an iPadOS 17+ deployment environment. Run the app.
3. Import a reference from Photos or Files. Vision selects the largest foreground instance automatically. If needed, choose **Vælg hovedmotiv** and tap another subject. Adjust the three sliders; open **Avanceret** only for technical overrides, presets, layers or debugging.
4. Reveal the original using the comparison slider. Choose **Kontrollér endelig stencil** to measure preview agreement and inspect final paths. Detection changes invalidate verification. Select PNG/PDF and physical width, choose **Eksportér stencil**, then **Gem eller del**. A verified result is reused when detection settings are unchanged. Main-outline emphasis changes only stroke appearance and does not invalidate verified geometry.

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

- Swift 6.0.3 on Linux in the official `swift:6.0` Docker image: **42 tests passed, zero failures** on October 24, 2026. The Apple-only blank-image Vision smoke test is compiled/run by the macOS workflow when its OS supports the API; it is excluded on Linux.
- Tests cover invalid inputs, uniform-image behavior, bilateral preservation, step-edge alignment, histogram thresholds, region suppression, shared borders, closed contours, diagonal connectivity, simplification, deterministic output and cancellation.
- All Swift files passed a Tree-sitter syntax parse. A syntax parse is not an Apple SDK compilation.
- The release CLI processed an asymmetric synthetic geometry fixture; exported SVGs passed dimension, nonempty-layer, coordinate-bound and dash-style checks. This is a geometry smoke test, not a realism-quality evaluation.
- Additional regression tests cover texture rejection, fine-feature retention, tone-aware region merging, strong-boundary preservation, concentric bands, clipping without bridging, fractional preview spacing, resource guards, active cancellation and preview scaling/agreement. GitHub Actions runs the portable tests on Linux and the Apple/Accelerate core on macOS; the iPad app still needs an Apple SDK build.
- Subject-guidance tests verify background suppression, weak silhouette recovery at the source coordinates, no invented lines from a mask, no geometric displacement, normalized mask alignment, role preservation through optimization, clipping, stroke hierarchy and the three-control parameter mapping. Real Vision quality, orientation and tap alignment still require device validation.
- No iPad performance or professional-quality claims are made. See [Validation/README.md](Validation/README.md) for representative-reference and export checks.

## Validation CLI

Provide an 8-bit binary **P5 PGM** reference (max value 255, interpreted as sRGB grayscale):

```sh
swift run -c release stencil-inspect reference.pgm Validation/Results/portrait
```

The CLI runs the real engine and writes separate and combined SVGs, a preview SVG, stage PGM images, and JSON with stage durations, path counts, thresholds and preview agreement. Linux also reports process peak resident memory from `/proc/self/status`; other hosts report null. Memory includes the CLI's decode, native processing, preview comparison and output, and is not an iPad measurement. An optional third argument sets the preview longest side (2–1200, default 900):

```sh
python Tools/make-validation-fixture.py Validation/Results/quality-reference.pgm
swift run -c release stencil-inspect Validation/Results/quality-reference.pgm Validation/Results/synthetic 450
```

It performs no downloads. Use your own licensed photographs for realism validation; the reproducible synthetic fixture tests geometry and sampling only.

## Limits and next phases

**The functional engine and initial quality/safety improvements are implemented; artist validation and later editing phases remain open.** Native processing uses a conservative base estimate of 48 bytes per source pixel plus 32 MiB, with remaining headroom divided between graph and region allowances. The device budget is the smaller of 768 MiB and one fifth of physical RAM. Hard caps are 400,000 graph links and 100,000 regions, further reduced to fit the budget. Shadow sampling is bounded by twice the link allowance. Oversized or over-complex references fail with an explicit message; export never falls back to preview pixels. The policy is an estimate, not a guarantee against OS memory pressure or allocator overhead. The source remains available for interactive preview even if native verification is rejected.

The engine is not tiled and has not been profiled on iPad. Cancellation applies throughout engine loops; platform decode and final encoding may complete before stopping. A serial lane prevents cancelled decode/process/render jobs from overlapping. Verified native results are released when detection settings change or memory pressure is reported. Previews remain approximations despite scale-aware radius, length, spacing and area controls. Reduced sampling, histogram shifts and subpixel topology can change shadow paths. Agreement is symmetric raster coverage (harmonic mean of precision and final coverage), not source fidelity or professional quality. Full verification replaces the canvas with final geometry. Spacing masks are conservative and have up to one pixel-cell diagonal of uncertainty; they suppress paths rather than moving geometry.

The native alternative avoids OpenCV: explicit Swift Scharr/Canny with multiscale/local-contrast ranking, histogram clustering, graph tracing, spacing cleanup and Accelerate contrast on Apple. Apple Vision supplies a foreground mask only; it does not identify anatomical landmarks or regenerate artwork. Core Image, guided filtering, Metal, gap bridging and semantic anatomy recognition are **not implemented**. Tone clustering adapts globally; local coherence only changes ambiguous, low-contrast pixels. Spacing suppresses nearby bands, but does not identify semantically redundant distant rings. Cross-layer cleanup uses generated outlines even if that layer is hidden; disable **Fjern overlap med konturer** when independent shadow coverage is preferred. Setting boundary spacing to zero disables spacing cleanup entirely.

Vision's foreground request requires iOS/iPadOS 17+ or macOS 14+. The portable CLI does not invoke Vision; it still runs deterministic processing and geometry/contrast-based main-contour ranking. The iPad app caches a thumbnail mask and samples it in normalized coordinates for preview and full-resolution runs, avoiding a native-size mask allocation and inconsistent separate model predictions. Vision inference is serialized off the UI thread. An in-flight platform request may complete before cancellation is observed. A soft mask may miss fine hair or details, select the wrong object, or be unavailable on a device; use tap selection or disable subject focus. No mask can create a contour where source gradient evidence is absent. This means it can improve selection, but cannot guarantee a complete silhouette. Apple's API is described in [Lift subjects from images in your app](https://developer.apple.com/videos/play/wwdc2023/10176/).

Highlights are opt-in, use luminance thresholding and size filtering, and do not yet have local-contrast screening. The UI inversion setting reverses stencil/background colors; it does not invert the analysis luminance. Transparent PNG uses the chosen stroke color; the preview uses an opaque inspection background. PDF always has an opaque background.

There is no Apple Pencil editing, selection, undo/redo, project persistence, independent single-layer regeneration, automated real-photo quality scoring or dedicated print controller yet. Layer settings affect rendering immediately; detection parameter changes rerun the pipeline. Sharing a PDF lets the system offer printing where available. Physical-size metadata does not force a printer to use 100% scaling or prevent printable-margin clipping; verify a proof with a ruler.

1. **Phase 2:** validate and tune the new multiscale/local-contrast selection, region coherence and spacing against the six reference categories with an artist; improve highlight significance and distant concentric-band selection; add stage protocols and independent regeneration.
2. **Phase 3:** persist generated vector paths separately from manual edits; implement Pencil/custom dashed paths, selection, per-layer undo and redo, direct printing, calibrated physical output and export integration tests.
3. **Phase 4:** profile on actual iPads; extend current bounds/preflight with tiled processing for images beyond the working budget, then use further Accelerate/Metal work where measurements justify it. Revalidate tiled seams and full-resolution geometry.
