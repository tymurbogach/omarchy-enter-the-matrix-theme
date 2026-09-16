#!/usr/bin/env python3
"""Derive the provider's boot splash from the Plymouth this machine has.

Omarchy's splash is a SCRIPT theme (`omarchy.script`), and what
`omarchy plymouth set-by-theme` lets a theme change is three things: background
colour, text colour and one still PNG. No animation fits through that door.

So it is done the way the lock is done: start from $OMARCHY_PATH's
`omarchy.script` and apply a minimal patch. Everything the patch does not name
-- the boot progress plumbing, the message callbacks, the entry and lock
sprites -- is Omarchy's, untouched. A post-update.d hook derives it again after
every `omarchy update`.

It installs as a SEPARATE theme under /usr/share/plymouth/themes/, so Omarchy's
own is never overwritten: going back is `omarchy plymouth reset`.

MIND: if your disk is encrypted, Plymouth is also what asks for the passphrase
at boot. The patch adds a display-password callback AFTER Omarchy's rather than
rewriting it -- the last registration wins -- so not one line of the passphrase
path is edited. Escape hatches remain `omarchy plymouth reset` and
`plymouth.enable=0` on the kernel line.

Verify it with `tools/preview-plymouth.sh`, which runs this for real in a window.
"""

import os
import re
import shutil
import string
import subprocess
import sys
import tempfile
from pathlib import Path

# Loaded by path rather than by name: this file may be exec'd from a spec, or
# run from the share dir's lib/, where lib/ is not on sys.path either way.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from provider import PROVIDER  # noqa: E402

OMARCHY = Path(os.environ.get("OMARCHY_PATH", "/usr/share/omarchy"))
SOURCE = OMARCHY / "default/plymouth"
SLUG = PROVIDER["slug"]
CLI = PROVIDER["cli"]
THEME = PROVIDER["plymouth"]["theme"]
TARGET = Path("/usr/share/plymouth/themes") / THEME
# Where the boot's text face lives on the system. The mkinitcpio hook resolves
# `Font=` with fc-match as root, so a user-local install is not enough: the
# face has to be visible system-wide, or the initramfs gets the wrong file.
SYS_FONT_DIR = Path("/usr/share/fonts/omarchy-matrix")

# What is typed out before the passphrase is answered, in order. Knock is last
# on purpose: in the film it lands with the knock at Neo's door, and here it
# lands with the prompt.
LINES = PROVIDER["plymouth"]["lines"]

# ...and what is typed once the passphrase is accepted, when boot proceeds.
# The script holds the storyboard at the end of LINES while a passphrase
# dialog is up, and the unlock callback releases it -- so on an encrypted disk
# this line only ever starts once the disk is open. On a disk with no
# passphrase there is no dialog to wait for, and the storyboard plays through.
# Empty or absent keeps the old shape: the boot lines, then progress.
AFTER_UNLOCK = PROVIDER["plymouth"].get("afterUnlock") or []

# ...and what is typed on the way out. Keyed by the mode plymouthd was started
# with, which is exactly what `Plymouth.GetMode()` hands back -- verified with
# `preview-plymouth.sh --mode`, and verified at the TOP of the script rather
# than inside a callback, which is what lets the whole storyboard be chosen
# before the first frame is drawn.
#
# ONLY TWO EXITS EXIST. plymouth-halt.service, plymouth-poweroff.service and
# plymouth-kexec.service all run `plymouthd --mode=shutdown`; only
# plymouth-reboot.service differs. A `halt` key would be config that never runs,
# so there is not one.
#
# A mode with no entry falls through to LINES, so an older provider.json -- and
# any provider that does not care -- keeps exactly the splash it had.
# "boot" is the pre lines plus the post-unlock tail: one storyboard, with a
# held gate between them rather than two dispatches.
BOOT_LINES = LINES + AFTER_UNLOCK
MODE_LINES = {"boot": BOOT_LINES, **(PROVIDER["plymouth"].get("modes") or {})}
# How many of the boot images belong to the pre phase. The gate sits after
# the last of these, and the type size is fixed by the longest of these --
# the tail must never resize what was already settled by looking at it.
PRE_COUNT = len(LINES)

# The typed lines take the THEME's `green` -- its accent, out of colors.toml at
# derive time. Repeating the hex in provider.json would work today and drift the
# first time the palette moved.
#
# Not the phosphor #00FF41 the shader's heads use: on a black screen, at the
# size these lines are drawn, that reads as glare rather than as a monitor. And
# not `foreground` either, which is the theme's text colour and comes out sage.
# A provider that wants something else says so with `color`.
COLOUR = PROVIDER["plymouth"].get("color")
COLOUR_HEX = ("".join(f"{round(channel * 255):02X}" for channel in COLOUR)
              if COLOUR else None)

# The boxed prompt is a different colour from the lines, on purpose: in the film
# the terminal runs green and the boxed prompt is a pale aqua. A provider that
# does not say gets the one colour, so nothing older changes shape.
DIALOG_COLOUR = PROVIDER["plymouth"].get("dialogColor") or COLOUR or [1, 1, 1]
DIALOG_HEX = "".join(f"{round(channel * 255):02X}" for channel in DIALOG_COLOUR)
BOX_TITLE = PROVIDER["plymouth"].get("boxTitle", "enter password")
PROGRESS_TITLE = PROVIDER["plymouth"].get("progressTitle", "booting")

# The title band's own ink. The band is FILLED with the dialog colour --
# like an old window manager's title bar, not a rule with a gap knocked in it
# for the caption, which is what this drew before and reads as a plain
# terminal divider rather than a window. Dark text and hollow corner widgets
# sit on top of it, the way the band inverts against the caption underneath.
# Measured off the reference screenshot's darkest pixels rather than flat
# black, so it keeps the same blue bias as the dialog colour instead of
# reading as a second, unrelated ink.
BAND_INK_HEX = "04121A"

# The one-shot feedback, worn by the panel's own title band -- each takes it
# over for a beat, then hands it back. GRANTED is a real signal (it plays
# exactly when Plymouth stops asking and boot proceeds); DENIED is not -- see
# mx_password_callback in DIALOG below for why.
GRANTED_TEXT = PROVIDER["plymouth"].get("grantedText", "ACCESS GRANTED")
DENIED_TEXT = PROVIDER["plymouth"].get("deniedText", "ACCESS DENIED")

# The family Plymouth is told about in the .plymouth. It decides which single
# TTF the mkinitcpio hook copies into the initramfs, and therefore what the one
# thing still drawn as TEXT comes out in -- the caps lock label. Everything
# whose shape matters is a PNG instead; see FONT_FILE. Installed system-wide
# by this script (see main), because a family the machine does not have
# resolves to the wrong face with nothing to say so.
FONT = "Courier Prime"

# ...and the face the splash is actually drawn in, as a FILE, out of the theme's
# own fonts/ directory rather than out of fc-match.
#
# Naming a family here instead would be a trap: at derive time fc-match may not
# have it, and when it misses it does not fail -- it returns `monospace`, and the
# splash comes out in the wrong face with nothing anywhere to say so. A file in
# the theme cannot miss. It is also why the typed lines are baked: at boot there
# is no fc-match at all, so a per-call family is ignored outright.
FONT_FILE = "fonts/CourierPrime-Regular.ttf"

# ...and the face the PANEL's own text is drawn in: the band captions and the
# progress digits. A chunky pixel face, the way the film draws its dialogs --
# at the panel's on-screen size a fine serif downscales to uneven stems, while
# chunky pixels survive. The typed boot lines stay in FONT_FILE above: Neo's
# monitor and Trinity's dialog are different screens, kept different here too.
PANEL_FONT_FILE = "fonts/VT323-Regular.ttf"

# The progress readout's characters, as one strip to crop cells out of. Baked
# for the same reason everything else here is: at boot the font is whatever the
# initramfs happens to hold, and digits in a face that does not match the box
# they sit inside is exactly the kind of seam this design exists to close.
# (The track itself is drawn, not typeset -- this face never had a full block,
# as no Courier does -- but it is drawn on the digits' own measured cell, so
# the two still share one grid. See splash_assets.)
ATLAS = "0123456789% "

# --- the animation, in frames of the 50 fps refresh omarchy.script assumes ---
FPS = 50
FRAMES_PER_CHAR = 5         # -> 10 keystrokes a second
OPEN_PAUSE = 60             # black, before the first letter
HOLD_PAUSE = 120            # once a line is complete
GAP_PAUSE = 60              # cleared screen, before the next line
#
# At 10 keystrokes a second the three pre lines take ~17 s, the tail another
# 5 s, and the storyboard plays ONCE -- `mx_advance` returns for good at the last step, it does not loop. Only
# 3.3 s of the splash is deterministic (plymouth-start to plymouth-quit); all
# the rest is the initrd phase, for as long as the disk's passphrase takes. So
# on a machine that boots fast, or unlocks fast, the later lines are simply
# never reached. That is the accepted price of a readable pace: the film's
# terminal types slowly, and 25 keystrokes a second read as a blur.

# The way out is not the way in, and it is much shorter. A boot's splash lives
# for as long as the disk takes to unlock; an exit's lives until the machine
# stops, which on this laptop is a couple of seconds. At the boot pace the first
# line would still be typing itself when the power went.
#
# So: no held black at the start, two and a half times the keystroke rate, and
# a hold long enough to read once rather than to sit on. The first line of
# each exit is still the payoff -- a real shutdown/reboot splash lives only a
# couple of seconds, so no pacing guarantees both lines on every machine --
# but the pauses below are tightened until a two-line exit plays in ~2.9-3.3 s
# (measured: reboot 2.9s, shutdown 3.3s), which gives the second line a real
# chance instead of none.
EXIT_FRAMES_PER_CHAR = 2    # -> ~25 keystrokes a second: fast, still legible
EXIT_OPEN_PAUSE = 5
EXIT_HOLD_PAUSE = 20
EXIT_GAP_PAUSE = 8

# How long the one-shot feedback holds the passphrase row before handing it
# back -- to the progress track for GRANTED, to an empty field for DENIED.
GRANTED_HOLD = 60           # 1.2s
DENIED_HOLD = 60            # 1.2s

# --- the phosphor halo -------------------------------------------------------
# The film's monitor is not flat ink: each glyph carries a soft halo, a few
# pixels wide, of its own colour. Plymouth has no blur at runtime, so the halo
# is baked here as a blurred twin of every typed line and layered under the
# crisp core at boot. Same size as the core (blur keeps dimensions), same
# crop, so no cell math changes: every guard below still measures the CORE.
#
# 0x5 baked nearly invisible (~2-3 px once scaled to the on-screen cell), so
# the lines read flat. The first attempt at wider, 0x18, measured wrong: its
# cut through a glyph falls only 109 to ~70-90 across 60 px of bake, a flat
# fog with no bright edge anywhere -- neighbouring halos merge into one haze
# instead of one bleed per letter. 0x8 keeps the gradient: 163 beside the ink
# falling to ~15 within 48 px of bake, i.e. a hot edge that decays outward,
# the way the reference stills bloom. 0.7 opacity keeps that edge present
# without washing the core out. Single layer on purpose: Plymouth sprites
# have opacity only, no additive blend, so a second tighter inner halo stays
# in reserve for if this still reads weak next to the reference, not shipped
# on a guess.
LINE_GLOW_BLUR = "0x8"      # bake pixels at size=120; reads as bleed on screen
LINE_GLOW_OPACITY = 0.7     # halo sprite opacity under the opaque core


