#!/usr/bin/env python3
"""Fail if any launcher icon PNG has a white (or near-white) corner
pixel. The icon must be full-bleed dark navy to all four edges:
background layer solid navy, blob foreground centered. Corner pixels
are read with a minimal stdlib-only PNG decoder (no PIL needed in CI),
supporting non-interlaced 8-bit color types 2 (RGB) and 6 (RGBA).

Usage: check_icon_corners.py <res-dir>
  where <res-dir> is android/app/src/main/res.
Exit 0 when every ic_launcher*.png corner is dark (max channel < 64
and not near-white); 1 otherwise.
"""
import struct
import sys
import zlib
from pathlib import Path


def _paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    if pb <= pc:
        return b
    return c


def read_png_corners(path):
    data = Path(path).read_bytes()
    if data[:8] != b'\x89PNG\r\n\x1a\n':
        raise SystemExit(f'{path}: not a PNG file')
    pos = 8
    width = height = bit_depth = color_type = None
    idat = bytearray()
    while pos < len(data):
        length = struct.unpack('>I', data[pos:pos + 4])[0]
        ctype = data[pos + 4:pos + 8]
        chunk = data[pos + 8:pos + 8 + length]
        if ctype == b'IHDR':
            width, height, bit_depth, color_type = struct.unpack(
                '>IIBB', chunk[:10])
            interlace = chunk[12]
            if bit_depth != 8 or color_type not in (2, 6):
                raise SystemExit(
                    f'{path}: unsupported PNG (bit_depth={bit_depth}, '
                    f'color_type={color_type})')
            if interlace != 0:
                raise SystemExit(f'{path}: interlaced PNG unsupported')
        elif ctype == b'IDAT':
            idat += chunk
        elif ctype == b'IEND':
            break
        pos += 12 + length
    channels = 3 if color_type == 2 else 4
    stride = width * channels
    raw = zlib.decompress(bytes(idat))
    rows = []
    prev = bytearray(stride)
    off = 0
    for _ in range(height):
        ftype = raw[off]
        line = bytearray(raw[off + 1:off + 1 + stride])
        off += 1 + stride
        if ftype == 0:
            pass
        elif ftype == 1:
            for i in range(channels, stride):
                line[i] = (line[i] + line[i - channels]) & 0xFF
        elif ftype == 2:
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif ftype == 3:
            for i in range(stride):
                a = line[i - channels] if i >= channels else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 0xFF
        elif ftype == 4:
            for i in range(stride):
                a = line[i - channels] if i >= channels else 0
                b = prev[i]
                c = prev[i - channels] if i >= channels else 0
                line[i] = (line[i] + _paeth(a, b, c)) & 0xFF
        else:
            raise SystemExit(f'{path}: unknown filter {ftype}')
        rows.append(bytes(line))
        prev = line

    def pixel(x, y):
        row = rows[y]
        i = x * channels
        return tuple(row[i:i + 3])

    return {
        'size': (width, height),
        'corners': [
            pixel(0, 0),
            pixel(width - 1, 0),
            pixel(0, height - 1),
            pixel(width - 1, height - 1),
        ],
    }


def main(argv):
    if len(argv) != 2:
        print(__doc__)
        return 2
    res = Path(argv[1])
    failures = []
    checked = 0
    for png in sorted(res.glob('mipmap-*/ic_launcher*.png')):
        info = read_png_corners(png)
        checked += 1
        for corner in info['corners']:
            r, g, b = corner
            if max(r, g, b) >= 64 or min(r, g, b) > 235:
                failures.append(f'{png}: corner {corner} is not dark navy')
        print(f'{png}: {info["size"]} corners {info["corners"]}')
    if checked == 0:
        print('FAIL: no launcher icon PNGs found')
        return 1
    if failures:
        print('FAIL:')
        for f in failures:
            print(' ', f)
        return 1
    print(f'OK: {checked} launcher icon PNGs, all corners dark navy')
    return 0


if __name__ == '__main__':
    raise SystemExit(main(sys.argv))
