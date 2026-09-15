#!/usr/bin/env bash
# Installs the Enter the Matrix pack on top of the theme: the rain plugin, the
# CLI and the hooks. After that, Omarchy's own menus decide: Style > Background
# for the desktop rain, Style > Unlock for the boot splash.
#
#   ./install.sh            asks once, on a first install, when there is a terminal
#   ./install.sh --sync     copies the files and nothing else
#
# Nothing under /usr/share/omarchy is touched, nor hyprland.lua. The two pieces
# that stand in for something of Omarchy's, the lock and the Plymouth theme, are
# derived from this machine's own sources (lib/derive-lock.py,
# lib/derive-plymouth.py).
#
# To undo all of it: ./uninstall.sh

set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TESTED_ON="4.0.3"

# --sync copies the files and stops: no question, no doctor, no boot splash.
# It is what `omarchy-matrix doctor` calls when it notices the theme directory
# has moved on. `omarchy theme update` is a bare `git pull` per theme and fires
# no hooks at all, so nothing else would ever refresh these copies.
SYNC_ONLY=0
[[ ${1:-} != "--sync" ]] || SYNC_ONLY=1

command -v omarchy >/dev/null || { echo "this needs Omarchy" >&2; exit 1; }

# --- the provider -----------------------------------------------------------
# provider.json is the only file that names the provider; everything below is
# machinery. It is installed next to the CLI's other files so that the CLI can
# still read it while another theme is current -- which is exactly when
# `suspend` runs.

PROVIDER="$HERE/provider.json"
[[ -f $PROVIDER ]] || { echo "cannot find $PROVIDER" >&2; exit 1; }
# shellcheck source=lib/pack.sh
. "$HERE/lib/pack.sh" || { echo "cannot load $HERE/lib/pack.sh" >&2; exit 1; }
pack_load_provider "$PROVIDER" || exit 1
pack_set_paths
mapfile -t PLUGIN_FILES < <(jq -r '.plugin.files[]' "$PROVIDER")

# `omarchy theme install` names the theme's folder after the REPO -- basename of
# the URL with `omarchy-` stripped (omarchy-theme-install) -- and the slug in
# provider.json has to be that same name, because pack_in_effect() compares the
# slug against ~/.local/state/omarchy/current/theme.name. Renaming the repo
# without renaming the slug is silent: everything installs, and then every piece
# stands down forever because the pack never considers itself the current theme.
# Written down after exactly that happened.
here_name=$(basename "$HERE")
if [[ $HERE == "$HOME/.config/omarchy/themes/"* && $here_name != "$SLUG" ]]; then
  echo "this theme is installed as '$here_name' but provider.json says '$SLUG'." >&2
  echo "The folder name comes from the repo name; the two have to agree." >&2
  exit 1
fi

