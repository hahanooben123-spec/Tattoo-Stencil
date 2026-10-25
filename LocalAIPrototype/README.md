# Local AI iPad prototype

Standalone native iPad app to test **FLUX.2 klein 4B on an iPad Pro M2 with 8 GB RAM**. The one-time model download is followed by local image editing, reference comparison, elapsed-time/physical-footprint reporting and black/white PNG export. There is no PC pairing, API key or cloud inference backend in this app.

**This is an experiment, not an already proven M2/8 GB implementation.** A successful build verifies compilation/linking. It does not establish that a full generation fits the iPad's application memory allowance, is fast enough, or produces the artist's desired stencil quality. The Windows PC's earlier results do not validate this different runtime/quantization.

## Swift Playgrounds limitation

The existing `StencilStudio.swiftpm` stays usable separately. This prototype uses Draw Things' native C/C++ inference stack through MediaGenerationKit; it is **not** a new `.swiftpm` file to open/run directly in Swift Playgrounds on iPad. It must be built and installed as a native app using Apple's tooling and signing. No signed installation or TestFlight upload is included.

The repository's **Local AI iPad prototype** GitHub Actions workflow builds the real iOS dependency and produces a build log plus an IPA requiring device signing when compilation succeeds. This IPA cannot be installed merely by opening it on the iPad. It carries an ad-hoc signature only so a subsequent signer can read the requested memory entitlement; it is not signed/provisioned for your iPad. The entitlement file also accompanies the artifact. A Mac/Xcode development install is the direct supported developer route. A Windows signing/sideloading workflow is a separate installation step requiring the user's own Apple account and device; no credentials are requested or stored here. Preserve the requested memory entitlement during signing and verify it on the installed app; packaging alone does not grant it.

## Build on a Mac

Install Xcode 26 or newer (the pinned runtime references the Apple 10 GPU family, even when targeting older iPads) and XcodeGen, then from the repository root:

```sh
xcodegen generate --spec LocalAIPrototype/project.yml
open LocalAIPrototype/StencilLocalAI.xcodeproj
```

Select `StencilLocalAI`, your attached iPad, and your signing team. Build a **Release** configuration for representative performance. The project requests Apple's increased-memory-limit entitlement; provisioning/device policy determines whether it is available. This entitlement does not make all 8 GB available to the app.

## Test on the iPad

1. Open **Stencil Lokal AI** and tap **Hent lokal model** on Wi-Fi. Keep the app foregrounded. The checkpoint, text encoder and VAE are downloaded into Application Support, excluded from iCloud backup. At least 12 GB free disk space is required initially.
2. Let SHA-256 verification finish. Each of the three files is independently hashed, including large files. A verification manifest records the hashes and file size/modification date; changed files require another explicit verification/install.
3. Select the same reference art used in the PC test and tap **Dan stencil på iPad**. The screen stays awake during processing. Going to the background or receiving a memory warning requests cancellation. The app waits for actual SDK cancellation before allowing another job.
4. Compare the eyes, iris/pupil, lips, fingers and object placement using the comparison slider. A generative edit can alter these or ignore the request to leave dark regions unfilled. All exported pixels are strictly black/white, but black filled shapes can still occur.
5. Record the displayed time, image dimensions and sampled maximum physical memory footprint. If iPadOS terminates the app, report that rather than treating it as a successful run. The 250 ms sampled footprint can miss brief peaks; it is not a memory ceiling.
6. After installation, enable airplane mode and turn Wi-Fi off, then repeat generation. Successful offline generation on the actual iPad is the acceptance test for the local runtime.

PNG here is a **test raster at model resolution**, without print-size/DPI controls or automatic upscaling. It is not a final professional transfer export. The existing workspace retains its own physical-size export.

## Fixed implementation choices

- MediaGenerationKit pinned to `8868a9685d9c299816f43ef53efd455ffca437f0`, which pins Draw Things Community to `d473a2f148b3e7dc9b90d0b7cfccc5cda999eb66`.
- Distilled `flux_2_klein_4b_q6p.ckpt` (6-bit checkpoint), `qwen_3_4b_q8p.ckpt` (8-bit text encoder) and `flux_2_vae_f16.ckpt`. This is not an all-4-bit pipeline. File hashes are pinned in ModelFiles.swift from the upstream ModelZoo and the official VAE hash catalog.
- 4 steps, guidance 1, seed 42, one image per explicit button press. Uses the model's Kontext image-edit modifier and full editing strength, not a text-only generation call.
- Reference is orientation normalized and limited to 768 px on its longest side. White padding makes each canvas dimension a multiple of 64; the known padding is removed afterward. The output dimensions are checked before cropping. No aspect stretching is used.
- VAE tiled decoding (256 px tiles / 64 px overlap); diffusion tiling and TeaCache disabled. Optional weights cache set to zero. These reduce some memory use, but **do not guarantee** total model/activation memory fits in 8 GB.
- Serial engine ownership, no concurrent download/generation, cancellation propagated to the SDK, no inference on slider changes. Reference/result publication happens on the main actor.
- Only the explicit install action calls `ensure`/downloads. Inference uses `.local`, an installed pinned checkpoint and matching built-in/bundled configuration. No remote/cloud fallback. Airplane-mode behavior still requires the device test above.
- Strict grayscale threshold at 192, retaining source aspect/canvas coordinates. No morphology pass that invents or hollows contours. Clean-looking output is not proof of faithful anatomy.

## Dependencies and licenses

MediaGenerationKit is [LGPL-3.0](https://github.com/drawthingsai/media-generation-kit/blob/8868a9685d9c299816f43ef53efd455ffca437f0/LICENSE), with upstream native dependencies distributed under its stated package terms. This app's source, project specification and pinned dependency references are available in this repository so the app can be rebuilt with a modified library. Bundled license notices are in Resources. No inference-engine code has been modified or copied into the existing Playgrounds app.

The exact [FLUX.2 klein 4B model](https://huggingface.co/black-forest-labs/FLUX.2-klein-4B) and [Qwen3-4B](https://huggingface.co/Qwen/Qwen3-4B) use Apache-2.0. Model weights are downloaded at installation time and are not committed. There is no per-image service charge for local inference. App signing/distribution is independent of model inference licensing.
