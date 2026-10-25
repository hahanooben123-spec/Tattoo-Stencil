# Stencil PC

Runs **FLUX.2 klein 4B** on your own NVIDIA PC. The iPad/iPhone app sends an image over the private LAN and retrieves one black/white PNG. No paid inference API, cloud upload, or Apple model download is involved. The PC must stay on. Model weights alone are about 16 GB; the tested environment is Python 3.12, Windows, RTX 4070 Ti 12 GB, 64 GB RAM.

## Start and pair

1. First setup: run `LocalStencilServer/Setup.ps1` from PowerShell (Python 3.12 and an NVIDIA driver supporting CUDA 12.8 required). A custom Python executable can be supplied with `-Python`.
2. Run `LocalStencilServer/Start.ps1`. Leave this terminal running. Use `-Address 192.168.x.x` if automatic interface selection chooses a VPN or the wrong network.
3. Open the private QR page with `LocalStencilServer/Show-Pairing.ps1`.
4. In the updated app select **Forbind PC**, scan the QR, then **Forbind PC**. Pasting the complete JSON code also works. Allow the camera and local network prompts.
5. Import a reference and select **Dan stencil på PC**. Compare it with the original using the existing comparison slider. Export PNG/PDF at the requested width in mm.

Both devices must be on the same private network. Guest Wi-Fi/client isolation blocks communication. If Windows Firewall blocks the connection, run `Enable-LAN.ps1` as Administrator **only on a network you trust**. It marks that interface private and allows TCP 8765 only from `LocalSubnet`, on the Private profile, for the running Python program and current PC address. Re-run after an IP change. It opens no router/public port. Closing the server stops processing. There is no auto-start or public tunnel.

The pairing page contains a bearer secret. Keep it private; it is never served over the LAN or committed. Certificate, key, token, weights and caches live in the ignored `.tools/local-stencil` folder. The app pins the certificate's SHA-256 fingerprint and stores pairing data in device-only Keychain. Redirects and public destinations are refused. If the PC IP changes, restart the server and pair again. To revoke existing pairings, stop the server, remove its specific `runtime/credentials.json` file, and restart.

## Runtime and limitations

- Four distilled inference steps, seed 42, bfloat16, model CPU offload, VAE tiling. Source aspect ratio is maintained with temporary padding; generation is limited to 1024 px on the longest side. This is not a 300-DPI enlargement or vector trace.
- Output is thresholded to strictly black/white pixels (no gray marks). Generated shapes can still have filled regions or changed anatomy. Always inspect eyes, fingers, text and proportions before transfer.
- Generation is explicitly triggered once per button press. It does not run during slider movements. The old local filter engine remains available separately.
- One GPU job at a time, two queued jobs, bounded uploads/history. Cancel is checked between model steps; loading/individual GPU operations may finish before cancellation is observed.
- Sources/results stay in RAM and completed jobs expire after 30 minutes. Restart clears the job history. Runtime loads only local weights with Hub offline flags; setup alone downloads dependencies/weights.
- PNG export includes physical DPI metadata. PDF contains the same raster at the requested physical dimensions. Print at actual size and measure.

## Reproducible model and evaluation

Model: [black-forest-labs/FLUX.2-klein-4B](https://huggingface.co/black-forest-labs/FLUX.2-klein-4B), revision `e7b7dc27f91deacad38e78976d1f2b499d76a294`, Apache-2.0. This applies to this exact model, not every FLUX variant. Keep the downloaded model's LICENSE.md when redistributing weights; other dependencies have their own licenses. No weights are included in this repository.

`python -m LocalStencilServer.evaluate` uses the two source-only prompts in `Research/StencilModels/prompt-tests.json`. `evaluate_prompt` compares a shorter contour prompt. Results and timing remain private under ignored `Validation/Results/flux-klein`. The earlier approved public samples were generated with the built-in imagegen tool, **not** FLUX; they are not proof of local model quality.

Server protocol tests use a fake engine: `python -m pytest LocalStencilServer/tests -q`. They check authorization, invalid images, cancellation, bounded queue, and binary output; they do not assess artistic quality. Actual GPU inference is evaluated separately.
