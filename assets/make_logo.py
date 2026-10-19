#!/usr/bin/env python3
"""Generates the autopilot-loop logo: a pixel-block wordmark in the style of an ASCII/ANSI-shadow banner
plus a pixel loop mark. Every 'pixel' is a rect, so the result does not depend on any font.
Run: python3 assets/make_logo.py   → assets/logo.svg, assets/mark.svg, assets/social-preview.svg"""
from pathlib import Path

HERE = Path(__file__).resolve().parent

# 5x7 block font, '#' = pixel
FONT = {
    "A": [".###.", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
    "U": ["#...#", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
    "T": ["#####", "..#..", "..#..", "..#..", "..#..", "..#..", "..#.."],
    "O": [".###.", "#...#", "#...#", "#...#", "#...#", "#...#", ".###."],
    "P": ["####.", "#...#", "#...#", "####.", "#....", "#....", "#...."],
    "I": ["###", ".#.", ".#.", ".#.", ".#.", ".#.", "###"],
    "L": ["#....", "#....", "#....", "#....", "#....", "#....", "#####"],
    "-": ["...", "...", "...", "###", "...", "...", "..."],
}

# 13x13 mark: a loop of blocks with an arrow head (top right) and a check mark inside
MARK = [
    "....#####....",
    "..##.....##..",
    ".#.........#.",
    ".#.........#.",
    "#.........###",
    "#........C.#.",
    "#.......C....",
    "#.C....C.....",
    "#..C..C.....#",
    ".#..CC.....#.",
    ".#.........#.",
    "..##.....##..",
    "....#####....",
]

BLUE, PURPLE, GREEN = (59, 130, 246), (139, 92, 246), (34, 197, 94)
SHADOW = "#0b1020"


def mix(a, b, t):
    return "#%02x%02x%02x" % tuple(round(a[i] + (b[i] - a[i]) * t) for i in range(3))


def text_pixels(text, gap=1):
    """(x, y) pixel positions for a string in the block font."""
    pixels, x = [], 0
    for ch in text:
        glyph = FONT[ch]
        for y, row in enumerate(glyph):
            pixels += [(x + i, y) for i, c in enumerate(row) if c == "#"]
        x += len(glyph[0]) + gap
    return pixels, x - gap


def blocks(pixels, size, ox, oy, colour, shadow=True):
    """SVG rects for pixels; colour is a function (x) -> hex. Shadow = offset dark copy (ANSI-shadow look)."""
    out = []
    r = size * 0.18
    if shadow and not LIGHT:
        out += [f'<rect x="{ox + (x + 0.3) * size:.1f}" y="{oy + (y + 0.3) * size:.1f}" width="{size * 0.92:.1f}" '
                f'height="{size * 0.92:.1f}" rx="{r:.1f}" fill="{SHADOW}" opacity="0.55"/>' for x, y in pixels]
    out += [f'<rect x="{ox + x * size:.1f}" y="{oy + y * size:.1f}" width="{size * 0.92:.1f}" height="{size * 0.92:.1f}" '
            f'rx="{r:.1f}" fill="{colour(x)}"/>' for x, y in pixels]
    return out


def mark(size, ox, oy):
    loop = [(x, y) for y, row in enumerate(MARK) for x, c in enumerate(row) if c == "#"]
    check = [(x, y) for y, row in enumerate(MARK) for x, c in enumerate(row) if c == "C"]
    w = len(MARK[0])
    return (blocks(loop, size, ox, oy, lambda x: mix(BLUE, PURPLE, x / (w - 1)))
            + blocks(check, size, ox, oy, lambda x: mix(GREEN, (134, 239, 172), x / (w - 1))))


def wordmark(size, ox, oy):
    a, wa = text_pixels("AUTOPILOT")
    l, wl = text_pixels("LOOP")
    out = blocks(a, size, ox, oy, lambda x: mix(BLUE, PURPLE, x / (wa - 1)))
    out += blocks(l, size, ox, oy + 9 * size, lambda x: mix(GREEN, (20, 184, 166), x / (wl - 1)))
    # block cursor after LOOP, like a terminal prompt waiting for the next task
    out.append(f'<rect x="{ox + (wl + 1) * size:.1f}" y="{oy + 9 * size:.1f}" width="{size * 2.6:.1f}" '
               f'height="{size * 6.92:.1f}" rx="{size * 0.18:.1f}" fill="{"#334155" if LIGHT else "#e2e8f0"}" opacity="0.85"/>')
    return out, wa


def svg(w, h, body, background=None):
    bg = background or ""
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" width="{w}" height="{h}" '
            f'role="img" aria-label="autopilot-loop">\n<title>autopilot-loop</title>\n{bg}' + "\n".join(body) + "\n</svg>\n")


LIGHT = False  # light variant: no shadow, dark cursor (for light page backgrounds)


def main():
    global LIGHT
    # Logo: mark left, two-line wordmark right; logo.svg for dark pages, logo-light.svg for light pages
    s, pad = 8, 8 * 1.5
    for LIGHT, name in ((False, "logo.svg"), (True, "logo-light.svg")):
        words, wa = wordmark(s, pad + 17 * s, pad)
        logo_w, logo_h = int(pad * 2 + (17 + wa + 4) * s), int(pad * 2 + 17 * s)
        (HERE / name).write_text(svg(logo_w, logo_h, mark(s, pad, pad + 1.5 * s) + words))
    LIGHT = False

    # Icon only
    (HERE / "mark.svg").write_text(svg(13 * 10 + 4, 13 * 10 + 4, mark(10, 0, 0)))

    # Social preview 1280x640: dark terminal window with the logo and the tagline
    bg = ('<defs><linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#0b1020"/>'
          '<stop offset="1" stop-color="#1e1b4b"/></linearGradient></defs>'
          '<rect width="1280" height="640" fill="url(#bg)"/>'
          '<rect x="60" y="60" width="1160" height="520" rx="22" fill="#0f172a" stroke="#334155" stroke-width="2"/>'
          '<circle cx="100" cy="98" r="9" fill="#ef4444"/><circle cx="130" cy="98" r="9" fill="#f59e0b"/>'
          '<circle cx="160" cy="98" r="9" fill="#22c55e"/>'
          '<text x="640" y="105" text-anchor="middle" font-family="DejaVu Sans Mono, monospace" font-size="22" '
          'fill="#64748b">~/my-project — autopilot</text>\n')
    s = 13
    words, wa = wordmark(s, 330, 170)
    body = mark(s, 110, 185) + words
    body.append('<text x="110" y="452" font-family="DejaVu Sans Mono, monospace" font-size="30" fill="#94a3b8">'
                '<tspan fill="#22c55e">$</tspan> autopilot plan README.md</text>')
    steps = [("plan", "#3b82f6"), ("build", "#8b5cf6"), ("verify", "#f59e0b"), ("commit", "#22c55e")]
    x = 110
    for i, (name, colour) in enumerate(steps):
        body.append(f'<text x="{x}" y="520" font-family="DejaVu Sans Mono, monospace" font-size="30" font-weight="700" '
                    f'fill="{colour}">[{name} ✓]</text>')
        x += 40 + 19 * (len(name) + 4)
    (HERE / "social-preview.svg").write_text(svg(1280, 640, body, bg))


if __name__ == "__main__":
    main()
