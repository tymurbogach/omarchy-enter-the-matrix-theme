#!/usr/bin/env bash
# Photograph every piece of the pack, for tools/generate-showcase.py.
#
#   ./tools/capture-showcase.sh [--out DIR] [--workspace N] [--only SCENES]
#
# SCENES is a comma-separated list. The default is all of them:
#
#   desktop      the rain alone, then Omarchy's About window over it
#   screensaver  the screensaver
#   lock         the lock preview
#   widget       the bar and the open widget panel
#   typing       a burst of frames while the boot lines type
#   dialog       the passphrase dots and the progress track
#   exits        the shutdown and reboot splashes
#
# One more scene runs only when --only names it:
#
#   update       the panel with its Update button, from a faked answer.
#                A check of the button, not a picture for the README
#
# It takes the screen over for two to four minutes. It applies the theme,
# turns on every piece and moves to an empty workspace. Keep your hands off
# the keyboard and the mouse while it runs: a key closes the screensaver, and
# a click can move the focus.
#
# On exit, also after a failure or Ctrl-C, it puts back what it found: the
# pack's settings, the theme, the background, the workspace and the idle
# setting.
#
# The boot splash comes from tools/preview-plymouth.sh, so no sudo is needed.
# No scenario can reach the passphrase dots or the progress track (see the
# trap about the doctored stage in CONTRIBUTING.md). So a probe, appended to a
# copy of the stage, calls the drawing code directly on every frame.

set -euo pipefail

SELF=$(basename "$0")
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(dirname "$HERE")
ALL_SCENES="desktop,screensaver,lock,widget,typing,dialog,exits"
KNOWN_SCENES="$ALL_SCENES,update"

die() {
  echo "$SELF: $*" >&2
  exit 1
}
say() {
  echo "· $*"
}

OUT="$PWD/showcase-shots"
WORKSPACE=8
SCENES=$ALL_SCENES
while [[ $# -gt 0 ]]; do
  case "$1" in
  --out) OUT=$2; shift 2 ;;
  --workspace) WORKSPACE=$2; shift 2 ;;
  --only) SCENES=$2; shift 2 ;;
  -h | --help) sed -n '2,/^set -euo/p' "$0" | sed 's/^# \?//;$d'; exit 0 ;;
  *) die "unknown option $1" ;;
  esac
