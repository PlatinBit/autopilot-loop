#!/usr/bin/env python3
"""Generates the autopilot-loop logo: plain black-and-white ASCII (keyboard characters only).
Run: python3 assets/make_logo.py   → assets/logo.txt, assets/logo.svg, assets/social-preview.svg
(the PNG preview is rendered from the SVG, e.g. with cairosvg or a browser)."""
from html import escape
from pathlib import Path

HERE = Path(__file__).resolve().parent

BANNER = [
    "               __              _ __      __        __",
    "  ____ ___  __/ /_____  ____  (_) /___  / /_      / /___  ____  ____",
    " / __ `/ / / / __/ __ \\/ __ \\/ / / __ \\/ __/_____/ / __ \\/ __ \\/ __ \\",
    "/ /_/ / /_/ / /_/ /_/ / /_/ / / / /_/ / /_/_____/ / /_/ / /_/ / /_/ /",
    "\\__,_/\\__,_/\\__/\\____/ .___/_/_/\\____/\\__/     /_/\\____/\\____/ .___/",
    "                    /_/                                     /_/",
]


def loop_lines(width):
    """The loop under the banner: plan -> build -> verify -> commit, and back again until done."""
    top = ".--> plan --> build --> verify --> commit --."
    bottom = "'" + " until done ".center(len(top) - 2, "-") + "'"
    pad = " " * ((width - len(top)) // 2)
    return [pad + top, pad + "^" + " " * (len(top) - 2) + "|", pad + bottom]


def art():
    width = max(map(len, BANNER))
    return BANNER + [""] + loop_lines(width)


def svg_text(lines, x, y, size, colour, line_height=1.12):
    tspans = "".join(f'<tspan x="{x}" dy="{0 if i == 0 else size * line_height:.1f}">{escape(l) or " "}</tspan>'
                     for i, l in enumerate(lines))
    return (f'<text x="{x}" y="{y}" font-family="DejaVu Sans Mono, Menlo, Consolas, monospace" font-size="{size}" '
            f'fill="{colour}" xml:space="preserve">{tspans}</text>')


def main():
    lines = art()
    (HERE / "logo.txt").write_text("\n".join(lines) + "\n")

    # Logo as SVG (black text on transparent; fine on light pages, use logo.txt in a code block elsewhere)
    size, cw = 16, 16 * 0.602
    w, h = int(max(map(len, lines)) * cw + 32), int(len(lines) * size * 1.25 + 24)
    (HERE / "logo.svg").write_text(
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" width="{w}" height="{h}" role="img" '
        f'aria-label="autopilot-loop"><title>autopilot-loop</title>{svg_text(lines, 16, 28, size, "#000")}</svg>\n')

    # Social preview 1280x640: white ASCII on black, centred, with the prompt line
    size = 22
    block_w = max(map(len, lines)) * size * 0.602
    x = (1280 - block_w) / 2
    prompt = ["$ autopilot plan README.md", "", "Point it at a plan file. Claude Code builds it task by task -",
              "every step verified, reviewed and committed."]
    (HERE / "social-preview.svg").write_text(
        '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1280 640" width="1280" height="640" role="img" '
        'aria-label="autopilot-loop"><title>autopilot-loop</title><rect width="1280" height="640" fill="#000"/>'
        + svg_text(lines, round(x), 150, size, "#fff")
        + svg_text(prompt, round(x), 470, size, "#bdbdbd") + "</svg>\n")


if __name__ == "__main__":
    main()
