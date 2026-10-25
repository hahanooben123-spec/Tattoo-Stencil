# Source-only generative prompt test — 25 October 2026

Two edits were executed with the built-in image generation tool, using the
imagegen skill. This is a test of prompt-controlled stencil generation, **not**
a FLUX test, a local model execution or an iPad integration. The tool does not
expose a pinned model revision here, so no exact model-version claim is made.

Each call received only its own source image and the saved text prompt. The
artist's paired stencil was withheld to avoid passing off copying that target
as successful source interpretation. The generated eye was not supplied as a
reference to the portrait test. No output strokes were manually repaired.
Full prompts and roles are in `prompt-tests.json`.

## Observations

| Source | Improvement in generated drawing | Remaining limits |
| --- | --- | --- |
| Eye, 973 x 608 | Continuous lid/iris/pupil contours, deliberate lashes, little skin texture; substantially closer to the requested stencil style | Lashes are thickened/regularized, iris has more marks than requested; exact individual lash geometry is not preserved or certified |
| Masked portrait, 384 x 768 | Both eyes retained; face, finger, crown, hair and banknotes read as a coherent stencil with selected dashed guides | Fine jewelry, lettering and banknote detail are reinterpreted; facial/graphic geometry is not certified as an exact transfer |

Outputs were saved as generated, without thresholding, tracing, warping or
manual cleanup. Eye output is 1588 x 991 and portrait output 887 x 1774.
Higher output resolution does not establish more source detail. The results
contain intermediate grayscale pixels, including antialiasing and near-white
background variation; they are not strict one-bit print exports.

These two qualitative observations demonstrate a promising style/selection
direction. They do not establish professional acceptance, exact anatomical
registration, reproducibility across runs or generalization across motifs.
The artist must assess whether any reinterpretation is acceptable. The app's
engine has not been replaced.

Private project-bound artifacts:

- `Validation/Results/prompt-stencil-test/eye-prompt.png`
- `Validation/Results/prompt-stencil-test/portrait-prompt.png`
- `Validation/Results/prompt-stencil-test/report.json` (sizes and image hashes)
- `Validation/Results/prompt-stencil-test/prompt-eye.txt` and `prompt-portrait.txt`

Original tool outputs are retained in the Codex generated-images directory;
copies are in the workspace. Source and output images remain ignored by Git.

## Local/free deployment investigation

The local Windows computer reports an NVIDIA RTX 4070 Ti with 12,282 MiB VRAM.
That is a plausible workstation for a separate FLUX.2 klein 4B trial. It is not
proof of peak memory usage, acceptable latency or comparable stencil quality.
No FLUX weights or CUDA runtime were downloaded for this test, no FLUX inference
was executed, and no paid API was integrated.

The [official klein model page](https://bfl.ai/models/flux-2-klein) lists 4B
under Apache 2.0 and approximately 8.4 GB VRAM for its published configuration.
Its approximately 1.2-second figure is for RTX 5090, not this 4070 Ti or an iPad.
The [official inference repository](https://github.com/black-forest-labs/flux2)
supports image-conditioned editing and distinguishes distilled four-step models
from the larger-step base variants. License-free local inference still requires
the hardware and implementation; it does not make the built-in tool an app API.

An [independent Swift/MLX implementation](https://github.com/icakinser/mlx-flux2-swift)
supports image editing on Apple Silicon but currently documents macOS 14+,
an M-series Mac and an Xcode toolchain. It is not a demonstrated iPad runtime.
[MFLUX's own implementation notes](https://github.com/mflux-community/mflux/blob/main/src/mflux/models/flux2/README.md)
show memory-reduction options and Mac timings; neither establishes real-time
iPad behavior. Quantization can change fidelity, so memory reduction would need
the same anatomy/style review as the full model.

Decision: prompt-based editing deserves further evaluation. The visual result
is promising, while free local deployment with comparable quality and real-time
iPad execution remain unverified. A logical next implementation test is the
Apache-licensed 4B model on the existing GPU, followed by an actual Apple-device
benchmark if its output passes review. Do not promise these tool-generated
results as the performance or quality of that different model.
