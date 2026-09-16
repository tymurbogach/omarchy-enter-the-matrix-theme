# fonts/

`CourierPrime-Bold.ttf` — Courier Prime, the typewriter serif of Neo's
monitor in the film (`Wake up, Neo...`, `The Matrix has you...`).

It is here rather than named as a dependency because `derive-plymouth.py` bakes
the boot splash's text into PNGs at derive time, and derive time is on the
machine of whoever installs the pack. Naming a family instead would mean
`fc-match` resolving it there, and when `fc-match` misses it does not say so --
it hands back `monospace` and the splash comes out in the wrong face with
nothing to warn anyone. A file in the repo cannot miss.

Courier Prime is what the film's terminal lines are set in: a monospace serif
with slab terminals, not a pixel sans. Measured before choosing it -- its
cells agree to 0.3 px across the typed lines (the crop guard allows 1 px),
and it carries every character in use, accents included (`Déjà vu.`).
What it does not carry is `█`, so the progress track is drawn as rectangles
rather than typeset; see `splash_assets()`.

BOLD, not Regular: next to the film's own stills the Regular weight's strokes
read as thin and the letters as narrow, where the reference is a blocky,
compact typewriter face. Same upstream project, same metrics, so nothing
else about the guards above changed when the weight did.

Copied **unmodified**, which is what OFL 1.1 permits. `LICENSE.txt` is the
licence as shipped with it.

Upstream: Courier Prime by Alan Dague-Greene for Quote-Unquote Apps, via
Google Fonts (`ofl/courierprime`).

`VT323-Regular.ttf` — VT323, the chunky VGA-terminal pixel face of the
dialogs in the film (`enter password`, `RTF CONTROL`, `ACCESS GRANTED`).

The panel's own text (band captions, progress digits) is baked in this face,
not in Courier Prime: at the panel's on-screen size Courier's fine serifs
downscale to uneven stems, while chunky pixels survive. The typed boot lines
stay in Courier Prime — Neo's monitor and Trinity's dialog are different
screens in the film, and this pack keeps them different.

Measured before choosing it — single advance (400/1000 em) across the whole
alphabet in use, accents included, and the derive-time guards (`splash_assets`)
re-check both faces on every run. Copied **unmodified** under the same
`LICENSE.txt`.

Upstream: VT323 by Peter Hull for the VT323 Project, via Google Fonts
(`ofl/vt323`).
