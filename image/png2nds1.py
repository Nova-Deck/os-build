#!/usr/bin/env python3
"""Convert an RGBA PNG into the NDS1 raw container that novadeck-splash loads.

    NDS1 | u32 width LE | u32 height LE | width*height*4 bytes BGRA

The splash binary is statically linked with no libraries at all (see the header of
apps/novadeck-splash/src/novadeck-splash.c), so it has no PNG decoder and no zlib. Flattening the
logo to raw pixels here — on the x86_64 build host, at build time — is what keeps it that way.
The cost is a few hundred KB in the initramfs, which is the right trade against a dynamic
dependency that fails to load on the device without saying so.

Deliberately strict, and deliberately stdlib-only. It only ever reads a PNG this repo's own build
just produced with rsvg-convert, so anything other than 8-bit non-interlaced RGBA is a sign that
the generating step changed underneath us — which should stop the build, not be quietly
accommodated. zlib is the only decompressor needed and it is in the standard library, so this
adds no package to the build image.

    image/png2nds1.py <in.png> <out.nds1>
"""

import struct
import sys
import zlib

PNG_MAGIC = b"\x89PNG\r\n\x1a\n"


def die(msg):
    print(f"png2nds1: {msg}", file=sys.stderr)
    raise SystemExit(1)


def read_chunks(data):
    """Yield (type, payload) for each chunk, verifying the CRC of every one."""
    if data[:8] != PNG_MAGIC:
        die("not a PNG")
    pos = 8
    while pos + 8 <= len(data):
        (length,) = struct.unpack(">I", data[pos : pos + 4])
        ctype = data[pos + 4 : pos + 8]
        payload = data[pos + 8 : pos + 8 + length]
        (want,) = struct.unpack(">I", data[pos + 8 + length : pos + 12 + length])
        if zlib.crc32(ctype + payload) & 0xFFFFFFFF != want:
            die(f"chunk {ctype.decode('ascii', 'replace')} failed its CRC")
        yield ctype, payload
        pos += 12 + length


def unfilter(raw, width, height):
    """Undo the per-scanline PNG filters. 4 bytes per pixel, so bpp == 4."""
    bpp = 4
    stride = width * bpp
    out = bytearray(stride * height)
    prev = bytearray(stride)
    pos = 0
    for y in range(height):
        ftype = raw[pos]
        pos += 1
        line = bytearray(raw[pos : pos + stride])
        pos += stride
        if ftype == 0:
            pass
        elif ftype == 1:  # Sub
            for i in range(bpp, stride):
                line[i] = (line[i] + line[i - bpp]) & 0xFF
        elif ftype == 2:  # Up
            for i in range(stride):
                line[i] = (line[i] + prev[i]) & 0xFF
        elif ftype == 3:  # Average
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                line[i] = (line[i] + ((a + prev[i]) >> 1)) & 0xFF
        elif ftype == 4:  # Paeth
            for i in range(stride):
                a = line[i - bpp] if i >= bpp else 0
                b = prev[i]
                c = prev[i - bpp] if i >= bpp else 0
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pr = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[i] = (line[i] + pr) & 0xFF
        else:
            die(f"unknown scanline filter {ftype} on row {y}")
        out[y * stride : (y + 1) * stride] = line
        prev = line
    return out


def main(argv):
    if len(argv) != 3:
        die("usage: png2nds1.py <in.png> <out.nds1>")
    src, dst = argv[1], argv[2]

    with open(src, "rb") as fh:
        data = fh.read()

    width = height = None
    idat = bytearray()
    for ctype, payload in read_chunks(data):
        if ctype == b"IHDR":
            width, height, depth, colour, compression, filt, interlace = struct.unpack(
                ">IIBBBBB", payload[:13]
            )
            if depth != 8:
                die(f"expected 8-bit samples, got {depth}")
            if colour != 6:
                die(f"expected RGBA (colour type 6), got colour type {colour}")
            if compression != 0 or filt != 0:
                die("unexpected compression/filter method")
            if interlace != 0:
                die("interlaced PNGs are not supported")
        elif ctype == b"IDAT":
            idat += payload
        elif ctype == b"IEND":
            break

    if width is None:
        die("no IHDR")
    if not idat:
        die("no image data")

    raw = zlib.decompress(bytes(idat))
    if len(raw) != (width * 4 + 1) * height:
        die(f"decompressed to {len(raw)} bytes, expected {(width * 4 + 1) * height}")

    rgba = unfilter(raw, width, height)

    # RGBA -> BGRA. Slice assignment on a bytearray is the fast path here; the logo is ~1440^2,
    # and a per-pixel Python loop over 2M pixels is measurably slow in a build step.
    bgra = bytearray(rgba)
    bgra[0::4] = rgba[2::4]
    bgra[2::4] = rgba[0::4]

    with open(dst, "wb") as fh:
        fh.write(b"NDS1")
        fh.write(struct.pack("<II", width, height))
        fh.write(bgra)

    print(f"png2nds1: {src} -> {dst} ({width}x{height}, {12 + len(bgra)} bytes)")


if __name__ == "__main__":
    main(sys.argv)
