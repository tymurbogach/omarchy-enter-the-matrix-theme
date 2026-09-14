#!/usr/bin/env bash
# Installs the Matrix pack: the rain plugin, the bar widget, the CLI and the hooks.
#
#   ./install.sh            interactive when there is a terminal
#   ./install.sh --sync     copy the files and nothing else
#
# It is additive. Nothing under /usr/share/omarchy is touched, nor hyprland.lua,
# nor Omarchy's background: the desktop rain draws on a layer of its own above
# it. The only two things of Omarchy's that get replaced are the lock plugin and
# the Plymouth theme, and neither ships as a frozen copy -- both are DERIVED
# from whatever this machine has (see lib/derive-lock.py, lib/derive-plymouth.py).
#
# To undo all of it: ./uninstall.sh

set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
TESTED_ON="4.0.3"

# --sync copies the files and stops: no questions, no doctor, no boot splash.
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
# `suspend` and `lock off` run.

PROVIDER="$HERE/provider.json"
[[ -f $PROVIDER ]] || { echo "cannot find $PROVIDER" >&2; exit 1; }
# shellcheck source=lib/pack.sh
. "$HERE/lib/pack.sh" || { echo "cannot load $HERE/lib/pack.sh" >&2; exit 1; }
pack_load_provider "$PROVIDER" || exit 1
pack_set_paths
mapfile -t PLUGIN_FILES < <(jq -r '.plugin.files[]' "$PROVIDER")
mapfile -t WIDGET_FILES < <(jq -r '.widget.files[]' "$PROVIDER")

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

version=$(omarchy version 2>/dev/null || echo unknown)
[[ $version == $TESTED_ON* ]] || cat >&2 <<WARNING
  warning: written and tested against Omarchy $TESTED_ON, this is $version.
  The rain plugin should not care. The lock and the boot splash are derived
  from yours, and if a patch no longer fits they abort and say so rather than
  leaving things half done.
WARNING

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

