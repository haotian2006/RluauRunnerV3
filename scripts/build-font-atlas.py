"""Usage: python scripts/build-font-atlas.py OUT.luau regular=R.ttf bold=B.ttf [--header LINE ...] [--ascender N --descender N]

Needs freetype-py numpy scipy zstandard. Atlas byte 127.5 is the outline, 255 / (2 * SPREAD) per px, inside brighter.
"""

import argparse
import base64

import freetype
import numpy as np
import zstandard
from scipy.ndimage import distance_transform_edt

EM = 32  # atlas px per em
SPREAD = 4  # distance-field reach, atlas px
ATLAS_W = 512
SS = 16  # supersampling for the outline raster
GAP = 1  # px between packed glyphs
CODEPOINTS = list(range(32, 127)) + [8230, 8226, 176, 169]


def num(x):
    s = f"{x:.3f}".rstrip("0").rstrip(".")
    return "0" if s == "-0" else s


def render_glyph(face, cp, upem):
    face.load_char(cp, freetype.FT_LOAD_NO_HINTING | freetype.FT_LOAD_NO_BITMAP)
    gs = face.glyph
    advance = face.get_advance(face.get_char_index(cp), freetype.FT_LOAD_NO_SCALE) * EM / upem
    gs.render(freetype.FT_RENDER_MODE_NORMAL)
    bm = gs.bitmap
    if bm.width == 0 or bm.rows == 0:
        return advance, None
    hi = np.array(bm.buffer, np.uint8).reshape(bm.rows, bm.pitch)[:, : bm.width]
    # glyph box in atlas px, padded by SPREAD; hi-res bitmap lands inside it at whole px
    left, top = gs.bitmap_left, gs.bitmap_top  # hi-res px, y up
    x0 = left // SS - SPREAD
    x1 = -(-(left + bm.width) // SS) + SPREAD
    y0 = -top // SS - SPREAD  # y down
    y1 = -(-(bm.rows - top) // SS) + SPREAD
    w, h = x1 - x0, y1 - y0
    canvas = np.zeros((h * SS, w * SS), bool)
    cx, cy = left - x0 * SS, -top - y0 * SS
    canvas[cy : cy + bm.rows, cx : cx + bm.width] = hi >= 128
    d_in = distance_transform_edt(canvas)
    d_out = distance_transform_edt(~canvas)
    sd = np.where(canvas, d_in - 0.5, 0.5 - d_out) / SS  # atlas px, inside positive
    sd = sd.reshape(h, SS, w, SS).mean(axis=(1, 3))
    pix = np.clip(np.round(127.5 + sd * 255 / (2 * SPREAD)), 0, 255).astype(np.uint8)
    return advance, (pix, x0, y0)


def build_face(path, ascender=None, descender=None):
    face = freetype.Face(path)
    upem = face.units_per_EM
    face.set_char_size(EM * SS * 64, 0, 72, 72)
    glyphs = {}
    for cp in CODEPOINTS:
        if face.get_char_index(cp) == 0:
            raise SystemExit(f"{path}: no glyph for U+{cp:04X}")
        glyphs[cp] = render_glyph(face, cp, upem)

    # shelf packing, tallest first
    order = sorted((cp for cp in CODEPOINTS if glyphs[cp][1]), key=lambda c: -glyphs[c][1][0].shape[0])
    placed, x, y, shelf = {}, 0, 0, 0
    for cp in order:
        h, w = glyphs[cp][1][0].shape
        if x + w > ATLAS_W:
            x, y, shelf = 0, y + shelf + GAP, 0
        placed[cp] = (x, y)
        x += w + GAP
        shelf = max(shelf, h)
    height = y + shelf
    atlas = np.zeros((height, ATLAS_W), np.uint8)
    entries = []
    for cp in CODEPOINTS:
        advance, img = glyphs[cp]
        if not img:
            entries.append(f"[{cp}]={{{num(advance)},0,0,0,0,0,0}}")
            continue
        pix, ox, oy = img
        ax, ay = placed[cp]
        atlas[ay : ay + pix.shape[0], ax : ax + pix.shape[1]] = pix
        entries.append(f"[{cp}]={{{num(advance)},{ax},{ay},{pix.shape[1]},{pix.shape[0]},{ox},{oy}}}")

    scale = EM / upem
    asc = ascender if ascender is not None else face.ascender * scale
    desc = descender if descender is not None else face.descender * scale
    data = base64.b64encode(zstandard.ZstdCompressor(level=19).compress(atlas.tobytes())).decode()
    return height, asc, desc, data, ",".join(entries)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("out")
    ap.add_argument("faces", nargs="+", help="name=path.ttf")
    ap.add_argument("--header", action="append", default=[])
    ap.add_argument("--ascender", type=float, help="atlas px; default hhea ascender")
    ap.add_argument("--descender", type=float, help="atlas px; default hhea descender")
    a = ap.parse_args()

    if any("\n" in h or "\r" in h for h in a.header):
        ap.error("--header values must be single lines")
    lines = [f"-- {h}" for h in a.header]
    lines += [
        "-- Glyph entries: { advance, atlasX, atlasY, width, height, offsetX, offsetY } in atlas px at `em` px per em.",
        "-- Built by scripts/build-font-atlas.py.",
        "return {",
        f"\tem = {EM},",
        f"\tspread = {SPREAD},",
        f"\twidth = {ATLAS_W},",
    ]
    for spec in a.faces:
        name, path = spec.split("=", 1)
        height, asc, desc, data, glyphs = build_face(path, a.ascender, a.descender)
        lines += [
            f"\t{name} = {{",
            f"\t\theight = {height},",
            f"\t\tascender = {asc:.3f},",
            f"\t\tdescender = {desc:.3f},",
            f'\t\tdata = "{data}",',
            f"\t\tglyphs = {{{glyphs}}},",
            "\t},",
        ]
    lines.append("}")
    with open(a.out, "w", encoding="utf-8", newline="\n") as f:
        f.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
