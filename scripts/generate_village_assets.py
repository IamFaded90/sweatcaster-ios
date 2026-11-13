#!/usr/bin/env python3
"""Generate FadedAI Landsbyen + Kontoret pixel assets (original CC0 work).

Style: coherent 2:1 isometric pixel art.
Palette: dark petrol / night blue with warm window light and discrete accents.
All output PNGs are transparent where appropriate; no baked-in labels/UI.
"""

from __future__ import annotations

import json
import math
from pathlib import Path

from PIL import Image, ImageDraw

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "App" / "Assets" / "Village"
PREVIEW = OUT / "previews"

# --- Palette ---------------------------------------------------------------
PAL = {
    "void": (0, 0, 0, 0),
    "petrol_deep": (8, 36, 42, 255),
    "petrol": (12, 52, 58, 255),
    "petrol_mid": (18, 72, 78, 255),
    "petrol_light": (36, 98, 104, 255),
    "night": (6, 18, 40, 255),
    "night_mid": (10, 32, 58, 255),
    "sky_day": (28, 58, 78, 255),
    "sky_day_hi": (48, 92, 118, 255),
    "grass_dark": (18, 64, 48, 255),
    "grass": (28, 92, 62, 255),
    "grass_light": (46, 122, 78, 255),
    "dirt_dark": (52, 58, 42, 255),
    "dirt": (74, 78, 52, 255),
    "dirt_light": (96, 98, 64, 255),
    "plaza_dark": (58, 68, 78, 255),
    "plaza": (78, 90, 102, 255),
    "plaza_light": (108, 120, 132, 255),
    "path_dark": (110, 88, 58, 255),
    "path": (148, 118, 78, 255),
    "path_light": (178, 148, 100, 255),
    "shadow": (0, 0, 0, 90),
    "shadow_hard": (0, 0, 0, 140),
    "outline": (4, 12, 18, 255),
    "warm": (255, 208, 120, 255),
    "warm_bright": (255, 236, 170, 255),
    "warm_dim": (200, 140, 70, 255),
    "window_day": (90, 170, 190, 255),
    "wood": (92, 62, 40, 255),
    "wood_light": (130, 92, 58, 255),
    "metal": (70, 86, 98, 255),
    "metal_light": (120, 140, 155, 255),
    "roof_research": (36, 78, 118, 255),
    "wall_research": (48, 92, 110, 255),
    "accent_research": (70, 160, 210, 255),
    "roof_studio": (88, 42, 96, 255),
    "wall_studio": (72, 58, 98, 255),
    "accent_studio": (190, 90, 160, 255),
    "roof_cafe": (118, 72, 42, 255),
    "wall_cafe": (96, 78, 58, 255),
    "accent_cafe": (220, 140, 70, 255),
    "roof_sleep": (42, 58, 98, 255),
    "wall_sleep": (58, 72, 108, 255),
    "accent_sleep": (140, 170, 230, 255),
    "leaf": (24, 110, 64, 255),
    "leaf_dark": (12, 72, 42, 255),
    "leaf_light": (58, 150, 88, 255),
    "lamp": (180, 170, 140, 255),
    "lamp_glow": (255, 220, 140, 200),
    "adam_skin": (210, 170, 130, 255),
    "adam_hair": (40, 56, 78, 255),
    "adam_shirt": (42, 92, 150, 255),
    "adam_accent": (90, 170, 255, 255),
    "adam_pants": (28, 48, 78, 255),
    "eva_skin": (224, 176, 148, 255),
    "eva_hair": (96, 48, 120, 255),
    "eva_shirt": (120, 72, 168, 255),
    "eva_accent": (190, 130, 255, 255),
    "eva_pants": (58, 36, 88, 255),
    "office_floor": (42, 58, 68, 255),
    "office_floor_hi": (58, 78, 90, 255),
    "office_wall": (22, 40, 56, 255),
    "office_wall_hi": (36, 58, 78, 255),
    "desk": (86, 64, 46, 255),
    "desk_top": (130, 98, 68, 255),
    "chair": (48, 62, 78, 255),
    "chair_seat": (70, 92, 118, 255),
    "screen": (20, 36, 48, 255),
    "screen_glow": (80, 200, 180, 255),
    "plant_pot": (120, 70, 50, 255),
}


def rgba(name: str):
    return PAL[name]


def new_img(w: int, h: int) -> Image.Image:
    return Image.new("RGBA", (w, h), (0, 0, 0, 0))


def put(img: Image.Image, x: int, y: int, color):
    if 0 <= x < img.width and 0 <= y < img.height and color[3] > 0:
        img.putpixel((x, y), color)


def fill_rect(img: Image.Image, x0: int, y0: int, x1: int, y1: int, color):
    for y in range(y0, y1 + 1):
        for x in range(x0, x1 + 1):
            put(img, x, y, color)


def blend(a, b, t: float):
    return tuple(int(a[i] * (1 - t) + b[i] * t) for i in range(4))


def iso_diamond_fill(img: Image.Image, cx: int, cy: int, w: int, h: int, color, noise=None):
    """Fill a 2:1 isometric diamond centered at (cx, cy)."""
    hw, hh = w // 2, h // 2
    for y in range(-hh, hh + 1):
        # width at this row for diamond
        if hh == 0:
            continue
        span = int(hw * (1 - abs(y) / hh))
        for x in range(-span, span + 1):
            c = color
            if noise is not None and ((x * 3 + y * 7) % 11 == 0):
                c = noise
            put(img, cx + x, cy + y, c)


def iso_diamond_outline(img: Image.Image, cx: int, cy: int, w: int, h: int, color):
    hw, hh = w // 2, h // 2
    # four edges
    for i in range(hw + 1):
        t = i / max(1, hw)
        put(img, cx - hw + i, cy - int(hh * (1 - t)), color)  # NW
        put(img, cx - hw + i, cy + int(hh * (1 - t)), color)  # SW
        put(img, cx + hw - i, cy - int(hh * (1 - t)), color)  # NE
        put(img, cx + hw - i, cy + int(hh * (1 - t)), color)  # SE


