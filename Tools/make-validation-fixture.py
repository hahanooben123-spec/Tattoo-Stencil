"""Deterministic geometry/texture fixture; not a realism-quality reference."""
import math
import sys
from pathlib import Path

destination = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("Validation/Results/quality-reference.pgm")
width, height = 1536, 1024
pixels = bytearray(width * height)
for y in range(height):
    for x in range(width):
        value = 215 + int(12 * math.sin(x / 140) + 10 * math.cos(y / 120))
        if 80 < x < 460 and 70 < y < 520:
            value = 35
        if (x - 1060) ** 2 + (y - 650) ** 2 < 235 ** 2:
            value = int(65 + 80 * math.hypot(x - 1060, y - 650) / 235)
        if 600 < x < 830 and 70 < y < 380:
            value = int(150 + 16 * math.sin(x * 2 * math.pi / 5))
        pixels[y * width + x] = max(0, min(255, value))
destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_bytes(f"P5\n{width} {height}\n255\n".encode() + pixels)
print(destination)
