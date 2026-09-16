#!/usr/bin/env bash
# Run the boot splash in a window, on this machine, and photograph it.
#
# The boot splash used to be the one piece of the pack that could not be
# checked without rebooting, so the docs said as much and every change to it
# went out on faith. It does not have to be that way.
#
# `plymouthd` ships an X11 renderer (/usr/lib/plymouth/renderers/x11.so). Point
# it at Xwayland and it draws the real splash -- the real script, the real
# callbacks, the real password dialog -- into an ordinary window that `grim`
# can capture. Everything it needs that normally belongs to root is faked
# inside a user namespace, so this needs NO sudo and cannot touch the machine's
# actual boot:
#
#   * `unshare -rm` gives us a private mount table and a uid mapped to root
#   * a tmpfs over /run gives plymouthd the /run/plymouth it insists on
#     (the compositor's own sockets under /run/user are bound back in, or grim
#     and hyprctl would have nothing to talk to)
#   * the theme under test is copied into /run/plymouth/themes/, which plymouthd
#     looks in BEFORE /usr/share/plymouth/themes/ -- so a staged, uninstalled
#     theme previews without being installed
#
# ONE deliberate lie, and it is worth knowing about: the two absolute paths in
# the .plymouth file (ImageDir, ScriptFile) are rewritten to point at the
# preview copy. The .script -- the thing actually being designed -- is used
# byte for byte.
#
# By default the preview also HIDES label-pango.so, because the initramfs never
# contains it: the mkinitcpio hook copies label-freetype.so, and that one
# resolves font families by shelling out to fc-match, which is not in the
# initramfs either. Previewing with pango would flatter the design with font
# fallbacks and line breaking that the real boot does not have. Pass --pango to
# see the difference.
#
#   ./tools/preview-plymouth.sh scenario.sh [--out DIR] [--theme NAME]
#                             [--stage DIR] [--mode NAME] [--pango] [--keep]
#
# --mode is what plymouthd is started with, and therefore what the theme's
# `Plymouth.GetMode()` reports: `boot` (the default), `shutdown` or `reboot`.
# It is the only way to see the exit splashes without actually turning the
# machine off. NOTE that `halt`, `poweroff` and `kexec` are NOT modes of their
# own -- all three units start plymouthd with --mode=shutdown.
#
# The scenario is a bash file run inside the sandbox, once the splash is up.
# Two helpers are in scope:
#
#   shot <name>     photograph the splash into <out>/<name>.png
#   pause <seconds> wait (fractional seconds are fine)
#   send <text>     type into the splash, down its own pty
#   press <key>     Return, BackSpace, Escape or Tab
#
# and `plymouth` is the real client, so a scenario reads like a boot:
#
#   shot 01-splash
#   plymouth ask-for-password --prompt "Enter passphrase" &
#   pause 1; shot 02-prompt
#   send "hunter2"; shot 03-typed
#
# What this CANNOT tell you:
#
#   * whether mkinitcpio actually put the theme in the initramfs, and whether
#     the DRM renderer agrees with the X11 one about the panel. Those still
#     need a reboot.
#   * what is under the bar. Omarchy's bar is a layer-shell surface on the
#     `top` level, which Hyprland draws above windows -- fullscreen ones
#     included -- so the first ~30 logical pixels of every shot are the bar,
#     not the splash. Nothing of the splash is lost, it is simply covered:
#     leave that strip out of any layout you judge from these images.
#   * whether Plymouth counts your keystrokes into bullets. plymouthd watches
#     the RENDERER for keys ("Watching for keyboard input from renderer" in the
#     log), not the terminal, so `send` reaches a shell prompt but not the
#     password dialog. Drive the theme's own password callback directly to
#     photograph a half-typed passphrase.
#   * anything to do with modifier STATE, Plymouth.GetCapslockState() included:
#     a pty has no modifiers.
#   * real seconds. derive-plymouth.py's typing pace assumes omarchy.script's
#     50 fps refresh; this X11 window is not vsync-capped to it, and the
#     script's own frame counter (mx_frame) has been measured advancing at
#     upwards of 100+ steps a real second here even on a 60Hz panel -- 2x or
#     more faster than the design math. A step table timed at N design
#     seconds can finish typing in well under N real seconds in this preview.
#     Judge TEXT and MOTION here (does it read as typing, does a line clip);
#     judge SECONDS only from a real boot/shutdown/reboot, timed by eye.
#   * a clean black backdrop. The X11 window is drawn with an alpha channel,
#     so wherever the splash paints nothing the desktop behind it shows
#     faintly through -- and grim photographs what the compositor composited,
#     so no amount of flattening afterwards takes it back out. Hyprland 0.56
#     offers no way to aim a workspace or fullscreen dispatch at this window,
#     and reaching into a live session to tidy a screenshot is not worth it.
#     Run from an empty workspace if it matters.

