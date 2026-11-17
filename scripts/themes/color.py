"""Color math for checking fx themes: WCAG 2 contrast, APCA lightness
contrast, OKLCH, CIEDE2000, and a deuteranopia simulation. Standard library
only."""
from __future__ import annotations

import math


def rgb(hex_color: str) -> tuple[int, int, int]:
    h = hex_color.lstrip("#")
    return int(h[0:2], 16), int(h[2:4], 16), int(h[4:6], 16)


def hex_of(r: float, g: float, b: float) -> str:
    return "#" + "".join(f"{round(min(max(v, 0), 255)):02X}" for v in (r, g, b))


def _linear(v: float) -> float:
    v /= 255
    return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4


def _encode(v: float) -> float:
    v = min(max(v, 0), 1)
    return 255 * (12.92 * v if v <= 0.0031308 else 1.055 * v ** (1 / 2.4) - 0.055)


def wcag_ratio(a: str, b: str) -> float:
    def luminance(c: str) -> float:
        r, g, bl = (_linear(v) for v in rgb(c))
        return 0.2126 * r + 0.7152 * g + 0.0722 * bl

    la, lb = luminance(a), luminance(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)


def apca(text: str, background: str) -> float:
    """APCA-W3 0.0.98G-4g lightness contrast (Lc) of text on background."""
    def y(c: str) -> float:
        r, g, b = ((v / 255) ** 2.4 for v in rgb(c))
        lum = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
        return lum if lum > 0.022 else lum + (0.022 - lum) ** 1.414

    yt, yb = y(text), y(background)
    if abs(yb - yt) < 0.0005:
        return 0.0
    if yb > yt:  # dark text on a light background
        sapc = (yb ** 0.56 - yt ** 0.57) * 1.14
        return 0.0 if sapc < 0.1 else (sapc - 0.027) * 100
    sapc = (yb ** 0.65 - yt ** 0.62) * 1.14
    return 0.0 if sapc > -0.1 else (sapc + 0.027) * 100


def to_oklch(hex_color: str) -> tuple[float, float, float]:
    r, g, b = (_linear(v) for v in rgb(hex_color))
    l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
    m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
    s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
    l, m, s = (math.copysign(abs(x) ** (1 / 3), x) for x in (l, m, s))
    lightness = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
    a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
    bb = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
    return lightness, math.hypot(a, bb), math.degrees(math.atan2(bb, a)) % 360


def from_oklch(lightness: float, chroma: float, hue: float) -> str:
    """OKLCH to hex, lowering chroma until the color fits in sRGB."""
    for _ in range(60):
        a, b = chroma * math.cos(math.radians(hue)), chroma * math.sin(math.radians(hue))
        l = (lightness + 0.3963377774 * a + 0.2158037573 * b) ** 3
        m = (lightness - 0.1055613458 * a - 0.0638541728 * b) ** 3
        s = (lightness - 0.0894841775 * a - 1.2914855480 * b) ** 3
        linear = (4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
                  -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
                  -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s)
        if all(-0.0005 <= v <= 1.0005 for v in linear):
            return hex_of(*(_encode(v) for v in linear))
        chroma *= 0.95
    return "#FFFFFF" if lightness > 0.5 else "#000000"


def _lab(c: str) -> tuple[float, float, float]:
    r, g, b = (_linear(v) for v in rgb(c))
    x = (0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047
    y = 0.2126 * r + 0.7152 * g + 0.0722 * b
    z = (0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883

    def f(t: float) -> float:
        return t ** (1 / 3) if t > 0.008856 else 7.787 * t + 16 / 116

    fx, fy, fz = f(x), f(y), f(z)
    return 116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz)


def ciede2000(c1: str, c2: str) -> float:
    l1, a1, b1 = _lab(c1)
    l2, a2, b2 = _lab(c2)
    cm = (math.hypot(a1, b1) + math.hypot(a2, b2)) / 2
    g = 0.5 * (1 - math.sqrt(cm ** 7 / (cm ** 7 + 25 ** 7)))
    a1p, a2p = (1 + g) * a1, (1 + g) * a2
    c1p, c2p = math.hypot(a1p, b1), math.hypot(a2p, b2)
    h1p = math.degrees(math.atan2(b1, a1p)) % 360
    h2p = math.degrees(math.atan2(b2, a2p)) % 360
    dlp, dcp = l2 - l1, c2p - c1p
    if c1p * c2p == 0:
        dhp = 0.0
    elif abs(h2p - h1p) <= 180:
        dhp = h2p - h1p
    else:
        dhp = h2p - h1p - 360 if h2p > h1p else h2p - h1p + 360
    dh = 2 * math.sqrt(c1p * c2p) * math.sin(math.radians(dhp / 2))
    lpm, cpm = (l1 + l2) / 2, (c1p + c2p) / 2
    if c1p * c2p == 0:
        hpm = h1p + h2p
    elif abs(h1p - h2p) <= 180:
        hpm = (h1p + h2p) / 2
    else:
        hpm = (h1p + h2p + 360) / 2 if h1p + h2p < 360 else (h1p + h2p - 360) / 2
    t = (1 - 0.17 * math.cos(math.radians(hpm - 30)) + 0.24 * math.cos(math.radians(2 * hpm))
         + 0.32 * math.cos(math.radians(3 * hpm + 6)) - 0.20 * math.cos(math.radians(4 * hpm - 63)))
    sl = 1 + 0.015 * (lpm - 50) ** 2 / math.sqrt(20 + (lpm - 50) ** 2)
    sc, sh = 1 + 0.045 * cpm, 1 + 0.015 * cpm * t
    rt = -2 * math.sqrt(cpm ** 7 / (cpm ** 7 + 25 ** 7)) * math.sin(math.radians(60 * math.exp(-((hpm - 275) / 25) ** 2)))
    return math.sqrt((dlp / sl) ** 2 + (dcp / sc) ** 2 + (dh / sh) ** 2 + rt * (dcp / sc) * (dh / sh))


def deuteranopia(c: str) -> str:
    """Machado et al. 2009 simulation at full severity."""
    m = ((0.367322, 0.860646, -0.227968), (0.280085, 0.672501, 0.047413), (-0.011820, 0.042940, 0.968881))
    lin = [_linear(v) for v in rgb(c)]
    return hex_of(*(_encode(sum(m[i][j] * lin[j] for j in range(3))) for i in range(3)))


def distances(a: str, b: str) -> tuple[float, float]:
    """CIEDE2000 for normal vision and under deuteranopia."""
    return ciede2000(a, b), ciede2000(deuteranopia(a), deuteranopia(b))
