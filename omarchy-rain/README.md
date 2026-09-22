# Omarchy Rain

This is the standalone terminal version of the Matrix screensaver.

It derives Omarchy's current `omarchy-screensaver` command and replaces its
random TTFX effect with continuous Matrix rain. `--rain-time 86400` keeps the
rain on screen and prevents the normal text resolution phase.

This variant does not use the QML rain plugin. It is useful when you want to
compare the native terminal effect with this theme's GPU rain.

Read [ARCHITECTURE.md](ARCHITECTURE.md) before changing this folder. It records
the origin, selection criteria, precedence rules, and maintenance contract.

## Install

Run this from the repository root:

```bash
./omarchy-rain/install.sh
```

The installer creates only these user-owned paths:

```text
~/.local/share/omarchy-rain/
~/.local/bin/omarchy-screensaver
~/.config/uwsm/env.d/50-omarchy-rain-path.sh
~/.config/hypr/autostart.lua (one marked PATH block)
```

It refuses to overwrite an existing custom `omarchy-screensaver` command or a
PATH override that it does not own. Run `hyprctl reload` after installation.
Omarchy puts its own bin directory first during a Hyprland reload. The marked
block restores the user command priority after that step.

Run the installer again after `omarchy update`. It derives the current Omarchy
script and stops if the expected random-effect call has changed.

## Test

From a terminal, start the native screensaver path:

```bash
omarchy-launch-screensaver force
```

The terminal shows continuous Matrix rain. A key or pointer movement closes it.

## Compare with the GPU rain

The GPU plugin covers this terminal effect when both are active. Test one
variant at a time.

For the terminal variant, install this folder, then run:

```bash
omarchy plugin disable io.github.tymurbogach.enter-the-matrix
omarchy restart shell
hyprctl reload
omarchy-launch-screensaver force
```

For the GPU variant, remove this folder, then run:

```bash
omarchy-matrix doctor
omarchy-launch-screensaver force
```

## Remove

```bash
./omarchy-rain/uninstall.sh
hyprctl reload
```

The marked block is removed before Hyprland restores Omarchy's normal command
precedence.
