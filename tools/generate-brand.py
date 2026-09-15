#!/usr/bin/env python3
"""Generate the matrix theme's three identity PNGs.

    ./tools/generate-brand.py

  · unlock.png          the Plymouth boot mark (with alpha; Plymouth paints it
                        over `background` from colors.toml). A line half typed
                        out and the cursor: no film logo, no wordmark.
                        Atmosphere, not branding.
  · preview-unlock.png  how that splash looks, for Plymouth's own picker.
  · preview.png         the theme card for the `omarchy theme` carousel: the
                        rain background with a terminal window and the palette
                        below it.

Needs rsvg-convert and ImageMagick, plus the rain's background (provider.json's
liveBackground), which is committed rather than generated --
generate-backgrounds.py has not produced it since the live background stopped
being a fresh render.
"""

import json
import os
import random
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE) # outputs land in the repo root, not in tools/
MONO = "JetBrainsMono Nerd Font, monospace"
CJK = "Noto Sans CJK JP"

BG = "#020A04"
ELEVATED = "#0F1E14"
BAR = "#000200"
FG = "#B8ECC6"
BRIGHT = "#DFFFE9"
DARK_FG = "#3A6B4A"
ACCENT = "#00FF41"

PALETTE = [
    ("bg", "#020A04"), ("red", "#E5484D"), ("green", "#00FF41"),
    ("yellow", "#B8E65C"), ("blue", "#5B8CA8"), ("magenta", "#35D68F"),
    ("cyan", "#8AF5C8"), ("fg", "#B8ECC6"),
    ("muted", "#203A27"), ("red+", "#E0605F"), ("green+", "#6BFF92"),
    ("yellow+", "#E2FF8F"), ("blue+", "#6B9AB5"), ("magenta+", "#66F0B4"),
    ("cyan+", "#B8FFE8"), ("fg+", "#DFFFE9"),
]


# The snippet shown in the terminal window of the preview card. It exists to
# show every ANSI slot at once on a realistic line of code, which is the whole
# argument for this palette.
CODE = [
    [("def ", "#5B8CA8"), ("wake_up", "#00FF41"), ("(", FG), ("subject", "#B8E65C"),
     (", ", FG), ("pill", "#B8E65C"), ("=", FG), ('"red"', "#8AF5C8"), ("):", FG)],
    [("    ", FG), ("if", "#5B8CA8"), (" pill ", FG), ("==", FG), (' "blue"', "#8AF5C8"), (":", FG)],
    [("        raise ", "#5B8CA8"), ("StillAsleep", "#E0605F"), ("(subject)", FG)],
    [("    ", FG), ("return", "#5B8CA8"), (" subject.", FG), ("unplug", "#35D68F"), ("()", FG)],
]


def render(svg, width, height, output):
    with tempfile.NamedTemporaryFile("w", suffix=".svg", delete=False) as fh:
        fh.write(svg)
        path = fh.name
    try:
        subprocess.run(["rsvg-convert", "-w", str(width), "-h", str(height),
                        path, "-o", output], check=True)
    finally:
        os.remove(path)