def in_diamond(px: int, py: int, cx: int, cy: int, w: int, h: int) -> bool:
    hw, hh = w / 2, h / 2
    if hw == 0 or hh == 0:
        return False
    return abs((px - cx) / hw) + abs((py - cy) / hh) <= 1.0


# --- Terrain tiles (64x32) -------------------------------------------------

def make_terrain_tile(kind: str) -> Image.Image:
    img = new_img(64, 32)
    cx, cy = 32, 16
    if kind == "grass":
        base, mid, hi = rgba("grass_dark"), rgba("grass"), rgba("grass_light")
    elif kind == "dirt":
        base, mid, hi = rgba("dirt_dark"), rgba("dirt"), rgba("dirt_light")
    elif kind == "plaza":
        base, mid, hi = rgba("plaza_dark"), rgba("plaza"), rgba("plaza_light")
    else:
        raise ValueError(kind)

    for y in range(32):
        for x in range(64):
            if not in_diamond(x, y, cx, cy, 62, 30):
                continue
            # subtle gradient: brighter toward top-right
            t = ((x - y) % 17) / 17
            c = blend(base, mid, 0.45 + 0.3 * t)
            if (x + y * 3) % 13 == 0:
                c = hi if kind != "plaza" else blend(mid, hi, 0.6)
            if kind == "plaza" and ((x // 8 + y // 4) % 2 == 0) and (x + y) % 5 == 0:
                c = blend(mid, rgba("plaza_light"), 0.5)
            put(img, x, y, c)
    iso_diamond_outline(img, cx, cy, 62, 30, rgba("outline"))
    return img


def make_path_tile(variant: str) -> Image.Image:
    """Path variants on transparent diamond footprint."""
    img = new_img(64, 32)
    cx, cy = 32, 16
    # base path diamond faintly
    for y in range(32):
        for x in range(64):
            if in_diamond(x, y, cx, cy, 62, 30):
                put(img, x, y, rgba("dirt_dark"))

    def paint_band(points, width=5):
        for px, py in points:
            for dy in range(-width // 2, width // 2 + 1):
                for dx in range(-width // 2, width // 2 + 1):
                    if abs(dx) + abs(dy) <= width // 2 + 1:
                        xx, yy = px + dx, py + dy
                        if in_diamond(xx, yy, cx, cy, 62, 30):
                            c = rgba("path") if (xx + yy) % 4 else rgba("path_light")
                            if (xx * 2 + yy) % 9 == 0:
                                c = rgba("path_dark")
                            put(img, xx, yy, c)

    # NE-SW diagonal (rising to the right): y decreases as x increases relative to center
    ne_sw = [(cx + t, cy - t // 2) for t in range(-28, 29)]
    nw_se = [(cx + t, cy + t // 2) for t in range(-28, 29)]

    if variant == "straight_ne":
        paint_band(ne_sw, 7)
    elif variant == "straight_nw":
        paint_band(nw_se, 7)
    elif variant == "cross":
        paint_band(ne_sw, 7)
        paint_band(nw_se, 7)
    elif variant == "corner_n":
        paint_band([(cx + t, cy - t // 2) for t in range(0, 29)], 7)
        paint_band([(cx - t, cy - t // 2) for t in range(0, 29)], 7)
    elif variant == "corner_e":
        paint_band([(cx + t, cy - t // 2) for t in range(0, 29)], 7)
        paint_band([(cx + t, cy + t // 2) for t in range(0, 29)], 7)
    elif variant == "corner_s":
        paint_band([(cx + t, cy + t // 2) for t in range(0, 29)], 7)
        paint_band([(cx - t, cy + t // 2) for t in range(0, 29)], 7)
    elif variant == "corner_w":
        paint_band([(cx - t, cy - t // 2) for t in range(0, 29)], 7)
        paint_band([(cx - t, cy + t // 2) for t in range(0, 29)], 7)
    elif variant == "t_n":
        paint_band(ne_sw, 7)
        paint_band([(cx + t, cy - t // 2) for t in range(-14, 15) if t], 7)  # noop keep
        paint_band([(cx - t, cy - abs(t) // 2) for t in range(0, 29)], 7)
        paint_band([(cx + t, cy - abs(t) // 2) for t in range(0, 29)], 7)
    elif variant == "t_e":
        paint_band(nw_se, 7)
        paint_band([(cx + t, cy - t // 2) for t in range(0, 29)], 7)
        paint_band([(cx + t, cy + t // 2) for t in range(0, 29)], 7)
    elif variant == "t_s":
        paint_band(ne_sw, 7)
        paint_band([(cx - t, cy + abs(t) // 2) for t in range(0, 29)], 7)
        paint_band([(cx + t, cy + abs(t) // 2) for t in range(0, 29)], 7)
    elif variant == "t_w":
        paint_band(nw_se, 7)
        paint_band([(cx - t, cy - t // 2) for t in range(0, 29)], 7)
        paint_band([(cx - t, cy + t // 2) for t in range(0, 29)], 7)
    else:
        raise ValueError(variant)

    iso_diamond_outline(img, cx, cy, 62, 30, rgba("outline"))
    return img


# --- Buildings (192x192 layered) -------------------------------------------

BUILDINGS = {
    "research_lab": {
        "roof": "roof_research",
        "wall": "wall_research",
        "accent": "accent_research",
        "style": "lab",
    },
    "video_studio": {
        "roof": "roof_studio",
        "wall": "wall_studio",
        "accent": "accent_studio",
        "style": "studio",
    },
    "cafe": {
        "roof": "roof_cafe",
        "wall": "wall_cafe",
        "accent": "accent_cafe",
        "style": "cafe",
    },
    "sleep_nook": {
        "roof": "roof_sleep",
        "wall": "wall_sleep",
        "accent": "accent_sleep",
        "style": "sleep",
    },
}


def fill_para(img, x0, y0, x1, y1, x2, y2, x3, y3, color_fn):
    """Fill parallelogram / quad by scanline (corners in any order)."""
    pts = [(x0, y0), (x1, y1), (x2, y2), (x3, y3)]
    min_y = max(0, min(p[1] for p in pts))
    max_y = min(img.height - 1, max(p[1] for p in pts))
    for y in range(min_y, max_y + 1):
        xs = []
        for i in range(4):
            (ax, ay), (bx, by) = pts[i], pts[(i + 1) % 4]
            if ay == by:
                if y == ay:
                    xs.extend([ax, bx])
                continue
            if (ay <= y <= by) or (by <= y <= ay):
                t = (y - ay) / (by - ay)
                xs.append(ax + t * (bx - ax))
        if len(xs) < 2:
            continue
        xa, xb = int(min(xs)), int(max(xs))
        for x in range(max(0, xa), min(img.width - 1, xb) + 1):
            put(img, x, y, color_fn(x, y))


def building_geometry():
    """Shared building footprint for layered assets. Foot/anchor at (96, 176)."""
    cx, foot_y = 96, 176
    half_w, half_d, wall_h = 64, 32, 64
    # roof diamond center
    top_y = foot_y - wall_h - half_d
    return cx, foot_y, half_w, half_d, wall_h, top_y


def draw_building_base(style: str, colors: dict) -> Image.Image:
    img = new_img(192, 192)
    cx, foot_y, half_w, half_d, wall_h, top_y = building_geometry()

    roof = rgba(colors["roof"])
    wall = rgba(colors["wall"])
    accent = rgba(colors["accent"])
    left = blend(wall, rgba("petrol_deep"), 0.28)
    right = blend(wall, rgba("petrol_light"), 0.18)
    roof_hi = blend(roof, (255, 255, 255, 255), 0.12)

    # Ground pad under building (separate from terrain — helps placement)
    for y in range(192):
        for x in range(192):
            if in_diamond(x, y, cx, foot_y - 4, 148, 68):
                put(img, x, y, rgba("grass_dark") if (x + y) % 7 else rgba("grass"))

    # Corners of roof diamond (N, E, S, W)
    n = (cx, top_y - half_d)
    e = (cx + half_w, top_y)
    s = (cx, top_y + half_d)
    w = (cx - half_w, top_y)
    # Base of walls (same diamond shifted down by wall_h)
    bn = (cx, top_y - half_d + wall_h)
    be = (cx + half_w, top_y + wall_h)
    bs = (cx, top_y + half_d + wall_h)
    bw = (cx - half_w, top_y + wall_h)

    # Left wall: W-S-BS-BW
    def left_fn(x, y):
        band = ((x + y) // 10) % 4
        c = left if band else blend(left, accent, 0.10)
        if (x + 2 * y) % 17 == 0:
            c = blend(c, rgba("outline"), 0.18)
        return c

    fill_para(img, w[0], w[1], s[0], s[1], bs[0], bs[1], bw[0], bw[1], left_fn)

    # Right wall: S-E-BE-BS
    def right_fn(x, y):
        band = ((x - y) // 10) % 4
        c = right if band else blend(right, accent, 0.06)
        if (2 * x + y) % 19 == 0:
            c = blend(c, rgba("outline"), 0.12)
        return c

    fill_para(img, s[0], s[1], e[0], e[1], be[0], be[1], bs[0], bs[1], right_fn)

    # Roof top face N-E-S-W
    def roof_fn(x, y):
        c = roof_hi if (x - cx) > 8 else roof
        if (x + y) % 11 == 0:
            c = blend(c, rgba("outline"), 0.22)
        return c

    fill_para(img, n[0], n[1], e[0], e[1], s[0], s[1], w[0], w[1], roof_fn)

    # Roof outline
    for a, b in ((n, e), (e, s), (s, w), (w, n)):
        steps = max(abs(b[0] - a[0]), abs(b[1] - a[1]))
        for i in range(steps + 1):
            t = i / max(1, steps)
            put(img, int(a[0] + (b[0] - a[0]) * t), int(a[1] + (b[1] - a[1]) * t), rgba("outline"))

    # Door at front (near S corner, spanning left/right)
    door_x = cx - 7
    door_y = bs[1] - 30
    fill_rect(img, door_x, door_y, door_x + 14, door_y + 28, rgba("wood"))
    fill_rect(img, door_x + 2, door_y + 2, door_x + 12, door_y + 26, rgba("wood_light"))
    put(img, door_x + 11, door_y + 15, rgba("metal_light"))

    # Day windows on left and right faces
    left_wins = [
        (cx - 46, top_y + 18),
        (cx - 30, top_y + 26),
    ]
    right_wins = [
        (cx + 18, top_y + 18),
        (cx + 34, top_y + 26),
    ]
    for wx, wy in left_wins + right_wins:
        fill_rect(img, wx, wy, wx + 11, wy + 13, rgba("outline"))
        fill_rect(img, wx + 1, wy + 1, wx + 10, wy + 12, rgba("window_day"))
        put(img, wx + 6, wy + 1, rgba("outline"))  # mullion
        put(img, wx + 6, wy + 12, rgba("outline"))

    # Style details
    if style == "lab":
        fill_rect(img, cx - 2, top_y - half_d - 26, cx + 2, top_y - half_d, rgba("metal"))
        for a in range(-10, 11):
            put(img, cx + a, top_y - half_d - 26 - abs(a) // 2, accent)
            put(img, cx + a, top_y - half_d - 24 - abs(a) // 2, accent)
        # side vent
        fill_rect(img, cx - 52, top_y + 40, cx - 40, top_y + 48, rgba("metal_light"))
    elif style == "studio":
        fill_rect(img, cx + 18, top_y - 10, cx + 42, top_y + 8, rgba("metal"))
        fill_rect(img, cx + 22, top_y - 6, cx + 38, top_y + 4, accent)
        # boom arm
        fill_rect(img, cx - 8, top_y - half_d - 4, cx + 20, top_y - half_d, rgba("metal_light"))
        fill_rect(img, cx - 44, top_y + 8, cx - 22, top_y + 16, rgba("metal"))
    elif style == "cafe":
        for i in range(7):
            c = accent if i % 2 == 0 else rgba("warm")
            fill_para(
                img,
                cx + 6 + i * 8, top_y + 10,
                cx + 12 + i * 8, top_y + 13,
                cx + 12 + i * 8, top_y + 20,
                cx + 6 + i * 8, top_y + 17,
                lambda x, y, cc=c: cc,
            )
        fill_rect(img, cx - 30, top_y - half_d - 14, cx - 18, top_y - half_d + 4, rgba("plaza_dark"))
        fill_rect(img, cx - 28, top_y - half_d - 18, cx - 20, top_y - half_d - 14, rgba("warm_dim"))
    elif style == "sleep":
        fill_para(
            img,
            cx - 14, top_y - 8,
            cx, top_y - 18,
            cx + 14, top_y - 8,
            cx, top_y + 2,
            lambda x, y: blend(roof, accent, 0.35),
        )
        put(img, cx, top_y - half_d - 8, accent)
        put(img, cx - 1, top_y - half_d - 7, accent)
        put(img, cx + 1, top_y - half_d - 7, accent)
        put(img, cx, top_y - half_d - 6, accent)

    return img


def draw_building_shadow(style: str) -> Image.Image:
    img = new_img(192, 192)
    cx, foot_y, *_ = building_geometry()
    for y in range(192):
        for x in range(192):
            if in_diamond(x, y, cx + 20, foot_y + 2, 136, 54):
                put(img, x, y, rgba("shadow"))
            if in_diamond(x, y, cx + 12, foot_y - 2, 96, 38):
                put(img, x, y, rgba("shadow_hard"))
    return img


def draw_building_windows_night(style: str, colors: dict) -> Image.Image:
    img = new_img(192, 192)
    cx, foot_y, half_w, half_d, wall_h, top_y = building_geometry()
    windows = [
        (cx - 46, top_y + 18),
        (cx - 30, top_y + 26),
        (cx + 18, top_y + 18),
        (cx + 34, top_y + 26),
    ]
    if style == "sleep":
        windows = windows[:2]
    for wx, wy in windows:
        fill_rect(img, wx, wy, wx + 11, wy + 13, rgba("warm"))
        fill_rect(img, wx + 2, wy + 2, wx + 9, wy + 11, rgba("warm_bright"))
        for gy in range(-3, 16):
            for gx in range(-3, 14):
                if abs(gx - 5) + abs(gy - 6) <= 10:
                    xx, yy = wx + gx, wy + gy
                    if 0 <= xx < 192 and 0 <= yy < 192 and img.getpixel((xx, yy))[3] == 0:
                        put(img, xx, yy, (255, 200, 100, 45))
    door_x, door_y = cx - 7, top_y + half_d + wall_h - 30
    fill_rect(img, door_x + 3, door_y + 6, door_x + 11, door_y + 22, (255, 180, 80, 100))
    return img


def draw_building_foreground(style: str) -> Image.Image:
    """Foreground props in front of building for depth sorting (bush / steps)."""
    img = new_img(192, 192)
    cx, foot_y, *_ = building_geometry()
    for i in range(3):
        for y in range(foot_y - 6 + i * 3, foot_y - 2 + i * 3):
            for x in range(cx - 16 + i * 2, cx + 16 - i * 2):
                put(img, x, y, rgba("plaza") if i % 2 == 0 else rgba("plaza_dark"))
    for bx, by in [(cx - 58, foot_y - 10), (cx + 52, foot_y - 8)]:
        for y in range(-10, 8):
            for x in range(-12, 13):
                if abs(x) / 12 + abs(y) / 10 <= 1:
                    put(img, bx + x, by + y, rgba("leaf") if (x + y) % 3 else rgba("leaf_dark"))
    if style == "cafe":
        fill_rect(img, cx + 28, foot_y - 16, cx + 38, foot_y - 4, rgba("wood"))
        fill_rect(img, cx + 26, foot_y - 18, cx + 40, foot_y - 16, rgba("wood_light"))
    return img


# --- Props -----------------------------------------------------------------

def make_tree() -> Image.Image:
    img = new_img(64, 96)
    # trunk
    fill_rect(img, 28, 58, 35, 88, rgba("wood"))
    fill_rect(img, 30, 58, 33, 88, rgba("wood_light"))
    # isometric canopy layers
    for layer, (cy, w, h, c) in enumerate([
        (52, 48, 24, "leaf_dark"),
        (42, 44, 22, "leaf"),
        (32, 36, 18, "leaf_light"),
    ]):
        for y in range(96):
            for x in range(64):
                if in_diamond(x, y, 32, cy, w, h):
                    col = rgba(c)
                    if (x + y + layer) % 7 == 0:
                        col = blend(col, rgba("outline"), 0.2)
                    put(img, x, y, col)
    # shadow under
    for y in range(88, 94):
        for x in range(18, 46):
            if in_diamond(x, y, 34, 90, 28, 10):
                put(img, x, y, rgba("shadow"))
    return img


def make_lamp() -> Image.Image:
    img = new_img(32, 64)
    fill_rect(img, 14, 20, 17, 56, rgba("metal"))
    fill_rect(img, 10, 56, 21, 60, rgba("metal_light"))
    # head
    fill_rect(img, 8, 10, 23, 22, rgba("lamp"))
    fill_rect(img, 10, 12, 21, 20, rgba("warm_bright"))
    # glow halo
    for y in range(4, 28):
        for x in range(2, 30):
            d = math.hypot(x - 15.5, y - 16)
            if 6 < d < 12 and img.getpixel((x, y))[3] == 0:
                put(img, x, y, (255, 220, 140, int(90 * (1 - (d - 6) / 6))))
    return img


def make_sign() -> Image.Image:
    """Blank signboard — app draws text overlays."""
    img = new_img(48, 48)
    fill_rect(img, 22, 18, 25, 42, rgba("wood"))
    fill_rect(img, 6, 8, 41, 24, rgba("wood_light"))
    fill_rect(img, 8, 10, 39, 22, rgba("plaza_dark"))
    # decorative corner bolts
    for x, y in [(9, 11), (37, 11), (9, 20), (37, 20)]:
        put(img, x, y, rgba("metal_light"))
    return img


# --- Characters ------------------------------------------------------------

def draw_character(who: str, pose: str = "idle") -> Image.Image:
    """64x64 sprite. Foot point: (32, 60). Adam=blue, Eva=purple."""
    img = new_img(64, 64)
    is_adam = who == "adam"

    skin = rgba("adam_skin" if is_adam else "eva_skin")
    hair = rgba("adam_hair" if is_adam else "eva_hair")
    shirt = rgba("adam_shirt" if is_adam else "eva_shirt")
    accent = rgba("adam_accent" if is_adam else "eva_accent")
    pants = rgba("adam_pants" if is_adam else "eva_pants")
    shoe = rgba("outline")

    # shadow under feet
    for y in range(56, 62):
        for x in range(22, 43):
            if in_diamond(x, y, 32, 58, 22, 8):
                put(img, x, y, rgba("shadow"))

    leg_shift = 0
    if pose == "walk_1":
        leg_shift = -3
    elif pose == "walk_2":
        leg_shift = 3
    elif pose == "sleep":
        fill_rect(img, 12, 38, 52, 50, shirt)
        fill_rect(img, 10, 34, 28, 46, skin)
        fill_rect(img, 6, 32, 22, 42, hair)
        if not is_adam:
            fill_rect(img, 4, 36, 10, 48, hair)
            fill_rect(img, 8, 30, 18, 34, accent)
        fill_rect(img, 48, 42, 56, 50, pants)
        fill_rect(img, 10, 30, 20, 34, accent)
        return img

    # feet anchored around (32, 60)
    fill_rect(img, 25 + leg_shift, 57, 30 + leg_shift, 60, shoe)
    fill_rect(img, 34 - leg_shift, 57, 39 - leg_shift, 60, shoe)
    fill_rect(img, 26 + leg_shift, 58, 29 + leg_shift, 59, blend(shoe, accent, 0.15))
    fill_rect(img, 35 - leg_shift, 58, 38 - leg_shift, 59, blend(shoe, accent, 0.15))

    # legs
    fill_rect(img, 26 + leg_shift, 46, 30 + leg_shift, 57, pants)
    fill_rect(img, 34 - leg_shift, 46, 38 - leg_shift, 57, pants)

    # body — distinct silhouettes
    if is_adam:
        # broader rectangular hoodie + hood accent
        fill_rect(img, 21, 26, 42, 48, shirt)
        fill_rect(img, 23, 28, 40, 46, blend(shirt, accent, 0.18))
        fill_rect(img, 27, 26, 36, 30, accent)  # collar
        fill_rect(img, 22, 44, 41, 47, shoe)  # belt
        # pocket accent
        fill_rect(img, 24, 36, 30, 42, blend(shirt, rgba("outline"), 0.25))
    else:
        # flared coat / dress silhouette + scarf
        for row in range(26, 50):
            flare = 1 + (row - 26) // 6
            fill_rect(img, 23 - flare, row, 40 + flare, row, shirt)
        fill_rect(img, 25, 28, 38, 46, blend(shirt, accent, 0.22))
        fill_rect(img, 29, 30, 42, 35, accent)  # scarf wrap
        fill_rect(img, 38, 35, 42, 46, accent)  # scarf end
        # hem highlight
        fill_rect(img, 20, 48, 43, 49, blend(shirt, accent, 0.4))

    if pose == "work":
        fill_rect(img, 14, 33, 22, 40, skin)
        fill_rect(img, 42, 33, 50, 40, skin)
        fill_rect(img, 14, 33, 16, 35, shirt)
        fill_rect(img, 48, 33, 50, 35, shirt)
    elif pose == "talk":
        fill_rect(img, 14, 22, 22, 36, skin)
        fill_rect(img, 42, 32, 50, 44, skin)
        put(img, 48, 16, accent)
        put(img, 50, 14, accent)
        put(img, 52, 16, accent)
        put(img, 50, 18, accent)
    elif pose == "rest":
        fill_rect(img, 16, 36, 24, 46, skin)
        fill_rect(img, 40, 36, 48, 46, skin)
    else:
        fill_rect(img, 16, 30, 22, 46, skin)
        fill_rect(img, 42, 30, 48, 46, skin)
        # sleeves
        fill_rect(img, 16, 30, 22, 34, shirt)
        fill_rect(img, 42, 30, 48, 34, shirt)

    # head
    fill_rect(img, 23, 12, 40, 28, skin)
    if is_adam:
        # short cropped hair + sideburns
        fill_rect(img, 23, 8, 40, 15, hair)
        fill_rect(img, 23, 14, 26, 22, hair)
        fill_rect(img, 37, 14, 40, 22, hair)
        # small blue earpiece
        fill_rect(img, 40, 18, 43, 22, accent)
    else:
        # long hair + purple streak
        fill_rect(img, 21, 8, 42, 16, hair)
        fill_rect(img, 19, 14, 24, 36, hair)
        fill_rect(img, 39, 14, 44, 38, hair)
        fill_rect(img, 22, 6, 32, 11, accent)
        fill_rect(img, 20, 34, 24, 42, hair)

    # face
    put(img, 28, 19, shoe)
    put(img, 35, 19, shoe)
    if pose != "sleep":
        put(img, 28, 19, accent)
        put(img, 35, 19, accent)
    put(img, 31, 23, blend(skin, shoe, 0.35))  # nose hint
    return img


def make_spritesheet(who: str, poses: list[str], cols: int = 4) -> tuple[Image.Image, dict]:
    frames = [draw_character(who, p) for p in poses]
    rows = math.ceil(len(frames) / cols)
    sheet = new_img(64 * cols, 64 * rows)
    meta = {
        "frame_width": 64,
        "frame_height": 64,
        "foot_point": {"x": 32, "y": 60},
        "fps": 6,
        "frames": [],
    }
    for i, (frame, pose) in enumerate(zip(frames, poses)):
        c, r = i % cols, i // cols
        sheet.paste(frame, (c * 64, r * 64), frame)
        meta["frames"].append({"index": i, "pose": pose, "x": c * 64, "y": r * 64})
    return sheet, meta


# --- Office ----------------------------------------------------------------

def make_office_background() -> Image.Image:
    img = new_img(320, 180)
    # wall
    fill_rect(img, 0, 0, 319, 70, rgba("office_wall"))
    for y in range(0, 70):
        for x in range(320):
            if (x + y * 3) % 29 == 0:
                put(img, x, y, rgba("office_wall_hi"))
    # wainscot
    fill_rect(img, 0, 60, 319, 78, rgba("petrol_mid"))
    # floor
    fill_rect(img, 0, 78, 319, 179, rgba("office_floor"))
    for y in range(78, 180):
        for x in range(320):
            # subtle tile grid
            if (x // 20 + y // 12) % 2 == 0 and (x + y) % 5 == 0:
                put(img, x, y, rgba("office_floor_hi"))
    # back windows
    for i in range(4):
        wx = 30 + i * 72
        fill_rect(img, wx, 12, wx + 48, 48, rgba("outline"))
        fill_rect(img, wx + 2, 14, wx + 46, 46, rgba("night_mid"))
        # city glow
        for gy in range(30, 46):
            for gx in range(wx + 4, wx + 44):
                if (gx + gy) % 6 == 0:
                    put(img, gx, gy, rgba("warm_dim"))
    # ceiling lights
    for lx in [80, 160, 240]:
        fill_rect(img, lx - 18, 2, lx + 18, 6, rgba("metal_light"))
        for y in range(6, 20):
            for x in range(lx - 22, lx + 23):
                if abs(x - lx) < 22 - (y - 6):
                    put(img, x, y, (255, 240, 200, 25))
    return img


def make_office_desk() -> Image.Image:
    img = new_img(48, 32)
    # top
    fill_rect(img, 2, 6, 45, 14, rgba("desk_top"))
    fill_rect(img, 0, 14, 47, 18, rgba("desk"))
    # legs
    fill_rect(img, 4, 18, 8, 30, rgba("wood"))
    fill_rect(img, 39, 18, 43, 30, rgba("wood"))
    # front panel
    fill_rect(img, 6, 18, 41, 26, blend(rgba("desk"), rgba("outline"), 0.2))
    return img


def make_office_chair() -> Image.Image:
    img = new_img(24, 28)
    fill_rect(img, 4, 10, 19, 18, rgba("chair_seat"))
    fill_rect(img, 6, 2, 17, 12, rgba("chair"))
    fill_rect(img, 10, 18, 13, 26, rgba("metal"))
    fill_rect(img, 4, 24, 19, 26, rgba("metal_light"))
    return img


def make_office_monitor() -> Image.Image:
    img = new_img(28, 24)
    fill_rect(img, 2, 2, 25, 16, rgba("outline"))
    fill_rect(img, 4, 4, 23, 14, rgba("screen"))
    # soft UI glow bars (not text)
    fill_rect(img, 6, 6, 14, 7, rgba("screen_glow"))
    fill_rect(img, 6, 9, 20, 10, blend(rgba("screen_glow"), rgba("screen"), 0.5))
    fill_rect(img, 6, 12, 12, 13, rgba("adam_accent"))
    fill_rect(img, 12, 16, 15, 20, rgba("metal"))
    fill_rect(img, 6, 20, 21, 22, rgba("metal_light"))
    return img


def make_office_plant() -> Image.Image:
    img = new_img(16, 24)
    fill_rect(img, 4, 14, 11, 22, rgba("plant_pot"))
    for y in range(2, 16):
        for x in range(2, 14):
            if abs(x - 8) / 6 + abs(y - 8) / 8 <= 1:
                put(img, x, y, rgba("leaf") if (x + y) % 2 else rgba("leaf_light"))
    return img


def make_office_mug() -> Image.Image:
    img = new_img(10, 10)
    fill_rect(img, 2, 3, 7, 9, rgba("accent_cafe"))
    fill_rect(img, 3, 4, 6, 5, rgba("warm"))
    put(img, 8, 5, rgba("accent_cafe"))
    put(img, 8, 6, rgba("accent_cafe"))
    return img


def compose_office_full() -> Image.Image:
    """Composited reference of office with 8 stations in 2 rows (no characters)."""
    bg = make_office_background()
    desk = make_office_desk()
    chair = make_office_chair()
    mon = make_office_monitor()
    plant = make_office_plant()
    mug = make_office_mug()

    # two rows of 4
    positions = []
    for row in range(2):
        for col in range(4):
            x = 18 + col * 76
            y = 78 + row * 46
            positions.append((x, y))

    for i, (x, y) in enumerate(positions):
        bg.alpha_composite(desk, (x, y))
        bg.alpha_composite(chair, (x + 12, y + 14))
        bg.alpha_composite(mon, (x + 10, y - 10))
        if i % 3 == 0:
            bg.alpha_composite(plant, (x + 36, y - 4))
        if i % 2 == 1:
            bg.alpha_composite(mug, (x + 34, y + 4))
    return bg


# --- Map compose / previews ------------------------------------------------

def tile_blit(dst, tile, map_x, map_y, origin_x, origin_y):
    """Place isometric tile where (map_x,map_y) is tile coord; screen from origin."""
    sx = origin_x + (map_x - map_y) * 32
    sy = origin_y + (map_x + map_y) * 16
    dst.alpha_composite(tile, (sx, sy))


def compose_village(night: bool = False) -> Image.Image:
    W, H = 640, 800
    img = new_img(W, H)
    if night:
        sky, ground = rgba("night"), rgba("petrol_deep")
    else:
        sky, ground = (72, 118, 148, 255), (40, 88, 96, 255)
    fill_rect(img, 0, 0, W - 1, H - 1, sky)
    for y in range(140, H):
        t = (y - 140) / (H - 140)
        fill_rect(img, 0, y, W - 1, y, blend(sky, ground, min(1, t * 1.35)))
    if not night:
        # soft daylight wash + horizon glow
        for y in range(0, 220):
            wash = blend(sky, (200, 220, 235, 255), 0.08 + 0.12 * (1 - y / 220))
            for x in range(W):
                if (x + y * 5) % 11 == 0:
                    put(img, x, y, wash)


    grass = make_terrain_tile("grass")
    dirt = make_terrain_tile("dirt")
    plaza = make_terrain_tile("plaza")
    path_ne = make_path_tile("straight_ne")
    path_nw = make_path_tile("straight_nw")
    path_cross = make_path_tile("cross")
    path_corner_e = make_path_tile("corner_e")

    ox, oy = 288, 200
    for my in range(0, 10):
        for mx in range(0, 10):
            tile_blit(img, grass if (mx + my) % 5 else dirt, mx, my, ox, oy)

    for mx, my in [(4, 4), (5, 4), (4, 5), (5, 5), (3, 4), (6, 4), (4, 3), (4, 6), (5, 3), (3, 5)]:
        tile_blit(img, plaza, mx, my, ox, oy)

    for i in range(1, 9):
        tile_blit(img, path_ne, i, 4, ox, oy)
        tile_blit(img, path_nw, 4, i, ox, oy)
    tile_blit(img, path_cross, 4, 4, ox, oy)
    tile_blit(img, path_corner_e, 5, 5, ox, oy)

    zones = {
        "research_lab": (2, 2),
        "video_studio": (7, 2),
        "cafe": (2, 7),
        "sleep_nook": (7, 7),
    }
    tree = make_tree()
    lamp = make_lamp()
    sign = make_sign()

    # draw order by depth (mx+my)
    ordered = sorted(zones.items(), key=lambda kv: kv[1][0] + kv[1][1])
    for name, (mx, my) in ordered:
        colors = BUILDINGS[name]
        shadow = draw_building_shadow(colors["style"])
        base = draw_building_base(colors["style"], colors)
        # building foot at tile center: sprite foot (96,176)
        sx = ox + (mx - my) * 32 + 32 - 96
        sy = oy + (mx + my) * 16 + 16 - 176
        img.alpha_composite(shadow, (sx, sy))
        img.alpha_composite(base, (sx, sy))
        if night:
            img.alpha_composite(draw_building_windows_night(colors["style"], colors), (sx, sy))
        img.alpha_composite(draw_building_foreground(colors["style"]), (sx, sy))
        img.alpha_composite(sign, (sx + 72, sy + 148))

    for mx, my in [(1, 3), (3, 1), (6, 1), (8, 3), (1, 6), (3, 8), (6, 8), (8, 6)]:
        sx = ox + (mx - my) * 32 + 32 - 32
        sy = oy + (mx + my) * 16 + 16 - 88
        img.alpha_composite(tree, (sx, sy))
    for mx, my in [(3, 3), (5, 3), (3, 5), (6, 5), (5, 6)]:
        sx = ox + (mx - my) * 32 + 32 - 16
        sy = oy + (mx + my) * 16 + 16 - 60
        img.alpha_composite(lamp, (sx, sy))
        if night:
            for gy in range(max(0, sy + 6), min(H, sy + 30)):
                for gx in range(max(0, sx), min(W, sx + 32)):
                    d = math.hypot(gx - (sx + 15), gy - (sy + 16))
                    if d < 18:
                        cur = img.getpixel((gx, gy))
                        glow = (255, 210, 120, int(55 * (1 - d / 18)))
                        img.putpixel((gx, gy), blend(cur, glow, glow[3] / 255))

    adam = draw_character("adam", "idle")
    eva = draw_character("eva", "work")
    # place by foot point (32, 60) on path near buildings
    ax = ox + (3 - 3) * 32 + 32 - 32
    ay = oy + (3 + 3) * 16 + 16 - 60
    img.alpha_composite(adam, (ax, ay))
    ex = ox + (6 - 3) * 32 + 32 - 32
    ey = oy + (6 + 3) * 16 + 16 - 60
    img.alpha_composite(eva, (ex, ey))

    return img


def crop_opaque(img: Image.Image, pad: int = 16) -> Image.Image:
    bbox = img.getbbox()
    if not bbox:
        return img
    x0, y0, x1, y1 = bbox
    x0 = max(0, x0 - pad)
    y0 = max(0, y0 - pad)
    x1 = min(img.width, x1 + pad)
    y1 = min(img.height, y1 + pad)
    return img.crop((x0, y0, x1, y1))


def phone_frame(content: Image.Image, title: str = "") -> Image.Image:
    """Wrap content in a vertical iPhone-like bezel for previews."""
    screen_w, screen_h = 390, 844
    phone_w, phone_h = 430, 900
    out = new_img(phone_w, phone_h)
    fill_rect(out, 0, 0, phone_w - 1, phone_h - 1, (12, 14, 18, 255))
    fill_rect(out, 12, 12, phone_w - 13, phone_h - 13, (28, 32, 40, 255))

    subject = crop_opaque(content, pad=24)
    # Fit width, pin near top (map above bot list area)
    scale = screen_w / subject.width
    nw, nh = screen_w, int(subject.height * scale)
    if nh > int(screen_h * 0.72):
        scale = (screen_h * 0.72) / subject.height
        nw, nh = int(subject.width * scale), int(subject.height * scale)
    fitted = subject.resize((max(1, nw), max(1, nh)), Image.Resampling.NEAREST)

    screen = new_img(screen_w, screen_h)
    bg = rgba("night") if "night" in title else rgba("sky_day_hi")
    fill_rect(screen, 0, 0, screen_w - 1, screen_h - 1, bg)
    # lower panel hint for bot list (empty — SwiftUI draws UI)
    fill_rect(screen, 0, int(screen_h * 0.62), screen_w - 1, screen_h - 1, rgba("petrol_deep"))
    for y in range(int(screen_h * 0.62), int(screen_h * 0.62) + 2):
        fill_rect(screen, 24, y, screen_w - 25, y, rgba("petrol_light"))
    ox = (screen_w - fitted.width) // 2
    oy = 36
    screen.alpha_composite(fitted, (ox, oy))
    out.alpha_composite(screen, (20, 28))
    fill_rect(out, phone_w // 2 - 60, 18, phone_w // 2 + 60, 36, (8, 8, 10, 255))
    fill_rect(out, phone_w // 2 - 50, phone_h - 28, phone_w // 2 + 50, phone_h - 22, (200, 200, 210, 180))
    return out


def save(img: Image.Image, path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    img.save(path, "PNG")
    print(f"wrote {path.relative_to(ROOT)} ({img.width}x{img.height})")


def main():
    tiles_dir = OUT / "tiles"
    bld_dir = OUT / "buildings"
    props_dir = OUT / "props"
    char_dir = OUT / "characters"
    office_dir = OUT / "office"

    # tiles
    for kind in ("grass", "dirt", "plaza"):
        save(make_terrain_tile(kind), tiles_dir / f"terrain_{kind}.png")
    for variant in (
        "straight_ne", "straight_nw", "cross",
        "corner_n", "corner_e", "corner_s", "corner_w",
        "t_n", "t_e", "t_s", "t_w",
    ):
        save(make_path_tile(variant), tiles_dir / f"path_{variant}.png")

    # buildings layered
    for name, colors in BUILDINGS.items():
        style = colors["style"]
        save(draw_building_base(style, colors), bld_dir / f"building_{name}.png")
        save(draw_building_shadow(style), bld_dir / f"building_{name}_shadow.png")
        save(draw_building_windows_night(style, colors), bld_dir / f"building_{name}_windows_night.png")
        save(draw_building_foreground(style), bld_dir / f"building_{name}_foreground.png")

    # props
    save(make_tree(), props_dir / "prop_tree.png")
    save(make_lamp(), props_dir / "prop_lamp.png")
    save(make_sign(), props_dir / "prop_sign.png")

    # characters
    save(draw_character("adam", "idle"), char_dir / "adam_idle.png")
    save(draw_character("eva", "idle"), char_dir / "eva_idle.png")
    adam_poses = ["idle", "walk_1", "walk_2", "work", "talk", "rest", "sleep"]
    eva_poses = ["idle", "walk_1", "walk_2", "work", "talk", "rest", "sleep"]
    adam_sheet, adam_meta = make_spritesheet("adam", adam_poses)
    eva_sheet, eva_meta = make_spritesheet("eva", eva_poses)
    save(adam_sheet, char_dir / "adam_spritesheet.png")
    save(eva_sheet, char_dir / "eva_spritesheet.png")
    (char_dir / "adam_spritesheet.json").write_text(json.dumps(adam_meta, indent=2) + "\n")
    (char_dir / "eva_spritesheet.json").write_text(json.dumps(eva_meta, indent=2) + "\n")
    print("wrote characters/*_spritesheet.json")

    # office
    save(make_office_background(), office_dir / "office_background.png")
    save(make_office_desk(), office_dir / "office_desk.png")
    save(make_office_chair(), office_dir / "office_chair.png")
    save(make_office_monitor(), office_dir / "office_monitor.png")
    save(make_office_plant(), office_dir / "office_decor_plant.png")
    save(make_office_mug(), office_dir / "office_decor_mug.png")
    save(compose_office_full(), office_dir / "office_composited_reference.png")

    # previews
    day = compose_village(night=False)
    night = compose_village(night=True)
    office = compose_office_full()
    save(day, PREVIEW / "preview_village_day.png")
    save(night, PREVIEW / "preview_village_night.png")
    save(phone_frame(day, "day"), PREVIEW / "preview_iphone_village_day.png")
    save(phone_frame(night, "night"), PREVIEW / "preview_iphone_village_night.png")
    save(phone_frame(office, "office"), PREVIEW / "preview_iphone_office.png")

    # also copy key previews to artifacts for walkthrough
    art = Path("/opt/cursor/artifacts")
    art.mkdir(parents=True, exist_ok=True)
    for name in (
        "preview_iphone_village_day.png",
        "preview_iphone_village_night.png",
        "preview_iphone_office.png",
        "preview_village_day.png",
        "preview_village_night.png",
    ):
        src = PREVIEW / name
        Image.open(src).save(art / name)
        print(f"artifact {name}")


if __name__ == "__main__":
    main()