def pace(mode):
    """Frames per character, and the three pauses, for one Plymouth mode."""
    if mode == "boot":
        return FRAMES_PER_CHAR, OPEN_PAUSE, HOLD_PAUSE, GAP_PAUSE
    return (EXIT_FRAMES_PER_CHAR, EXIT_OPEN_PAUSE, EXIT_HOLD_PAUSE,
            EXIT_GAP_PAUSE)


def keystroke_frames(char, prev, pos, base, line_seed=0):
    """Frames for one typed character: a human hand, not a metronome.

    Derived here so the .script stays a dumb step table with no string
    slicing. Deterministic: same phrase types the same way every boot.
    Spaces are fast, punctuation lands heavy, capitals cost a shift.
    A small positional jitter plus a burst/breath cycle breaks the
    leftover metronome inside plain lowercase runs.
    """
    if char == " ":
        return max(2, base - 2)
    frames = base
    if pos == 0:
        frames += 2  # first key finds the rhythm
    if char.isupper() and prev != " " and prev != "":
        frames += 1  # mid-word capital reaches
    elif char.isupper():
        frames += 2  # shift held for it
    if char in ",;:":
        frames += 5
    elif char in ".!?":
        frames += 7
        if prev in ".!?":
            frames += 4  # second and third dot of "..." hang
    elif char in "'-":
        frames += 2
    # Hand noise: -1..+1 from char and position, seeded per line so no
    # two lines share the same wobble. Bursts of two fast keys then one
    # breath, on a 9-key cycle offset per line.
    frames += ((ord(char) * 7 + pos * 13 + line_seed * 5) % 3) - 1
    phase = (pos + line_seed * 3) % 9
    if phase in (4, 5):
        frames -= 1
    elif phase == 6:
        frames += 2
    return max(2, frames)

# --- layout, all of it in fractions of the window ---------------------------
# NOTHING here is a pixel count, and no point size is worked out at derive time.
# Plymouth draws at the panel's NATIVE resolution, so a size chosen against
# `hyprctl` today is wrong the moment the machine is docked to another screen
# -- and wrong in the preview, where the script sees half the panel's width.
# The script measures its own text instead (see mx_fit), which is exact
# whatever the panel and whatever the font's metrics turn out to be.
TEXT_X = 0.055              # left margin of Neo's terminal
TEXT_Y = 0.085              # and how far down it starts
TEXT_WIDTH = 0.42           # what the longest line takes up
KEY_CELLS = 21              # passphrase slots, at most. 21 on purpose: it
                            # is exactly the progress row's own width (16
                            # track blocks + a gap + 4 digits), so both rows
                            # fill the panel the same way -- and it is ODD,
                            # so one typed circle lands on the exact centre.
PROMPT_WIDTH = 0.27          # sizes the CAPS LOCK label; the disk's own prompt
                            # this was named for is no longer drawn. Nine
                            # tenths of the box below, so the label belongs to
                            # the panel rather than to the window.

# --- the box ----------------------------------------------------------------
# The film's prompt is a framed panel with a filled title band across its top.
# It is one baked PNG per caption rather than a frame plus text composed at
# boot: Plymouth has no blit, and two images that have to line up are two
# images that can drift.
#
# Its interior is wide enough for BOTH phases, so the panel never changes size
# between asking for the passphrase and reporting progress -- 21 masked
# characters, and 16 track blocks + a gap + 4 digits, is 21 either way. Same
# width, same centre, one grid.
#
# Every element inside the panel that is drawn LIVE rather than baked -- the
# mask, the track, the digits -- is sized off `mx_cell`, a fraction of this,
# so this scales the whole panel and its contents together. It went 0.46 ->
# 0.58 to fix contents that looked small, which was the wrong knob: the
# caption's own scale and the panel's internal proportions were the actual
# problem, and both are fixed below. With those right, 0.40 is enough panel --
# 0.58 was simply too big on a real screen. And 0.30 is a quarter off that:
# the film's prompt is a small nested dialog (RTF CONTROL / ACCESS GRANTED
# in the corner of Trinity's screen), not a centred billboard.
BOX_WIDTH = 0.30            # of the window
BOX_CELLS = 26              # interior width, in cells: 25 of content and air

# --- the progress track -----------------------------------------------------
# Not a fraction of the window: it is measured in CELLS of the passphrase line,
# so the dashes, the blocks and the digits all land on one monospace grid. The
# track is one image drawn twice -- the whole of it at TRACK_ALPHA, and the part
# that is done, opaque, on top -- so an empty track is the same object as a full
# one rather than a different material. `[████░░░░] 42%` was the old readout:
# `░` is a dither pattern and `█` is solid ink, which made 0% and 50% look like
# two unrelated widgets.
#
# 16, not 20: kerning (added when the mask became a drawn circle) widens
# every cell on this grid, and this row -- BAR_CELLS+BAR_GAP_CELLS+PCT_CELLS
# -- only had ONE cell of slack against BOX_CELLS to absorb that in. It did
# not: photographed on real hardware, "27%" ran past the panel's own right
# edge. The passphrase row was never at risk, which
# is why only the digits, not the passphrase, ever showed it. 16 brings this
# row to 21 cells, leaving a five-cell margin --
# see the guard right after `pitch` is computed in splash_assets(), which
# now checks this arithmetic instead of leaving it to a comment.
BAR_CELLS = 16              # blocks in the track
BAR_GAP_CELLS = 1           # between the track and the digits
PCT_CELLS = 4               # "  0%" .. "100%", padded, so the width is fixed
TRACK_ALPHA = 0.25          # the part still to do


def die(message):
    print(f"derive-plymouth: {message}", file=sys.stderr)
    sys.exit(1)


def available_font():
    """The font has to exist: the mkinitcpio hook resolves it with fc-match from
    the .plymouth's `Font=` and copies it into the initramfs. Without it, boot
    would have no text at all -- and label-freetype does not fall back politely
    when it finds nothing, it segfaults."""
    try:
        output = subprocess.run(["fc-match", "-f", "%{family}", FONT],
                                capture_output=True, text=True, check=True).stdout
    except (OSError, subprocess.CalledProcessError):
        return "monospace"
    return FONT if FONT.lower() in output.lower() else "monospace"


def literal(text):
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def storyboard(mode="boot"):
    """The typing for one mode, already resolved into steps: which line, how
    much of it, and for how many frames.

    Generated here rather than inside the Plymouth script on purpose -- that way
    the .script needs no SubString, no Length and no string slicing. It used to
    carry every step's literal text; now a step is two integers, because the
    drawing is one Crop of a picture that already exists.

    The film's shape, not a terminal's: a line types, holds, and the screen
    CLEARS before the next one. They do not pile up.

    NOTHING BLINKS. The block cursor that used to trail every step is gone, and
    that is what makes the rest of this cheap: with nothing after the text, the
    first N characters of a line are exactly the first N cells of its image, so
    typing is a crop and needs no font at boot at all.

    A step with 0 characters shown is a held blank -- the pause before the first
    line, and the cleared screen between them.

    `line` is an index into MODE_IMAGES[mode], not into the mode's own list --
    every mode's pictures share one flat table in the script, so a step can be
    used without knowing which mode it came from.

    Returns (steps, gate). In boot mode with post-unlock lines, gate is the
    index of the last pre line's HOLD step: the script holds there while a
    passphrase dialog is up, resting on the finished line rather than on the
    cleared screen after it, and the unlock callback releases it. None
    everywhere else.
    """
    if mode == "boot":
        pre, post = LINES, AFTER_UNLOCK
    else:
        pre, post = MODE_LINES[mode], []
    per_char, open_pause, hold_pause, gap_pause = pace(mode)
    steps = [(0, 0, open_pause)]
    gate = None
    for index, phrase in enumerate(pre):
        for n in range(1, len(phrase) + 1):
            char = phrase[n - 1]
            prev = phrase[n - 2] if n > 1 else ""
            steps.append((index, n, keystroke_frames(char, prev, n - 1,
                                                     per_char, index)))
        steps.append((index, len(phrase), hold_pause))
        if index != len(pre) - 1 or post:
            steps.append((index, 0, gap_pause))
    if post:
        # The last pre line's hold step, not the gap after it: holding here
        # rests on the finished line, while the gap would rest on a blank.
        gate = len(steps) - 2
        for offset, phrase in enumerate(post):
            index = len(pre) + offset
            for n in range(1, len(phrase) + 1):
                char = phrase[n - 1]
                prev = phrase[n - 2] if n > 1 else ""
                steps.append((index, n, keystroke_frames(char, prev, n - 1,
                                                         per_char, index)))
            steps.append((index, len(phrase), hold_pause))
            if offset != len(post) - 1:
                steps.append((index, 0, gap_pause))
    return steps, gate


def percent_cells():
    """`  0%` .. `100%` as indices into the digit atlas, four per percent.

    A table, for the same reason the storyboard is one: no string is ever built
    up inside the .script. The atlas is ATLAS, so a digit's index is its own
    value, `%` is 10 and a space is 11.
    """
    rows = []
    for percent in range(101):
        label = f"{percent:>{PCT_CELLS - 1}}%"
        rows.append([ATLAS.index(character) for character in label])
    return rows