def rain(w, h, seed, pitch, size, opacity, clear_centre=True):
    """Background streaks. clear_centre dims them towards the middle so they do
    not compete with whatever is painted on top."""
    random.seed(seed)
    glyphs = [chr(c) for c in range(0x30A1, 0x30FA)]
    out = []
    for cx in range(w // pitch + 1):
        x = cx * pitch + random.randint(-pitch // 4, pitch // 4)
        from_centre = abs(x - w / 2) / (w / 2)
        threshold = (0.34 + from_centre * 0.52) if clear_centre else 0.75
        if random.random() > threshold:
            continue
        length = random.randint(6, 16)
        y0 = random.randint(int(h * 0.1), h)
        for i in range(length):
            y = y0 - i * int(size * 1.45)
            if y < size:
                break
            op = max(0.0, (1 - i / length) ** 1.6) * opacity * (
                (0.4 + from_centre * 0.9) if clear_centre else 1.0)
            colour = BRIGHT if i == 0 else ACCENT
            # Mirrored glyphs, the way they are in the film.
            out.append(
                f'<text x="0" y="0" transform="translate({x + size},{y}) scale(-1,1)" '
                f'font-family="{CJK}" font-size="{size}" fill="{colour}" '
                f'opacity="{op:.3f}">{random.choice(glyphs)}</text>')
    return "".join(out)


PHOSPHOR = f'''
    <filter id="phosphor" x="-40%" y="-40%" width="180%" height="180%">
      <feGaussianBlur stdDeviation="6" result="b"/>
      <feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge>
    </filter>
'''


def brand(w=1108, h=523, background=None):
    """The splash mark. `background` of None leaves alpha, which Plymouth needs.

    The line from the start of the film, typed in a terminal, with its block
    cursor behind it. Still no logo and no wordmark: it is a sentence you read,
    not a poster. This used to be "MATRIX" at 104 px with "WAKE UP" underneath,
    and that did turn the boot into a film poster.

    The cursor lives INSIDE the <text>, as one more character, and the whole
    line is centred with text-anchor="middle". That way there is no need to
    guess the font's advance to place it: in a monospace face the block takes
    exactly one cell and the centring falls out on its own.
    """
    base = f'<rect width="{w}" height="{h}" fill="{background}"/>' if background else ""

    line = "Wake up, Neo..."
    size = 72
    y = 276

    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 1108 523">
  <defs>{PHOSPHOR}</defs>
  {base}
  <g filter="url(#phosphor)">
    <text x="554" y="{y}" text-anchor="middle" xml:space="preserve"
          font-family="{MONO}" font-size="{size}" fill="{ACCENT}"
          letter-spacing="1">{line} <tspan fill="{BRIGHT}">\u2588</tspan></text>
  </g>
</svg>'''


def preview_unlock(w=1920, h=1080):
    """The splash as it looks: the mark centred and the password field."""
    cx, cy = w / 2, h * 0.46
    mw, mh = 1108, 523
    campo_y = h * 0.74
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}">
  <defs>{PHOSPHOR}</defs>
  <rect width="{w}" height="{h}" fill="{BG}"/>
  <g transform="translate({cx - mw/2},{cy - mh/2})">
    {brand().split('</defs>')[1].rsplit('</svg>')[0]}
  </g>
  <g>
    <rect x="{cx - 150}" y="{campo_y}" width="300" height="42" rx="6"
          fill="{ELEVATED}" stroke="{ACCENT}" stroke-opacity="0.45"/>
    <rect x="{cx - 176}" y="{campo_y + 11}" width="14" height="11" rx="2" fill="{DARK_FG}"/>
    <path d="M {cx - 173} {campo_y + 11} v -4 a 4 4 0 0 1 8 0 v 4"
          fill="none" stroke="{DARK_FG}" stroke-width="2"/>
    <g fill="{FG}">
      <circle cx="{cx - 124}" cy="{campo_y + 21}" r="4"/>
      <circle cx="{cx - 108}" cy="{campo_y + 21}" r="4"/>
      <circle cx="{cx - 92}"  cy="{campo_y + 21}" r="4"/>
      <circle cx="{cx - 76}"  cy="{campo_y + 21}" r="4"/>
    </g>
  </g>
</svg>'''


def preview(w=1800, h=1012):
    """The carousel card: the terminal window over the rain."""
    vw, vh = 1120, 404
    vx, vy = (w - vw) / 2, 150
    # One <text> per line with the tspans chained and given no x of their own:
    # letting them flow is the only thing that respects the font's real advance.
    # Working out each tspan's x by eye left the operators out of line.
    rows = []
    y = vy + 122
    for code_line in CODE:
        tspans = "".join(
            '<tspan fill="%s">%s</tspan>' % (
                colour, txt.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;"))
            for txt, colour in code_line)
        rows.append(f'<text x="{vx + 44}" y="{y}" font-family="{MONO}" font-size="27" '
                    f'xml:space="preserve">{tspans}</text>')
        y += 46
    # A panel under the palette: without it the labels land on the rain and
    # cannot be read.
    sw, gap = 92, 12
    total = len(PALETTE) * sw + (len(PALETTE) - 1) * gap
    sx = (w - total) / 2
    py = 700
    swatches = [f'<rect x="{sx - 34}" y="{py - 30}" width="{total + 68}" height="150" rx="10" '
                f'fill="{BG}" opacity="0.93"/>']
    for i, (name, colour) in enumerate(PALETTE):
        x = sx + i * (sw + gap)
        swatches.append(
            f'<rect x="{x}" y="{py}" width="{sw}" height="54" rx="3" fill="{colour}" '
            f'stroke="{FG}" stroke-opacity="0.18"/>'
            f'<text x="{x + sw/2}" y="{py + 82}" text-anchor="middle" font-family="{MONO}" '
            f'font-size="17" fill="{DARK_FG}">{name}</text>')
    prompt = (f'<tspan fill="{ACCENT}">~</tspan><tspan fill="{DARK_FG}"> on </tspan>'
              f'<tspan fill="{BRIGHT}">main</tspan><tspan fill="{ACCENT}"> ❯ </tspan>')
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}">
  <rect width="{w}" height="{h}" fill="{BG}" opacity="0.62"/>

  <rect width="{w}" height="46" fill="{BAR}"/>
  <text x="26" y="30" font-family="{MONO}" font-size="20" fill="{FG}">1 2 3</text>
  <text x="{w/2}" y="30" text-anchor="middle" font-family="{MONO}" font-size="20" fill="{FG}">matrix</text>
  <text x="{w - 26}" y="30" text-anchor="end" font-family="{MONO}" font-size="20" fill="{FG}">23:58</text>

  <rect x="{vx - 2}" y="{vy - 2}" width="{vw + 4}" height="{vh + 4}" rx="10" fill="{ACCENT}"/>
  <rect x="{vx}" y="{vy}" width="{vw}" height="{vh}" rx="8" fill="{ELEVATED}"/>
  <text x="{vx + 44}" y="{vy + 62}" font-family="{MONO}" font-size="27" xml:space="preserve">{prompt}<tspan fill="{FG}">bat wake_up.py</tspan></text>
  {"".join(rows)}
  <text x="{vx + 44}" y="{vy + 356}" font-family="{MONO}" font-size="27" xml:space="preserve">{prompt}<tspan fill="{BRIGHT}">▊</tspan></text>

  {"".join(swatches)}
</svg>'''


def main():
    unlock = os.path.join(ROOT, "unlock.png")
    render(brand(), 1108, 523, unlock)
    print(f"  unlock.png  {os.path.getsize(unlock) // 1024} KB")

    pu = os.path.join(ROOT, "preview-unlock.png")
    render(preview_unlock(), 1920, 1080, pu)
    subprocess.run(["magick", pu, "-strip", "-dither", "None", "-colors", "256", pu], check=True)
    print(f"  preview-unlock.png  {os.path.getsize(pu) // 1024} KB")

    with open(os.path.join(ROOT, "provider.json"), encoding="utf-8") as fh:
        background = os.path.join(ROOT, json.load(fh)["liveBackground"])
    if not os.path.exists(background):
        print(f"  ! {background} not found. That file is committed, not "
              "generated: restore it from git rather than regenerating it.",
              file=sys.stderr)
        return 1
    with tempfile.NamedTemporaryFile(suffix=".png", delete=False) as fh:
        overlay = fh.name
    p = os.path.join(ROOT, "preview.png")
    try:
        render(preview(), 1800, 1012, overlay)
        subprocess.run(
            ["magick", background, "-resize", "1800x1012^", "-gravity", "center",
              "-extent", "1800x1012", overlay, "-composite",
              "-strip", "-dither", "None", "-colors", "256",
              "-define", "png:compression-level=9", p], check=True)
    finally:
        os.remove(overlay)
    print(f"  preview.png  {os.path.getsize(p) // 1024} KB")


if __name__ == "__main__":
    sys.exit(main())
