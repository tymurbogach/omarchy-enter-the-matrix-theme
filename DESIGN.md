# DESIGN.md — why the pack is built this way

The [README](README.md) says what the pack does. This says why, and it is mostly
a record of ceilings found by reading Omarchy's source rather than guessing. If
you are changing the pack, read [CONTRIBUTING.md](CONTRIBUTING.md) first. It
carries the rules and the traps.

## The lock

A `WlSessionLock` is exclusive by protocol: nothing may draw inside its surface
but itself. So raining there means replacing the lock plugin, and there is no
way around that.

What is **not** done is publishing a frozen copy. That plugin carries the PAM
and fingerprint flows, and an old copy is the last one you want.
`lib/derive-lock.py` always starts from **your** Omarchy's `LockView.qml` and
applies one minimal change: it drops the blurred wallpaper and puts the rain
there. The other ~200 lines are yours. A `post-update.d` hook derives it again
after every `omarchy update`, so Omarchy's fixes keep arriving.

If the block to replace does not appear exactly once, the script **aborts and
tells you** rather than leaving things half done.

Try it without locking yourself out: `omarchy-shell lock preview`. To go back to
Omarchy's: `omarchy-matrix lock off`.

## The boot splash

Omarchy's splash is a script theme too (`omarchy.script`, `ModuleName=script`),
and what `omarchy plymouth set-by-theme` lets a theme change is three things:
background colour, text colour and **one still PNG**. No animation fits through
that door.

`lib/derive-plymouth.py` starts from your machine's `omarchy.script` and turns
it into Neo's monitor. Upper left, one line at a time, the screen clearing
between them, in the theme's own `green` -- taken from colors.toml rather than
repeated in provider.json, so the pack has one green rather than two that drift
apart:

```
Wake up, Neo...
```

Nothing blinks. There was a block cursor trailing each line once, and taking it
away is what makes the rest of this cheap -- with nothing after the text, the
first N characters of a line are exactly the first N cells of a picture of it,
so typing is a crop.

The way out gets its own lines. `Plymouth.GetMode()` reports what `plymouthd`
was started with, and it is already right at the top of the script -- not only
inside a callback, which is the one place `omarchy.script` asks it -- so the
whole storyboard is chosen before the first frame rather than swapped
mid-flight:

```
boot        Wake up, Neo...            /  The Matrix has you...
            Follow the white rabbit.   /  Knock, knock, Neo.

shutdown    Goodbye, Mr. Anderson.     /  Unplug him.

reboot      Déjà vu.                   /  They changed something.
```

The panel does not come to the exits. Nothing asks for a passphrase on the way
out, so there is no dialog and no progress readout — just the words on black.
That took a fix: `plymouthd` feeds boot progress in `--mode=shutdown` as well,
and the readout's fill turned *itself* on, so a shutdown used to show one lit
cell of the track floating on an empty screen with no panel behind it.

**There are two exits, not three.** `plymouth-halt.service`,
`plymouth-poweroff.service` and `plymouth-kexec.service` all run
`plymouthd --mode=shutdown`; only `plymouth-reboot.service` differs. A halt
cannot be told apart from a power off from inside the script, so there is no
`halt` entry in `provider.json` -- it would be configuration that never runs.

Two things follow from an exit being *short*. It lives until the machine stops,
which is a couple of seconds, so the exits type half again as fast, hold for
half as long, and start with no held black -- and even then, assume only the
**first** line is ever seen, which is why the first line of each is the payoff.
And the type size does not change: the cell every mode is drawn on comes from
the longest **boot** line, so a shorter exit line is not blown up to fill the
same width. `derive-plymouth.py` checks instead that no line of any mode runs
off the right-hand edge at that size.

Any mode the dispatch does not name -- `updates`, `firmware-upgrade`, whatever
Plymouth grows next -- falls through to the boot lines rather than to a blank
screen. Modes are slices of one flat step table, so that fallback is two
numbers rather than a branch.

And in the middle, where Omarchy puts its dialog, the film's framed panel: a
FILLED title band across its top, the way an old window manager's title bar
is rather than a rule with a caption-shaped hole in it, two hollow corner
widgets sitting inside that band, one dash per character typed -- centred as a
group in the row below, not anchored to the left edge, so a passphrase does
not end up stranded off to one side of a box wide enough for a much longer
one -- and `[ CAPS LOCK ]` underneath when it is on, which Omarchy's dialog
does not tell you. The disk's own prompt is not drawn above it any more:
once the band carries its own caption, saying "enter password" twice was the
panel repeating itself.

