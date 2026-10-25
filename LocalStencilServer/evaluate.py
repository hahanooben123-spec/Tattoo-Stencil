"""Run the same source-only prompts used in the earlier imagegen comparison."""
import json
import threading
from pathlib import Path
from .engine import FluxEngine, decode, binary_png

def main():
    root = Path(__file__).resolve().parents[1]
    tests = json.loads((root / "Research/StencilModels/prompt-tests.json").read_text())["tests"]
    sources = ["Validation/PrivateReferences/new-pairs/eye/source.png",
               "Validation/Results/model-prototype/masked-portrait/reference.png"]
    folder = root / "Validation/Results/flux-klein"
    folder.mkdir(parents=True, exist_ok=True)
    engine = FluxEngine()
    results = []
    for test, source in zip(tests, sources):
        print("Testing", test["name"], flush=True)
        image, seconds = engine.generate(decode((root/source).read_bytes()), threading.Event(),
                                        lambda _, message: print(message, flush=True), test["prompt"])
        image.save(folder / (test["name"] + "-raw.png"))
        (folder / (test["name"] + "-binary.png")).write_bytes(binary_png(image))
        results.append({"name":test["name"], "seconds":seconds, "size":image.size})
        (folder/"timing.json").write_text(json.dumps(results, indent=2))
        print(results[-1], flush=True)

if __name__ == "__main__":
    main()