done
for scene in ${SCENES//,/ }; do
  [[ ,$KNOWN_SCENES, == *",$scene,"* ]] || die "unknown scene $scene"
done

for tool in grim hyprctl jq magick omarchy-shell omarchy-launch-about; do
  command -v "$tool" >/dev/null || die "$tool is needed"
done
[[ -n ${WAYLAND_DISPLAY:-} ]] || die "run this from your desktop session"

provider() {
  jq -r "$1" "$ROOT/provider.json"
}
SLUG=$(provider .slug)
CLI=$(provider .cli)
IPC=$(provider .ipc)
WIDGET_ID=$(provider .widget.id)
PLYMOUTH_THEME=$(provider .plymouth.theme)
UPDATE_CACHE="$HOME/.cache/$CLI/update.json"
command -v "$CLI" >/dev/null || die "$CLI is not installed: install the pack first"

about_pids() {
  hyprctl clients -j | jq -r '.[] | select(.class == "org.omarchy.about") | .pid'
}

windows=$(hyprctl workspaces -j |
  jq --argjson w "$WORKSPACE" '[.[] | select(.id == $w) | .windows] | add // 0')
((windows == 0)) || die "workspace $WORKSPACE has $windows windows: pick an empty one with --workspace"
# The About window is closed by its class, so one of the user's own must not
# be open, or it would close too.
[[ -z $(about_pids) ]] || die "an About window is open: close it first"

mkdir -p "$OUT"
WORK=$(mktemp -d)

# --- what to put back ------------------------------------------------------

STATE="$HOME/.local/state/omarchy/current"
old_theme=$(cat "$STATE/theme.name")
old_background=$(readlink "$STATE/background")
old_workspace=$(hyprctl activeworkspace -j | jq .id)
# `enabled` answers "is Stay Awake on?", not "is idle allowed?".
old_awake=$(omarchy toggle idle status | jq -r .enabled)
old_settings=$("$CLI" status --json | jq -c .settings)

focus() {
  hyprctl dispatch "hl.dsp.focus({ workspace = \"$1\" })" >/dev/null
}

close_about() {
  local pid
  for pid in $(about_pids); do
    kill "$pid" 2>/dev/null
  done
}

restore() {
  set +e
  say "putting the machine back"
  close_about
  ((${FAKE_UPDATE:-0})) && rm -f "$UPDATE_CACHE"
  omarchy-shell "$IPC" screensaver stop >/dev/null 2>&1
  omarchy-shell lock hidePreview >/dev/null 2>&1
  local piece want now
  for piece in wallpaper screensaver lock widget; do
    want=$(jq -r --arg p "$piece" '.[$p]' <<<"$old_settings")
    now=$("$CLI" status --json | jq -r --arg p "$piece" '.settings[$p]')
    if [[ $want != "$now" ]]; then
      "$CLI" "$piece" "$([[ $want == true ]] && echo on || echo off)" >/dev/null
    fi
  done
  # The old background lives inside the staged theme, so it exists again
  # only after the old theme is back.
  [[ $old_theme == "$SLUG" ]] || omarchy theme set "$old_theme" >/dev/null
  [[ -f $old_background ]] && omarchy-theme-bg-set "$old_background" >/dev/null
  focus "$old_workspace"
  [[ $old_awake == true ]] || omarchy toggle idle allow-idle >/dev/null
  rm -rf "$WORK"
}
trap restore EXIT

# --- helpers ---------------------------------------------------------------

wait_for() { # <seconds> <command...>
  local limit=$1 i
  shift
  for ((i = 0; i < limit * 4; i++)); do
    "$@" >/dev/null 2>&1 && return 0
    sleep 0.25
  done
  return 1
}

shoot() {
  grim "$OUT/$1.png"
  say "$1.png"
}

pack_up() {
  "$CLI" status --json | jq -e '.pieces | .wallpaper and .screensaver and .lock and .widget'
}

shell_answers() {
  omarchy-shell "$IPC" status
}

about_open() {
  [[ -n $(about_pids) ]]
}

# --- the scenes ------------------------------------------------------------

scene_desktop() {
  shoot desktop-bare
  setsid -f omarchy-launch-about >/dev/null 2>&1
  wait_for 10 about_open || die "the About window did not open"
  sleep 4 # it resizes itself to fit fastfetch, at most twice
  shoot desktop
  close_about
  sleep 1
}

scene_screensaver() {
  omarchy-shell "$IPC" screensaver start >/dev/null
  sleep 6
  shoot screensaver
  omarchy-shell "$IPC" screensaver stop >/dev/null
  sleep 1
}

scene_lock() {
  omarchy-shell lock preview >/dev/null
  sleep 4
  shoot lock
  omarchy-shell lock hidePreview >/dev/null
  sleep 1
}

# A second summon does not close the panel. Only a shell restart does.
show_panel() { # <shot name>
  omarchy-restart-shell >/dev/null 2>&1
  wait_for 30 shell_answers || die "the shell did not come back"
  sleep 3
  omarchy-shell shell summon "$WIDGET_ID" >/dev/null
  sleep 2
  shoot "$1"
  omarchy-restart-shell >/dev/null 2>&1
  wait_for 30 shell_answers || die "the shell did not come back"
  sleep 3
}

scene_widget() {
  show_panel widget
}

# The Update button shows only when a newer version is out, so this scene
# fakes that answer: a test entry in the CLI's cache, keyed on the current
# commit, that says 9.9.9 is out. It is for checking the button, never for the
# README. The scene deletes the entry, and so does restore().
FAKE_UPDATE=0
scene_update() {
  local head
  head=$(git -C "$(omarchy-theme-dir "$SLUG")" rev-parse HEAD) ||
    die "the theme folder is not a git clone, so there is no update to fake"
  mkdir -p "${UPDATE_CACHE%/*}"
  FAKE_UPDATE=1
  jq -nc --arg head "$head" --argjson checked "$(date +%s)" \
    '{schema: 1, current: "", latest: "9.9.9", available: true, head: $head, checked: $checked}' \
    >"$UPDATE_CACHE"
  show_panel widget-update
  rm -f "$UPDATE_CACHE"
  FAKE_UPDATE=0
}

# The splash window is translucent where the splash paints nothing. A flat
# background in the splash's own colour makes that invisible.
SPLASH_READY=0
prepare_splash() {
  ((SPLASH_READY)) && return
  local void
  void=$(sed -n 's/^background *= *"\(#[0-9A-Fa-f]\{6\}\)".*/\1/p' "$ROOT/colors.toml")
  magick -size 64x64 "xc:$void" "$WORK/void.png"
  omarchy-theme-bg-set "$WORK/void.png" >/dev/null
  sleep 2
  python3 "$ROOT/lib/derive-plymouth.py" --stage-only >/dev/null ||
    die "cannot stage the boot splash"
  SPLASH_READY=1
}

preview() { # <scenario> [preview-plymouth options]
  "$HERE/preview-plymouth.sh" "$@" --out "$OUT" >"$WORK/preview.log" 2>&1 || {
    tail -20 "$WORK/preview.log" >&2
    die "the splash preview failed"
  }
}

scenario() { # <shot name> <seconds>
  printf 'pause %s\nshot %s\n' "$2" "$1" >"$WORK/$1.sh"
  echo "$WORK/$1.sh"
}

# The boot lines type for about 22 s (derive-plymouth.py prints the time), and
# each line replaces the one before it. A burst over the whole run lets the
# picture be chosen afterwards, with the cursor half way through a line.
scene_typing() {
  prepare_splash
  local i
  for i in $(seq -w 1 32); do
    printf 'pause 0.7\nshot boot-typing-%s\n' "$i"
  done >"$WORK/typing.sh"
  preview "$WORK/typing.sh"
  say "boot-typing-*.png"
}

probe() { # <name> <statements run on every frame>
  cp -r "$HOME/.cache/$CLI/plymouth" "$WORK/$1"
  cat >>"$WORK/$1/$PLYMOUTH_THEME.script" <<EOF

# --- showcase probe, appended by $SELF to a copy of the stage ---
global.mx_showcase_after = 0;
fun mx_showcase_quiet(duration, progress) { }
Plymouth.SetBootProgressFunction(mx_showcase_quiet);
fun mx_showcase_refresh() {
  refresh_callback();
  $2
}
Plymouth.SetRefreshFunction(mx_showcase_refresh);
EOF
}

# The accepted password plays the real order once the lines are typed: the
# dots, then ACCESS GRANTED in the box for GRANTED_HOLD frames, then the track
# in a box of its own. An earlier probe called mx_bar_show() directly: the
# track came up, but the box did not, and the picture showed a splash that no
# boot ever shows. The burst catches both states, and the pictures are chosen
# afterwards, the same way as for the typed lines.
scene_dialog() {
  prepare_splash
  probe password 'mx_password_callback("", 9);'
  probe accepted 'if (global.mx_step >= global.mx_end) {
    global.mx_showcase_after = global.mx_showcase_after + 1;
    if (global.mx_showcase_after == 1) mx_password_callback("", 9);
    if (global.mx_showcase_after == 25) mx_normal_callback();
  }
  mx_progress(0.62);'
  preview "$(scenario boot-password 24)" --stage "$WORK/password"
  say "boot-password.png"
  local i
  {
    echo "pause 22"
    for i in $(seq -w 1 20); do
      printf 'shot boot-accepted-%s\npause 0.4\n' "$i"
    done
  } >"$WORK/accepted.sh"
  preview "$WORK/accepted.sh" --stage "$WORK/accepted"
  say "boot-accepted-*.png"
}

scene_exits() {
  prepare_splash
  preview "$(scenario shutdown 7)" --mode shutdown
  say "shutdown.png"
  preview "$(scenario reboot 7)" --mode reboot
  say "reboot.png"
}

# --- run -------------------------------------------------------------------

say "staying awake while this runs"
omarchy toggle idle stay-awake >/dev/null

if [[ $old_theme != "$SLUG" ]]; then
  say "applying $SLUG"
  omarchy theme set "$SLUG" >/dev/null
fi
for piece in wallpaper screensaver lock widget; do
  "$CLI" "$piece" on >/dev/null
done
wait_for 60 pack_up || die "the pack did not come up: $("$CLI" status)"
wait_for 30 shell_answers || die "the rain service does not answer"
sleep 3 # the theme transition fades for about a second

focus "$WORKSPACE"
sleep 2
for scene in ${SCENES//,/ }; do
  "scene_$scene"
done

say "done: $OUT"
