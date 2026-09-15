#!/usr/bin/env python3
"""Compose the showcase pictures from real screenshots.

    ./tools/generate-showcase.py SHOTS

SHOTS is the folder that tools/capture-showcase.sh fills: full-screen grabs at
the monitor's native resolution, one per piece of the pack. The frame, the
backdrop and the captions are drawn here. Everything inside a frame is a
screenshot, so a picture cannot show a feature that does not work.

Outputs:
  preview.png            the theme card for `omarchy theme`, and the picture
                         that gallery sites convert. The desktop, unframed.
  docs/showcase/*.webp   the poster at the top of the README, and one framed
                         picture per piece.

The colours come from colors.toml and the face from fonts/. A change of the
palette changes the frames too.
"""

import argparse
import pathlib
import random
import sys
import tomllib

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "docs" / "showcase"
FONT = ROOT / "fonts" / "TerminessNerdFont-Regular.ttf"
ATLAS = ROOT / "glyphs.png"
ATLAS_CELL = (38, 80)  # generate-atlas.py: an 8x7 grid of 38x80 px cells
ATLAS_GRID = (8, 7)


def hex_rgb(value):
    value = value.lstrip("#")
    return tuple(int(value[i:i + 2], 16) for i in (0, 2, 4))


COLORS = {key: hex_rgb(value)
          for key, value in tomllib.loads((ROOT / "colors.toml").read_text()).items()
          if isinstance(value, str) and value.startswith("#")}
VOID = COLORS["darker_background"]
SURFACE = COLORS["lighter_background"]
ACCENT = COLORS["accent"]
BORDER = COLORS["active_border_color"]
BRIGHT = COLORS["bright_foreground"]
DIM = COLORS["dark_foreground"]
MUTED = COLORS["muted"]

# The width that every picture is composed at, and the width that it is saved
# at. Composing larger and scaling down once keeps the hairlines crisp.
CANVAS_W = 2400
SAVE_W = 1800
WEBP_QUALITY = 88

# One entry per framed picture. `crop` is a box in fractions of the screen
# (left, top, right, bottom), because the grabs arrive at whatever resolution
# the monitor has. The bar is a layer-shell surface above everything, so the
# crops of the boot splash start below it.
FULL = (0.0, 0.0, 1.0, 1.0)
SPLASH = (0.0, 0.035, 1.0, 1.0)  # the whole splash, below the bar
LINE = (0.0, 0.035, 0.62, 0.20)  # the typed line, top left
SINGLES = [
    {"name": "desktop", "shot": "desktop.png", "crop": FULL,
     "title": "Desktop",
     "line": "Digital rain behind your windows, drawn live on the GPU."},
    {"name": "screensaver", "shot": "screensaver.png", "crop": FULL,
     "title": "Screensaver",
     "line": "The same rain, full screen, when the machine sits idle."},
    {"name": "lock", "shot": "lock.png", "crop": FULL,
     "title": "Lock",
     "line": "Omarchy's own lock, with the rain behind the password field."},
]
# boot-granted.png and boot-progress.png come from the same burst
# (capture-showcase.sh, scene dialog): pick the frame with ACCESS GRANTED in
# the box, and one with the track in its own box after it.
BOOT = {
    "name": "boot", "title": "Boot splash",
    "line": "It asks for the disk passphrase, grants access, then shows how far the boot has come.",
    "panels": [
        {"shot": "boot-password.png", "crop": SPLASH, "label": "passphrase"},
        {"shot": "boot-granted.png", "crop": SPLASH, "label": "access granted"},
        {"shot": "boot-progress.png", "crop": SPLASH, "label": "progress"},
    ],
}
# The typed lines. capture-showcase.sh takes a burst of frames while they type.
# Copy the frame where each line is complete to boot-line-N.png by hand: the
# timing of the lines belongs to derive-plymouth.py, not to this script.
LINES = {
    "name": "lines", "title": "Typed at boot",
    "line": "The first lines of the film, one after the other, while the machine starts.",
    "panels": [{"shot": f"boot-line-{n}.png", "crop": LINE, "label": ""} for n in range(1, 5)],
}
EXITS = {
    "name": "exits", "title": "Shutdown and reboot",
    "line": "Each way out has a last line of its own.",
    "panels": [
        {"shot": "shutdown.png", "crop": LINE, "label": "shutdown"},
        {"shot": "reboot.png", "crop": LINE, "label": "reboot"},
    ],
}

# --- drawing primitives ------------------------------------------------------

SUPERSAMPLE = 3  # for the rounded corners and the hairline border


def font(size):
    return ImageFont.truetype(str(FONT), round(size))


