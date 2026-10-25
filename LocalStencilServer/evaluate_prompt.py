"""Private comparison of a concise contour-only editing instruction."""
import threading
from pathlib import Path
from .engine import FluxEngine, decode, binary_png

PROMPT = """Make a precise tattoo transfer tracing of the input artwork. Same composition, same proportions, same eye positions and expression. Pure white paper, very thin black monoline outlines. All dark shapes are empty white shapes bounded by thin lines, including pupils, lashes, eyebrows and lettering. Trace visible eyelids, iris, pupil, lips, fingers and object overlaps accurately. Simplify hair into a few flowing strands. Add only a few short dashed guides for broad shadows. No black filled areas, no shading, no crosshatching, no gray, no texture, no signature. Do not redraw or beautify the subject. One sparse stencil only."""

def main():
    folder = Path("Validation/Results/flux-klein")
    engine = FluxEngine()
    for name, path in [("eye","Validation/PrivateReferences/new-pairs/eye/source.png"),
                       ("masked-portrait","Validation/Results/model-prototype/masked-portrait/reference.png")]:
        image, seconds = engine.generate(decode(Path(path).read_bytes()),threading.Event(),
                                        lambda _, message: print(message,flush=True),PROMPT)
        image.save(folder/(name+"-concise-raw.png"))
        (folder/(name+"-concise-binary.png")).write_bytes(binary_png(image))
        print(name,seconds,flush=True)

if __name__ == "__main__": main()
