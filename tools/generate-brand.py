#!/usr/bin/env python3
"""Generate the matrix theme's two boot identity PNGs.

    ./tools/generate-brand.py

  · unlock.png          the Plymouth boot mark (with alpha; Plymouth paints it
                        over black). The film's first line, typed, in the
                        provider's pale core with its saturated halo. Still
                        no logo and no wordmark: it is a sentence you read,
                        not a poster. Atmosphere, not branding.
  · preview-unlock.png  how that splash looks, for Plymouth's own picker:
                        the line over the film's framed passphrase panel --
                        filled title band with `enter password`, hollow
                        corner widgets, and the content row of short
                        horizontal dashes the real field answers with.

The theme card `preview.png` is not made here: `generate-showcase.py` composes
it from real screenshots, so this script must never write it.

Needs rsvg-convert and ImageMagick. The two faces ship in `fonts/` and are
exposed to rsvg through a throwaway fontconfig file, so nothing is installed.
"""

import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)  # outputs land in the repo root, not in tools/
FONTS_DIR = os.path.join(ROOT, "fonts")

COURIER = "Courier Prime"       # the typed lines' face, as in derive-plymouth
PANEL_FACE = "VT323"            # the panel's own face, as in derive-plymouth
BAND_INK = "04121A"             # the title band's dark ink, as in derive-plymouth
BG = "#000000"                  # the splash is black, not themed background


def provider_colors():
    """Core, halo and dialog colours from provider.json, as hex without '#'.

    Falls back the way derive-plymouth does: one colour for everything when
    the provider names none, so an older provider still gets a coherent mark.
    """
    with open(os.path.join(ROOT, "provider.json")) as fh:
        plymouth = json.load(fh)["plymouth"]

    def section(key, fallback):
        channels = plymouth.get(key)
        if not channels:
            return fallback
        return "".join(f"{round(channel * 255):02X}" for channel in channels)

    core = section("color", "7BAE4E")
    return core, section("glowColor", core), section("dialogColor", core)


CORE, GLOW, DIALOG = provider_colors()


def fontconfig():
    """A throwaway fontconfig file exposing the repo's `fonts/` to rsvg."""
    fh = tempfile.NamedTemporaryFile("w", suffix=".conf", delete=False)
    fh.write(f'''<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "urn:fontconfig:fonts.dtd">
<fontconfig>
  <dir>{FONTS_DIR}</dir>
</fontconfig>
''')
    fh.close()
    return fh.name


def render(svg, width, height, output):
    with tempfile.NamedTemporaryFile("w", suffix=".svg", delete=False) as fh:
        fh.write(svg)
        path = fh.name
    conf = fontconfig()
    try:
        env = dict(os.environ, FONTCONFIG_FILE=conf)
        subprocess.run(["rsvg-convert", "-w", str(width), "-h", str(height),
                        path, "-o", output], check=True, env=env)
    finally:
        os.remove(path)
        os.remove(conf)


def halo_defs(size):
    """One halo, the way derive-plymouth bakes it: a tight pass keeping the
    bright edge on the ink, plus a wider contained one at 0.45 -- combined
    additively (feComposite arithmetic), not layered, so no opaque band
    forms where the two overlap."""
    tight, wide = 0.028 * size, 0.100 * size
    return f'''
    <filter id="halo" x="-40%" y="-120%" width="180%" height="340%">
      <feGaussianBlur in="SourceGraphic" stdDeviation="{tight:.1f}" result="t"/>
      <feGaussianBlur in="SourceGraphic" stdDeviation="{wide:.1f}" result="w"/>
      <feComposite in="t" in2="w" operator="arithmetic" k2="1" k3="0.45"/>
    </filter>
'''


LIT_CORE = "D8FFFC"              # the core as SEEN: derive-plymouth plus-
                                # composites core and glow, so the ink inside
                                # a glyph overexposes to near-white (sampled
                                # off line-boot-0.png over its glow:
                                # ~216,255,252, not the raw #B4E3C8)


def typed_line(x, y, size, anchor="middle"):
    """`Wake up, Neo...`, pale core over a saturated halo. No cursor: the
    splash types by cropping a picture of the finished line, so nothing
    trails it (see derive-plymouth)."""
    line = "Wake up, Neo..."
    return f'''
    <text x="{x}" y="{y}" text-anchor="{anchor}"
          font-family="{COURIER}" font-weight="bold" font-size="{size}"
          fill="#{GLOW}" filter="url(#halo)">{line}</text>
    <text x="{x}" y="{y}" text-anchor="{anchor}"
          font-family="{COURIER}" font-weight="bold" font-size="{size}"
          fill="#{LIT_CORE}">{line}</text>
'''


