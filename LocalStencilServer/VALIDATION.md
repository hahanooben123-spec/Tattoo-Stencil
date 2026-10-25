# Local PC validation — 2026-10-25

Hardware: Windows, RTX 4070 Ti 12 GB, 64 GB RAM. Python 3.12, CUDA PyTorch 2.11.0+cu128. Exact dependencies in requirements.txt; pinned model revision in download_model.py. All 19 downloaded model files verified against the Hub revision's sizes and SHA-256/git-blob hashes. Model is non-gated; no API key was used.

Actual local inference was performed, not substituted with the built-in imagegen tool. Private inputs/results remain ignored. The two source images are the previously used eye (973×608) and photographed portrait composition (384×768); no target stencil was supplied to the model.

| Run | Eye inference | Portrait inference | Observation |
| --- | ---: | ---: | --- |
| Previous long source-only prompts | 16.14 s | 7.56 s | Coherent readable forms, heavy lashes and filled eye pupil; portrait proportions reinterpret the source. |
| Short contour prompt | 14.42 s | 6.89 s | Open pupil on this eye, but portrait lettering/details were lost. |
| Initial application prompt via HTTPS | 14.34 s | 6.81 s | Protocol works, but eye pupil stays filled and portrait lettering lost. |
| Revised application prompt via HTTPS | 13.94 s | 6.63 s | Portrait retains outlined WARNING and more banknote detail. Eye pupil still filled. |

The last HTTPS run took 29.03 s wall time for the first eye request including cold model loading and polling, then 7.12 s for the portrait. Smaller portrait pixel count explains some of the difference. These are two examples, not a latency guarantee or a broad quality benchmark. No real-time generation claim is made.

The final default prompt favors preserving composition and existing graphic elements. It does **not** reliably enforce all requested artistic constraints. These are promising local line-art outputs, not verified equivalents of the previously approved imagegen samples. Facial shape, gaze, eyelashes, source lettering/signature handling and filled regions still require the tattoo artist's inspection. A prompt-only pass cannot guarantee an exact transfer tracing.

The running HTTPS API was exercised with its generated certificate as the trust anchor, bearer authentication, submit/poll/download/delete, actual GPU generation, and binary PNG decoding. Output mode is 1-bit PNG. It was tested from the PC itself; that does not prove iPhone/iPad LAN reachability or the native camera/Keychain/certificate-pin UI at runtime.

Server fake-engine tests passed: authorization, bad/small image rejection, queued/running cancellation, queue limit, transparency compositing and binary output. Swift core tests passed (77 tests), and GitHub's macOS iOS 17 SDK source typecheck passed for the initial app integration. Signed app/device testing remains with the user. No private input or new evaluation output has been published.