def tint(colour, mask, strength=1.0):
    """A flat colour whose alpha is `mask`, scaled by `strength`."""
    layer = Image.new("RGBA", mask.size, colour + (0,))
    layer.putalpha(mask if strength == 1.0 else mask.point(lambda p: round(p * strength)))
    return layer


def paste(canvas, layer, x, y):
    """alpha_composite that accepts a layer which hangs off any edge."""
    x, y = round(x), round(y)
    left, top = max(0, -x), max(0, -y)
    right = min(layer.width, canvas.width - x)
    bottom = min(layer.height, canvas.height - y)
    if right <= left or bottom <= top:
        return
    canvas.alpha_composite(layer.crop((left, top, right, bottom)), (x + left, y + top))


def rounded_mask(size, radius, outline=0):
    w, h = size
    s = SUPERSAMPLE
    big = Image.new("L", (w * s, h * s), 0)
    draw = ImageDraw.Draw(big)
    if outline:
        draw.rounded_rectangle((0, 0, w * s - 1, h * s - 1), radius * s,
                               outline=255, width=outline * s)
    else:
        draw.rounded_rectangle((0, 0, w * s - 1, h * s - 1), radius * s, fill=255)
    return big.resize(size, Image.LANCZOS)


def tracked(draw, x, y, text, face, fill, tracking):
    """Text with letter spacing, which Pillow does not offer. Returns the end x."""
    for char in text:
        draw.text((x, y), char, font=face, fill=fill)
        x += face.getlength(char) + tracking
    return x


# --- the rain behind the pictures --------------------------------------------

def glyph_masks(height):
    """The shader's own glyphs, cut out of its atlas and scaled to `height`."""
    atlas = Image.open(ATLAS).convert("LA")
    ink = ImageChops.multiply(*atlas.split())
    height = max(1, round(height))
    cw, ch = ATLAS_CELL
    width = max(1, round(cw * height / ch))
    masks = []
    for row in range(ATLAS_GRID[1]):
        for col in range(ATLAS_GRID[0]):
            cell = ink.crop((col * cw, row * ch, (col + 1) * cw, (row + 1) * ch))
            if cell.getbbox():
                masks.append(cell.resize((width, height), Image.LANCZOS))
    return masks


def rain(size, rng, height, density, strength, blur):
    """One plane of falling columns: a bright head and a fading trail."""
    w, h = size
    height = max(1, round(height))
    layer = Image.new("RGBA", size, (0, 0, 0, 0))
    masks = glyph_masks(height)
    for x in range(0, w, masks[0].width):
        if rng.random() > density:
            continue
        length = rng.randint(6, 26)
        head = rng.randint(0, h + length * height)
        for i in range(length):
            y = head - i * height
            if y + height < 0 or y > h:
                continue
            fade = (1 - i / length) ** 1.8
            colour = BRIGHT if i == 0 else ACCENT
            paste(layer, tint(colour, rng.choice(masks), strength * fade), x, y)
    return layer.filter(ImageFilter.GaussianBlur(blur)) if blur else layer


