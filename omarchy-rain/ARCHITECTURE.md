# Omarchy Rain Architecture

## Purpose

`omarchy-rain` is a standalone terminal screensaver option.

It replaces Omarchy's random TTFX effect with one continuous Matrix rain
effect. It does not change the Matrix theme plugin, lock screen, or boot
splash.

This folder exists so a user can compare the native terminal effect with the
GPU effect in the main theme. Only one option should control the screensaver
at a time.

## Origin

This implementation comes from an earlier Matrix rain experiment in the
user's `omarchy_thinkpad` project. That version used Omarchy's original
terminal screensaver lifecycle, but selected TTFX Matrix rain without the
random effect cycle.

This version was recreated in this repository as a clean, portable layer. It
does not copy a frozen Omarchy script. `lib/derive-screensaver.py` reads the
installed command and changes one verified TTFX call.

The replacement is:

```text
--random-effect --no-eol --no-restore-cursor
```

to:

```text
--no-eol --no-restore-cursor matrix --rain-time 86400
```

The long rain duration prevents TTFX from changing to its text phase during a
normal screensaver session.

## Choose an implementation

| Requirement | Choose |
| --- | --- |
| Terminal-rendered rain, native TTFX motion, no overlay | `omarchy-rain` |
| One-second black lead-in, GPU rendering, Matrix theme composition | Main Matrix theme |
| Lock screen and screensaver use the same QML visual language | Main Matrix theme |
| Independent comparison with Omarchy's terminal screensaver | `omarchy-rain` |

The main theme plugin can cover the terminal window with GPU rain. Disable the
plugin before you evaluate this option. Remove `omarchy-rain` before you
evaluate the GPU option.

## Architecture

```text
Omarchy idle service
  -> omarchy-launch-screensaver
    -> terminal with class org.omarchy.screensaver
      -> omarchy-screensaver
        -> TTFX Matrix rain for 86400 seconds
```

Omarchy invokes `omarchy-screensaver` by name. The installer makes the
user-owned command resolve before Omarchy's packaged command.

Omarchy's Hyprland defaults put `$OMARCHY_PATH/bin` first during reload. The
installer therefore writes a marked block at the end of
`~/.config/hypr/autostart.lua`. That block puts `~/.local/bin` first again.

The installer also writes a UWSM environment file. It covers a fresh graphical
session. The Hyprland block covers later `hyprctl reload` calls.

## Ownership and safety

The installer owns only these paths:

```text
~/.local/share/omarchy-rain/
~/.local/bin/omarchy-screensaver
~/.config/uwsm/env.d/50-omarchy-rain-path.sh
~/.config/hypr/autostart.lua (one marked block)
```

The installer derives the command from `$OMARCHY_PATH/bin/omarchy-screensaver`.
It aborts if Omarchy changes the expected source line. It refuses to replace a
different `~/.local/bin/omarchy-screensaver` or UWSM PATH override.

The uninstaller removes only its symlink, environment file, share directory,
and marked Hyprland block. It never writes below `/usr/share/omarchy`.

## Coexistence with other customizations

Another screensaver customization can add its own command under
`~/.config/omarchy/bin`. BeforeLight is one known example. Its wrapper can use
an absolute path to the packaged Omarchy command.

The local PATH priority restores this variant for terminal windows created by
Omarchy. Do not edit another customization's files. If another customization
uses an absolute `omarchy-screensaver` path in its own launcher, this variant
cannot intercept it. Disable or remove that customization before comparison.

## Operation

Install or refresh after an Omarchy update:

```bash
./omarchy-rain/install.sh
hyprctl reload
```

Test the real idle path:

```bash
omarchy plugin disable io.github.tymurbogach.enter-the-matrix
omarchy restart shell
omarchy-launch-screensaver force
```

The display must show continuous rain. A key press or pointer movement must
close it. The `socat` broken-pipe message from the launcher is unrelated to
the selected visual effect.

Remove this option before use of the GPU variant:

```bash
./omarchy-rain/uninstall.sh
hyprctl reload
omarchy-matrix doctor
```

## Future maintenance

When Omarchy updates, run the installer again. If derivation fails, inspect
the installed `omarchy-screensaver` command and update the exact anchor in
`lib/derive-screensaver.py`.

Do not replace the derived script with a copy of an Omarchy release. Preserve
the installed focus, input, cursor, resize, and terminal behavior.

Test these conditions after a change:

- The installer changes only owned paths.
- `hyprctl reload` makes the local command win.
- The forced screensaver shows continuous rain.
- Input closes the screensaver.
- The uninstaller restores the original command path.
- `./tools/check.sh` passes from the repository root.