TYPING = string.Template("""
#----------------------------------------- $NAME $RULE
# Put here by $CLI. DO NOT edit this file by hand: it is derived again
# from Omarchy's omarchy.script on every `omarchy update`.
#
# Neo's monitor. The logo is still loaded, just invisible -- its box is what
# the password dialog below measures itself against, and moving that would move
# Omarchy's own geometry with it.
#
# The lines are PICTURES, one per line, baked at derive time in the theme's
# own face. At boot there is no fc-match, so a font family asked for by name is
# ignored and every Image.Text comes out in whatever single TTF the initramfs
# holds -- which is no way to choose a typeface. Typing is therefore a Crop: N
# characters of a monospace line is the first N cells of its picture, exact at
# any panel size, and it costs no text rendering at all.
#
# Nothing here is a pixel count. Sizes come from the window and from ratios
# measured at derive time, never from the machine this was generated on.

global.mx_r = $R;   # the box's colour. The one thing still drawn as TEXT is
global.mx_g = $G;   # the caps lock label, which belongs to the box, so it
global.mx_b = $B;   # takes its colour too.
global.mx_font = "$FONT";
global.mx_w = Window.GetWidth();
global.mx_h = Window.GetHeight();

# Ask the font how big it really is at a known size, then scale to the width we
# actually want. 40 is arbitrary and cancels out. Still needed for the prompt
# and the caps label, which are the only text left.
fun mx_fit(text, target) {
  probe = Image.Text(text, 1, 1, 1, 1, global.mx_font + " 40");
  width = probe.GetWidth();
  if (width < 1) return 12;
  size = Math.Int(40 * target / width);
  if (size < 8) size = 8;
  return size;
}

# One cell for every line of every mode: they were rendered at one point size in
# one monospace face, so scaling each to its own character count keeps them on a
# single grid. $LINE_ASPECT is a RATIO measured at derive time -- the line's
# height over one cell's width -- so it survives any panel.
#
# $WIDEST_CELLS is the longest BOOT line, not the longest line there is. That is
# what fixes the size: the boot lines are the ones whose size, colour and face
# were settled by looking at them, and an exit whose longest line is shorter
# would otherwise be typed LARGER to fill the same $TEXT_WIDTH. Every mode
# therefore shares the boot's cell, and the deriver checks that no line of any
# mode runs off the right-hand edge at it.
global.mx_cell_w = global.mx_w * $TEXT_WIDTH / $WIDEST_CELLS;
global.mx_line_h = Math.Int(global.mx_cell_w * $LINE_ASPECT);
$LINE_LOAD

$TABLE

# Which storyboard plays, decided before the first frame.
#
# `Plymouth.GetMode()` is what plymouthd was started with, and it is already
# right HERE, at load time -- not only inside a callback, which is the only
# place omarchy.script asks it. Checked with `preview-plymouth.sh --mode`:
# probes at the top and the bottom of the file both read `shutdown` under
# --mode=shutdown. So the whole sequence can be selected rather than swapped
# mid-flight.
#
# Every mode's steps and pictures live in the ONE flat table above; a mode is
# just a slice of it. That keeps this dispatch to two numbers, and it means an
# unknown mode -- `updates`, `firmware-upgrade`, anything Plymouth grows later
# -- falls through to the boot lines rather than to a blank screen.
#
# There are only TWO exits to have a slice for. plymouth-halt.service,
# plymouth-poweroff.service and plymouth-kexec.service all start the daemon with
# --mode=shutdown; only plymouth-reboot.service differs. A halt cannot be told
# apart from a power off from in here.
global.mx_mode = Plymouth.GetMode();
global.mx_step = $BOOT_FIRST;
global.mx_end = $BOOT_END;
$DISPATCH

global.mx_frame = 0;
global.mx_painted = -1;

# The gate between asking and entering: the last pre-unlock line's hold step.
# -1 when the provider names no post-unlock tail, and then this never matches.
# mx_unlocked is released by the accepted-password path below -- and only
# there: normal also fires when the splash is first shown, before any dialog,
# and Plymouth re-fires it when the renderer re-shows, so `password_shown`
# alone cannot tell acceptance apart from arrival.
global.mx_gate = $GATE;
global.mx_unlocked = 0;

mx.sprite = Sprite();
# The halo twin rides one layer under the crisp core, same box, same crop.
# Plymouth has no blur, so the blur was baked at derive time; here it is just
# a second sprite that appears and clears together with the core.
mx_glow.sprite = Sprite();
mx_glow.sprite.SetPosition(Math.Int(global.mx_w * $TEXT_X),
                           Math.Int(global.mx_h * $TEXT_Y), 9999);
mx_glow.sprite.SetOpacity(0);
# The left edge never moves: the line grows rightwards from a fixed column, the
# way a terminal does. Centring it would shuffle the whole line sideways on
# every keystroke.
mx.sprite.SetPosition(Math.Int(global.mx_w * $TEXT_X),
                      Math.Int(global.mx_h * $TEXT_Y), 10000);
mx.sprite.SetOpacity(0);

fun mx_paint(step) {
  if (step == global.mx_painted) return;
  global.mx_painted = step;
  shown = global.mx_shown[step];
  if (shown < 1) {
    # A held blank: the pause before the first line, and between them.
    mx.sprite.SetOpacity(0);
    mx_glow.sprite.SetOpacity(0);
    return;
  }
  mx.sprite.SetImage(global.mx_img[global.mx_line[step]].Crop(
    0, 0, Math.Int(shown * global.mx_cell_w), global.mx_line_h));
  mx.sprite.SetOpacity(1);
  mx_glow.sprite.SetImage(global.mx_glow[global.mx_line[step]].Crop(
    0, 0, Math.Int(shown * global.mx_cell_w), global.mx_line_h));
  mx_glow.sprite.SetOpacity($GLOW_ALPHA);
}

fun mx_tick() {
  mx_caps_tick();
  mx_feedback_tick();

  if (global.mx_step >= global.mx_end) return;

  # Held at the gate while a passphrase dialog is up: the pre lines rest on
  # their last line until the disk is open, and only then does the tail type.
  # No dialog -- no encryption -- means no hold: the storyboard plays through.
  if (global.mx_gate >= 0 && global.mx_step == global.mx_gate &&
      global.mx_unlocked == 0 && global.password_shown == 1) return;

  if (global.mx_painted == -1) {
    mx_paint(global.mx_step);
    return;
  }

  global.mx_frame++;
  if (global.mx_frame < global.mx_dur[global.mx_step]) return;

  global.mx_frame = 0;
  global.mx_step++;
  # At the end it rests on the last line rather than looping: a boot is shorter
  # than the whole sequence, and starting over would be noticeable. An exit is
  # shorter still -- the machine usually stops before the second line.
  if (global.mx_step >= global.mx_end) return;
  mx_paint(global.mx_step);
}

# Defined here because refresh_callback below calls it on every frame, and it
# has to exist before the first one. The dialog it drives is set up at the end
# of this file, where `entry` finally has a position to hang off.
#
# MIND the names. A global holding a number and an object holding sprites
# cannot share an identifier: `global.mx_caps = -1` followed by
# `mx_caps.image = ...` further down assigns to a number, silently does
# nothing, and the sprite draws nothing with no error anywhere. Hence the
# _state suffix, and why the progress track's numbers are mx_bar_* while its
# sprites are mx_track / mx_fill -- no name is ever both.
global.mx_dialog_on = 0;
global.mx_bullets = -1;
global.mx_caps_state = -1;
global.mx_percent = -1;
# Whether the progress readout is on screen at all. It is NOT the same question
# as "what is the percentage": see mx_progress.
global.mx_bar_on = 0;
# Countdown, in frames, of the one-shot feedback -- see mx_feedback_tick().
global.mx_denied_frames = 0;
global.mx_granted_frames = 0;
# Set the moment the DENIED heuristic fires, cleared the moment real typing
# progress is seen again -- see mx_password_callback for why GRANTED cannot
# just read `password_shown` on its own.
global.mx_was_denied = 0;
""")