def backdrop(size, seed):
    """Two planes of rain, a pool of light in the middle, a vignette and grain.

    The far plane is small and sharp, the near plane large and out of focus.
    That depth is what makes the flat pictures in front of it read as objects.
    """
    w, h = size
    rng = random.Random(seed)
    canvas = Image.new("RGBA", size, VOID + (255,))

    pool = Image.new("L", size, 0)
    ImageDraw.Draw(pool).ellipse((w * 0.12, h * 0.05, w * 0.88, h * 0.95), fill=255)
    paste(canvas, tint(SURFACE, pool.filter(ImageFilter.GaussianBlur(w / 7)), 0.9), 0, 0)

    paste(canvas, rain(size, rng, h / 56, 0.55, 0.24, 0.5), 0, 0)
    paste(canvas, rain(size, rng, h / 20, 0.08, 0.14, h / 300), 0, 0)

    edge = Image.new("L", size, 255)
    ImageDraw.Draw(edge).ellipse((-w * 0.1, -h * 0.15, w * 1.1, h * 1.15), fill=0)
    paste(canvas, tint((0, 0, 0), edge.filter(ImageFilter.GaussianBlur(w / 10)), 0.75), 0, 0)

    # Grain, so that the dark gradients do not band in the WebP.
    noise = Image.effect_noise(size, 48)
    paste(canvas, tint((255, 255, 255), noise.point(lambda p: max(0, p - 128) // 10)), 0, 0)
    paste(canvas, tint((0, 0, 0), noise.point(lambda p: max(0, 128 - p) // 10)), 0, 0)
    return canvas


# --- the pictures ------------------------------------------------------------

def cut(shot, box):
    l, t, r, b = box
    return shot.crop((round(l * shot.width), round(t * shot.height),
                      round(r * shot.width), round(b * shot.height)))


def card(shot, max_w, max_h, radius=16):
    """The screenshot, scaled to fit, with round corners and a phosphor hairline."""
    scale = min(max_w / shot.width, max_h / shot.height)
    w, h = round(shot.width * scale), round(shot.height * scale)
    image = shot.convert("RGB").resize((w, h), Image.LANCZOS).convert("RGBA")
    image.putalpha(rounded_mask((w, h), radius))
    paste(image, tint(BORDER, rounded_mask((w, h), radius, outline=2), 0.85), 0, 0)
    return image


def place(canvas, image, x, y, glow=0.20, shadow=0.75):
    """Put a card down with a drop shadow under it and a green halo around it."""
    w, h = image.size
    pad = max(w, h) // 7
    alpha = image.getchannel("A")

    below = Image.new("L", (w + 2 * pad, h + 2 * pad), 0)
    below.paste(alpha, (pad, pad + h // 30))
    paste(canvas, tint((0, 0, 0), below.filter(ImageFilter.GaussianBlur(pad / 3)), shadow),
          x - pad, y - pad)

    around = Image.new("L", (w + 2 * pad, h + 2 * pad), 0)
    around.paste(alpha, (pad, pad))
    paste(canvas, tint(ACCENT, around.filter(ImageFilter.GaussianBlur(pad / 2)), glow),
          x - pad, y - pad)

    paste(canvas, image, x, y)


def caption(canvas, x, y, index, title, line, scale=1.0):
    draw = ImageDraw.Draw(canvas)
    big, small = font(34 * scale), font(26 * scale)
    end = tracked(draw, x, y, f"{index:02d}", big, ACCENT, 4 * scale)
    indent = end + 26 * scale
    tracked(draw, indent, y, title.upper(), big, BRIGHT, 7 * scale)
    draw.text((indent, y + 54 * scale), line, font=small, fill=DIM)


def signature(canvas, y):
    """The repo's name, bottom right. Every picture carries it once."""
    draw = ImageDraw.Draw(canvas)
    face = font(24)
    text = "omarchy-enter-the-matrix-theme"
    width = sum(face.getlength(c) + 3 for c in text)
    tracked(draw, canvas.width - 110 - width, y, text, face, MUTED, 3)


def single(shot, index, entry, seed):
    image = card(cut(shot, entry["crop"]), 2000, 1250)
    margin_top, gap, caption_h, margin_bottom = 110, 80, 110, 80
    height = margin_top + image.height + gap + caption_h + margin_bottom
    canvas = backdrop((CANVAS_W, height), seed)
    x = (CANVAS_W - image.width) // 2
    place(canvas, image, x, margin_top)
    caption_y = margin_top + image.height + gap
    caption(canvas, x, caption_y, index, entry["title"], entry["line"])
    signature(canvas, caption_y + 58)
    return canvas


def row(shots, index, entry, seed):
    """Several crops side by side under one caption, each with a small label."""
    panels = entry["panels"]
    margin, gap = 200, 60
    cell_w = (CANVAS_W - 2 * margin - gap * (len(panels) - 1)) // len(panels)
    cards = [card(cut(shots[p["shot"]], p["crop"]), cell_w, 1400) for p in panels]
    card_h = max(c.height for c in cards)
    margin_top, label_h, caption_h, margin_bottom = 130, 80, 110, 80
    height = margin_top + card_h + label_h + 60 + caption_h + margin_bottom
    canvas = backdrop((CANVAS_W, height), seed)
    draw = ImageDraw.Draw(canvas)
    face = font(24)
    for i, (panel, image) in enumerate(zip(panels, cards)):
        x = margin + i * (cell_w + gap) + (cell_w - image.width) // 2
        place(canvas, image, x, margin_top + (card_h - image.height) // 2)
        tracked(draw, x, margin_top + card_h + 34, panel["label"].upper(), face, DIM, 5)
    caption_y = margin_top + card_h + label_h + 60
    caption(canvas, margin, caption_y, index, entry["title"], entry["line"])
    signature(canvas, caption_y + 58)
    return canvas


def stack(shots, index, entry, seed):
    """Crops of the typed line, one under another, in the order they appear."""
    panels = entry["panels"]
    cards = [card(cut(shots[p["shot"]], p["crop"]), 1300, 400, radius=12) for p in panels]
    labelled = any(p["label"] for p in panels)
    margin_top, gap, caption_h, margin_bottom = 120, 44, 110, 80
    height = (margin_top + sum(c.height for c in cards) + gap * (len(cards) - 1)
              + 90 + caption_h + margin_bottom)
    canvas = backdrop((CANVAS_W, height), seed)
    draw = ImageDraw.Draw(canvas)
    face = font(26)
    x = (CANVAS_W - cards[0].width) // 2 + (90 if labelled else 0)
    y = margin_top
    for panel, image in zip(panels, cards):
        place(canvas, image, x, y, glow=0.14)
        if panel["label"]:
            text = panel["label"].upper()
            width = sum(face.getlength(c) + 5 for c in text)
            tracked(draw, x - 50 - width, y + image.height // 2 - 14, text, face, DIM, 5)
        y += image.height + gap
    caption_y = y - gap + 90
    caption(canvas, x, caption_y, index, entry["title"], entry["line"])
    signature(canvas, caption_y + 58)
    return canvas


def poster(shots, seed):
    """The first picture in the README: the desktop, and two pieces in front."""
    w, h = CANVAS_W, 1400
    canvas = backdrop((w, h), seed)
    draw = ImageDraw.Draw(canvas)

    desktop = card(shots["desktop.png"], 1560, 975, radius=18)
    place(canvas, desktop, w - desktop.width - 130, 150, glow=0.24)

    # Cropped towards the password field: at this size the whole screen reads
    # as a black rectangle.
    lock = card(cut(shots["lock.png"], (0.15, 0.10, 0.85, 0.90)), 700, 480)
    place(canvas, lock, 130, 560, glow=0.16)

    boot = card(cut(shots["boot-password.png"], SPLASH), 520, 420)
    place(canvas, boot, 620, 860, glow=0.16)


    title = font(96)
    tracked(draw, 130, 170, "ENTER THE", title, BRIGHT, 14)
    tracked(draw, 130, 280, "MATRIX", title, ACCENT, 14)
    draw.multiline_text((134, 410), "A theme for Omarchy,\nwith an optional pack.",
                        font=font(30), fill=DIM, spacing=14)
    signature(canvas, h - 90)
    return canvas


# --- output ------------------------------------------------------------------

def save_webp(canvas, name):
    height = round(canvas.height * SAVE_W / canvas.width)
    path = OUT / f"{name}.webp"
    canvas.convert("RGB").resize((SAVE_W, height), Image.LANCZOS).save(
        path, "WEBP", quality=WEBP_QUALITY, method=6)
    print(f"  {path.relative_to(ROOT)}  {path.stat().st_size // 1024} KB")


def save_preview(shot):
    """The theme card. Omarchy's picker shows it as it is, so it has no frame."""
    path = ROOT / "preview.png"
    image = shot.convert("RGB").resize((1800, round(shot.height * 1800 / shot.width)),
                                       Image.LANCZOS)
    # Octree, not the default median cut. Median cut spends its 256 colours on
    # the greens that fill the picture, and the eight palette dots in fastfetch
    # came out with the red gone and the blue grey. Octree keeps them, and the
    # file is smaller.
    image.quantize(256, method=Image.Quantize.FASTOCTREE,
                   dither=Image.Dither.NONE).save(path, optimize=True)
    print(f"  preview.png  {path.stat().st_size // 1024} KB")


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("shots", type=pathlib.Path, help="folder of raw screenshots")
    parser.add_argument("--only", help="compose only this picture (poster, desktop, boot, ...)")
    args = parser.parse_args()

    wanted = {e["shot"] for e in SINGLES}
    wanted |= {p["shot"] for group in (BOOT, LINES, EXITS) for p in group["panels"]}
    missing = sorted(n for n in wanted if not (args.shots / n).is_file())
    if missing:
        print(f"missing in {args.shots}: {', '.join(missing)}", file=sys.stderr)
        return 1
    shots = {n: Image.open(args.shots / n) for n in wanted}

    OUT.mkdir(parents=True, exist_ok=True)
    jobs = [("poster", lambda: poster(shots, 1))]
    for i, entry in enumerate(SINGLES, start=1):
        jobs.append((entry["name"],
                     lambda i=i, e=entry: single(shots[e["shot"]], i, e, 10 + i)))
    n = len(SINGLES)
    jobs.append((BOOT["name"], lambda: row(shots, n + 1, BOOT, 20)))
    jobs.append((LINES["name"], lambda: stack(shots, n + 2, LINES, 21)))
    jobs.append((EXITS["name"], lambda: stack(shots, n + 3, EXITS, 22)))

    for name, build in jobs:
        if args.only in (None, name):
            save_webp(build(), name)
    if args.only in (None, "preview"):
        save_preview(shots["desktop.png"])
    return 0


if __name__ == "__main__":
    sys.exit(main())