def panel(x, y, w):
    """The film's framed passphrase panel, in fractions of its width, measured
    off the derived `box-key.png` (1346x483): filled title band with the
    tracked caption in dark ink, two hollow squares left and the wide hollow
    widget right, thin frame with divider, and the content row -- nine short
    horizontal dashes centred as a group, the way `keydots.png` answers."""
    u = w / 1346
    h = 483 * u
    sw = 7 * u                        # frame stroke
    m = 3 * u                         # outer transparent margin
    band_y1 = 128 * u                 # divider between band and content
    wdg_y0, wdg = 31 * u, 66 * u      # corner widgets' top and height
    cap_size = 0.06311 * w            # caption spans three fifths of the panel
    cap_gap = 0.233 * cap_size        # half a panel cell between glyphs
    dash_cell, dash_n = 57.1 * u, 9
    dash_w, dash_h = 24 * u, 10 * u
    dash_y = 270 * u
    dash_x0 = x + (w - dash_n * dash_cell) / 2 + (dash_cell - dash_w) / 2
    dashes = "".join(
        f'<rect x="{dash_x0 + i * dash_cell:.1f}" y="{y + dash_y:.1f}" '
        f'width="{dash_w:.1f}" height="{dash_h:.1f}" fill="#{DIALOG}"/>'
        for i in range(dash_n))
    return f'''
  <g>
    <rect x="{x + 6 * u:.1f}" y="{y + 6 * u:.1f}" width="{w - 12 * u:.1f}"
          height="{band_y1 - 6 * u:.1f}" fill="#{DIALOG}"/>
    <rect x="{x + m:.1f}" y="{y + m:.1f}" width="{w - 2 * m:.1f}"
          height="{h - 2 * m:.1f}" fill="none" stroke="#{DIALOG}"
          stroke-width="{sw:.1f}"/>
    <line x1="{x + m:.1f}" y1="{y + band_y1:.1f}" x2="{x + w - m:.1f}"
          y2="{y + band_y1:.1f}" stroke="#{DIALOG}" stroke-width="{sw:.1f}"/>
    <g fill="none" stroke="#{BAND_INK}" stroke-width="{max(1, 3 * u):.1f}">
      <rect x="{x + 47 * u:.1f}" y="{y + wdg_y0:.1f}"
            width="{wdg:.1f}" height="{wdg:.1f}"/>
      <rect x="{x + 136 * u:.1f}" y="{y + wdg_y0:.1f}"
            width="{wdg:.1f}" height="{wdg:.1f}"/>
      <rect x="{x + 1117 * u:.1f}" y="{y + wdg_y0:.1f}"
            width="{181 * u:.1f}" height="{wdg:.1f}"/>
    </g>
    <text x="{x + 0.49108 * w + cap_gap / 2:.1f}"
          y="{y + 0.04978 * w + 0.22 * cap_size:.1f}" text-anchor="middle"
          font-family="{PANEL_FACE}" font-size="{cap_size:.1f}"
          letter-spacing="{cap_gap:.1f}" fill="#{BAND_INK}">enter password</text>
    {dashes}
  </g>
'''


def brand(w=1108, h=523):
    """The splash mark. Transparent: Plymouth paints it over black."""
    size = 0.0938 * w
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}" viewBox="0 0 1108 523">
  <defs>{halo_defs(size)}</defs>
  {typed_line(554, int(0.528 * h), round(size))}
</svg>'''


def preview_unlock(w=1920, h=1080):
    """The splash as it looks: the typed line over the passphrase panel.

    The composition is scaled to 0.78 about the canvas centre: the picker's
    thumbnail centre-crops to a taller cell and the QML cell crops the
    sides further, so edge-to-edge content does not survive there."""
    line_w = 15 / 21 * 0.32 * w       # this line's share of the typed width
    size = line_w / (15 * 0.6028)     # Courier Prime Bold is a 0.6 face
    panel_w = 0.30 * w
    panel_h = 483 / 1346 * panel_w
    zoom = 0.78
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="{w}" height="{h}">
  <defs>{halo_defs(size)}</defs>
  <rect width="{w}" height="{h}" fill="{BG}"/>
  <g transform="translate({w / 2},{h / 2}) scale({zoom})
                translate({-w / 2},{-h / 2})">
  {typed_line(f"{0.055 * w:.1f}", f"{0.085 * h + 0.572 * size:.1f}",
              round(size, 1), anchor="start")}
  {panel((w - panel_w) / 2, 0.684 * h, panel_w)}
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