DIALOG = string.Template("""
#----------------------------------------- $NAME dialog $RULE
# The passphrase, as the film's framed panel rather than a rounded box.
#
# Omarchy's own dialog is NOT rewritten. Its callbacks are registered further
# up this file; ours are registered below, and the last registration wins. So
# `display_password_callback` simply stops being called, its entry, lock and
# bullet sprites stay at the opacity 0 they were created with, and nothing on
# the passphrase path has been edited. If any of this ever fails to load,
# Omarchy's dialog is still whole underneath.
#
# It hangs off `entry.y`, Omarchy's own idea of where a dialog goes -- raised
# a bit from there, not left exactly on it. Photographed sitting right at the
# bottom edge of the screen with entry.y as the top, which read as too low
# once the panel was its own filled window rather than a thin rule; entry.y
# is still the anchor, `mx_box_lift` just moves the box up off it.
#
# ONE panel, two captions. The passphrase and the progress readout are never on
# screen together, so they share the frame as well as the row -- swapping a
# whole baked image rather than composing a frame and a caption, because
# Plymouth has no blit and two images that must line up are two images that can
# drift. It also means the boot never cuts from a framed panel to a bare bar,
# which is the "three unrelated widgets taking turns" this design exists to
# avoid.

global.mx_box_w = Math.Int(global.mx_w * $BOX_WIDTH);
global.mx_box_h = Math.Int(global.mx_box_w * $BOX_ASPECT);

global.mx_box_x = Math.Int((global.mx_w - global.mx_box_w) / 2);
global.mx_box_lift = Math.Int(global.mx_h * 0.20);
global.mx_box_y = entry.y - global.mx_box_lift;

# BOX_ASPECT is derive-time -- baked from THIS machine's font metrics, never
# from a screen it has not seen. entry.y is boot-time, and on a panel where
# it sits low there may not be BOX_ASPECT's worth of room under it even after
# the lift above: measured, not assumed, on this machine's own panel, where
# the unlifted box once ran off the bottom of the screen entirely. So the
# height is clamped against the window Plymouth is actually drawing into, the
# same way the type sizes elsewhere in this file are measured at boot rather
# than baked in.
global.mx_box_room = global.mx_h - global.mx_box_y - Math.Int(global.mx_h * 0.02);
if (global.mx_box_h > global.mx_box_room) global.mx_box_h = global.mx_box_room;

mx_box.key = Image("box-key.png");
mx_box.bar = Image("box-bar.png");
mx_box.granted = Image("box-granted.png");
mx_box.denied = Image("box-denied.png");
mx_box.key_scaled = mx_box.key.Scale(global.mx_box_w, global.mx_box_h);
mx_box.bar_scaled = mx_box.bar.Scale(global.mx_box_w, global.mx_box_h);
mx_box.granted_scaled = mx_box.granted.Scale(global.mx_box_w, global.mx_box_h);
mx_box.denied_scaled = mx_box.denied.Scale(global.mx_box_w, global.mx_box_h);

mx_box.sprite = Sprite();
mx_box.sprite.SetPosition(global.mx_box_x, global.mx_box_y, 10000);
mx_box.sprite.SetOpacity(0);

# The interior grid. mx_cell and mx_in_x are FRACTIONS OF THE BOX'S WIDTH,
# measured when the box was drawn, so they scale with it and no pixel count
# ever crosses from the machine that derived this to the one that boots it.
# mx_in_y and mx_in_h are FRACTIONS OF THE BOX'S HEIGHT instead: the whole
# panel image (corner squares included) is scaled to (mx_box_w, mx_box_h),
# but mx_box_h is clamped against the screen room while mx_box_w never is,
# so a width-based row drifts down past the panel's own compressed bottom
# edge when the clamp fires. Height-based, the row rides the same vertical
# squash as the baked band and stays where it was drawn. Unclamped the two
# bases agree exactly (box_h == box_w * BOX_ASPECT at derive time).
#
# Everything inside is scaled to a whole number of these cells and rendered at
# one point size, which is what puts the mask, the track and the digits on a
# single monospace grid instead of three that nearly agree.
global.mx_cell = global.mx_box_w * $BOX_CELL_FRAC;
global.mx_in_x = global.mx_box_x + Math.Int(global.mx_box_w * $BOX_PAD_FRAC);
global.mx_in_y = global.mx_box_y + Math.Int(global.mx_box_h * $BOX_ROW_FRAC);
# The row's HEIGHT is the unkerned pitch times the aspect -- NOT mx_cell:
# `cell` carries kerning's air, which belongs between glyphs horizontally,
# not stacked vertically. Sizing the height off the kerned cell stretches
# every row by kerning's share (19% on the panel's face), which is exactly
# the oval-mask look a real boot photographed once. Pitch times aspect is
# the row's own baked height, scaled -- nothing more.
global.mx_in_h = Math.Int(global.mx_box_h * $BOX_PITCH_FRAC * $CELL_ASPECT);

# The panel's content rows -- the passphrase ($KEY_CELLS slots) and the track
# plus its gap plus the digits -- are all $ROW_CELLS cells wide here, share
# one centre, the box's own, and are centred as groups rather than anchored
# left: a short passphrase stranded off to one side of a wide box is exactly
# what the old left anchor did. The progress fill still grows left to right
# inside its centred track; only the passphrase fill re-centres per keystroke,
# so one dash sits exactly in the middle and the row grows outward
# symmetrically.
global.mx_row_w = Math.Int($ROW_CELLS * global.mx_cell);
global.mx_row_x = global.mx_box_x + Math.Int((global.mx_box_w - global.mx_row_w) / 2);
global.mx_pass_w = Math.Int($KEY_CELLS * global.mx_cell);
global.mx_pass_x = global.mx_box_x + Math.Int((global.mx_box_w - global.mx_pass_w) / 2);

# The passphrase: one dash per typed character, growing from the centre
# outward on the panel's grid. The field shows nothing until the first
# keystroke -- there is no placeholder row.
# The typed dashes live in their own image, `keydots.png` -- drawn, not
# typeset, the way the film's field answers with `-`. The fill
# below crops its prefix out of here; it is never shown whole.
mx_dots.image = Image("keydots.png");
mx_dots.scaled = mx_dots.image.Scale(Math.Int($KEY_CELLS * global.mx_cell), global.mx_in_h);

mx_key_fill.sprite = Sprite();
mx_key_fill.sprite.SetPosition(global.mx_pass_x, global.mx_in_y, 10002);
mx_key_fill.sprite.SetOpacity(0);


# The disk's own prompt used to be drawn here too, dimmed, above the panel --
# but the panel now has its own caption baked into its band ("enter
# password"), so the disk's words on top of ours just repeated the question.
# Dropped rather than kept and hidden.
#
# `mx_prompt_size`/`mx_prompt_face` survive -- they are not really about the
# prompt any more, they are the shared type size the CAPS LOCK label below
# still sizes itself from, and changing that would be its own regression.
global.mx_prompt_size = mx_fit($PROMPT_PROBE, global.mx_w * $PROMPT_WIDTH);
global.mx_prompt_face = global.mx_font + " " + global.mx_prompt_size;

mx_caps.image = Image.Text($CAPS_TEXT, global.mx_r, global.mx_g, global.mx_b, 1,
                           global.mx_prompt_face);
mx_caps.sprite = Sprite(mx_caps.image);
mx_caps.sprite.SetPosition(
  Math.Int((global.mx_w - mx_caps.image.GetWidth()) / 2),
  global.mx_box_y + global.mx_box_h + Math.Int(global.mx_prompt_size * 0.6),
  10001);
mx_caps.sprite.SetOpacity(0);

# The progress track, inside the same panel and on the same grid.
#
# ONE image, drawn by TWO sprites: the whole track at $TRACK_ALPHA underneath,
# and the part that is done, opaque, cropped over it. That is deliberate -- an
# empty track has to be the same object as a full one, merely unlit. The old
# readout spelt `[####....]`, where the empty half was a dither pattern and the
# full half was solid ink, so 0% and 50% looked like two different things.
mx_track.image = Image("bar.png");
mx_track.scaled = mx_track.image.Scale(Math.Int($BAR_CELLS * global.mx_cell), global.mx_in_h);
mx_track.sprite = Sprite(mx_track.scaled);
mx_track.sprite.SetPosition(global.mx_row_x, global.mx_in_y, 10001);
mx_track.sprite.SetOpacity(0);

mx_fill.sprite = Sprite();
mx_fill.sprite.SetPosition(global.mx_row_x, global.mx_in_y, 10002);
mx_fill.sprite.SetOpacity(0);

# The digits, cropped out of a baked strip rather than typeset. Image.Text would
# put them in the initramfs's font -- a different face from the panel they sit
# inside, and the one seam a reader would actually notice.
mx_digits.image = Image("digits.png");
mx_digits.scaled = mx_digits.image.Scale(Math.Int($ATLAS_CELLS * global.mx_cell),
                                         global.mx_in_h);
$PCT_TABLE
$PCT_SPRITES

fun mx_pct_show(on) {
$PCT_SHOW
}

fun mx_bar_show(on) {
  # The fill is never turned on from here, only off: mx_progress owns it,
  # because it is the only thing that knows how wide the crop should be. Clearing
  # mx_percent makes the next update repaint rather than short-circuit, so the
  # fill comes back with a fresh crop instead of the one from the last boot
  # phase.
  global.mx_percent = -1;
  global.mx_bar_on = on;
  mx_fill.sprite.SetOpacity(0);
  if (on == 0) {
    mx_track.sprite.SetOpacity(0);
    mx_pct_show(0);
  } else {
    mx_box.sprite.SetImage(mx_box.bar_scaled);
    mx_box.sprite.SetOpacity(1);
    mx_track.sprite.SetOpacity($TRACK_ALPHA);
    mx_pct_show(1);
  }
}

# Driven from mx_tick() on every frame. It used to hang off the caret's blink;
# with the caret gone it needs a driver of its own, and a flag of its own to say
# the panel is up.
fun mx_caps_tick() {
  if (global.mx_dialog_on == 0) return;
  state = Plymouth.GetCapslockState();
  if (state == global.mx_caps_state) return;
  global.mx_caps_state = state;
  if (state == 0) {
    mx_caps.sprite.SetOpacity(0);
  } else {
    mx_caps.sprite.SetOpacity(1);
  }
}

# Driven from mx_tick() on every frame, same as mx_caps_tick(). Counts down
# whichever one-shot flash is up, and hands the BAND back when the count runs
# out -- to `enter password` for DENIED, to the progress caption (which also
# starts the real track) for GRANTED. The flash lives in the band itself now,
# not as text layered over the content row: GRANTED/DENIED and "enter
# password"/the progress title were two captions saying the same thing in two
# places, and the band is the one that already exists for exactly this.
fun mx_feedback_tick() {
  if (global.mx_denied_frames > 0) {
    global.mx_denied_frames = global.mx_denied_frames - 1;
    if (global.mx_denied_frames == 0) mx_box.sprite.SetImage(mx_box.key_scaled);
  }
  if (global.mx_granted_frames > 0) {
    global.mx_granted_frames = global.mx_granted_frames - 1;
    if (global.mx_granted_frames == 0) {
      mx_box.sprite.SetImage(mx_box.bar_scaled);
      mx_bar_show(1);
    }
  }
}

fun mx_hide_dialog() {
  global.mx_dialog_on = 0;
  global.mx_bullets = -1;
  global.mx_caps_state = -1;
  global.mx_denied_frames = 0;
  mx_key_fill.sprite.SetOpacity(0);
  mx_caps.sprite.SetOpacity(0);
  mx_box.sprite.SetOpacity(0);
}

fun mx_password_callback(prompt, bullets) {
  # Omarchy's own callback sets this, and its display_normal_callback needs it
  # to know a password was asked for. Ours has to set it too.
  global.password_shown = 1;
  stop_fake_progress();
  hide_progress_bar();
  mx_bar_show(0);

  shown = bullets;
  if (shown > $KEY_CELLS) shown = $KEY_CELLS;

  if (shown > 0 && global.mx_denied_frames > 0) {
    # Typing resumed while the DENIED flash was still up: cut it short rather
    # than sit in front of what the user is typing right now.
    global.mx_denied_frames = 0;
  }

  if (global.mx_dialog_on == 1 && shown == 0 && global.mx_bullets > 0 &&
      global.mx_denied_frames == 0) {
    # HEURISTIC, not a real signal -- see provider.json's //grantedDenied.
    # Plymouth re-asking after a rejected passphrase calls this with the same
    # prompt and bullets back at 0, and there is nothing else here to tell
    # that apart from the user backspacing the field to nothing by hand.
    global.mx_denied_frames = $DENIED_HOLD;
    mx_box.sprite.SetImage(mx_box.denied_scaled);
    # See `mx_was_denied`'s own declaration for why GRANTED cannot be decided
    # from `password_shown` alone.
    global.mx_was_denied = 1;
  } else {
    mx_box.sprite.SetImage(mx_box.key_scaled);
  }
  mx_box.sprite.SetOpacity(1);

  if (shown != global.mx_bullets) {
    global.mx_bullets = shown;
    if (shown < 1) {
      # Crop() to zero width is not worth trusting, and an empty field is what
      # "nothing typed yet" should look like anyway -- the panel and its
      # caption stay on screen, the row itself stays empty.
      mx_key_fill.sprite.SetOpacity(0);
    } else {
      # Real typing progress -- the passphrase field just grew by a character
      # -- is the one event that un-arms a denial. `password_shown` cannot do
      # this job on its own: this whole function runs on every refresh tick
      # the dialog is up, not once per keystroke (the `shown != mx_bullets`
      # guard right here exists for exactly that reason), and it sets
      # `password_shown = 1` unconditionally at its own top every single one
      # of those ticks. A flag reset inside the DENIED branch above would be
      # re-armed by the very next tick's unconditional set, before
      # mx_normal_callback ever gets a chance to read it -- proved by feeding
      # this function a denial followed by repeated no-op ticks in a doctored
      # preview and watching GRANTED paint anyway. `mx_was_denied` only ever
      # changes on these two real events, never on a tick that changed
      # nothing.
      global.mx_was_denied = 0;
      # Centred as a GROUP, not left-anchored: the typed dashes grow outward
      # from the middle of the centred row, so one dot sits exactly
      # in the centre rather than stranded off to one side of a wide box.
      # The offset is a WHOLE number of cells from the row's own left
      # edge, so every bright dash lands exactly on the shared grid: a
      # fractional offset would park each dash between two cells, straddling them.
      key_w = Math.Int(shown * global.mx_cell);
      key_x = global.mx_pass_x + Math.Int((($KEY_CELLS - shown) / 2) * global.mx_cell);
      mx_key_fill.sprite.SetPosition(key_x, global.mx_in_y, 10002);
      mx_key_fill.sprite.SetImage(mx_dots.scaled.Crop(0, 0, key_w, global.mx_in_h));
      mx_key_fill.sprite.SetOpacity(1);
    }
  }

  global.mx_dialog_on = 1;
  mx_caps_tick();
}

fun mx_normal_callback() {
  # Omarchy's first: it hides its dialog and starts the fake progress, and that
  # timing is its business, not ours.
  display_normal_callback();
  # Whether OUR dialog was up when normal arrived: the one signal that tells
  # acceptance apart from a splash (re-)show. Read before mx_hide_dialog()
  # below clears it.
  dialog_was_up = global.mx_dialog_on;
  # ...but the bar it just showed is the rounded one, and we draw a readout.
  progress_box.sprite.SetOpacity(0);
  progress_bar.sprite.SetOpacity(0);
  mx_hide_dialog();
  # `password_shown` alone is not enough -- it is Omarchy's own "a dialog was
  # shown at least once this boot" flag, set the instant a single character is
  # typed and never reset by anything, ours or Omarchy's. A boot that gives up
  # on a wrong passphrase (retries exhausted, no further prompt) reaches this
  # function with password_shown still 1 from the very first keystroke, and
  # painted ACCESS GRANTED over a rejected password. `mx_was_denied` is what
  # actually rules that out: see its own declaration and mx_password_callback.
  if (global.password_shown == 1 && global.mx_was_denied == 0 &&
      dialog_was_up == 1) {
    # ...and the gate opens: the dialog was up and now normal is back, so the
    # passphrase was accepted and the post-unlock tail may type. Only HERE --
    # normal also fires when the splash is first shown, before any dialog, and
    # Plymouth re-fires it whenever the renderer re-shows, so a history flag
    # cannot tell acceptance apart from arrival. The dialog still being up can.
    global.mx_unlocked = 1;
    # ACCESS GRANTED in the band itself -- mx_feedback_tick() hands it to the
    # progress caption, and starts the real track, once $GRANTED_HOLD runs out.
    mx_box.sprite.SetImage(mx_box.granted_scaled);
    mx_box.sprite.SetOpacity(1);
    global.mx_granted_frames = $GRANTED_HOLD;
  }
}

fun mx_progress(fraction) {
  # Nothing is drawn unless the readout is actually on screen, and that is not a
  # tidiness check -- without it the fill turns ITSELF on, since it is the only
  # thing that knows how wide the crop should be.
  #
  # Photographed: on the way out the splash showed one lit cell of the track
  # floating in the middle of a black screen, with no panel and no track behind
  # it. plymouthd feeds progress into `Plymouth.SetBootProgressFunction` in
  # --mode=shutdown and --mode=reboot as well as --mode=boot, and nothing on an
  # exit ever asks for a passphrase, so mx_bar_show(1) is never reached and the
  # panel that block belongs to is never shown.
  #
  # The opacity is cleared rather than merely left alone: a percent arriving
  # after the readout was hidden must not leave the last crop lit.
  if (global.mx_bar_on == 0) {
    mx_fill.sprite.SetOpacity(0);
    return;
  }

  percent = Math.Int(fraction * 100);
  if (percent < 0) percent = 0;
  if (percent > 100) percent = 100;
  if (percent == global.mx_percent) return;
  global.mx_percent = percent;

  # Whole cells only. A partial cell would mean a block cut down the middle,
  # which is the one thing a monospace grid must never show.
  filled = Math.Int(percent * $BAR_CELLS / 100);
  if (filled < 1) {
    # Crop() to zero width is not worth trusting, and an unlit track already
    # says "nothing done yet" -- that is the whole point of drawing it.
    mx_fill.sprite.SetOpacity(0);
  } else {
    mx_fill.sprite.SetImage(
      mx_track.scaled.Crop(0, 0, Math.Int(filled * global.mx_cell), global.mx_in_h));
    mx_fill.sprite.SetOpacity(1);
  }

$PCT_PAINT
}

# Only take the dialog over if there is something to draw it with.
#
# Tested by deleting keydots.png from a staged theme: Plymouth does NOT abort
# the script over Scale() on an image that failed to load, it carries on. So
# without this guard the prompt appeared with no field, no mask and no panel
# -- you could still type your passphrase, but with nothing on screen to say
# so, which on an encrypted disk at 7am is its own kind of broken.
#
# It asks for the WIDTH, not for the image: `Image()` on a file that is not
# there still hands back something that tests as true, and the first version of
# this guard let the broken case straight through.
#
# EVERY asset, not just the passphrase line. Taking the password callback over
# also takes the progress readout over -- mx_normal_callback hides Omarchy's
# rounded bar -- so a missing bar.png, or missing digits, or a missing panel
# would leave a boot with no progress of any kind and nothing to say why.
#
# With it, a theme missing its assets falls back to Omarchy's own dialog:
# registered further up, never unregistered, and whole.
if (mx_dots.image.GetWidth() > 0 &&
    mx_track.image.GetWidth() > 0 &&
    mx_digits.image.GetWidth() > 0 && mx_box.key.GetWidth() > 0 &&
    mx_box.bar.GetWidth() > 0 && mx_box.granted.GetWidth() > 0 &&
    mx_box.denied.GetWidth() > 0) {
  Plymouth.SetDisplayPasswordFunction(mx_password_callback);
  Plymouth.SetDisplayNormalFunction(mx_normal_callback);
}
""")


