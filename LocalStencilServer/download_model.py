"""Explicit download/setup step. The running stencil server never calls the Hub."""
from __future__ import annotations

import argparse
import concurrent.futures
import hashlib
import json
import time
import urllib.error
import urllib.request
from pathlib import Path

MODEL_ID = "black-forest-labs/FLUX.2-klein-4B"
REVISION = "e7b7dc27f91deacad38e78976d1f2b499d76a294"
DEFAULT_ROOT = Path(__file__).resolve().parents[1] / ".tools/local-stencil/model"


def selected(name):
    return name in {"model_index.json", "LICENSE.md"} or name.startswith(
        ("transformer/", "text_encoder/", "tokenizer/", "scheduler/", "vae/"))


def verify(path, entry):
    if not path.is_file() or path.stat().st_size != entry["size"]:
        return False
    lfs = entry.get("lfs")
    hasher = hashlib.sha256() if lfs else hashlib.sha1()
    if not lfs:
        hasher.update(f"blob {entry['size']}\0".encode())
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(16 * 1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest() == (lfs["sha256"] if lfs else entry["blobId"])


def download(root, entry):
    name = entry["rfilename"]
    relative = Path(name)
    if relative.is_absolute() or ".." in relative.parts:
        raise ValueError("Unsafe model path")
    path = root / relative
    if verify(path, entry):
        print("Verified", name, flush=True)
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    partial = path.with_suffix(path.suffix + ".part")
    url = f"https://huggingface.co/{MODEL_ID}/resolve/{REVISION}/{name}?download=true"
    for attempt in range(4):
        try:
            offset = partial.stat().st_size if partial.exists() else 0
            request = urllib.request.Request(url, headers={"Range": f"bytes={offset}-"} if offset else {})
            with urllib.request.urlopen(request, timeout=60) as response:
                append = offset > 0 and response.status == 206
                if append and not response.headers.get("Content-Range", "").startswith(f"bytes {offset}-"):
                    raise ValueError("Unexpected resume response")
                received, last = (offset if append else 0), time.monotonic()
                with partial.open("ab" if append else "wb") as handle:
                    while chunk := response.read(8 * 1024 * 1024):
                        handle.write(chunk)
                        received += len(chunk)
                        if time.monotonic() - last > 25:
                            print(f"{name}: {received / entry['size']:.0%}", flush=True)
                            last = time.monotonic()
            if not verify(partial, entry):
                # Leave files recoverable; an oversized/bad partial is reset on
                # the next attempt, never accepted as a finished model.
                partial.write_bytes(b"")
                raise ValueError("Model file checksum mismatch")
            partial.replace(path)
            print("Downloaded and verified", name, flush=True)
            return
        except Exception as error:
            # Do not print signed redirect URLs or local credential information.
            print(f"Retry {attempt + 1}/4: {name} ({type(error).__name__})", flush=True)
            if attempt == 3:
                raise RuntimeError(f"Could not download {name}") from None
            time.sleep(2)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=DEFAULT_ROOT)
    args = parser.parse_args()
    url = f"https://huggingface.co/api/models/{MODEL_ID}/revision/{REVISION}?blobs=true"
    with urllib.request.urlopen(url, timeout=30) as response:
        metadata = json.load(response)
    entries = [entry for entry in metadata["siblings"] if selected(entry["rfilename"])]
    args.output.mkdir(parents=True, exist_ok=True)
    print(f"Model: {MODEL_ID}@{REVISION}; {sum(e['size'] for e in entries)/1e9:.2f} GB", flush=True)
    # The Hub's parallel Xet downloader avoids slow single-connection transfers.
    # Our own verification below checks every file against the pinned manifest.
    from huggingface_hub import snapshot_download
    snapshot_download(MODEL_ID,revision=REVISION,local_dir=str(args.output),
                      allow_patterns=["model_index.json","LICENSE.md","scheduler/*","text_encoder/*",
                                      "tokenizer/*","transformer/*","vae/*"],max_workers=6)
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        list(pool.map(lambda entry: download(args.output, entry), entries))
    manifest = {"model": MODEL_ID, "revision": REVISION, "files": entries, "verified": True}
    (args.output / "download-manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    print("Model setup complete. Runtime can now operate offline.", flush=True)


if __name__ == "__main__":
    main()