G=$'\033[38;2;'$((16#${ACCENT:1:2}))';'$((16#${ACCENT:3:2}))';'$((16#${ACCENT:5:2}))'m' # the provider's accent
DIM=$'\033[2m'
BOLD=$'\033[1m'
OFF=$'\033[0m'

INTERACTIVE=0
[[ -t 0 && -t 1 ]] && INTERACTIVE=1

# No share dir yet means a first install. Only a first install asks, sets the
# rain as the background and installs the boot splash. A later run is an
# update, and by then those choices are Omarchy's and the user's.
FIRST_INSTALL=0
[[ -f $SHARE_DIR/provider.json ]] || FIRST_INSTALL=1

say() {
  ((SYNC_ONLY)) || echo "  ${G}·${OFF} $*"
}

# --- the question -------------------------------------------------------------
# Asked before anything is written, so that the blue pill leaves the machine
# exactly as it was. The red pill is the default: Enter takes it. Without a
# terminal there is nobody to ask, and the red pill goes without the boot
# splash, which needs a password.

#
# The colours are Omarchy's: gum reads the GUM_* variables that Omarchy
# generates from the current theme (default/themed/gum_env.lua.tpl).

HEADER="This is your last chance. After this, there is no turning back."
RED_PILL="Red pill    You stay in Wonderland, and I show you how deep the rabbit hole goes."
BLUE_PILL="Blue pill   The story ends. You wake up in your bed with your simple theme."

take_the_red_pill() {
  local choice=""
  echo
  if command -v gum >/dev/null; then
    choice=$(gum choose --header "$HEADER" "$RED_PILL" "$BLUE_PILL") || choice=""
  else
    printf '  %s\n\n  %s\n  %s\n\n  [R/b] ' "$HEADER" "$RED_PILL" "$BLUE_PILL"
    read -r choice || choice=""
    if [[ ${choice,,} == b* ]]; then choice="$BLUE_PILL"; else choice="$RED_PILL"; fi
  fi
  [[ $choice == "$RED_PILL" ]]
}

if ((FIRST_INSTALL && !SYNC_ONLY && INTERACTIVE)) && ! take_the_red_pill; then
  echo
  echo "  ${DIM}The story ends. Nothing was installed, and the theme stays as it is.${OFF}"
  echo "  ${DIM}Changed your mind? Run this again.${OFF}"
  exit 0
fi

if ((!SYNC_ONLY)); then
  version=$(omarchy version 2>/dev/null || echo unknown)
  [[ $version == $TESTED_ON* ]] ||
    echo "  ${DIM}Tested on Omarchy $TESTED_ON, and this is $version. If the lock or boot patch no longer fits, it stops and says so.${OFF}" >&2
  echo
fi

# --- the boot splash, first ---------------------------------------------------
# The only piece that needs a password, so it comes first: the user types it
# once, and the rest installs on its own. It runs from here, before the CLI is
# copied: the deriver needs only provider.json and the theme folder that
# `omarchy theme install` has just made. Without a terminal there is nobody to
# ask, and a cached sudo grant would rebuild the initramfs unasked.
boot_skipped=0
if ((FIRST_INSTALL && !SYNC_ONLY)); then
  if ((INTERACTIVE)); then
    say "Setting the boot splash (it asks for your password)"
    OMARCHY_MATRIX_PROVIDER="$PROVIDER" "$HERE/lib/derive-plymouth.py" || boot_skipped=1
    echo
  else
    boot_skipped=1
  fi
fi

# --- the plugin -------------------------------------------------------------
# Only the files the plugin needs are copied, not the whole theme: that keeps
# the plugins directory readable and passes `omarchy plugin validate`.
#
# Built in a staging directory and moved into place, rather than copied file by
# file over the live one. Saving ANY file under ~/.config/omarchy/plugins/
# hot-reloads that plugin, so the old way fired one reload per file -- eleven in
# under a second, which is the two-instances trap idling (see CONTRIBUTING.md). A
# dot-prefixed name is skipped by the plugin scanner on purpose: Omarchy uses
# the same idiom for its own clone staging (PluginRegistry.qml:707).
#
# Returns 0 when it put a folder in place, and 1 when the live folder already
# held exactly these files. A reinstall of the same version then reloads
# nothing, and the rain does not blink.

stage_plugin() { # <id> <absolute source dir> <file>...
  local id="$1" src="$2" f
  shift 2
  local dest="$PLUGINS_DIR/$id" staging="$PLUGINS_DIR/.$id.staging"

  # A folder carrying a .git checkout is managed by hand -- `omarchy plugin add`
  # clones the repo there -- and staging over it would take the checkout with
  # it. Leave it alone.
  if [[ -e $dest/.git ]]; then
    echo "  $id has a .git checkout; leaving it alone"
    return 1
  fi

  rm -rf "$staging"
  mkdir -p "$staging"
  for f in "$@"; do
    cp -f "$src/$f" "$staging/$f"
  done

  if [[ -d $dest ]] && diff -rq "$staging" "$dest" >/dev/null 2>&1; then
    rm -rf "$staging"
    return 1
  fi

  # Validated BEFORE it goes live: a folder that fails validation must never be
  # the one the shell picks up.
  if ! omarchy-plugin-validate "$staging" >/dev/null; then
    rm -rf "$staging"
    echo "  $id does not pass Omarchy's validation; stopping here" >&2
    exit 1
  fi

  # `rm -rf "$dest"` fires one watcher event per file deleted -- the same burst
  # this staging exists to avoid, just on the way out instead of on the way in.
  # Renaming the live folder to a dot-prefixed name is a single event the
  # scanner ignores, and the removal after the swap is invisible.
  local retired="$PLUGINS_DIR/.$id.retired"
  rm -rf "$retired"
  [[ ! -e $dest ]] || mv "$dest" "$retired"
  mv "$staging" "$dest"
  rm -rf "$retired"
}

say "Installing the rain"

# A live plugin that gets new files can end up loaded twice (the two-instances
# trap). doctor restarts the shell once for that, and only for that.
was_enabled=0
if plugin_enabled "$PLUGIN_ID"; then was_enabled=1; fi
placed=0
replaced_live=0
if stage_plugin "$PLUGIN_ID" "$HERE/$PLUGIN_SRC" "${PLUGIN_FILES[@]}"; then
  placed=1
  replaced_live=$was_enabled
fi

# The rain's background, first in Omarchy's list for this theme (lib/pack.sh).
# The link goes to the theme folder that Omarchy knows, not to a working copy
# that can go away.
live_theme=$(omarchy-theme-dir "$SLUG" 2>/dev/null) || live_theme=""
[[ -n $live_theme && -f $live_theme/$LIVE_BACKGROUND ]] || live_theme="$HERE"
offer_live_background "$live_theme"

# --- the CLI ----------------------------------------------------------------
# The share dir mirrors the repo: bin/ holds the one command, lib/ its python,
# provider.json its names, uninstall.sh its own undo. ~/.local/bin holds only a
# symlink, so the command resolves its root -- and everything else -- from
# itself, and no file writes the share path by hand.

mkdir -p "$BIN_DIR" "$SHARE_DIR/bin" "$SHARE_DIR/lib"
install -m 755 "$HERE/bin/$CLI" "$SHARE_DIR/bin/$CLI"
install -m 755 "$HERE/lib/derive-lock.py" "$SHARE_DIR/lib/derive-lock.py"
install -m 755 "$HERE/lib/derive-plymouth.py" "$SHARE_DIR/lib/derive-plymouth.py"
install -m 755 "$HERE/lib/derive-menu.py" "$SHARE_DIR/lib/derive-menu.py"
# Imported by both derivers, and the python half of the provider lookup.
install -m 644 "$HERE/lib/provider.py" "$SHARE_DIR/lib/provider.py"
# Sourced by the CLI and both scripts; without it nothing runs.
install -m 644 "$HERE/lib/pack.sh" "$SHARE_DIR/lib/pack.sh"
install -m 644 "$PROVIDER" "$SHARE_DIR/provider.json"
# uninstall.sh lives in the theme directory, and `omarchy theme remove` deletes
# that directory and nothing else -- so a copy goes to the share dir, where it
# outlives the theme, and `$CLI uninstall` execs it from there.
install -m 755 "$HERE/uninstall.sh" "$SHARE_DIR/uninstall.sh"
ln -sfn "$SHARE_DIR/bin/$CLI" "$BIN_DIR/$CLI"

clean_legacy_bins

# --- the hooks --------------------------------------------------------------
# theme-set: brings the pack up when you pick this theme, stands it down when
# you pick anything else.
# post-update: derives the lock, the boot splash and the Unlock row again from
# the freshly updated sources.
#
# Generated four-line wrappers calling back into the CLI, installed with
# `omarchy hook install`. The logic lives in `$CLI hook`, so the file on disk
# carries no provider names and never goes stale on its own -- and generating
# it on every run (including --sync) refreshes whatever an older install left.

for hook in theme-set post-update; do
  # Named $SLUG up front: `omarchy hook install` keeps the file's basename.
  tmpdir=$(mktemp -d)
  {
    echo "#!/bin/bash"
    echo "# Generated by the $DISPLAY_NAME pack's install.sh; do not edit."
    echo "# Calls back into the CLI, where the hook logic lives."
    echo "exec \"\$HOME/.local/bin/$CLI\" hook $hook \"\$@\""
  } >"$tmpdir/$SLUG"
  omarchy-hook-install "$hook" "$tmpdir/$SLUG" >/dev/null
  rm -rf "$tmpdir"
done

# Everything above is a file copy, and that is all --sync is for: refreshing
# what a `omarchy theme update` pulled into the theme directory. What follows
# brings pieces up. A refresh may not do that behind the user's back.
if ((placed)); then
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
  sleep 0.3
fi
((!SYNC_ONLY)) || exit 0

# --- bring it up --------------------------------------------------------------

# A screensaver-off flag that is already here on a first install is the user's
# own, so release_screensaver_flag (lib/pack.sh) must leave it alone.
if ((FIRST_INSTALL)); then touch "$SHARE_DIR/.screensaver-v2"; fi
prune_backups

# doctor brings the pieces up, takes back what an older version left, and
# restarts the shell once if the shell has something to unload.
problems=0
OMARCHY_MATRIX_RESTART=$replaced_live "$BIN_DIR/$CLI" doctor >/dev/null || problems=1

in_effect=0
[[ $(cat "$HOME/.local/state/omarchy/current/theme.name" 2>/dev/null) != "$SLUG" ]] || in_effect=1

# The red pill starts on the rain. After that the background is Omarchy's: a
# theme set starts on the rain by itself, and Style > Background changes it.
if ((FIRST_INSTALL && in_effect)) && [[ -e $LIVE_LINK ]]; then
  omarchy-theme-bg-set "$LIVE_LINK" >/dev/null 2>&1 || true
fi

echo
if ((FIRST_INSTALL)); then
  echo "  ${G}${BOLD}Welcome to the real world.${OFF}"
else
  echo "  ${G}${BOLD}Done.${OFF} ${DIM}The pack is up to date.${OFF}"
fi
echo
((in_effect)) || echo "  It comes on with the theme: Style › Theme › $DISPLAY_NAME."
((!boot_skipped)) || echo "  No boot splash yet. Pick it in Style › Unlock, on the $DISPLAY_NAME card."
((!problems)) || echo "  Something did not come up. See what: $CLI status"
cat <<EOF
  ${DIM}Desktop rain${OFF}   Style › Background, the rain
  ${DIM}Boot splash${OFF}    Style › Unlock, the $DISPLAY_NAME card
  ${DIM}Remove${OFF}         $CLI uninstall
EOF