def typing_block(font, metrics):
    """The typed lines: every mode's pictures and every mode's steps, flat.

    One table and one image list for the whole file, with each mode owning a
    slice of them, rather than a table per mode. Two reasons. The .script gets
    no function big enough to worry about -- the boot's storyboard alone is some
    ninety statements -- and `mx_tick` never has to know which mode it is in: it
    walks from `mx_step` to `mx_end` and those two numbers are all a mode is.

    Loading every mode's pictures rather than only the running mode's is
    deliberate too. It is four extra `Image()` calls on a splash that already
    does four, it happens once, and it means the dispatch below cannot leave a
    sprite pointing at an image that was never loaded.
    """
    load, table, slices = [], [], {}
    boot_gate = -1              # no post-unlock tail: the gate never matches
    image_base = 0              # image slots; load holds 2 statements per image
    for mode, lines in MODE_LINES.items():
        first_image = image_base
        # One Image() and one Scale() per line, at start-up, never again. Each
        # is scaled to its OWN character count times the shared cell, which is
        # what keeps pictures of different lengths on one grid. The halo twin
        # rides the same slot in mx_glow.
        for index, cells in enumerate(metrics["LINE_CELLS"][mode]):
            slot = first_image + index
            load.append(
                f'global.mx_img[{slot}] = Image("line-{mode}-{index}.png")'
                f".Scale(Math.Int({cells} * global.mx_cell_w), "
                f"global.mx_line_h);")
            load.append(
                f'global.mx_glow[{slot}] = '
                f'Image("lineglow-{mode}-{index}.png")'
                f".Scale(Math.Int({cells} * global.mx_cell_w), "
                f"global.mx_line_h);")

        first_step = len(table)
        steps, gate = storyboard(mode)
        if mode == "boot" and gate is not None:
            boot_gate = first_step + gate
        for line, shown, frames in steps:
            table.append(
                f"global.mx_line[{len(table)}] = {first_image + line}; "
                f"global.mx_shown[{len(table)}] = {shown}; "
                f"global.mx_dur[{len(table)}] = {frames};")
        slices[mode] = (first_step, len(table))
        image_base += len(lines)

    # Boot is the fallback, so it is assigned before the tests rather than
    # inside one: a mode nobody thought of gets the boot lines, not a blank
    # screen. `else if` is avoided on purpose -- one flat `if` per mode is the
    # same code whatever modes a provider names.
    dispatch = "\n".join(
        f'if (global.mx_mode == "{mode}") {{ global.mx_step = {first}; '
        f"global.mx_end = {end}; }}"
        for mode, (first, end) in slices.items() if mode != "boot")

    name = PROVIDER["displayName"]
    return TYPING.substitute(
        NAME=name, RULE="-" * max(1, 35 - len(name)), CLI=CLI, FONT=font,
        R=DIALOG_COLOUR[0], G=DIALOG_COLOUR[1], B=DIALOG_COLOUR[2],
        GLOW_ALPHA=LINE_GLOW_OPACITY,
        TEXT_X=TEXT_X, TEXT_Y=TEXT_Y, TEXT_WIDTH=TEXT_WIDTH,
        WIDEST_CELLS=metrics["WIDEST_CELLS"], LINE_ASPECT=metrics["LINE_ASPECT"],
        LINE_LOAD="\n".join(load), TABLE="\n".join(table),
        BOOT_FIRST=slices["boot"][0], BOOT_END=slices["boot"][1],
        GATE=boot_gate, DISPATCH=dispatch or "# (this provider names no exit lines)")


# The four cells of the progress readout. The TABLES and the SPRITES are
# deliberately on different prefixes -- mx_pd_* against mx_pct_* -- because a
# global holding a number and an object holding sprites cannot share a name:
# the second assignment goes to the number, silently does nothing, and the
# sprite draws nothing with no error anywhere. It cost an hour once already.
PCT_NAMES = ("a", "b", "c", "d")


def dialog_block(metrics):
    rows = percent_cells()
    table = "\n".join(
        " ".join(f"global.mx_pd_{PCT_NAMES[cell]}[{percent}] = {index};"
                 for cell, index in enumerate(row))
        for percent, row in enumerate(rows))

    offset = BAR_CELLS + BAR_GAP_CELLS
    sprites = "\n".join(
        f"mx_pct_{n}.sprite = Sprite();\n"
        f"mx_pct_{n}.sprite.SetPosition(global.mx_row_x + "
        f"Math.Int(({offset + i}) * global.mx_cell), global.mx_in_y, 10001);\n"
        f"mx_pct_{n}.sprite.SetOpacity(0);"
        for i, n in enumerate(PCT_NAMES))

    show = ("  if (on == 0) {\n"
            + "".join(f"    mx_pct_{n}.sprite.SetOpacity(0);\n" for n in PCT_NAMES)
            + "  } else {\n"
            + "".join(f"    mx_pct_{n}.sprite.SetOpacity(1);\n" for n in PCT_NAMES)
            + "  }")

    paint = "\n".join(
        f"  mx_pct_{n}.sprite.SetImage(mx_digits.scaled.Crop("
        f"Math.Int(global.mx_pd_{n}[percent] * global.mx_cell), 0, "
        f"Math.Int(global.mx_cell), global.mx_in_h));"
        for n in PCT_NAMES)

    name = PROVIDER["displayName"]
    return DIALOG.substitute(
        NAME=name, RULE="-" * max(1, 28 - len(name)),
        BOX_WIDTH=BOX_WIDTH, BOX_ASPECT=metrics["BOX_ASPECT"],
        BOX_CELL_FRAC=metrics["BOX_CELL_FRAC"],
        BOX_PITCH_FRAC=metrics["BOX_PITCH_FRAC"],
        BOX_PAD_FRAC=metrics["BOX_PAD_FRAC"],
        BOX_ROW_FRAC=metrics["BOX_ROW_FRAC"],
        CELL_ASPECT=metrics["CELL_ASPECT"],
        DENIED_HOLD=DENIED_HOLD, GRANTED_HOLD=GRANTED_HOLD,
        KEY_CELLS=KEY_CELLS, BAR_CELLS=BAR_CELLS,
        ROW_CELLS=max(KEY_CELLS, BAR_CELLS + BAR_GAP_CELLS + PCT_CELLS),
        ATLAS_CELLS=len(ATLAS), TRACK_ALPHA=TRACK_ALPHA,
        PROMPT_WIDTH=PROMPT_WIDTH,
        PROMPT_PROBE=literal("Please enter passphrase for disk nvme0n1p2 (cryptroot):"),
        CAPS_TEXT=literal("[ CAPS LOCK ]"),
        PCT_TABLE=table, PCT_SPRITES=sprites, PCT_SHOW=show, PCT_PAINT=paint)


