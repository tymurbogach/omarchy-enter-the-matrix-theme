#!/usr/bin/env python3
"""Generate the matrix theme's two boot identity PNGs.

    ./tools/generate-brand.py

  · unlock.png          the Plymouth boot mark (with alpha; Plymouth paints it
                        over `background` from colors.toml). A line half typed
                        out and the cursor: no film logo, no wordmark.
                        Atmosphere, not branding.
  · preview-unlock.png  how that splash looks, for Plymouth's own picker.

The theme card `preview.png` is not made here: `generate-showcase.py` composes
it from real screenshots, so this script must never write it.

Needs rsvg-convert and ImageMagick.
"""

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


def main():
    unlock = os.path.join(ROOT, "unlock.png")
    render(brand(), 1108, 523, unlock)
    print(f"  unlock.png  {os.path.getsize(unlock) // 1024} KB")

    pu = os.path.join(ROOT, "preview-unlock.png")
    render(preview_unlock(), 1920, 1080, pu)
    subprocess.run(["magick", pu, "-strip", "-dither", "None", "-colors", "256", pu], check=True)
    print(f"  preview-unlock.png  {os.path.getsize(pu) // 1024} KB")


if __name__ == "__main__":
    sys.exit(main())