stage_plugin() { # <id> <absolute source dir> <file>...
  local id="$1" src="$2" f
  shift 2
  local dest="$PLUGINS_DIR/$id" staging="$PLUGINS_DIR/.$id.staging"

  # A folder carrying a .git checkout is managed by hand -- `omarchy plugin add`
  # clones the repo there -- and staging over it would take the checkout with
  # it. Leave it alone.
  if [[ -e $dest/.git ]]; then
    echo "  $id has a .git checkout; leaving it alone"
    return 0
  fi

  rm -rf "$staging"
  mkdir -p "$staging"
  for f in "$@"; do
    cp -f "$src/$f" "$staging/$f"
  done

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

# The widget lives in its own repo (see provider.json's "widget" comment), pinned
# to one commit. The commit is fetched once into a cache outside the plugins
# dir. If the cache is already at the pin, nothing touches the network. This
# also runs from `omarchy-matrix doctor` (via --sync), which must work offline.
# MATRIX_WIDGET_SRC bypasses all of this for local development against an
# uncommitted checkout of the widget repo.
# WIDGET_CLONE itself comes from pack_set_paths: the share dir's widget-src.

resolve_widget_src() {
  if [[ -n ${MATRIX_WIDGET_SRC:-} ]]; then
    echo "$MATRIX_WIDGET_SRC"
    return
  fi

  # Pinned to a commit, never a branch: a branch moves under the cache, and only
  # a full SHA can be fetched by SHA below.
  [[ $WIDGET_REF =~ ^[0-9a-f]{40}$ ]] ||
    { echo "  provider's widget.ref is not a 40-hex SHA: $WIDGET_REF" >&2; exit 1; }

  mkdir -p "$SHARE_DIR"
  if [[ -d "$WIDGET_CLONE/.git" ]]; then
    # provider.json's widget.repo may have moved since this cache was made (a
    # rename, a migration to another org). Re-point origin at the CURRENT URL
    # before every fetch, or a stale origin fetches forever from the old
    # address while the warning below quotes the new one -- silently correct
    # in its wording and silently wrong in what it just did. A failure here
    # isn't fatal on its own: it just means the fetch that follows will fail
    # too, which is what actually surfaces as the "could not refresh" warning.
    git -C "$WIDGET_CLONE" remote set-url origin "$WIDGET_REPO" >/dev/null 2>&1 || true
    # Already at the pin: stay offline. A pinned cache needs no network to know
    # nothing changed.
    if [[ $(git -C "$WIDGET_CLONE" rev-parse HEAD 2>/dev/null) == "$WIDGET_REF" ]]; then
      echo "$WIDGET_CLONE"
      return
    fi
    if ! git -C "$WIDGET_CLONE" fetch --depth 1 origin "$WIDGET_REF" >/dev/null 2>&1 ||
       ! git -C "$WIDGET_CLONE" reset --hard FETCH_HEAD >/dev/null 2>&1; then
      echo "  warning: could not fetch $WIDGET_REF from $WIDGET_REPO" >&2
    fi
  else
    rm -rf "$WIDGET_CLONE"
    mkdir -p "$WIDGET_CLONE"
    if ! git -C "$WIDGET_CLONE" init -q >/dev/null 2>&1 ||
       ! git -C "$WIDGET_CLONE" remote add origin "$WIDGET_REPO" >/dev/null 2>&1 ||
       ! git -C "$WIDGET_CLONE" fetch --depth 1 origin "$WIDGET_REF" >/dev/null 2>&1 ||
       ! git -C "$WIDGET_CLONE" reset --hard FETCH_HEAD >/dev/null 2>&1; then
      echo "  could not clone $WIDGET_REPO" >&2
      exit 1
    fi
  fi
  # Detached at the pin, whatever the remote calls it now: a cache that drifted
  # (a hand pull, a branch of the same name) comes back here, and anything else
  # warns instead of staging a surprise.
  git -C "$WIDGET_CLONE" checkout -q --detach "$WIDGET_REF" >/dev/null 2>&1 || true
  # Anything but the pin is not what this commit was tested with, and it can
  # speak an older status protocol. Say so, and let the caller keep what is
  # already staged.
  if [[ $(git -C "$WIDGET_CLONE" rev-parse HEAD 2>/dev/null) != "$WIDGET_REF" ]]; then
    echo "  warning: the widget cache is not at $WIDGET_REF" >&2
    return 1
  fi
  echo "$WIDGET_CLONE"
}

echo "· plugin $PLUGIN_ID"
stage_plugin "$PLUGIN_ID" "$HERE/$PLUGIN_SRC" "${PLUGIN_FILES[@]}"

# --- the CLI ----------------------------------------------------------------
# The share dir mirrors the repo: bin/ holds the one command, lib/ its python,
# provider.json its names, uninstall.sh its own undo. ~/.local/bin holds only a
# symlink, so the command resolves its root -- and everything else -- from
# itself, and no file writes the share path by hand.

echo "· $CLI in $BIN_DIR (a link to the share dir)"
mkdir -p "$BIN_DIR" "$SHARE_DIR/bin" "$SHARE_DIR/lib"
install -m 755 "$HERE/bin/$CLI" "$SHARE_DIR/bin/$CLI"
install -m 755 "$HERE/lib/derive-lock.py" "$SHARE_DIR/lib/derive-lock.py"
install -m 755 "$HERE/lib/derive-plymouth.py" "$SHARE_DIR/lib/derive-plymouth.py"
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
# theme-set: brings the pack back when you pick this theme, stands it down when
# you pick anything else.
# post-update: re-derives the lock and the boot splash from the freshly updated
# sources.
#
# Generated four-line wrappers calling back into the CLI, installed with
# `omarchy hook install`. The logic lives in `$CLI hook`, so the file on disk
# carries no provider names and never goes stale on its own -- and generating
# it on every run (including --sync) refreshes whatever an older install left.

echo "· theme-set and post-update hooks"
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

# --- the bar widget ---------------------------------------------------------
# The switchboard on the bar. A plugin of its own rather than another kind on
# the rain: for a `bar-widget`, enabled means present in bar.layout, so folding
# the two together would take the icon off the bar the moment both rain layers
# were switched off. Fetched from its own repo -- see resolve_widget_src above.
#
# LAST of the file copies, and deliberately: it is the only step here that can
# fail on a first install (no cache to fall back on, so the clone is fatal). It
# used to run right after the rain plugin, which meant a failed clone aborted
# the script with a plugin already staged and no `$CLI` on PATH: a
# half-installed pack with no command to inspect or remove it. Nothing above
# depends on the widget being staged, so everything that can be installed is
# installed before the one step that can stop the run.
echo "· bar widget $WIDGET_ID"
if WIDGET_SRC_DIR=$(resolve_widget_src); then
  stage_plugin "$WIDGET_ID" "$WIDGET_SRC_DIR" "${WIDGET_FILES[@]}"
elif [[ -d $PLUGINS_DIR/$WIDGET_ID ]]; then
  # Offline, or the pin cannot be reached: the widget already staged keeps
  # working. A cache off the pin could stage a widget that does not speak this
  # CLI's status protocol.
  echo "  keeping the installed widget; run install.sh again when online" >&2
else
  echo "  could not install the bar widget; the rest of the pack is in place" >&2
  exit 1
fi

# Everything above is a file copy, and that is all --sync is for: refreshing
# what a `omarchy theme update` pulled into the theme directory. What follows
# prunes old backups and switches pieces on. A refresh may do neither behind
# the user's back.
if ((SYNC_ONLY)); then
  omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
  exit 0
fi

# --- stale plugin backups --------------------------------------------------
# `omarchy plugin remove` renames rather than deletes; prune_backups (in
# lib/pack.sh) takes ours back. Counted here so the run says what it did.
pruned=0
for dir in "$PLUGINS_DIR"/.*.bak.*; do
  [[ -d $dir ]] || continue
  if ours "$dir"; then
    rm -rf "$dir"
    pruned=$((pruned + 1))
  fi
done
((pruned == 0)) || echo "· removed $pruned stale plugin backup(s) of ours"

# --- switch it on -----------------------------------------------------------
# Interactive when there is a terminal to ask on, and silent-but-identical to
# the old behaviour when there is not: this also runs from `omarchy theme
# install` chained on one line, from a hook, and from an agent.

G=$'\033[38;2;'$((16#${ACCENT:1:2}))';'$((16#${ACCENT:3:2}))';'$((16#${ACCENT:5:2}))'m'  # the provider's accent
DIM=$'\033[2m'
BOLD=$'\033[1m'
OFF=$'\033[0m'

INTERACTIVE=0
[[ -t 0 && -t 1 ]] && INTERACTIVE=1

# Default yes. Anything starting with n is a no; Enter is a yes.
ask() {
  local reply=""
  ((INTERACTIVE)) || return 0
  printf '  %s%s%s  %s%s%s [Y/n] ' "$G" "$1" "$OFF" "$DIM" "$2" "$OFF"
  read -r reply || true
  [[ ${reply,,} != n* ]]
}

if [[ ! -f $CONFIG ]]; then
  # A first install. A screensaver-off flag that is already here is the user's
  # own, so release_screensaver_flag (lib/pack.sh) must leave it alone.
  mkdir -p "$SHARE_DIR" && touch "$SHARE_DIR/.screensaver-v2"
  if ((INTERACTIVE)); then
    echo
    echo "  ${BOLD}Which pieces do you want?${OFF} Each one switches on and off later,"
    echo "  ${DIM}from the $DISPLAY_NAME icon on the bar, or with '$CLI'.${OFF}"
    echo
  fi
  w=true; s=true; l=true; g=true
  ask "Background " "rain on the desktop"                  || w=false
  ask "Screensaver" "rain over Omarchy's own screensaver"  || s=false
  ask "Lock       " "rain behind the password field"       || l=false
  ask "Bar icon   " "these switches, one click away"       || g=false
  printf '{"wallpaper": %s, "screensaver": %s, "lock": %s, "boot": true, "widget": %s}\n' \
    "$w" "$s" "$l" "$g" >"$CONFIG"
fi

omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true
sleep 0.5

echo
"$BIN_DIR/$CLI" doctor

# One restart at the end, and only here. Three reasons, all paid for:
#
# - A hot reload is not enough for a bar widget that has just appeared or
#   changed shape. Watched here: the icon's slot stayed 0 px wide through
#   several reloads and only took its size after a restart.
# - It guarantees exactly one instance of every plugin the pack touches, which
#   is the two-instances trap closed rather than dodged.
# - restart_shell lets the plugin scan settle first: a rescan still in flight
#   when the shell goes down segfaults quickshell (#972), and staging two
#   plugins plus a lock clone is exactly that workload.
restart_shell || true

# The boot splash is last because it is the only piece that needs a password and
# rebuilds the initramfs. Without a terminal there is nobody to ask, and a
# cached sudo grant would rebuild the initramfs unasked -- so it is skipped,
# with the command that enables it later.
if ! "$BIN_DIR/$CLI" status --is boot 2>/dev/null; then
  echo
  echo "  ${BOLD}Boot splash${OFF} — the screen before login, typing out the four lines"
  echo "  from the film. ${DIM}Writes to /usr/share/plymouth and rebuilds the initramfs,"
  echo "  so it asks for your password.${OFF}"
  if ((INTERACTIVE)); then
    if ask "Install it" "you can also do this later"; then
      "$BIN_DIR/$CLI" boot on || echo "  skipped — the rest of the pack is installed and working" >&2
    else
      "$BIN_DIR/$CLI" boot off >/dev/null 2>&1 || true
      echo "  ${DIM}skipped. Turn it on later with: $CLI boot on${OFF}"
    fi
  else
    echo "  ${DIM}skipped (no terminal here). Turn it on later with: $CLI boot on${OFF}"
  fi
fi

cat <<EOF

  ${G}${BOLD}Done.${OFF}

  ${BOLD}$CLI${OFF}                 ${DIM}the switchboard${OFF}
  ${DIM}installed at${OFF} $BIN_DIR/$CLI

    $CLI status         ${DIM}what is on right now${OFF}
    $CLI wallpaper off  ${DIM}any piece: wallpaper screensaver lock boot widget${OFF}
    $CLI doctor         ${DIM}re-apply everything after 'omarchy refresh shell'${OFF}
    $CLI uninstall      ${DIM}remove the pack and the theme${OFF}

  ${BOLD}The $DISPLAY_NAME icon on your bar${OFF}  ${DIM}the same switches, with a tick${OFF}
  ${DIM}and Repair and Uninstall beneath them. Not there? '$CLI widget on'${OFF}

  ${DIM}Note: 'omarchy theme set' rotates to the next background, so re-applying
  the theme takes you off the rain. Back with: $CLI wallpaper on${OFF}
EOF
