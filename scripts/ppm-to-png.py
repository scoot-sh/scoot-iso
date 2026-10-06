#!/usr/bin/env python3
"""Convert QMP screendump PPMs to PNGs (stdlib only).

QMP `screendump` writes P6 PPM; GitHub renders neither PPM nor shows it
in the README, so the QEMU test converts every *.ppm in a directory to
*.png beside it. Idempotent: re-running skips nothing but overwrites
identical bytes.

Usage: ppm-to-png.py <dir>
"""

import struct
import sys
import zlib
from pathlib import Path


def ppm_to_png(ppm: Path) -> None:
    data = ppm.read_bytes()
    assert data[:2] == b"P6", f"not a P6 PPM: {ppm}"
    tail, pos, got = data[2:], 0, []
    while len(got) < 3:
        while tail[pos:pos + 1] in b" \t\r\n":
            pos += 1
        if tail[pos:pos + 1] == b"#":
            pos = tail.index(b"\n", pos) + 1
            continue
        end = pos
        while tail[end:end + 1] not in b" \t\r\n":
            end += 1
        got.append(tail[pos:end])
        pos = end
    w, h, vmax = int(got[0]), int(got[1]), int(got[2])
    assert vmax == 255, f"maxval {vmax} unsupported: {ppm}"
    raster = tail[pos + 1:]
    assert len(raster) >= w * h * 3, f"short raster in {ppm}"
    raster = raster[:w * h * 3]
    raw = b"".join(b"\x00" + raster[y * w * 3:(y + 1) * w * 3] for y in range(h))

    def chunk(typ: bytes, payload: bytes) -> bytes:
        c = struct.pack(">I", len(payload)) + typ + payload
        return c + struct.pack(">I", zlib.crc32(typ + payload) & 0xFFFFFFFF)

    png = (
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(raw, 6))
        + chunk(b"IEND", b"")
    )
    out = ppm.with_suffix(".png")
    out.write_bytes(png)
    print(f"converted {ppm.name} -> {out.name} ({w}x{h})")


if __name__ == "__main__":
    for ppm in sorted(Path(sys.argv[1]).glob("*.ppm")):
        ppm_to_png(ppm)
