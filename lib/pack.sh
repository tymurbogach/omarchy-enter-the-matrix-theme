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
  # Up to 1.2.x a bar widget of the pack had this id. retire_widget takes an
  # installed one back.
  LEGACY_WIDGET_ID="$PLUGIN_ID.widget"
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
  # Up to 1.2.x: a switch per piece. retire_settings takes the file back.
  LEGACY_CONFIG="$HOME/.config/omarchy/$SLUG.json"
  USER_BACKGROUNDS="$HOME/.config/omarchy/backgrounds/$SLUG"
  LIVE_LINK="$USER_BACKGROUNDS/${LIVE_BACKGROUND##*/}"
}

# The desktop rain is picked like any other background. Its still is not in the
# theme's backgrounds/, so the theme alone never offers it. The pack links it
# into Omarchy's folder for the user's own backgrounds of this theme. Omarchy
# lists that folder first (omarchy-theme-set sorts the full paths), so a theme
# set starts on the rain, and Style > Background shows it like any other.
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
  [[ $id == "$PLUGIN_ID" || $id == "$LEGACY_WIDGET_ID" ]]
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
  omarchy-plugin-remove "$1" --yes >/dev/null 2>&1 ||
    omarchy-plugin-remove "$1" >/dev/null 2>&1 || true
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

# Remove <file> only if it contains <marker>, a line that only the pack's own old
# copy of that file carries. Never fails.
remove_if_marked() { # <file> <marker>
  [[ -f $1 ]] && grep -qF -- "$2" "$1" && rm -f "$1"
  return 0
}

# One release only: the previous layout put the derivers, provider.py and a copy
# of uninstall.sh straight on PATH. Take them back once. Each file is matched by
# its content, not by its name alone: `provider.py` is a plausible name for a
# file of the user's own, and a first install with no old layout runs this too.
# The bytecode cache gets the same care, because other programs share it.
clean_legacy_bins() {
  [[ ! -f $SHARE_DIR/.layout-v2 ]] || return 0
  remove_if_marked "$BIN_DIR/derive-lock.py" "from provider import PROVIDER"
  remove_if_marked "$BIN_DIR/derive-plymouth.py" "from provider import PROVIDER"
  remove_if_marked "$BIN_DIR/provider.py" "OMARCHY_MATRIX_PROVIDER"
  remove_if_marked "$BIN_DIR/$CLI-uninstall" "handing Omarchy's lock back"
  local name
  for name in provider derive-lock derive-plymouth derivar-lock derivar-plymouth; do
    rm -f "$BIN_DIR/__pycache__/$name".*.pyc
  done
  rmdir "$BIN_DIR/__pycache__" 2>/dev/null || true
  find "$SHARE_DIR" -name '*.pyc' -delete 2>/dev/null || true
  mkdir -p "$SHARE_DIR" && touch "$SHARE_DIR/.layout-v2"
}

# Up to 1.2.0 the pack set Omarchy's screensaver-off flag and drew a screensaver
# of its own. Now the rain covers Omarchy's screensaver, so the flag belongs to
# the user again. Hand back the flag that the pack set, once.
#
# The pack set it whenever the screensaver piece was on, and doctor forced it.
# So a flag seen here, with the piece on, is the pack's. A first install marks
# itself done in install.sh, because a flag found then is the user's. Never fails.
release_screensaver_flag() {
  local marker="$SHARE_DIR/.screensaver-v2" wanted
  [[ ! -f $marker ]] || return 0
  wanted=$(jq -r 'if has("screensaver") then .screensaver else true end | tostring' "$LEGACY_CONFIG" 2>/dev/null) ||
    wanted=""
  if [[ $wanted == "true" && -f $HOME/.local/state/omarchy/toggles/screensaver-off ]]; then
    omarchy-toggle screensaver-off off >/dev/null 2>&1 || true
  fi
  mkdir -p "$SHARE_DIR" && touch "$marker"
  return 0
}

remember_previous_theme() {
  mkdir -p "$SHARE_DIR" && printf '%s\n' "$1" >"$PREVIOUS_THEME_FILE"
}

# Up to 1.2.x each piece had a switch, kept in ~/.config/omarchy/<slug>.json.
# The pieces now follow Omarchy's own choices, so only the theme to return to
# on uninstall is kept, in the share dir. The screensaver flag is handed back
# first, because only the old file can tell whose flag it is. Never fails.
retire_settings() {
  [[ -f $LEGACY_CONFIG ]] || return 0
  release_screensaver_flag
  local previous
  previous=$(jq -r '.previousTheme // empty' "$LEGACY_CONFIG" 2>/dev/null) || previous=""
  [[ -z $previous || -f $PREVIOUS_THEME_FILE ]] || remember_previous_theme "$previous"
  rm -f "$LEGACY_CONFIG"
}

# Up to 1.2.x a bar widget switched the pieces. There are no switches now, so
# the widget goes, once: its plugin (and with it its entry on the bar), its
# backups, the cache of its repo, and the update answer that only its panel
# read. A checkout that somebody added with `omarchy plugin add` carries a .git
# and stays. Never fails.
retire_widget() {
  local dir="$PLUGINS_DIR/$LEGACY_WIDGET_ID"
  if [[ -d $dir && ! -e $dir/.git ]]; then
    remove_plugin "$LEGACY_WIDGET_ID"
    forget_plugin_list
    prune_backups
  fi
  rm -rf "$SHARE_DIR/widget-src" "$HOME/.cache/$CLI/update.json"
  return 0
}

# Everything an older install leaves that this version no longer has. Each step
# is a no-op once done, so every entry point can run it. Never fails.
pack_migrate() {
  retire_settings
  retire_widget
}
