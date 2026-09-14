#!/usr/bin/env bash
# Undoes the pack and leaves Omarchy the way it was.
#
#   ./uninstall.sh [--keep-theme]      installed: omarchy-matrix uninstall
#
# The theme directory goes too, unless --keep-theme keeps it as an ordinary
# Omarchy theme with its colours and its backgrounds.

set -uo pipefail

# provider.json is the only file that names the provider. This runs both from the
# share dir (`<cli> uninstall` execs it there, with the theme directory possibly
# already gone) and from a working copy. Learn the names from beside this script
# first, then prefer the share copy: that is the live install.
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/pack.sh
. "$HERE/lib/pack.sh" || { echo "cannot load $HERE/lib/pack.sh" >&2; exit 1; }

PROVIDER=""
for candidate in "${OMARCHY_MATRIX_PROVIDER:-}" "$HERE/provider.json"; do
  [[ -n $candidate && -f $candidate ]] || continue
  PROVIDER="$candidate"
  break
done
[[ -n $PROVIDER ]] || { echo "cannot find provider.json; nothing to undo" >&2; exit 1; }
pack_load_provider "$PROVIDER" || exit 1
pack_set_paths
if [[ -z ${OMARCHY_MATRIX_PROVIDER:-} && $PROVIDER != "$SHARE_DIR/provider.json" &&
  -f $SHARE_DIR/provider.json ]]; then
  PROVIDER="$SHARE_DIR/provider.json"
  pack_load_provider "$PROVIDER" || exit 1
  pack_set_paths
fi

THEME_DIR="$HOME/.config/omarchy/themes/$SLUG"

# Read before anything is deleted: the theme step-off at the very bottom needs
# it, and the settings file is removed long before then. The theme-set hook
# records it every time you pick another theme, because Omarchy overwrites
# current/theme.name before it calls that hook -- afterwards nobody knows.
PREVIOUS_THEME=$(jq -r '.previousTheme // empty' "$CONFIG" 2>/dev/null || echo "")

# The theme goes too, unless you say otherwise. It used to be kept -- it is a
# perfectly good theme on its own -- but "uninstall" that leaves a directory
# behind is not what anybody means by the word, and the widget button that
# calls this is labelled Uninstall, not Disable.
#
# Only --keep-theme modifies the run. Anything else -- including --help -- must
# never fall through into deleting things: `omarchy-matrix uninstall --help`
# reaches here, and printing usage is all it may do.
case "${1:-}" in
"" | --keep-theme) ;;
-h | --help)
  echo "Usage: $CLI uninstall [--keep-theme]"
  echo
  echo "Undoes the $DISPLAY_NAME pack and leaves Omarchy the way it was. The theme"
  echo "goes too, unless --keep-theme keeps it as an ordinary Omarchy theme."
  exit 0
  ;;
*)
  echo "$CLI uninstall: unknown option: $1 (use --keep-theme)" >&2
  exit 1
  ;;
esac
KEEP_THEME=0
[[ ${1:-} != "--keep-theme" ]] || KEEP_THEME=1

