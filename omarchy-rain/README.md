# Omarchy Rain

This is the standalone terminal version of the Matrix screensaver.

It derives Omarchy's current `omarchy-screensaver` command and replaces its
random TTFX effect with continuous Matrix rain. `--rain-time 86400` keeps the
rain on screen and prevents the normal text resolution phase.

This variant does not use the QML rain plugin. It is useful when you want to
compare the native terminal effect with this theme's GPU rain.

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
```

It refuses to overwrite an existing custom `omarchy-screensaver` command or a
PATH override that it does not own. Log out and log in after the first install.
UWSM reads the PATH override when it starts the graphical session.

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

For the terminal variant, install this folder, log out and log in, then run:

```bash
omarchy plugin disable io.github.tymurbogach.enter-the-matrix
omarchy restart shell
omarchy-launch-screensaver force
```

For the GPU variant, remove this folder, log out and log in, then run:

```bash
omarchy-matrix doctor
omarchy-launch-screensaver force
```

## Remove

```bash
./omarchy-rain/uninstall.sh
```

Log out and log in after removal so UWSM restores Omarchy's normal command
precedence.