set -euo pipefail

SELF=$(basename "$0")
HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

die() {
  echo "$SELF: $*" >&2
  exit 1
}

# --- stage 1: on the host ---------------------------------------------------

if [[ ${MX_PREVIEW_STAGE:-} != inner ]]; then
  SCENARIO=""
  OUT="$PWD/plymouth-preview"
  THEME=""
  STAGE=""
  MODE=boot
  LABEL=freetype
  KEEP=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
    --out) OUT=$2; shift 2 ;;
    --theme) THEME=$2; shift 2 ;;
    --stage) STAGE=$2; shift 2 ;;
    --mode) MODE=$2; shift 2 ;;
    --pango) LABEL=pango; shift ;;
    --keep) KEEP=1; shift ;;
    -h | --help) sed -n '2,/^set -euo/p' "$0" | sed 's/^# \?//;$d'; exit 0 ;;
    -*) die "unknown option $1" ;;
    *) SCENARIO=$1; shift ;;
    esac
  done

  [[ -n $SCENARIO ]] || die "no scenario given. See --help."
  [[ -f $SCENARIO ]] || die "no such scenario: $SCENARIO"
  case "$MODE" in
  boot | shutdown | reboot | updates | system-upgrade | firmware-upgrade) ;;
  *) die "unknown --mode $MODE (boot, shutdown, reboot, updates, system-upgrade, firmware-upgrade)" ;;
  esac
  command -v grim >/dev/null || die "grim is needed to photograph the splash"
  command -v unshare >/dev/null || die "unshare is needed (util-linux)"
  [[ -n ${WAYLAND_DISPLAY:-} ]] || die "no WAYLAND_DISPLAY: run this from your desktop session"
  [[ -n ${DISPLAY:-} ]] || die "no DISPLAY: plymouth's X11 renderer needs Xwayland"

  # The theme name, and where its files come from. Default: whatever the
  # provider calls its Plymouth theme, staged but not installed. Read from the
  # repo beside this script -- never from the installed share copy, which may
  # belong to another version.
  if [[ -z $THEME ]]; then
    THEME=$(python3 -c "
import json, pathlib, sys
p = pathlib.Path('$HERE').parent / 'provider.json'
if p.is_file():
    print(json.loads(p.read_text())['plymouth']['theme']); sys.exit()
sys.exit('cannot find provider.json')
") || die "cannot work out the theme name; pass --theme"
  fi
  if [[ -z $STAGE ]]; then
    for candidate in "$HOME/.cache/omarchy-matrix/plymouth" \
      "/usr/share/plymouth/themes/$THEME"; do
      [[ -d $candidate ]] && { STAGE=$candidate; break; }
    done
  fi
  [[ -n $STAGE && -d $STAGE ]] ||
    die "nothing to preview: stage a theme first with 'derive-plymouth.py --stage-only'"
  [[ -f $STAGE/$THEME.plymouth ]] ||
    die "$STAGE holds no $THEME.plymouth"

  # Resolve the theme's fonts the way /usr/lib/initcpio/install/plymouth does:
  # take Font= and MonospaceFont= out of the .plymouth, drop the trailing point
  # size, and ask fc-match for the file. Inside the sandbox those three files
  # become the ONLY fonts there are, under the fixed names label-freetype falls
  # back to. Getting this wrong is not cosmetic -- plymouthd segfaults outright
  # when it can resolve no font at all.
  font_file() {
    local key=$1 fallback=$2 name
    name=$(sed -n "s/^ *$key *= *//p" "$STAGE/$THEME.plymouth" | sed 's/ [0-9]\+ *$//')
    [[ -n $name ]] || name=$fallback
    fc-match -f '%{file}' "$name"
  }
  FONT_MAIN=$(font_file Font sans-serif)
  FONT_MONO=$(font_file MonospaceFont monospace)
  FONT_MONO_BOLD=$(fc-match -f '%{file}' "$(fc-match -f '%{family}' "$FONT_MONO" | sed 's/,.*//'):weight=bold")

  mkdir -p "$OUT"
  echo "$SELF: previewing $THEME"
  echo "  from    $STAGE"
  echo "  shots   $OUT"
  echo "  mode    $MODE"
  echo "  labels  $LABEL$([[ $LABEL == freetype ]] && echo "  (as the initramfs has it)")"
  echo "  font    $(basename "$FONT_MAIN"), mono $(basename "$FONT_MONO")"

  exec unshare --user --map-root-user --mount --propagation private \
    env MX_PREVIEW_STAGE=inner \
    MX_THEME="$THEME" MX_STAGE="$STAGE" MX_OUT="$OUT" \
    MX_LABEL="$LABEL" MX_KEEP="$KEEP" MX_MODE="$MODE" \
    MX_SCENARIO="$(realpath "$SCENARIO")" \
    MX_FONT_MAIN="$FONT_MAIN" MX_FONT_MONO="$FONT_MONO" \
    MX_FONT_MONO_BOLD="$FONT_MONO_BOLD" \
    bash "$0"
fi

# --- stage 2: inside the sandbox --------------------------------------------

THEME=$MX_THEME
STAGE=$MX_STAGE
OUT=$MX_OUT
MODE=$MX_MODE
SCENARIO=$MX_SCENARIO

# /run is about to be replaced wholesale, and the compositor's sockets live
# under it. Park them somewhere outside /run first, then bind them back.
RUNTIME=${XDG_RUNTIME_DIR:-/run/user/$(id -u)}
WORK=$(mktemp -d /tmp/.plymouth-preview.XXXXXX)   # our own scratch, never /run's
PARK=$WORK/runtime                                # where the sockets wait
mkdir -p "$PARK"
# --rbind, not --bind: the runtime dir has submounts of its own, and a
# plain bind refuses it.
mount --rbind "$RUNTIME" "$PARK"
mount -t tmpfs tmpfs /run
mkdir -p "$RUNTIME" /run/plymouth/themes
mount --rbind "$PARK" "$RUNTIME"

# Make the text stack match the initramfs, which is stricter than this machine
# in three separate ways:
#
#   1. no label-pango.so -- the mkinitcpio hook copies label-freetype.so only
#   2. no fc-match -- and label-freetype resolves a font FAMILY by shelling out
#      to /usr/bin/fc-match. With it gone, every per-call family is ignored and
#      the request falls back to a fixed path instead
#   3. /usr/share/fonts holds exactly three files, the ones the hook put there
#
# All three matter, and the third one bites hardest: label-freetype's fallback
# path is /usr/share/fonts/Plymouth.ttf, which exists ONLY inside the initramfs.
# Take away fc-match without providing it and plymouthd does not fall back --
# it segfaults, because nothing checks that FT_New_Face found a file.
#
# Number 2 is the quiet one. Leave fc-match in place and a per-call family like
# "DejaVu Serif 30" renders as a serif here and silently comes out as the
# theme's mono font at boot, with nothing to warn you.
if [[ $MX_LABEL == freetype ]]; then
  : >"$WORK/nothing"
  mount --bind "$WORK/nothing" /usr/lib/plymouth/label-pango.so

  mkdir -p "$WORK/fonts"
  cp "$MX_FONT_MAIN" "$WORK/fonts/Plymouth.ttf"
  cp "$MX_FONT_MONO" "$WORK/fonts/Plymouth-monospace.ttf"
  cp "$MX_FONT_MONO_BOLD" "$WORK/fonts/Plymouth-monospace-bold.ttf"
  mount -t tmpfs tmpfs /usr/share/fonts
  cp "$WORK/fonts/." /usr/share/fonts/ -a

  mount --bind "$WORK/nothing" /usr/bin/fc-match
fi

# The theme under test, where plymouthd looks before /usr/share.
# --no-preserve=ownership, or previewing the INSTALLED theme fails: those files
# belong to real root, which is not mapped into this namespace, so `cp -a` warns
# on every one of them and exits non-zero. Previewing what is actually on the
# machine is the whole point right before a reboot, so it must not be the case
# that breaks.
cp -r --no-preserve=mode,ownership "$STAGE" "/run/plymouth/themes/$THEME"
chmod -R u+w "/run/plymouth/themes/$THEME"
sed -i -e "s|^ImageDir=.*|ImageDir=/run/plymouth/themes/$THEME|" \
  -e "s|^ScriptFile=.*|ScriptFile=/run/plymouth/themes/$THEME/$THEME.script|" \
  "/run/plymouth/themes/$THEME/$THEME.plymouth"

# Which theme to show. plymouthd reads this before anything else.
mkdir -p "$WORK/etc"
printf '[Daemon]\nTheme=%s\n' "$THEME" >"$WORK/etc/plymouthd.conf"
mount --bind "$WORK/etc/plymouthd.conf" /etc/plymouth/plymouthd.conf

# plymouthd wants a terminal it can open; /dev/null is not one, and it stops
# dead on it. Hand it a pty -- and then KEEP READING the master end.
#
# plymouthd sends its trace to the terminal (it says so: "redirecting debug
# output to /dev/pts/N", and it does that even with --debug-file). A pty whose
# buffer nobody drains blocks the writer, so the daemon simply stops, part way
# through, with no error printed anywhere. That drained trace is the only place
# a .script syntax error ever shows up, so it is kept rather than thrown away.
python3 - "$WORK/tty" "$WORK/plymouthd.log" "$WORK/keys" <<'PYEOF' &
import ctypes, os, pty, select, sys, time

# Die with the harness. Without this, a killed run (a timeout, a Ctrl-C in the
# wrong place) leaves this helper holding a pty forever.
ctypes.CDLL("libc.so.6", use_errno=True).prctl(1, 9, 0, 0, 0)  # PR_SET_PDEATHSIG, SIGKILL

tty_path, log_path, keys_path = sys.argv[1:4]
master, slave = pty.openpty()
with open(tty_path, "w") as handle:
    handle.write(os.ttyname(slave))

log = open(log_path, "ab", buffering=0)
while True:
    # Drain the trace, or plymouthd blocks on a full pty and simply stops.
    ready, _, _ = select.select([master], [], [], 0.05)
    if ready:
        try:
            chunk = os.read(master, 65536)
        except OSError:
            break
        if not chunk:
            break
        log.write(chunk)
    # And carry keystrokes the other way. plymouthd listens on its terminal as
    # well as on the renderer, so this is a keyboard the compositor knows
    # nothing about -- which is the point: it cannot land anywhere else.
    if os.path.exists(keys_path):
        try:
            with open(keys_path, "rb") as pending:
                data = pending.read()
            os.unlink(keys_path)
            if data:
                os.write(master, data)
        except OSError:
            pass
PYEOF
PTY_HELPER=$!
for _ in $(seq 1 100); do [[ -s $WORK/tty ]] && break; sleep 0.05; done
[[ -s $WORK/tty ]] || die "could not allocate a pty for plymouthd"
TTY=$(cat "$WORK/tty")

cleanup() {
  plymouth --quit 2>/dev/null || true
  kill "$PLYMOUTHD" "$PTY_HELPER" 2>/dev/null || true
  wait "$PLYMOUTHD" 2>/dev/null || true
  # The daemon's trace dies with the sandbox, and it is the ONLY place a
  # .script error is ever reported -- the splash just quietly draws less than
  # it should. Keep it next to the shots it explains.
  cp "$WORK/plymouthd.log" "$OUT/plymouthd.log" 2>/dev/null || true
}

export DISPLAY=${DISPLAY:-:0}
plymouthd --no-daemon --debug --debug-file="$WORK/plymouthd.log" \
  --mode="$MODE" --tty="$TTY" &
PLYMOUTHD=$!
trap cleanup EXIT

for _ in $(seq 1 100); do
  plymouth --ping 2>/dev/null && break
  sleep 0.1
done
plymouth --ping 2>/dev/null || {
  tail -20 "$WORK/plymouthd.log" 2>/dev/null >&2
  die "plymouthd never came up"
}

plymouth --show-splash

# Wait for the splash window, then take the screen over with it.
#
# grim photographs a REGION OF THE SCREEN, not a window: aiming it at the
# window's rectangle gives you whatever happens to be stacked on top there,
# which the first time round was the terminal that launched this. Fullscreen
# fixes both halves of that -- Hyprland raises the window above the bar's
# layer-shell surface as well as above other clients -- and since the X11
# renderer already sized the window to the whole monitor, going fullscreen does
# not resize it. So the shot is the monitor, at its native resolution, showing
# nothing but the splash: exactly the framing a boot has.
window_address() {
  hyprctl clients -j 2>/dev/null | python3 -c "
import json, sys
for c in json.load(sys.stdin):
    if c.get('class', '').lower().startswith('plymouth'):
        print(c['address'])
        break
" 2>/dev/null
}

ADDRESS=""
for _ in $(seq 1 100); do
  ADDRESS=$(window_address)
  [[ -n $ADDRESS ]] && break
  sleep 0.1
done
[[ -n $ADDRESS ]] || die "the splash window never appeared"

GEOMETRY=$(hyprctl clients -j 2>/dev/null | python3 -c "
import json, sys
for c in json.load(sys.stdin):
    if c['address'] == '$ADDRESS':
        print('%d,%d %dx%d' % (c['at'][0], c['at'][1], c['size'][0], c['size'][1]))
        break
") || die "cannot work out where the splash window is"

# This deliberately does NOT try to focus, fullscreen or move the window.
#
# Hyprland 0.56 took its dispatchers to a Lua API, and none of the forms it
# accepts can be aimed at this window: `hl.dsp.focus` wants a direction,
# `hl.dsp.window.fullscreen()` acts on whatever IS focused -- which is the
# user's own window, so "make the splash fullscreen" quietly fullscreened their
# terminal instead. Reaching into someone's live session to tidy up a
# screenshot is not worth it. Two consequences, both documented at the top:
# the bar overlays the first strip, and the window's black is transparent.
sleep 0.3

# --- what a scenario gets ---------------------------------------------------

shot() {
  local name=${1:?shot needs a name}
  grim -g "$GEOMETRY" "$OUT/$name.png" >/dev/null 2>&1 || {
    echo "$SELF: could not photograph $name" >&2
    return
  }
  echo "  · $name.png"
}

pause() {
  sleep "${1:-0.5}"
}

# Keystrokes go down the pty, not through the compositor.
#
# The obvious route was wtype, and it is the wrong one twice over. Hyprland
# never gives the splash window keyboard focus -- plymouthd's X11 window does
# not ask for it -- so the keys go wherever the user was working instead. That
# is not a flaky test, it is typing a passphrase and its Return into somebody's
# editor, and it happened here before this was rewritten.
#
# plymouthd also reads its terminal, and the master end of that pty belongs to
# this script. Writing there is a keyboard nothing else on the machine can see.
send() {
  printf '%s' "$1" >"$WORK/keys.tmp"
  mv "$WORK/keys.tmp" "$WORK/keys"
  sleep 0.5
}

# Named keys, by the bytes a terminal actually sends for them.
press() {
  case "$1" in
  Return | Enter) send $'\r' ;;
  BackSpace) send $'\177' ;;
  Escape) send $'\033' ;;
  Tab) send $'\t' ;;
  *) die "press: I only know Return, BackSpace, Escape and Tab down a pty.
  Caps Lock and other modifiers are keyboard STATE, which a terminal has none
  of -- Plymouth.GetCapslockState() cannot be exercised this way." ;;
  esac
}

echo "$SELF: running $(basename "$SCENARIO")"
# shellcheck disable=SC1090
source "$SCENARIO"

if [[ $MX_KEEP == 1 ]]; then
  echo "$SELF: --keep: leaving the splash up. Ctrl-C to finish."
  wait "$PLYMOUTHD"
fi

echo "$SELF: done. Shots in $OUT"
