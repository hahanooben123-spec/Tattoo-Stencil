"""Offline FLUX image editing. No Hub requests or paid services at runtime."""
from __future__ import annotations
import io
import json
import time
from pathlib import Path
from PIL import Image, ImageOps
from .download_model import DEFAULT_ROOT, MODEL_ID, REVISION

PROMPT = """Convert this exact artwork into a professional tattoo transfer stencil.
Preserve framing, proportions, expression, gaze and every object's placement.
Keep both eyes readable: eyelid rims, iris and pupil boundaries and important lashes.
Use thin smooth continuous black contours on pure white. Outline pupils, do not fill.
Clearly separate overlapping forms, fingers, lips, nose, hair groups and ornaments.
Select sparse short dashed guides for major shadow transitions only.
Remove grayscale shading, solid shadow fills, texture, grain and redundant contours.
Do not invent anatomy, redesign, mirror, crop, add text or change composition.
Output one source-faithful stencil, no panels or captions."""

def decode(data: bytes) -> Image.Image:
    with Image.open(io.BytesIO(data)) as image:
        if image.width * image.height > 40_000_000 or min(image.size) < 32:
            raise ValueError("Billedet skal være mellem 32 px og 40 megapixel.")
        image.load()
        image = ImageOps.exif_transpose(image).convert("RGBA")
        white = Image.new("RGBA", image.size, "white")
        white.alpha_composite(image)
        return white.convert("RGB")

def binary_png(image: Image.Image) -> bytes:
    # Keep every printed mark opaque black. No gray shadow fills.
    image = image.convert("L").point(lambda p: 0 if p < 192 else 255, mode="1")
    buffer = io.BytesIO()
    image.save(buffer, format="PNG")
    return buffer.getvalue()

class Cancelled(Exception):
    pass

class FluxEngine:
    def __init__(self, root: Path = DEFAULT_ROOT):
        self.root = root
        self.pipeline = None

    def load(self):
        if self.pipeline is not None:
            return
        import torch
        from diffusers import Flux2KleinPipeline
        manifest = json.loads((self.root / "download-manifest.json").read_text())
        if manifest.get("revision") != REVISION or manifest.get("model") != MODEL_ID or not manifest.get("verified"):
            raise RuntimeError("Hent og verificér den fastlåste model med download_model.py først.")
        if not torch.cuda.is_available():
            raise RuntimeError("En NVIDIA CUDA GPU er nødvendig til denne opsætning.")
        self.pipeline = Flux2KleinPipeline.from_pretrained(
            str(self.root), dtype=torch.bfloat16, local_files_only=True)
        self.pipeline.enable_model_cpu_offload()
        self.pipeline.vae.enable_tiling()

    def generate(self, image, cancelled, progress, prompt=PROMPT):
        import torch
        if cancelled.is_set():
            raise Cancelled()
        progress(0.02, "Indlæser lokal model")
        self.load()
        source = image.copy()
        source.thumbnail((1024, 1024), Image.Resampling.LANCZOS)
        width, height = source.size
        canvas = Image.new("RGB", ((width + 15)//16*16, (height + 15)//16*16), "white")
        offset = ((canvas.width-width)//2, (canvas.height-height)//2)
        canvas.paste(source, offset)
        def step(pipe, index, timestep, values):
            if cancelled.is_set():
                raise Cancelled()
            progress(0.2 + (index+1)/4*0.7, f"Danner stencil · trin {index+1}/4")
            return values
        start = time.monotonic()
        with torch.inference_mode():
            output = self.pipeline(image=canvas, prompt=prompt, width=canvas.width, height=canvas.height,
                                   num_inference_steps=4, guidance_scale=1.0,
                                   generator=torch.Generator("cpu").manual_seed(42),
                                   callback_on_step_end=step).images[0]
        if cancelled.is_set():
            raise Cancelled()
        output = output.crop((offset[0], offset[1], offset[0]+width, offset[1]+height))
        return output, time.monotonic()-start
