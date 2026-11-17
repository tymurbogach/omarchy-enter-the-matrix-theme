# lib/pack.sh -- the shell the pack's scripts share. Sourced, never executed.
# shellcheck shell=bash
# SC2034 off: HOOKS, LIVE_LINK and friends are read by the scripts that source
# this file, which shellcheck cannot see.
# shellcheck disable=SC2034
#
# Defines only: sourcing it changes nothing but what is defined here, and every
# function works with or without `set -e` (callers check return codes
# explicitly). Each script resolves PROVIDER its own way, then calls
# pack_load_provider and pack_set_paths before anything else.

# One jq for every name the machinery needs. The provider owns them all;
# nothing else writes a provider name down.
pack_load_provider() {
  if [[ -z ${1:-} || ! -f $1 ]]; then
    echo "pack: cannot find provider.json" >&2
    return 1
  fi
  eval "$(jq -r '@sh "SLUG=\(.slug) DISPLAY_NAME=\(.displayName) CLI=\(.cli) ACCENT=\(.accent) PLUGIN_ID=\(.plugin.id) PLUGIN_SRC=\(.plugin.dir) PLYMOUTH_THEME=\(.plymouth.theme) IPC=\(.ipc) RAIN_QML=\(.rainFiles[0]) LIVE_BACKGROUND=\(.liveBackground // "")"' "$1")" ||
    { echo "pack: $1 is not valid JSON" >&2; return 1; }
}

# Every path the machinery writes, derived from $HOME and the provider's names.
# Needs SLUG and CLI from pack_load_provider first.
pack_set_paths() {
  BIN_DIR="$HOME/.local/bin"
  SHARE_DIR="$HOME/.local/share/$CLI"
  PLUGINS_DIR="$HOME/.config/omarchy/plugins"
  HOOKS="$HOME/.config/omarchy/hooks"
  # The theme to go back to on uninstall. The theme-set hook writes it down.
  PREVIOUS_THEME_FILE="$SHARE_DIR/previous-theme"
  USER_BACKGROUNDS="$HOME/.config/omarchy/backgrounds/$SLUG"
  LIVE_LINK="$USER_BACKGROUNDS/${LIVE_BACKGROUND##*/}"
}

# The desktop rain is picked like any other background. Its still is not in the
# theme's backgrounds/, so the theme alone never offers it. The pack links it
# into Omarchy's folder for the user's own backgrounds of this theme. Omarchy
# lists that folder first (omarchy-theme-set sorts the full paths), so a theme
# set starts on the rain, and Appearance > Background shows it like any other.
offer_live_background() { # <theme dir>
  local source="$1/$LIVE_BACKGROUND"
  [[ -n $LIVE_BACKGROUND && -f $source ]] || return 0
  [[ $(readlink "$LIVE_LINK" 2>/dev/null) != "$source" ]] || return 0
  # A file of the user's own under the same name stays.
  [[ ! -e $LIVE_LINK || -L $LIVE_LINK ]] || return 0
  mkdir -p "$USER_BACKGROUNDS" && ln -sfn "$source" "$LIVE_LINK"
}

# Takes back the link and nothing else: the folder can also hold backgrounds of
# the user's own. Never fails.
withdraw_live_background() {
  [[ ! -L $LIVE_LINK ]] || rm -f "$LIVE_LINK"
  rmdir "$USER_BACKGROUNDS" 2>/dev/null
  return 0
}

# Whether a lock clone is ours: cloned from omarchy.lock AND (marked as derived
# by this CLI OR carrying the rain). A clone somebody made for their own
# reasons matches the first half and must survive untouched -- the deriver once
# adopted such a clone, patched it, and `lock off` then deleted it.
lock_is_ours() {
  local dir="$1" derived
  [[ -d $dir ]] || return 1
  jq -e '.omarchy.clonedFrom == "omarchy.lock"' "$dir/manifest.json" >/dev/null 2>&1 || return 1
  derived=$(jq -r '.omarchy.derivedBy // empty' "$dir/manifest.json" 2>/dev/null)
  [[ $derived == "$CLI" ]] && return 0
  [[ -f $dir/$RAIN_QML ]]
}

# `omarchy plugin clone` decides the lock clone's id: <username>.lock. Discover
# it rather than assume it, because on another machine the username differs.
lock_clone_id() {
  local dir
  for dir in "$PLUGINS_DIR"/*.lock; do
    lock_is_ours "$dir" || continue
    jq -r '.id' "$dir/manifest.json"
    return 0
  done
  return 1
}

# Whether a plugin backup is ours and may go: the rain inside, or one of our
# ids. A lock clone somebody made themselves has the same name shape and stays.
ours() {
  [[ -f "$1/$RAIN_QML" ]] && return 0
  [[ -f "$1/manifest.json" ]] || return 1
  local id
  id=$(jq -r '.id // empty' "$1/manifest.json" 2>/dev/null)
  [[ $id == "$PLUGIN_ID" ]]
}

# `omarchy plugin remove` renames rather than deletes, so every folder it took
# away is still on disk as .<id>.bak.<timestamp>. Take ours back.
prune_backups() {
  local dir
  for dir in "$PLUGINS_DIR"/.*.bak.*; do
    [[ -d $dir ]] || continue
    if ours "$dir"; then rm -rf "$dir"; fi
  done
  return 0
}

# Remove one plugin, however the installed omarchy-plugin-remove asks to be
# called. Never fails: callers decide what a missing plugin means.
remove_plugin() {
  omarchy-plugin-remove "$1" --yes >/dev/null 2>&1 || true
}

# `omarchy plugin list` is a process, and one `status` asks it several times.
# Read it once and forget it whenever something changes.
PLUGIN_LIST=""

plugin_list() {
  [[ -n $PLUGIN_LIST ]] || PLUGIN_LIST=$(omarchy-plugin-list --json 2>/dev/null || echo "[]")
  echo "$PLUGIN_LIST"
}

forget_plugin_list() {
  PLUGIN_LIST=""
}

plugin_enabled() {
  plugin_list | jq -e --arg id "$1" 'any(.[]; .id == $id and .enabled)' >/dev/null 2>&1
}

plugin_known() {
  plugin_list | jq -e --arg id "$1" 'any(.[]; .id == $id)' >/dev/null 2>&1
}

# A plugin rescan still in flight when the shell goes down SEGFAULTS quickshell
# (quickshell-mirror/quickshell#972): the scan finishes mid-teardown and asks an
# IPC registry the teardown already freed. Let the registry stop moving first --
# three identical live answers -- which NARROWS the window without blocking
# anything. Nothing to observe before the watcher's own 150ms debounce elapses.
settle_plugin_scan() {
  local previous="" current="" steady=0 waited=0

  sleep 0.3

  while ((waited < 40)); do # ~4s ceiling, plus the debounce wait above
    forget_plugin_list
    current=$(plugin_list)
    # `[]` is a shell that is not answering; steadiness there means nothing.
    if [[ $current != "[]" && $current == "$previous" ]]; then
      steady=$((steady + 1))
      ((steady < 3)) || break
    else
      steady=0
    fi
    previous="$current"
    sleep 0.1
    waited=$((waited + 1))
  done

  forget_plugin_list
}

# Settle the scan, then restart the shell. Callers say why themselves.
restart_shell() {
  settle_plugin_scan
  omarchy-restart-shell >/dev/null 2>&1 || return 1
}

# What the running shell has loaded from the pack: which plugins are the lock,
# and the bytes of the rain plugin and of our lock clone. A command compares
# this before and after its work, and restarts the shell once if it changed.
# If nothing changed, nothing restarts: a restart blanks the bar and the
# background, and it is the flicker that a reinstall used to show.
pack_fingerprint() {
  local id dirs=("$PLUGINS_DIR/$PLUGIN_ID")
  if id=$(lock_clone_id); then dirs+=("$PLUGINS_DIR/$id"); fi
  forget_plugin_list
  {
    plugin_list | jq -c '[.[] | select(.enabled and (.id | endswith(".lock"))) | .id] | sort'
    find "${dirs[@]}" -type f -exec md5sum {} + 2>/dev/null | sort
  } | md5sum
}

remember_previous_theme() {
  mkdir -p "$SHARE_DIR" && printf '%s\n' "$1" >"$PREVIOUS_THEME_FILE"
}

# 2.0 needs Omarchy 4.5: the lock deriver patches BackgroundMedia and the menu
# deriver writes appearance.unlock. An older Omarchy never runs either deriver:
# install.sh and the CLI refuse before they get that far.
pack_version_ok() {
  local version major minor
  version=$(omarchy version 2>/dev/null || echo "")
  [[ $version =~ ^([0-9]+)\.([0-9]+) ]] || return 1
  major=${BASH_REMATCH[1]} minor=${BASH_REMATCH[2]}
  ((10#$major > 4 || (10#$major == 4 && 10#$minor >= 5)))
}

# --- shared state readers ---------------------------------------------------
# One copy of the three questions every script asks Omarchy: which theme is
# current, whether the rain's still is the background, and whether a theme
# folder exists anywhere. bin/omarchy-matrix, install.sh and uninstall.sh all
# read through these, so the paths agree by construction.

# The theme Omarchy names as current (empty when Omarchy names none).
current_theme() {
  cat "$HOME/.local/state/omarchy/current/theme.name" 2>/dev/null
}

# Whether the rain's still is the background (its name carries -live-).
on_live_background() {
  [[ $(readlink -f "$HOME/.local/state/omarchy/current/background" 2>/dev/null) == *-live-* ]]
}

# Whether a theme folder exists in either place Omarchy keeps themes.
theme_exists() {
  [[ -n ${1:-} ]] || return 1
  [[ -d "$HOME/.config/omarchy/themes/$1" || -d "${OMARCHY_PATH:-/usr/share/omarchy}/themes/$1" ]]
}

# A plugin folder carrying a .git checkout is managed by hand, and the pack
# leaves it alone: staging over it would take the checkout with it, and
# judging it stale would send --sync after a checkout nothing may overwrite.
plugin_has_git_checkout() { # <plugin dir>
  [[ -e ${1:?}/.git ]]
}

# A 1.x install that nothing migrates any more: the 1.2.x settings file and
# widget leftovers, and the pre-rename menu block of 1.3.0. These paths are
# the only 1.x constants the pack still names, and only here. install.sh and
# doctor refuse with the uninstall message while any of them is present;
# hooks stay silent and do nothing.
legacy_install_present() {
  [[ -f $HOME/.config/omarchy/$SLUG.json ]] && return 0
  [[ -e $PLUGINS_DIR/$PLUGIN_ID.widget ]] && return 0
  [[ -f $SHARE_DIR/widget-src/update.json ]] && return 0
  local menu="$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"
  if [[ -f $menu ]]; then
    grep -qF "// >>> $SLUG: Style > Unlock, managed by $CLI. Do not edit." "$menu" &&
      return 0
  fi
  return 1
}