```
   ┌──[■][■]───────────── enter password ─────────────────[■■]──┐
   │                                                              │
   │                        - - - - - - -                        │
   │                                                              │
   └──────────────────────────────────────────────────────────────┘
```

(The top row is filled, caption in the panel's own dark ink on top of it --
ASCII cannot really draw that, only the shape of it.)

Once it is answered the boot's progress takes the same panel -- same frame, same
row, same grid, only the caption changes:

```
   ┌──[■][■]───────────────── booting ─────────────────────[■■]──┐
   │                                                              │
   │    ########------------                              42%    │
   │                                                              │
   └──────────────────────────────────────────────────────────────┘
```

One panel with two captions rather than a panel and then a bare bar: a boot that
cut from a framed dialog to a loose meter read as two unrelated widgets taking
turns, which is the same mistake, one level up, as the one below.

One track, drawn twice: the whole of it dimmed, and the part that is done,
opaque, on top. That matters more than it sounds. It was `[####........] 42%`
once, where the empty half was a dither pattern and the full half was solid ink
-- so an empty bar and a half-full one looked like two unrelated widgets, and
the passphrase, then drawn in blocks, looked like a third.

The boot messages are Omarchy's, untouched. It installs as a **separate** theme
at `/usr/share/plymouth/themes/omarchy-matrix/`, never overwriting its own:
going back is `omarchy plymouth reset`. The `post-update.d` hook derives it
again after every `omarchy update`.

Details that explain the design, each of them forced by something:

- **Everything whose shape matters is a PNG, baked at derive time.** In the
  initramfs there is no `fc-match`, and `label-freetype` resolves font families
  by shelling out to it -- so at boot a per-call font *family* is ignored and
  every `Image.Text` comes out in whatever single TTF the initramfs happens to
  hold. A theme cannot choose a typeface through text; it can only choose one
  through pixels. So the four lines, the passphrase field, the track, its digits
  and the panel are all pictures.
- **Which single TTF that is comes from `Font=` in the `.plymouth`.** The
  mkinitcpio hook resolves it with `fc-match` and copies it in as
  `/usr/share/fonts/Plymouth.ttf`, which is what `label-freetype` falls back to.
  So the family there is not decoration -- it is the only text face the boot has.
- **The face ships with the theme, as a file.** Naming a family would mean
  `fc-match` resolving it on the installing machine, and when `fc-match` misses
  it does not fail: it returns `monospace`, and the splash comes out in the
  wrong face with nothing to say so. See `fonts/`.
- **Nothing is a pixel count.** The lines are scaled to a cell taken from the
  window; the panel's interior is described in fractions of its own width; and
  what little text is left is measured at boot by rendering a probe and reading
  its width back. Plymouth draws at the panel's *native* resolution, so anything
  worked out at derive time from `hyprctl` is wrong the moment you dock.
- **The step table is generated in Python.** A step is two integers -- which
  line, how much of it -- so the script needs no `SubString` and no `Length`.
- **The face is asked whether it has every character, not just the mask.** A
  missing glyph draws *nothing* in freetype -- no box, no warning -- so
  `Déjà vu.` in a face without accents comes out with two holes in it and
  nothing anywhere says why. The deriver renders every character in use as one
  strip and measures the ink in each cell.
- **The colours are measured, not chosen.** The panel's ice blue was sampled off
  the frames themselves. The first guess was a mint green-cyan, and beside the
  real thing it was obviously the wrong colour: what matters is that blue sits
  above green. The lines are not sampled at all -- they take the theme's own
  accent, which is one fewer hex to keep in step. The shader's phosphor
  `#00FF41` was what they used first, and at this size on black it reads as
  glare rather than as a monitor.
- **`logo.png` is still loaded, just invisible.** Its box is what
  `omarchy.script` uses to place the dialog, and we do not want to move it.
- **Omarchy's password callback is not rewritten, it is out-registered.** Ours
  is registered after it, and the last registration wins. And if any generated
  PNG is ever missing, ours is not registered at all and Omarchy's own dialog --
  padlock, box and bullets -- comes up instead, whole. Verified by deleting one
  and photographing the result.

You do not have to reboot to see any of it. `tools/preview-plymouth.sh` runs the
real splash in a window, through Plymouth's own X11 renderer, inside a user
namespace that needs no `sudo` and cannot touch your actual boot -- down to
hiding `label-pango` and every font but the three the initramfs would have.