def splash_assets(target, font_path, line_hex, panel_path):
    """Everything the splash draws, baked to PNG here rather than typeset there.

    At boot there is no fc-match, so `label-freetype` ignores any font family
    asked for by name and renders everything in the one TTF the mkinitcpio hook
    put in the initramfs. A theme therefore cannot choose a typeface through
    Image.Text -- it can only choose one through pixels. So the typed lines,
    the passphrase field, the progress track, its digits and the panel around
    them
    all arrive as pictures, and the only text left at boot is the caps label,
    which is the system's own word rather than ours.

    It buys two more things. Typing costs no rendering at all -- N characters is
    one Crop of a picture that already exists -- and every element is scaled to
    a whole number of ONE cell, so the mask, the blocks and the digits land on
    a single grid instead of three that nearly agree.

    Returns the metrics the two templates need, all of them RATIOS. Not one
    pixel count crosses from this machine to the one that boots.
    """
    if not shutil.which("magick"):
        die("ImageMagick is not installed, so the splash cannot be generated.\n"
            "  Install it (`omarchy pkg add imagemagick`) and run this again.")
    if not Path(font_path).is_file():
        die(f"the splash's font is missing: {font_path}\n"
            f"  It ships with the theme, in {FONT_FILE}. Re-install the theme.")
    if not Path(panel_path).is_file():
        die(f"the panel's font is missing: {panel_path}\n"
            f"  It ships with the theme, in {PANEL_FONT_FILE}. "
            f"Re-install the theme.")

    size = 120                      # generous: everything is only scaled DOWN

    # Air between the digit glyphs, the drawn track segments, and the mask's
    # own dashes (which share their grid but are drawn, not typeset: the
    # film's passphrase field answers with `-`, and no glyph hunt is worth
    # what one rectangle draws exactly).
    # `kerning` has a hard ceiling: the mask row must not outgrow the
    # panel's interior, i.e. KEY_CELLS*(pitch+kerning) <= BOX_CELLS*pitch, which
    # at this font's own measured pitch works out to roughly kerning <= 0.24 *
    # pitch (~0.12 * size). 0.08 reads clearly separated; the fit guard after
    # `pitch` is what says if that still fits the interior. (0.10 was tuned
    # against a wider face; on the panel's narrower pixel face it eats the
    # whole budget -- the guard below died saying exactly that.)
    kerning = int(size * 0.08)

    def render(text, colour, out, face=None, kerning=0):
        subprocess.run(
            ["magick", "-background", "none", "-fill", colour,
             *(["-kerning", str(kerning)] if kerning else []),
             "-font", str(face or font_path), "-pointsize", str(size),
             f"label:{text}",
             "-background", "none", "-flatten", "-strip", str(out)], check=True)

    def measure(path):
        out = subprocess.run(["identify", "-format", "%w %h", str(path)],
                             capture_output=True, text=True, check=True).stdout
        return tuple(int(n) for n in out.split())

    def ink(path):
        """How much of the image the glyphs actually cover, 0..1."""
        return float(subprocess.run(
            ["magick", str(path), "-alpha", "extract", "-format", "%[fx:mean]",
             "info:"], capture_output=True, text=True, check=True).stdout)

    # --- the typed lines, for every mode ------------------------------------
    # One picture per line per mode, all at the same point size in the same
    # face, so a single cell describes the lot. The mode is in the FILENAME
    # rather than in a subdirectory: Plymouth's ImageDir is one flat folder.
    line_cells, units, heights, first_height = {}, [], set(), None
    for mode, lines in MODE_LINES.items():
        if not lines:
            die(f"the {mode!r} mode in provider.json names no lines. Remove the "
                f"key to fall back to the boot lines,\n  or give it something to "
                f"type.")
        line_cells[mode] = [len(line) for line in lines]
        for index, line in enumerate(lines):
            render(line, f"#{line_hex}", target / f"line-{mode}-{index}.png")
            subprocess.run(
                ["magick", str(target / f"line-{mode}-{index}.png"),
                 "-blur", LINE_GLOW_BLUR,
                 "-strip", str(target / f"lineglow-{mode}-{index}.png")],
                check=True)
        sizes = [measure(target / f"line-{mode}-{index}.png")
                 for index in range(len(lines))]
        units += [w / c for (w, _), c in zip(sizes, line_cells[mode])]
        heights |= {h for _, h in sizes}
        if first_height is None:
            first_height = sizes[0][1]

    # Is the face really monospace? The whole typewriter rests on it: a crop of
    # N cells is only the first N characters if every character is one cell.
    # Asked of the PICTURES, per line, because that is what will be cropped --
    # and across every mode, because they all share one cell.
    if max(units) - min(units) > 1:
        die(f"the splash's font ({font_path}) is not monospace: its cell "
            f"measures between {min(units):.1f} and {max(units):.1f} px across "
            f"the typed lines,\n  so a half-typed line would be cropped mid-glyph.")
    if len(heights) != 1:
        die(f"the typed lines came out {sorted(heights)} px tall. They are drawn "
            f"by one sprite at one height,\n  so they have to agree.")
    line_cell = sum(units) / len(units)
    line_height = first_height

    # Does the face actually HAVE every character these lines are spelt with?
    #
    # This is the missing-glyph trap again -- freetype draws nothing at all for
    # one, no box, no warning -- but a line is not a mask: a whole line inks
    # plenty even with a character missing from the middle of it, so the mask's
    # ink test would pass and the splash would come out spelt wrong. An accent
    # is the realistic way to hit it (`Déjà vu.`), and a face that has `e` says
    # nothing about whether it has `é`.
    #
    # Rendered as ONE strip and measured per cell, because the face is monospace
    # by the assertion above: one magick call for the whole alphabet in use.
    alphabet = "".join(sorted({c for lines in MODE_LINES.values()
                               for line in lines for c in line if c != " "}))
    probe = target / ".alphabet.png"
    render(alphabet, "#FFFFFF", probe)
    width, height = measure(probe)
    tile = width / len(alphabet)
    means = subprocess.run(
        ["magick", str(probe), "-alpha", "extract",
         "-crop", f"{round(tile)}x{height}", "+repage",
         "-format", "%[fx:mean] ", "info:"],
        capture_output=True, text=True, check=True).stdout.split()
    blank = [c for c, mean in zip(alphabet, means) if float(mean) < 0.005]
    probe.unlink(missing_ok=True)
    if blank:
        die(f"{font_path} has no glyph for {' '.join(repr(c) for c in blank)}.\n"
            f"  freetype draws a missing glyph as BLANK rather than as a box, so "
            f"the line would simply\n  come out with holes in it and nothing "
            f"anywhere would say why. Respell it, or ship a face that has them.")

    # And does every line fit on the screen at the boot's cell? The cell is
    # fixed by the longest PRE line so that no mode -- and not even the
    # post-unlock tail -- changes the type size (see the template), which
    # means a longer line elsewhere does not shrink anything -- it runs off
    # the right-hand edge instead, silently.
    widest = max(line_cells["boot"][:PRE_COUNT])
    for mode, cells in line_cells.items():
        overrun = TEXT_X + max(cells) / widest * TEXT_WIDTH
        if overrun > 0.97:
            longest = max(MODE_LINES[mode], key=len)
            die(f"the {mode!r} line {longest!r} is {max(cells)} characters, "
                f"which at the boot's type size\n  reaches {overrun:.0%} across "
                f"the screen and runs off the edge. Keep it to "
                f"{int((0.97 - TEXT_X) / TEXT_WIDTH * widest)} characters.")

    # --- what goes inside the panel -----------------------------------------
    # The digits are typeset in the PANEL's face -- the pixel face of the
    # film's dialogs, not the serif of the typed lines. Same reason as the
    # captions below: fine stems do not survive the panel's on-screen size.
    # The track stays DRAWN: no pixel face has a full block either. It is
    # drawn on the digits' own measured cell, which keeps both on one grid
    # by construction rather than by a guard comparing two renders.
    render(ATLAS, f"#{DIALOG_HEX}", target / "digits.png", panel_path,
           kerning=kerning)
    # The panel's face gets the same two guards the lines' face got above.
    # Monospace first: the readout crops cells out of this strip, so every
    # glyph but the space must be one identical cell (the space's advance was
    # measured at selection time -- uniform 400/1000 em with the rest).
    widths = []
    for ch in ATLAS:
        if ch == " ":
            continue
        probe_ch = target / ".panelch.png"
        render(ch, "#FFFFFF", probe_ch, panel_path)
        widths.append(measure(probe_ch)[0])
        probe_ch.unlink(missing_ok=True)
    if max(widths) - min(widths) > 1:
        die(f"the panel's font ({panel_path}) is not monospace: its digits "
            f"measure between {min(widths)} and {max(widths)} px.\n"
            f"  The readout crops cells out of one strip, so they have to agree.")
    # ...and no missing glyphs in anything the band can ever say.
    captions = (BOX_TITLE, PROGRESS_TITLE, GRANTED_TEXT, DENIED_TEXT)
    alphabet = "".join(sorted({c for cap in captions for c in cap if c != " "}))
    probe = target / ".panel-alphabet.png"
    render(alphabet, "#FFFFFF", probe, panel_path)
    width, height = measure(probe)
    tile = width / len(alphabet)
    means = subprocess.run(
        ["magick", str(probe), "-alpha", "extract",
         "-crop", f"{round(tile)}x{height}", "+repage",
         "-format", "%[fx:mean] ", "info:"],
        capture_output=True, text=True, check=True).stdout.split()
    blank = [c for c, mean in zip(alphabet, means) if float(mean) < 0.005]
    probe.unlink(missing_ok=True)
    if blank:
        die(f"{panel_path} has no glyph for {' '.join(repr(c) for c in blank)}.\n"
            f"  freetype draws a missing glyph as BLANK rather than as a box, so "
            f"a caption would come\n  out with holes in it and nothing anywhere "
            f"would say why. Respell it, or ship a face that has them.")
    digit_w, row_height = measure(target / "digits.png")
    cell = (digit_w + kerning) / len(ATLAS)
    # `cell` above is INFLATED by kerning -- correct for BOX_CELL_FRAC (which
    # decides how much of the panel's fixed on-screen width each glyph gets at
    # boot), but wrong for sizing the panel itself: box_w below is DEFINED as a
    # multiple of whatever cell feeds it, so the kerned cell would silently
    # shrink CELL_ASPECT and BOX_ASPECT and flatten the whole panel as a side
    # effect of a change that was only supposed to touch spacing. `pitch` is
    # the unkerned reference -- what `cell` would have measured without the
    # air -- and is what everything that sizes the box uses instead.
    pitch = cell - kerning

    bar_w = int(round(BAR_CELLS * cell))
    bars = " ".join(
        f"rectangle {round(i * cell)},{0} {round(i * cell + pitch)},{row_height}"
        for i in range(BAR_CELLS))
    subprocess.run(["magick", "-size", f"{bar_w}x{row_height}", "xc:none",
                    "-fill", f"#{DIALOG_HEX}", "-draw", bars, "-strip",
                    str(target / "bar.png")], check=True)

    # Does the widest row (mask, or track+gap+digits, whichever needs more
    # cells) actually fit the interior once kerning's air is added back in?
    # BOX_CELLS is the budget; a row that needs more of it than it has runs
    # past the panel's own frame -- "27%" doing exactly that on real hardware,
    # because this was never checked, is why this guard exists now.
    widest_row = max(KEY_CELLS, BAR_CELLS + BAR_GAP_CELLS + PCT_CELLS)
    if widest_row * cell > BOX_CELLS * pitch:
        die(f"the widest row on the panel's grid is {widest_row} cells, which "
            f"at this kerning needs {widest_row * cell:.0f}px -- more than "
            f"the {BOX_CELLS}-cell interior's {BOX_CELLS * pitch:.0f}px.\n"
            f"  Shrink `kerning`, or free up cells: BAR_CELLS + "
            f"BAR_GAP_CELLS + PCT_CELLS and KEY_CELLS both have to fit "
            f"BOX_CELLS.")

    # One height for the row, full stop: the track was drawn at the digits'
    # own height, so there is nothing to pad and no second line box to agree
    # with the first. The mask below shares it too.

    block_ink = ink(target / "bar.png")

    # The typed dashes: KEY_CELLS short horizontal marks, DRAWN on this same
    # `cell`/`row_height` grid rather than typeset -- the way the film's own
    # passphrase field answers keystrokes, a row of `-`, not a row of dots.
    # One magick call, one `rectangle` primitive per dash, each centred in its
    # own cell. The dialog shows nothing until the first keystroke; the dashes
    # are only ever cropped out of this image a few cells at a time.
    key_w = int(round(KEY_CELLS * cell))
    dash_w = int(round(cell * 0.55))
    dash_h = max(4, int(round(row_height * 0.14)))
    dashes = " ".join(
        f"rectangle {i * cell + (cell - dash_w) / 2},{(row_height - dash_h) / 2} "
        f"{i * cell + (cell + dash_w) / 2},{(row_height + dash_h) / 2}"
        for i in range(KEY_CELLS))
    subprocess.run(["magick", "-size", f"{key_w}x{int(row_height)}", "xc:none",
                    "-fill", f"#{DIALOG_HEX}", "-draw", dashes, "-strip",
                    str(target / "keydots.png")], check=True)

    # Are the dashes actually visible -- and still dashes? Ask the PICTURE,
    # the same way every other guard in this function does: measure how much
    # of its cell it inks, against a full block.
    #
    # TOO LITTLE, and the dash drew nothing (or next to it) -- a
    # passphrase prompt that does not react as you type, indistinguishable from
    # a dead keyboard on an encrypted disk at 7am.
    #
    # TOO MUCH, and the dashes touch or fill their cell, which puts the row of
    # solid marks back and undoes the entire point of drawing a mask rather
    # than typesetting one.
    dash_ink = ink(target / "keydots.png") * KEY_CELLS / BAR_CELLS
    if block_ink > 0:
        share = dash_ink / block_ink
        if share < 0.01:
            die(f"the mask dash draws next to nothing "
                f"({share:.0%} of a full block's ink).\n"
                f"  A passphrase prompt that does not react as you type is "
                f"indistinguishable from a dead\n  keyboard. Grow the dash.")
        if share > 0.6:
            die(f"the mask dash inks {share:.0%} of a full "
                f"block.\n  A row of that reads as a progress bar rather than "
                f"as typed characters, which is the\n  one thing this design "
                f"exists to avoid. Shrink the dash.")

    # The placeholder row is gone -- the dialog shows nothing until the first
    # keystroke -- so a `keyline.png` left behind by an older derive must not
    # linger in the staged theme (stage() overlays, it never wipes).
    (target / "keyline.png").unlink(missing_ok=True)

    # --- the panel ----------------------------------------------------------
    interior = BOX_CELLS * pitch
    pad = pitch                     # a cell of air either side of the content
    box_w = int(interior + pad * 2)
    # The frame's own width, in bake pixels. 0.05: the reference's frame
    # profiles at ~4-5 px true on a 922 px panel once the CRT bloom is
    # discounted, and 5 px bakes to 3.4 -- visibly thinner side by side.
    # 6 px bakes to ~4.1 there and ~2.6 at 1080p: the same thin rule, with
    # enough ink to read as a rule rather than a suggestion.
    stroke = max(2, int(size * 0.05))
    # The corner widgets, and the band's own proportions -- both MEASURED off
    # the reference rather than guessed. ... (history in git.)
    #
    # Third pass, against the `enter password` frame rather than the blurrier
    # RTF CONTROL close-ups: its squares profile at ~46 px on a 922 px panel
    # with the band at ~100, i.e. less than half the band's height -- the
    # close-ups read bigger through blur and perspective. 0.56 of size lands
    # 67 px bake, 46 on screen. Same for the zoom's height; its WIDTH stays
    # where it was (2.7 now, same ~180 px bake the reference profiles),
    # because the reference's zoom is wide AND short, not a scaled square.
    block = int(size * 0.56)        # the corner widgets' height

    # The title band. FILLED, the way an old window manager's title bar is --
    # not a rule with a caption-shaped hole knocked in it, which is what this
    # drew before and reads as a terminal's plain divider rather than a
    # window. Sized to the corner widgets, the tallest thing that sits in it,
    # with air above and below; the caption is centred in whatever that
    # leaves.
    band_pad = max(stroke * 2, int(size * 0.21))
    band_h = block + band_pad * 2
    band_bottom = stroke + band_h   # the divider between band and content

    # The panel is sized to its CONTENT, not to the point size: a fixed multiple
    # of `size` gave a box with the mask row stranded in the top third and
    # a hand's width of nothing under it. 2.98, measured off the reference:
    # its panel profiles at 2.78:1 wide, and with the band below (which the
    # smaller widgets shortened) that lands the box on the same aspect.
    content_h = int(row_height * 2.98)
    box_h = band_bottom + content_h

    # ...and the row sits where the reference puts it: its ink starts 39%
    # down the free space, not dead centre. `label:` returns a full line box
    # with room for ascenders and descenders, and the glyph inks only part of
    # it -- so placing the box leaves the only thing anyone can see wherever
    # the box says, which the reference overrules: its dashes profile at 39%
    # of the body, sitting high the way a text line does. Measured off the
    # track, because blocks fill their cell and are therefore the honest
    # extent of the row; the mask shares a baseline with them, so it lands
    # where it should.
    trimmed = subprocess.run(["magick", str(target / "bar.png"), "-format", "%@",
                              "info:"], capture_output=True, text=True,
                              check=True).stdout
    ink_h, ink_y = (int(n) for n in re.match(
        r"\d+x(\d+)\+\d+\+(\d+)", trimmed).groups())
    content_y = band_bottom + int((content_h - ink_h) * 0.39) - ink_y

    corner_y0 = stroke + band_pad
    corner_y1 = corner_y0 + block
    zoom_w = int(block * 2.7)       # the right widget: wide and short, as
                                    # profiled -- same ~180 px bake as before

    for name, caption in (("box-key.png", BOX_TITLE),
                          ("box-bar.png", PROGRESS_TITLE),
                          ("box-granted.png", GRANTED_TEXT),
                          ("box-denied.png", DENIED_TEXT)):
        # Dark on the band, not the panel's usual light-on-dark -- the band
        # is what inverts, the way the reference's title bar does. Tracked
        # wide, the way the reference sets it: its caption spans three fifths
        # of the panel, airy, while untracked pixels huddle at two. 0.50 of a
        # cell between glyphs lands the span now the band is shallower (the
        # height sizing below shrank the caption with it); the clamp below
        # keeps the longest caption off the corner widgets either way.
        render(caption, f"#{BAND_INK_HEX}", target / ".caption.png",
               panel_path, kerning=int(round(cell * 0.50)))
        # Sized to the BAND's height, not to a fraction of its own natural
        # width: the old `* 62 // 100` scaled the caption against itself, so
        # it stayed the same small size while the band grew around it over
        # two passes of this function. 0.75 of band_h leaves the padding the
        # corner widgets get too, and reads close to the reference's own
        # caption, which very nearly fills the band top to bottom.
        caption_w, natural_h = measure(target / ".caption.png")
        caption_w = int(caption_w * (band_h * 0.75) / natural_h)
        # ...and never wider than the band's usable span: the free run between
        # the left widgets' right edge (pad + two blocks + a stroke) and the
        # zoom widget's left edge (box_w - pad - zoom_w), less two strokes of
        # breathing room a side. The old formula subtracted one block per side
        # and let a tracked caption run under both widgets -- photographed
        # touching them side by side with the reference.
        free_left = pad + 2 * block + stroke + 2 * stroke
        free_right = box_w - pad - zoom_w - 2 * stroke
        caption_max = free_right - free_left
        if caption_w > caption_max:
            caption_w = caption_max
        subprocess.run(["magick", str(target / ".caption.png"), "-resize",
                        f"{caption_w}x", "-strip", str(target / ".caption.png")],
                       check=True)
        caption_h = measure(target / ".caption.png")[1]
        # Centred in the FREE span, not in the box: the box's centre sits left
        # of the free span's (two squares plus a gap outweigh the zoom), so
        # centring in the box parks the caption against the left widgets.
        left = (free_left + free_right - caption_w) // 2
        bottom, right = box_h - stroke, box_w - stroke
        subprocess.run([
            "magick", "-size", f"{box_w}x{box_h}", "xc:none",
            # The band, filled, full width, top edge to the divider.
            "-fill", f"#{DIALOG_HEX}", "-stroke", "none",
            "-draw", f"rectangle {stroke},{stroke} {right},{band_bottom}",
            # The frame: one rectangle for the whole panel, plus the divider
            # under the band. `-fill none` is deliberate here -- an earlier
            # version of this box tried to knock a hole in a filled rectangle
            # with `-compose clear`, which silently does nothing: `-draw`
            # takes its colour from `-fill`, and `-fill none` means "do not
            # fill" rather than "erase". There is no hole to knock any more,
            # but the frame still has to stay unfilled or it would paint over
            # the band and the content beneath it.
            "-fill", "none", "-stroke", f"#{DIALOG_HEX}", "-strokewidth", str(stroke),
            "-draw", f"rectangle {stroke},{stroke} {right},{bottom}",
            "-draw", f"line {stroke},{band_bottom} {right},{band_bottom}",
            # The corner widgets: hollow outlines sitting inside the band, its
            # own fill showing through the middle -- not the solid squares
            # this drew before, which is right on a bare rule but reads as a
            # patch on a filled one. 3 px floor, not 1: on the 0.30 panel a
            # 1 px bake is 0.46 px on a 3072x1920 screen, i.e. gone, while 3 px
            # is ~1.4 px -- the same hairline the eye expects, with enough ink
            # to survive the downscale. Same shapes, same proportions.
            "-strokewidth", str(max(3, stroke // 2)), "-stroke", f"#{BAND_INK_HEX}",
            "-draw", f"rectangle {pad},{corner_y0} {pad + block},{corner_y1}",
            "-draw", f"rectangle {pad + block + stroke},{corner_y0} "
                     f"{pad + block * 2 + stroke},{corner_y1}",
            "-draw", f"rectangle {box_w - pad - zoom_w},{corner_y0} "
                     f"{box_w - pad},{corner_y1}",
            "-strip", str(target / name)], check=True)
        subprocess.run([
            "magick", str(target / name), str(target / ".caption.png"),
            "-geometry", f"+{left}+{stroke + (band_h - caption_h) // 2}",
            "-composite", "-strip", str(target / name)], check=True)
    (target / ".caption.png").unlink(missing_ok=True)

    return {
        # The boot's pre lines set the type size for every mode; see the template.
        "WIDEST_CELLS": max(line_cells["boot"][:PRE_COUNT]),
        "LINE_ASPECT": round(line_height / line_cell, 4),
        "LINE_CELLS": line_cells,
        "BOX_ASPECT": round(box_h / box_w, 4),
        # The kerned `cell`, deliberately, not `pitch` -- this is the one export
        # meant to carry the extra air forward to boot time. See the `pitch`
        # comment above for why everything else here uses `pitch` instead.
        "BOX_CELL_FRAC": round(cell / box_w, 6),
        # The row height's own fraction, of the box HEIGHT, never the width:
        # the panel image is clamped vertically at boot while its width is
        # not, so a width-based row would drift past the baked band when the
        # clamp fires. See the mx_in_y/mx_in_h comment in the template.
        # Pitch, never the kerned cell -- see that same comment for what
        # kerning does stacked vertically.
        "BOX_PITCH_FRAC": round(pitch / box_h, 6),
        "BOX_PAD_FRAC": round(pad / box_w, 6),
        "BOX_ROW_FRAC": round(content_y / box_h, 6),
        "CELL_ASPECT": round(row_height / pitch, 4),
    }


def patch(text, font, metrics):
    # 1. The logo stops being visible but is still loaded: its box places the
    #    password dialog.
    anchor = "logo.sprite.SetOpacity(1);"
    if text.count(anchor) != 1:
        die(f"expected exactly one `{anchor}` in omarchy.script, found "
            f"{text.count(anchor)}. Omarchy's splash has changed: leaving it alone.")
    text = text.replace(
        anchor,
        "logo.sprite.SetOpacity(0);  # the line is typed by mx_tick(), below\n"
        + typing_block(font, metrics))

    # 2. Hook the typing onto the 50 fps refresh that already exists.
    anchor = "fun refresh_callback() {"
    if text.count(anchor) != 1:
        die("cannot find refresh_callback() in omarchy.script: leaving it alone.")
    text = text.replace(anchor, anchor + "\n  mx_tick();")

    # 3. Every progress update, real or faked, also drives the readout.
    anchor = "fun update_progress_bar(progress) {"
    if text.count(anchor) != 1:
        die("cannot find update_progress_bar() in omarchy.script: leaving it alone.")
    text = text.replace(anchor, anchor + "\n  mx_progress(progress);")

    # 4. Ours must be the LAST word on what a password dialog looks like, and
    #    that only holds if Omarchy still registers its own where we think.
    for anchor in ("Plymouth.SetDisplayPasswordFunction(display_password_callback);",
                   "fun display_normal_callback() {"):
        if text.count(anchor) != 1:
            die(f"expected exactly one `{anchor}` in omarchy.script. Its dialog "
                f"has changed shape: leaving it alone rather than half-overriding it.")

    # Appended, not spliced: there is no anchor to get wrong, and by the end of
    # the file `entry` exists to hang the dialog off.
    return text + dialog_block(metrics)


def stage(target, colours, theme_dir):
    background, foreground, accent, logo = colours
    if not (SOURCE / "omarchy.script").is_file():
        die(f"cannot find Omarchy's Plymouth at {SOURCE}")
    if not Path(logo).is_file():
        die(f"cannot find the theme's logo: {logo}")

    for f in SOURCE.iterdir():
        if f.is_file():
            shutil.copy2(f, target / f.name)
    shutil.copy2(logo, target / "logo.png")

    # The same asset re-tinting omarchy-plymouth-set does. Nothing we draw uses
    # these, but Omarchy's script still loads them, and if our override ever
    # failed to take, its dialog should at least come up in the right colour.
    for asset in ("bullet.png", "entry.png", "lock.png", "progress_bar.png"):
        path = target / asset
        if path.is_file():
            subprocess.run(["magick", str(path), "-channel", "RGB",
                            "+level-colors", f"#{foreground},#{foreground}", str(path)],
                           check=True)

    # Two different fonts, and the difference is the point.
    #
    # `font` is a FAMILY, and all it does is decide which single TTF the
    # mkinitcpio hook copies into the initramfs -- which is what the disk's own
    # prompt and the caps label come out in, and what stops plymouthd
    # segfaulting when it can resolve nothing at all.
    #
    # `face` is a FILE, out of the theme, and it is what the splash is actually
    # drawn in: every picture below is baked from it here, because at boot a
    # font asked for by name is ignored.
    font = available_font()
    face = theme_dir / FONT_FILE
    panel = theme_dir / PANEL_FONT_FILE
    metrics = splash_assets(target, face, COLOUR_HEX or accent, panel)

    r, g, b = (int(background[i:i + 2], 16) / 255 for i in (0, 2, 4))
    script = (target / "omarchy.script").read_text()
    script = re.sub(r"^Window\.SetBackgroundTopColor.*$",
                    f"Window.SetBackgroundTopColor({r:.3f}, {g:.3f}, {b:.3f});",
                    script, count=1, flags=re.M)
    script = re.sub(r"^Window\.SetBackgroundBottomColor.*$",
                    f"Window.SetBackgroundBottomColor({r:.3f}, {g:.3f}, {b:.3f});",
                    script, count=1, flags=re.M)
    script = patch(script, font, metrics)

    (target / f"{THEME}.script").write_text(script)
    (target / "omarchy.script").unlink()
    (target / "omarchy.plymouth").unlink(missing_ok=True)

    # The size on this line is only a floor: every size the splash actually
    # draws at is measured at run time. What matters here is the FAMILY, which
    # is what the mkinitcpio hook feeds to fc-match to decide which single TTF
    # gets copied into the initramfs.
    (target / f"{THEME}.plymouth").write_text(f"""[Plymouth Theme]
Name={PROVIDER["plymouth"]["name"]}
Description={PROVIDER["plymouth"]["description"]}

ModuleName=script

[script]
ImageDir={TARGET}
ScriptFile={TARGET}/{THEME}.script
ConsoleLogBackgroundColor=0x{background}
MonospaceFont={font} 16
Font={font} 16
""")
    return font, face


def theme_colour(key, theme_dir):
    for row in (theme_dir / "colors.toml").read_text().splitlines():
        if "=" in row:
            k, v = row.split("=", 1)
            if k.strip() == key:
                return v.strip().strip('"').lstrip("#")
    die(f"`{key}` is missing from colors.toml")


def ensure_user_font(theme_dir):
    """The face where derive-time fc-match and the preview can see it.

    stage() bakes from the FILE, so the splash never depends on this -- but
    available_font() (the CAPS LOCK label) and preview-plymouth.sh both
    resolve the FAMILY, and both go quiet to the wrong face when it misses.
    A file copied once into the user's fonts cannot miss afterwards.
    """
    src = theme_dir / FONT_FILE
    if not src.is_file():
        return  # splash_assets() below dies about this, with the path
    dest_dir = Path.home() / ".local/share/fonts"
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest = dest_dir / Path(FONT_FILE).name
    if not dest.is_file() or dest.read_bytes() != src.read_bytes():
        shutil.copy2(src, dest)
    if shutil.which("fc-cache"):
        subprocess.run(["fc-cache", "-f", str(dest_dir)],
                       check=False, capture_output=True)


def main():
    stage_only = "--stage-only" in sys.argv
    # The one entry point that used to escape the die() treatment below: with
    # the theme removed (omarchy theme remove) while boot is still on, this came
    # out as a raw CalledProcessError traceback -- the failure shape the rest of
    # this file is careful never to show, because it reads as a broken pack.
    try:
        theme_dir = Path(subprocess.run(["omarchy-theme-dir", SLUG],
                                        capture_output=True, text=True,
                                        check=True).stdout.strip())
    except (OSError, subprocess.CalledProcessError):
        die(f"cannot find the {SLUG} theme directory.\n"
            f"  Reinstall it, or take the piece back with: {CLI} boot off")
    if not (theme_dir / "colors.toml").is_file():
        die(f"{theme_dir} has no colors.toml -- it does not look like the "
            f"{SLUG} theme.\n"
            f"  Reinstall it, or take the piece back with: {CLI} boot off")

    colours = (theme_colour("background", theme_dir),
               theme_colour("foreground", theme_dir),
               theme_colour("green", theme_dir),
               theme_dir / "unlock.png")

    # Before anything resolves the family: the caps label, the preview and,
    # later, the mkinitcpio hook all go through fc-match, not through the file.
    ensure_user_font(theme_dir)

    staging = Path(tempfile.mkdtemp(prefix=f"{SLUG}-plymouth."))
    try:
        font, face = stage(staging, colours, theme_dir)

        if stage_only:
            # What a designer wants to know. Somebody who picks a card in
            # Style > Unlock does not, so an install prints none of it.
            for mode in MODE_LINES:
                steps, gate = storyboard(mode)
                seconds = sum(frames for _, _, frames in steps) / FPS
                print(f"  {THEME} [{mode}]: {len(steps)} steps, {seconds:.1f}s of "
                       f"typing, {len(MODE_LINES[mode])} lines"
                       + (f", gate at step {gate}" if gate is not None else ""))
            print(f"  drawn in {face.name}, baked to PNG; {font!r} only for the "
                  f"CAPS LOCK label")
            print(f"  every size measured at boot, none baked in")
            out = Path.home() / f".cache/{CLI}/plymouth"
            out.parent.mkdir(parents=True, exist_ok=True)
            shutil.rmtree(out, ignore_errors=True)
            shutil.copytree(staging, out)
            print(f"  staged at {out} (not installed)")
            print(f"  see it: tools/preview-plymouth.sh <scenario>")
            return

        # The five privileged steps. sudo may have nowhere to ask for a
        # password -- from a hook, from an agent, from an editor's shell -- or
        # the answer may simply be no. A Python traceback is a terrible way to
        # say "you did not authenticate": it reads as a broken pack rather than
        # an unauthorised one, and install.sh prints it in the middle of an
        # otherwise successful run.
        already_installed = TARGET.is_dir()
        try:
            subprocess.run(["sudo", "mkdir", "-p", str(TARGET)], check=True)
            subprocess.run(["sudo", "cp", "-a", "--no-preserve=mode,ownership",
                            f"{staging}/.", f"{TARGET}/"], check=True)
            # The copy overlays, it never wipes: a `keyline.png` from before
            # the placeholder row was dropped would sit here forever, and ride
            # along in every initramfs. The staged theme no longer carries it.
            subprocess.run(["sudo", "rm", "-f", str(TARGET / "keyline.png")],
                           check=True)
            # The text face, system-wide, BEFORE the initramfs is rebuilt: the
            # hook resolves `Font=` with fc-match as root, and a face it cannot
            # see comes out as the wrong font with nothing to say so.
            subprocess.run(["sudo", "mkdir", "-p", str(SYS_FONT_DIR)],
                           check=True)
            subprocess.run(["sudo", "cp", str(face), str(SYS_FONT_DIR) + "/"],
                           check=True)
            subprocess.run(["sudo", "fc-cache", "-f", str(SYS_FONT_DIR)],
                           check=True)
            subprocess.run(["sudo", "plymouth-set-default-theme", THEME], check=True)

            # The same rebuild, with the same log, as Omarchy's own
            # omarchy-plymouth-set: picking this card in Style > Unlock looks
            # the same as picking any other.
            if shutil.which("limine-mkinitcpio"):
                subprocess.run(["sudo", "limine-mkinitcpio"], check=True)
            else:
                subprocess.run(["sudo", "mkinitcpio", "-P"], check=True)
        except subprocess.CalledProcessError as failure:
            # Failing between the copy and the initramfs would leave a directory
            # that is not yet a theme. Only what THIS run created is taken back:
            # re-deriving over a splash that already worked must not delete it.
            if not already_installed:
                subprocess.run(["sudo", "-n", "rm", "-rf", str(TARGET)],
                               check=False, capture_output=True)
            die(f"`{' '.join(failure.cmd[:3])}` failed, so the boot splash was "
                f"not installed.\n"
                f"  Nothing was left half written, and the rest of the pack is "
                f"unaffected.\n"
                f"  This step writes outside your home directory and needs a "
                f"real terminal to ask\n"
                f"  for your password. From one, run: {CLI} boot on")
        # Nothing more to print. Omarchy's own publisher also ends with the
        # build log, and the floating terminal prints "Done!" after it.
    finally:
        shutil.rmtree(staging, ignore_errors=True)


if __name__ == "__main__":
    main()