echo "· handing Omarchy's lock back"
lock_removed=0
for dir in "$PLUGINS_DIR"/*.lock; do
  lock_is_ours "$dir" || continue
  id=$(jq -r '.id' "$dir/manifest.json")
  # `plugin remove` is what re-enables omarchy.lock (cloneSourceRestores).
  # Deleting the directory by hand would leave the session with no lock enabled
  # at all.
  remove_plugin "$id"
  lock_removed=1
done

echo "· removing the rain plugin and the bar widget"
for id in "$PLUGIN_ID" "$WIDGET_ID"; do
  remove_plugin "$id"
done

# Up to 1.2.0 the pack switched Omarchy's screensaver off. If this install still
# holds that flag, hand it back. A flag that the user set stays (lib/pack.sh).
release_screensaver_flag

# The boot splash is the only piece that lives outside your home directory, so
# it is also the only one that would survive an uninstall unnoticed. It needs a
# password and rebuilds the initramfs, which is why it is asked for last.
current_plymouth=$(plymouth-set-default-theme 2>/dev/null) ||
  current_plymouth=$(sed -n 's/^Theme=//p' /etc/plymouth/plymouthd.conf 2>/dev/null)

# Two separate questions, and they used to be conflated. Handing the splash back
# is only needed when OURS is the live one. Deleting the folder is needed
# whenever the folder exists -- and it exists after any `boot off`, which is
# precisely the case the old `if` skipped, leaving the theme on disk forever.
if [[ ${current_plymouth:-} == "$PLYMOUTH_THEME" ]]; then
  echo "· handing the boot splash back (needs your password, rebuilds the initramfs)"
  omarchy-plymouth-reset ||
    echo "  skipped — undo it later with: omarchy plymouth reset" >&2
fi

# Asked again, AFTER the reset. Never before it: removing the folder of a theme
# that is still the default is how a machine boots to a black screen. Asked into
# a variable rather than through a pipe, because `set -o pipefail` plus grep's
# early exit can turn "still ours" into a zero and invert the test.
live_plymouth=$(plymouth-set-default-theme 2>/dev/null) || live_plymouth=""
if [[ -d "/usr/share/plymouth/themes/$PLYMOUTH_THEME" && ${live_plymouth:-} != "$PLYMOUTH_THEME" ]]; then
  echo "· removing the boot theme from /usr/share/plymouth (needs your password)"
  sudo rm -rf "/usr/share/plymouth/themes/$PLYMOUTH_THEME" ||
    echo "  skipped — remove it later with: sudo rm -rf /usr/share/plymouth/themes/$PLYMOUTH_THEME" >&2
fi

# `omarchy plugin remove` renames rather than deletes: every folder taken away
# above is still on disk as .<id>.bak.<timestamp>. Take ours back (in
# lib/pack.sh); a lock clone somebody made themselves stays.
echo "· removing the plugin backups the pack left behind"
prune_backups

echo "· removing hooks, the CLI and the share dir"
rm -f "$HOOKS/theme-set.d/$SLUG" "$HOOKS/post-update.d/$SLUG"
rm -f "$BIN_DIR/$CLI"
clean_legacy_bins
rm -f "$CONFIG"
# Where install.sh keeps the CLI, its python, provider.json and this script.
# Unlinking the running script is safe -- the open inode survives to the last
# line -- but truncating it is not, so never rewrite it here.
rm -rf "$SHARE_DIR"
# Where derive-plymouth.py --stage-only leaves a build for inspection.
rm -rf "$HOME/.cache/$CLI"

omarchy-shell shell rescanPlugins >/dev/null 2>&1 || true

# Handing the lock back swapped which plugin owns the `lock` IPC target, and a
# rescan does not unload the loser: the running shell can still hand the screen
# to the clone whose files this script just deleted. Only a restart settles
# that. restart_shell (in lib/pack.sh) lets the scan settle first -- a scan in
# flight when the shell goes down segfaults quickshell (#972), and the removals
# above are exactly that workload.
if ((lock_removed)); then
  echo "· restarting the shell so only Omarchy's lock is loaded"
  restart_shell || true
fi

# --- the theme itself ---------------------------------------------------------
# Last, and only now: everything above still needed the theme directory to be
# there. Deleting it while Omarchy still names it as the current theme leaves
# current/theme.name pointing at nothing, so step off it first.

if ((KEEP_THEME)); then
  cat <<DONE

Done. The theme was kept and works like any other Omarchy theme.

To remove that too:
  omarchy theme remove $SLUG
DONE
  exit 0
fi

theme_exists() {
  [[ -n ${1:-} ]] || return 1
  [[ -d "$HOME/.config/omarchy/themes/$1" || -d "/usr/share/omarchy/themes/$1" ]]
}

# Where to land. In order: the theme you were on before you picked this one,
# then whatever you say when there is a terminal to ask on, and only then the
# first stock theme -- which is alphabetical, which is why everyone who ever
# uninstalled this pack ended up on catppuccin.
step_off_target() {
  if theme_exists "$PREVIOUS_THEME"; then
    echo "$PREVIOUS_THEME"
    return
  fi

  local first reply
  first=$(find /usr/share/omarchy/themes -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort | head -1)

  # Not `-t 1`: this function is called from a command substitution, so its
  # stdout is a pipe by construction and would say "no terminal here" on a
  # machine that plainly has one. The prompt goes to stderr, so ask about that.
  if [[ -t 0 && -t 2 ]]; then
    echo >&2
    echo "  This theme is about to go. Which one do you want instead?" >&2
    find "$HOME/.config/omarchy/themes" /usr/share/omarchy/themes -mindepth 1 -maxdepth 1 -type d \
      -printf '%f\n' 2>/dev/null | grep -vx "$SLUG" | sort -u | column -c 74 | sed 's/^/  /' >&2
    printf '  [%s] ' "$first" >&2
    read -r reply || true
    reply=${reply// /}
    if theme_exists "$reply"; then
      echo "$reply"
      return
    fi
    [[ -z $reply ]] || printf '\n  no theme called %s; using %s\n' "'$reply'" "$first" >&2
  fi

  echo "$first"
}

if [[ $(cat "$HOME/.local/state/omarchy/current/theme.name" 2>/dev/null) == "$SLUG" ]]; then
  target=$(step_off_target)
  if [[ -n ${target:-} ]]; then
    echo "· stepping off the $SLUG theme onto $target"
    omarchy-theme-set "$target" >/dev/null 2>&1 || true
  fi
fi

echo "· removing the theme"
rm -rf "$THEME_DIR"
# Omarchy remembers a background per theme, and a hook of the user's may read it.
rm -f "$HOME/.local/state/omarchy/backgrounds/$SLUG"
rm -rf "$HOME/.config/omarchy/backgrounds/$SLUG"

cat <<DONE

Done. Nothing of the $DISPLAY_NAME pack is left, the theme included.

Omarchy's own lock, screensaver and boot splash are back.
DONE