> **If your disk is encrypted**, Plymouth is also what asks for your passphrase.
> That is why the patch adds a callback rather than editing one, and why the
> pack falls back to Omarchy's dialog rather than to no dialog. If anything goes
> wrong: `omarchy plymouth reset` from a running system, or `plymouth.enable=0`
> on the kernel line from your boot loader.

## What is inside

| | |
|---|---|
| `colors.toml` | The palette. Semantic, not `color0..15`. Includes the Hyprland border colours, which go through the template. |
| `shell.{bar,menu,launcher,notifications}.toml` | Shell section overrides: they give the bar and the cards some relief, which otherwise all paint the same black. |
| `backgrounds/` | The carousel. `0-pills.jpg` is the default, so installing only the theme still gives you a wallpaper. `1-live-rain.png` is a still frame of the shader: thumbnail, marker and fallback in one — selecting it is what turns the desktop rain on, and the shader finds it by the `-live-` in its name. The rest are stills: seven from the film, three not. |
| `unlock.png`, `preview-unlock.png` | The static boot mark: what Omarchy's own Style › Unlock installs for this theme, and its card there. With the pack, the same card installs the animation instead, where `logo.png` goes invisible and the lines are typed. |
| `manifest.json`, `Service.qml`, `MatrixRain.qml`, `matrix.frag.qsb`, `glyphs.png` | The plugin. |
| *(not here)* | The bar widget — one icon, four switches, Repair and Uninstall — lives in its own repo, [omarchy-matrix-widget](https://github.com/tymurbogach/omarchy-matrix-widget), so it can be submitted to plugins.omarchy.org on its own. `install.sh` fetches it and caches it under `~/.local/share/omarchy-matrix/widget-src`; `provider.json`'s `widget.repo`/`widget.ref` say which repo and which ref. |
| `provider.json` | The only file that names this provider — slug, plugin ids, Plymouth theme, the lines typed at boot. Everything else is machinery. |
| `bin/` | `omarchy-matrix`, the one command on PATH (a link to the share dir). |
| `lib/` | The shared shell (`pack.sh`), the two derivers and `provider.py` — the machinery the CLI, `install.sh` and `uninstall.sh` run from the share dir. |
| `tools/` | Dev tools, never installed: `preview-plymouth.sh`, `capture-showcase.sh` and `generate-showcase.py` (the pictures in `docs/showcase/` and `preview.png`), `generate-brand.py`, `generate-backgrounds.py`, `generate-atlas.py` and the `matrix.frag` shader source. |
| `fonts/` | The face the boot splash is drawn in, shipped as a file rather than named as a dependency. See `fonts/README.md`. |

### status --json

The one document the widget reads, and the one definition of the ✓. Fields:

| Field | What it is |
|---|---|
| `schema` | The protocol version, currently 1. Readers take 1 and reject anything else, so either side can grow without silent misreads. |
| `name`, `slug` | The provider's display name and theme slug, from `provider.json`. |
| `version` | The version of the theme folder, from its `manifest.json`. Empty when the folder is gone. |
| `theme` | The current theme, from Omarchy's state directory. |
| `active` | Whether the pack is in effect: the current theme is ours. `boot` is exempt, since the splash belongs to the system. |
| `settings` | What was asked for, per piece, from the pack's own settings file. |
| `pieces` | What is happening now, per piece: asked for AND in effect AND applied (the live background selected, the plugin enabled, our lock in charge, our splash installed). |

### update --check --json

What the widget asks when its panel opens. It is apart from `status` because
it can reach GitHub, and `status` has to stay instant. The CLI keeps the
answer for six hours in `~/.cache/omarchy-matrix/update.json`, keyed on the
commit of the theme folder.

| Field | What it is |
|---|---|
| `schema` | 1, as for `status`. |
| `current` | The version of the theme folder. |
| `latest` | The version on GitHub. Empty when there is nothing to offer. |
| `available` | `true` only when the theme folder can fast-forward to a newer commit. No network, no git clone, or commits of your own all give `false`. |

`omarchy-matrix update` pulls with `--ff-only` from the repository URL written
out in the command, then runs `doctor` from the pulled theme. The URL is
literal on purpose: see the updates section of `bin/omarchy-matrix`.

### About the borders

The theme sets the border **colour** (`hyprland_active_border`, flat green) but
not its thickness or the rounding: `omarchy theme install` **rejects any `.lua`**
from a theme that came from git, because Lua runs code inside the compositor.
That is Omarchy's decision, not a bug. Borders keep the stock thickness.

If you want the thin frame, it belongs in your `~/.config/hypr/looknfeel.lua`:

```lua
hl.config({
  general = { border_size = 1 },
  decoration = {
    rounding = 2,
    shadow = { enabled = true, range = 14, color = "rgba(00FF4130)",
               color_inactive = "rgba(00000000)" },
  },
})
```

### The palette

There is no void black here, because the film never shows one: the pills
scene averages `#171716`, Neo's sleep `#0E170C`, Morpheus in warm ambers
(`#433C2D`, `#584B35`). Surfaces sit in that range with a faint warm-green
cast, and the green is the monitor's own -- yellow-leaning, the way the grade
pushes it -- with the ice-blue prompt untouched and red reserved for errors.

What sets it apart from any other green theme is that each ANSI slot sits on
a **different rung of luminance**, so in `nvim` or `bat` the syntactic roles
stay apart instead of blurring into one smear. Minimum contrast against the
background: 4.5.

The hue axis follows the rain rather than grass: yellow-leaning phosphor for
the hero, the grade's sickly midtones for yellow, the real world's steel for
blue, the ship's amber for brown. Saturation stays below the rain's own trail,
so the interface accompanies the wallpaper instead of competing with it.

And the accent is not the border. `#7BAE4E` marks what the eye should find;
window frames, selections and card edges run dimmer. A border delimits; it
does not need to shout.

| | | |
|---|---|---|
| `background` | `#131610` | the film's shadows, faintly warm-green |
| `foreground` | `#93B298` | sage, never phosphor · 7.9 |
| `accent` / `green` | `#7BAE4E` | monitor phosphor, yellow-leaning · 7.0 |
| `yellow` | `#A8BE5A` | the grade's sickly midtones · 8.9 |
| `cyan` | `#7CBCA0` | pale terminal · 8.3 |
| `magenta` | `#4CAF7E` | jade · 6.7 |
| `orange` | `#7BAE5A` | olive · 7.0 |
| `blue` | `#5B8CA8` | the real world's steel · 5.0 |
| `brown` | `#A07A45` | the ship's amber · 4.7 |
| `red` | `#E5484D` | signal red, lightened to read · 4.7 |
| `muted` | `#33482F` | |

Blue used to be a third green and red a pink: neither exists in the film.
The real red (`#C8102E`, pill and dress) sits at 3.3:1 and cannot carry text,
so the theme wears the closest rung that holds the floor -- and says so,
here, rather than pretending the hex came off a frame.

### Regenerating

```bash
./tools/generate-brand.py                # unlock, preview-unlock and preview
./tools/generate-atlas.py               # the shader's glyph atlas
./tools/generate-backgrounds.py --out /tmp/x.png --seed 42 --density 0.7

# recompile the shader (qsb is not on PATH; qt6-shadertools puts it here)
/usr/lib/qt6/bin/qsb --glsl 300es,330 --hlsl 50 --msl 12 \
    -o matrix.frag.qsb tools/matrix.frag
```

**The backgrounds are not regenerated.** `generate-backgrounds.py` requires
`--out` and writes nowhere by default, on purpose: every shipped background is
now either a still or `1-live-rain.png`, all of them committed, and an
argument-less run had one job left — to overwrite a file somebody had
deliberately removed. It stays because a fresh frame of the rain is still worth
being able to paint.

Those `qsb` targets are the ones the shipped `matrix.frag.qsb` was built with —
GLSL 300 es and 330, HLSL 50, MSL 12. Using different ones silently produces a
different set of shader variants.

Needs ImageMagick, `rsvg-convert`, Python 3, the Noto Sans CJK JP font and
`qt6-shadertools` for `qsb`.

## Working on the pack

`~/.config/omarchy/themes/enter-the-matrix` is what `omarchy theme install` puts
there and it gets regenerated, so editing in it loses the change. Keep a working
copy elsewhere:

```bash
git clone https://github.com/tymurbogach/omarchy-enter-the-matrix-theme ~/Projects/omarchy-enter-the-matrix
# edit, commit and push there, then:
cd ~/.config/omarchy/themes/enter-the-matrix && git pull && ./install.sh
```

That is a detour, but it is exactly the path anyone installing the pack takes,
so mistakes surface on your machine rather than on theirs.

Editing `Service.qml` can skip the detour by copying it straight into
`~/.config/omarchy/plugins/io.github.tymurbogach.enter-the-matrix/`, but **finish with `omarchy restart
shell`**: hot reloads can leave two instances alive, the old one still answering
IPC while the new one paints, and the symptom is maddening.
