"""Explicit setup download only. Inference never uses the network."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from urllib.request import urlopen

HERE = Path(__file__).resolve().parent
DEFAULT_ASSETS = HERE.parents[1] / ".tools/stencil-models/assets"


def verify_assets(root: Path) -> list[dict]:
    entries = json.loads((HERE / "assets.json").read_text(encoding="utf-8"))
    for entry in entries:
        path = root / entry["path"]
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != entry["sha256"]:
            raise ValueError(f"Missing or changed asset: {path}. Run fetch_models.py first.")
    return entries


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--assets", type=Path, default=DEFAULT_ASSETS)
    args = parser.parse_args()
    for entry in json.loads((HERE / "assets.json").read_text(encoding="utf-8")):
        path = args.assets / entry["path"]
        if path.is_file() and hashlib.sha256(path.read_bytes()).hexdigest() == entry["sha256"]:
            print(f"Verified {entry['path']}")
            continue
        data = urlopen(entry["url"], timeout=120).read()
        if hashlib.sha256(data).hexdigest() != entry["sha256"]:
            raise ValueError(f"Checksum mismatch: {entry['path']}")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        print(f"Downloaded {entry['path']}")
    verify_assets(args.assets)


if __name__ == "__main__":
    main()
