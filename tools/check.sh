#!/usr/bin/env bash
# tools/check.sh -- the cheap checks and the coherence checks. No Omarchy
# session needed: what needs the real session (screenshots, toggles, the boot
# preview) lives in CONTRIBUTING.md's clean-room test instead.
#
#   ./tools/check.sh
#
# Docker is used for exactly one thing: shellcheck, when it is not installed
# on the host. Everything else runs here.

set -euo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(dirname "$HERE")

failures=0
fail() {
  echo "  FAIL: $*" >&2
  failures=$((failures + 1))
}
section() {
  echo "· $*"
}

# --- shell ---------------------------------------------------------------

check_shell() { # <files...>
  section "bash -n and shellcheck"
  local f
  for f in "$@"; do
    bash -n "$f" || fail "bash -n: $f"
  done
  if command -v shellcheck >/dev/null 2>&1; then
    shellcheck -S warning "$@" || fail "shellcheck"
  elif command -v docker >/dev/null 2>&1; then
    docker run --rm -v "$ROOT:$ROOT" -w "$ROOT" koalaman/shellcheck:stable \
      -S warning "$@" || fail "shellcheck (docker)"
  else
    fail "neither shellcheck nor docker is available"
  fi
}

# --- python --------------------------------------------------------------

check_python() { # <files...>
  section "python compile (pycache kept out of the tree)"
  local cache
  cache=$(mktemp -d)
  PYTHONPYCACHEPREFIX="$cache" python3 -m py_compile "$@" || fail "py_compile"
  rm -rf "$cache"
}

# --- QML -----------------------------------------------------------------

check_qml() { # <files...>
  section "qmllint"
  local omarchy="${OMARCHY_PATH:-/usr/share/omarchy}" lint=""
  # The pack is Qt6 QML (typed function signatures and all). A Qt5 qmllint --
  # still the one on PATH on some machines -- dies silently on that syntax,
  # so only a 6.x binary counts.
  for candidate in qmllint /usr/lib/qt6/bin/qmllint; do
    if command -v "$candidate" >/dev/null 2>&1 &&
       [[ $("$candidate" --version 2>/dev/null) == *" 6."* ]]; then
      lint="$candidate"
      break
    fi
  done
  if [[ -z $lint ]]; then
    echo "  skip: no Qt6 qmllint installed" >&2
    return 0
  fi
  "$lint" -I "$omarchy/shell" "$@" || fail "qmllint"
}

# --- plugin validation ----------------------------------------------------

check_validate() { # <dir>
  section "omarchy-plugin-validate $1"
  if ! command -v omarchy-plugin-validate >/dev/null 2>&1; then
    fail "omarchy-plugin-validate is not installed"
    return 0
  fi
  omarchy-plugin-validate "$1" >/dev/null || fail "plugin validation"
}

# --- coherence: main repo --------------------------------------------------

check_main_coherence() {
  section "coherence with provider.json"
  if python3 - "$ROOT" <<'PY'
import hashlib, json, pathlib, re, sys
root = pathlib.Path(sys.argv[1])
errors = []
def bad(message):
    errors.append(message)
provider = json.loads((root / "provider.json").read_text())
slug, cli = provider["slug"], provider["cli"]
service = (root / "Service.qml").read_text()
manifest = json.loads((root / "manifest.json").read_text())
cli = (root / "bin" / "omarchy-matrix").read_text()
plymouth = (root / "lib" / "derive-plymouth.py").read_text()
# No switches: Omarchy's own choices decide every piece. Up to 1.2.x a settings
# file and a bar widget of the pack's own duplicated them.
if re.search(r'\.config/omarchy/[^"]*\.json', service):
    bad("Service.qml reads a settings file: the rain must follow Omarchy's choices")
if "read_setting" in cli or "write_setting" in cli:
    bad("bin/omarchy-matrix keeps settings: the pieces follow Omarchy's choices")
if "widget" in provider:
    bad("provider.json names a widget: the pack has none since 1.3")
# The IPC target the service registers is the provider's ipc.
m = re.search(r'target:\s*"([^"]+)"', service)
if not m or m.group(1) != provider["ipc"]:
    bad(f"Service.qml IPC target is {m.group(1) if m else 'missing'}, want {provider['ipc']}")
# The manifest is the provider's plugin.
if manifest.get("id") != provider["plugin"]["id"]:
    bad(f"manifest id is {manifest.get('id')}, want {provider['plugin']['id']}")
for kind, path in manifest.get("entryPoints", {}).items():
    if not (root / path).is_file():
        bad(f"entryPoint {kind} points at missing {path}")
plugindir = root / provider["plugin"]["dir"]
for name in provider["plugin"]["files"]:
    if not (plugindir / name).is_file():
        bad(f"plugin file missing: {name}")
# The rain's background: a file of its own, marked by -live-, and never in the
# carousel as well. There, the theme alone would offer a still that never moves,
# and the pack would list the rain twice.
live = provider.get("liveBackground", "")
if "-live-" not in pathlib.Path(live).name:
    bad(f"liveBackground is {live!r}, want a file name with -live- in it")
elif not (root / live).is_file():
    bad(f"liveBackground {live} is missing")
stray = sorted(p.name for p in (root / "backgrounds").glob("*-live-*"))
if stray:
    bad(f"backgrounds/ holds {stray}: the rain's still goes in liveBackground only")
# The still is the thumbnail, the marker and what the desktop shows during the
# one-second lead-in, so it must stay a 16:10 superset in the live palette.
import struct
try:
    with open(root / live, "rb") as fh:
        header = fh.read(24)
    if header[12:16] != b"IHDR":
        bad(f"liveBackground {live} is not a PNG")
    elif struct.unpack(">II", header[16:24]) != (3840, 2400):
        bad(f"liveBackground {live} is not 3840x2400")
except OSError:
    pass
# Keep the curated carousel free of byte-identical copies. A duplicate makes
# the background menu longer without offering another scene.
backgrounds = root / "backgrounds"
for name in ("11-falling-code.jpg", "12-mono-rain.jpg", "13-after-hours.jpg"):
    if not (backgrounds / name).is_file():
        bad(f"curated background is missing: {name}")
seen_backgrounds = {}
for image in sorted(backgrounds.glob("*")):
    if not image.is_file():
        continue
    digest = hashlib.sha256(image.read_bytes()).hexdigest()
    other = seen_backgrounds.get(digest)
    if other:
        bad(f"duplicate background: {other.name} and {image.name}")
    else:
        seen_backgrounds[digest] = image
# License: the manifest says MIT and the file to back it is there.
if manifest.get("license") != "MIT":
    bad(f"manifest license is {manifest.get('license')!r}, want 'MIT'")
if not (root / "LICENSE").is_file():
    bad("LICENSE is missing")
# The update pulls from a URL written out in the CLI, not read from the
# provider: see the updates section of bin/omarchy-matrix for why. It must stay
# the provider's own repository.
urls = re.findall(r'git -C "\$dir" (?:fetch --quiet|pull --ff-only) (\S+) ', cli)
if len(urls) != 2 or set(urls) != {provider["repoUrl"]}:
    bad(f"the update URLs in bin/omarchy-matrix are {urls}, want {provider['repoUrl']} twice")
# The rain covers Omarchy's screensaver and never decides when it runs. A
# third-party service gets a scoped shell that cannot see Stay Awake, the idle
# timings or the lock. Up to 1.2.0 each of these left the pack with no
# screensaver at all, while every check here passed.
for needle in ("IdleMonitor", "firstPartyServiceFor", "shellConfig", "_services"):
    if needle in service:
        bad(f"Service.qml uses {needle}: the rain must follow Omarchy's screensaver, not decide on its own")
if '"org.omarchy.screensaver"' not in service:
    bad("Service.qml does not follow Omarchy's screensaver window (org.omarchy.screensaver)")
if "omarchy-toggle screensaver-off on" in cli:
    bad("bin/omarchy-matrix switches Omarchy's screensaver off: that flag belongs to the user")
# The backlight hook is a complete, removable initramfs layer. It must run
# before Plymouth and its generated config must survive into the active theme.
for path in (
    root / "initcpio/hooks/omarchy-matrix-backlight",
    root / "initcpio/install/omarchy-matrix-backlight",
    root / "initcpio/99-omarchy-matrix-backlight.conf",
):
    if not path.is_file():
        bad(f"early backlight source is missing: {path.relative_to(root)}")
initcpio_config = (root / "initcpio/99-omarchy-matrix-backlight.conf").read_text()
if 'omarchy-matrix-backlight' not in initcpio_config or 'plymouth' not in initcpio_config:
    bad("the early backlight hook is not ordered before Plymouth")
for needle in (
    'BOOT_BACKGROUND_HEX = "000000"',
    'CRT_VIGNETTE_OPACITY = 0.08',
    'CAPS_POLL_FRAMES = 10',
    'crt-vignette.png',
    'PANEL_ROW_CENTER = 0.57',
    'mx_vignette.image.Scale(global.mx_w, global.mx_h)',
    'write_early_backlight_config',
    'install_early_backlight',
):
    if needle not in plymouth:
        bad(f"derive-plymouth.py is missing {needle!r}")
for needle in ('crt-phosphor', 'apply_phosphor', 'crt-scanline', 'CRT_SCANLINE'):
    if needle in plymouth:
        bad(f"derive-plymouth.py keeps removed CRT texture code ({needle})")
rain = (root / "MatrixRain.qml").read_text()
for needle in (
    'property int startDelayMs: 1000',
    'property bool delayingStart: false',
    'now - root.lastFrameAt >= root.suspendGapMs',
    'root.restart()\n        return',
    'Component.onCompleted: if (root.running',
    'visible: !root.delayingStart',
):
    if needle not in rain:
        bad(f"MatrixRain.qml does not preserve the delayed restart ({needle!r})")
if service.count('startDelayMs: 1000') < 2 or 'startDelayMs: 0' in service:
    bad("Service.qml does not hold the desktop and the screensaver for one second each")
if service.count('onRunningChanged: if (running) restart()') < 2:
    bad("Service.qml does not restart the hold once running is true (desktop and screensaver)")
for needle in ('UPower', 'windowsHere'):
    if needle in service:
        bad(f"Service.qml keeps a battery brake ({needle}): the rain runs always")
# Both rain panels are black: while the shader hides during the one-second
# hold, a transparent panel would show Omarchy's still instead of black.
if service.count('color: "black"') < 2:
    bad('Service.qml does not hold black behind the desktop and the screensaver')
lock_deriver = (root / "lib/derive-lock.py").read_text()
for needle in ('startDelayMs: 1000', 'onRunningChanged: if (running) restart()'):
    if needle not in lock_deriver:
        bad(f"derive-lock.py does not restart with the black lead-in ({needle!r})")
callback = plymouth.find('Plymouth.SetDisplayPasswordFunction(mx_password_callback)')
crt = plymouth.find('Optional CRT vignette')
if callback == -1 or crt == -1 or callback > crt:
    bad("the CRT layer is initialized before the password callback")
for needle in (
    'if (shown == previous) return;',
    'if (was_open == 0) {',
    'global.mx_caps_frames >= $CAPS_POLL_FRAMES',
):
    if needle not in plymouth:
        bad(f"derive-plymouth.py does not keep the low-work password path ({needle!r})")
early_sudo = plymouth.find('subprocess.run(["sudo", "-v"], check=True)')
asset_stage = plymouth.find('font, face, early_backlight = stage(staging, colours, theme_dir)')
if early_sudo == -1 or asset_stage == -1 or early_sudo > asset_stage:
    bad("derive-plymouth.py does not authenticate before generating splash assets")
for needle in (
    'remove_early_backlight',
    'initramfs_rebuild',
    '99-omarchy-matrix-backlight.conf',
):
    if needle not in cli:
        bad(f"bin/omarchy-matrix does not remove its early backlight layer ({needle})")
for message in errors:
    print(f"  FAIL: {message}")
sys.exit(1 if errors else 0)
PY
  then
    :
  else
    failures=$((failures + 1))
  fi
}

check_repo_hygiene() {
  section "no agent files, no symlinks"
  local tracked
  tracked=$(git -C "$ROOT" ls-files)
  grep -qx "AGENTS.md" <<<"$tracked" && fail "AGENTS.md is tracked"
  grep -qx "CLAUDE.md" <<<"$tracked" && fail "CLAUDE.md is tracked"
  grep -q "^\.claude/" <<<"$tracked" && fail ".claude/ is tracked"
  git -C "$ROOT" ls-files -s | grep -q "^120000" && fail "a symlink is tracked"
  # And none hiding untracked in the tree either (outside ignored paths).
  local f links
  links=$(git -C "$ROOT" status --porcelain --ignored=no | awk '$1 == "??" {print $2}')
  for f in $links; do
    if [[ -L $ROOT/$f ]]; then fail "symlink on disk: $f"; fi
  done
  return 0
}

# --- initramfs backlight ----------------------------------------------------

check_early_backlight() {
  section "early initramfs backlight hook"
  local tmp hook order
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' RETURN
  hook="$ROOT/initcpio/hooks/omarchy-matrix-backlight"
  order=$(bash -c 'HOOKS=(base udev plymouth keyboard); source "$1"; printf "%s " "${HOOKS[@]}"' \
    bash "$ROOT/initcpio/99-omarchy-matrix-backlight.conf")
  [[ $order == 'base udev omarchy-matrix-backlight plymouth keyboard ' ]] || {
    fail "the early backlight hook is not immediately before Plymouth: [$order]"
    return 0
  }
  mkdir -p "$tmp/backlight/intel_backlight"
  printf '100\n' >"$tmp/backlight/intel_backlight/max_brightness"
  printf '1\n' >"$tmp/backlight/intel_backlight/brightness"
  printf 'DEVICE=intel_backlight\nPERCENT=20\n' >"$tmp/config"
  OMARCHY_MATRIX_BACKLIGHT_CONFIG="$tmp/config" \
    OMARCHY_MATRIX_BACKLIGHT_ROOT="$tmp/backlight" \
    sh -c '. "$1"; run_hook' sh "$hook" || {
      fail "the early backlight hook does not run"
      return 0
    }
  [[ $(<"$tmp/backlight/intel_backlight/brightness") == 20 ]] ||
    fail "the early backlight hook did not set 20%"

  printf 'DEVICE=../../bad\nPERCENT=20\n' >"$tmp/config"
  printf '1\n' >"$tmp/backlight/intel_backlight/brightness"
  OMARCHY_MATRIX_BACKLIGHT_CONFIG="$tmp/config" \
    OMARCHY_MATRIX_BACKLIGHT_ROOT="$tmp/backlight" \
    sh -c '. "$1"; run_hook' sh "$hook" || fail "the malformed hook fixture failed"
  [[ $(<"$tmp/backlight/intel_backlight/brightness") == 1 ]] ||
    fail "the early backlight hook accepts an unsafe device name"
}

# --- M4 ownership fixtures ---------------------------------------------------
# The one rule, in both languages: clonedFrom == omarchy.lock AND
# (derivedBy == cli OR the rain QML inside). A hand-made clone matches only the
# first half and must come back as foreign everywhere.

check_ownership() {
  section "ownership fixtures (lock clones, legacy files)"
  # In a subshell: the fixture provider would clobber this shell's names.
  (
    local tmp rain="CheckRain.qml"
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    # shellcheck source=../lib/pack.sh
    . "$ROOT/lib/pack.sh"
    cat >"$tmp/provider.json" <<JSON
{"slug": "check", "cli": "check-cli", "rainFiles": ["$rain"],
 "plugin": {"id": "check.rain"}}
JSON
    pack_load_provider "$tmp/provider.json" >/dev/null || exit 1
    PLUGINS_DIR="$tmp/plugins"
    mkdir -p "$PLUGINS_DIR"
    mkplugin() { # <dir> <manifest> [rain]
      mkdir -p "$PLUGINS_DIR/$1"
      printf '%s' "$2" >"$PLUGINS_DIR/$1/manifest.json"
      if [[ ${3:-} == rain ]]; then touch "$PLUGINS_DIR/$1/$rain"; fi
      return 0
    }
    mkplugin "ours-derived.lock" '{"id":"ours-derived.lock","omarchy":{"clonedFrom":"omarchy.lock","derivedBy":"check-cli"}}'
    mkplugin "ours-rain.lock" '{"id":"ours-rain.lock","omarchy":{"clonedFrom":"omarchy.lock"}}' rain
    mkplugin "handmade.lock" '{"id":"handmade.lock","omarchy":{"clonedFrom":"omarchy.lock"}}'
    mkplugin "other.lock" '{"id":"other.lock"}'
    lock_is_ours "$PLUGINS_DIR/ours-derived.lock" || { echo "  FAIL: bash: derived clone is not ours" >&2; exit 1; }
    lock_is_ours "$PLUGINS_DIR/ours-rain.lock" || { echo "  FAIL: bash: rain-carrying clone is not ours" >&2; exit 1; }
    lock_is_ours "$PLUGINS_DIR/handmade.lock" && { echo "  FAIL: bash: hand-made clone counts as ours" >&2; exit 1; }
    lock_is_ours "$PLUGINS_DIR/other.lock" && { echo "  FAIL: bash: non-clone counts as ours" >&2; exit 1; }
    OMARCHY_MATRIX_PROVIDER="$tmp/provider.json" python3 - "$ROOT/lib/derive-lock.py" "$tmp" <<'PY' || exit 1
import importlib.util as u, sys
from pathlib import Path
deriver, tmp = sys.argv[1], Path(sys.argv[2])
s = u.spec_from_file_location("d", deriver)
m = u.module_from_spec(s)
s.loader.exec_module(m)
m.PLUGINS = tmp / "plugins"
assert m.is_ours(tmp / "plugins/ours-derived.lock"), "derived clone is not ours"
assert m.is_ours(tmp / "plugins/ours-rain.lock"), "rain-carrying clone is not ours"
assert not m.is_ours(tmp / "plugins/handmade.lock"), "hand-made clone counts as ours"
assert not m.is_ours(tmp / "plugins/other.lock"), "non-clone counts as ours"
# handmade.lock sorts before both of ours: discovery must still hand back ours.
target, _ = m.existing_clone()
assert target is not None, "discovery finds no clone at all"
assert m.is_ours(target), f"discovery prefers a foreign clone over ours: {target}"
PY
    # clean_legacy_bins takes back only files that carry the pack's marker.
    # SC2034: clean_legacy_bins (in lib/pack.sh) reads SHARE_DIR.
    # shellcheck disable=SC2034
    BIN_DIR="$tmp/bin" SHARE_DIR="$tmp/share"
    mkdir -p "$BIN_DIR/__pycache__"
    echo "from provider import PROVIDER" >"$BIN_DIR/derive-lock.py"
    echo "print('mine')" >"$BIN_DIR/provider.py"
    touch "$BIN_DIR/__pycache__/provider.cpython-314.pyc" "$BIN_DIR/__pycache__/other.cpython-314.pyc"
    clean_legacy_bins
    [[ ! -e $BIN_DIR/derive-lock.py ]] || { echo "  FAIL: the old deriver stayed on PATH" >&2; exit 1; }
    [[ -f $BIN_DIR/provider.py ]] || { echo "  FAIL: a provider.py of the user's own was deleted" >&2; exit 1; }
    [[ -f $BIN_DIR/__pycache__/other.cpython-314.pyc ]] || { echo "  FAIL: bytecode of another program was deleted" >&2; exit 1; }
    [[ ! -e $BIN_DIR/__pycache__/provider.cpython-314.pyc ]] || { echo "  FAIL: the pack's bytecode stayed" >&2; exit 1; }
  ) || failures=$((failures + 1))
}

# --- Style > Unlock ------------------------------------------------------------
# The derived row, against this machine's Omarchy menu, in a scratch HOME. Each
# choice runs through a fake switcher and a fake launcher, so every branch is
# seen without sudo and without a terminal.

check_menu() {
  section "Style > Unlock (lib/derive-menu.py)"
  local omarchy="${OMARCHY_PATH:-/usr/share/omarchy}"
  if [[ ! -f $omarchy/default/omarchy/omarchy-menu.jsonc ]]; then
    echo "  skip: no Omarchy menu installed" >&2
    return 0
  fi
  (
    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    mkdir -p "$tmp/home" "$tmp/fake"
    export HOME="$tmp/home" OMARCHY_PATH="$omarchy" OMARCHY_MATRIX_PROVIDER="$ROOT/provider.json"
    menu="$HOME/.config/omarchy/extensions/omarchy-menu.jsonc"
    slug=$(jq -r .slug "$ROOT/provider.json")
    cli="$HOME/.local/bin/$(jq -r .cli "$ROOT/provider.json")"

    "$ROOT/lib/derive-menu.py" >/dev/null || { echo "  FAIL: no derive into an empty HOME" >&2; exit 1; }
    first=$(cat "$menu")
    "$ROOT/lib/derive-menu.py" >/dev/null && [[ $(cat "$menu") == "$first" ]] ||
      { echo "  FAIL: a second derive changed the file" >&2; exit 1; }

    # Read back with the same two rules as Omarchy's stripJsonc (MenuModel.js).
    row_action() { # <row id>
      python3 - "$menu" "$1" <<'PY'
import json, re, sys
raw = open(sys.argv[1], encoding="utf-8").read()
raw = re.sub(r"^\s*//[^\n]*(\n|$)", "", raw, flags=re.M)
raw = re.sub(r",(\s*[}\]])", r"\1", raw)
print(json.loads(raw)[sys.argv[2]]["action"])
PY
    }
    action=$(row_action style.unlock) && remove=$(row_action remove.theme) ||
      { echo "  FAIL: the menu does not parse the way Omarchy parses it" >&2; exit 1; }

    # Remove > Theme: Omarchy's command first and unchanged, then ours.
    want="omarchy-theme-remove; [[ ! -x '$cli' ]] || '$cli' hook theme-remove"
    [[ $remove == "$want" ]] || { echo "  FAIL: remove.theme runs [$remove], want [$want]" >&2; exit 1; }
    bash -n -c "$remove" || { echo "  FAIL: remove.theme is not a command that bash can read" >&2; exit 1; }

    # A block from 1.2.x, under its old first line, gives way to the new one.
    sed -i "s|^  // >>> $slug: rows of Omarchy's menu,|  // >>> $slug: Style > Unlock,|" "$menu"
    "$ROOT/lib/derive-menu.py" >/dev/null && [[ $(cat "$menu") == "$first" ]] ||
      { echo "  FAIL: a block from 1.2.x did not give way to the new one" >&2; exit 1; }

    printf '#!/bin/bash\necho "$CHOICE"\n' >"$tmp/fake/omarchy-plymouth-switcher"
    printf '#!/bin/bash\nprintf "%%s" "$*" >"$OUT"\n' >"$tmp/fake/omarchy-launch-floating-terminal-with-presentation"
    chmod +x "$tmp/fake"/*
    expect() { # <choice> <the command that the terminal must run>
      local got
      CHOICE="$1" OUT="$tmp/out" PATH="$tmp/fake:$PATH" bash -c "$action"
      got=$(cat "$tmp/out")
      rm -f "$tmp/out"
      [[ $got == "$2" ]] || { echo "  FAIL: $1 runs [$got], want [$2]" >&2; exit 1; }
      bash -n -c "$got" || { echo "  FAIL: $1 hands the terminal a command that bash cannot read" >&2; exit 1; }
    }
    expect "$slug" "'$cli' boot on"
    expect default "omarchy-plymouth-reset && '$cli' boot off"
    expect tokyo-night "omarchy-plymouth-set-by-theme tokyo-night && '$cli' boot off"

    "$ROOT/lib/derive-menu.py" --remove >/dev/null
    cmp -s "$menu" "$omarchy/config/omarchy/extensions/omarchy-menu.jsonc" ||
      { echo "  FAIL: --remove did not give back Omarchy's template" >&2; exit 1; }
  ) || failures=$((failures + 1))
}

# --- main ----------------------------------------------------------------------

check_shell install.sh uninstall.sh bin/omarchy-matrix lib/pack.sh tools/preview-plymouth.sh \
  tools/capture-showcase.sh tools/check.sh initcpio/hooks/omarchy-matrix-backlight \
  initcpio/install/omarchy-matrix-backlight
check_python lib/*.py tools/*.py
check_qml Service.qml MatrixRain.qml
check_validate "$ROOT"
check_main_coherence
check_repo_hygiene
check_early_backlight
check_ownership
check_menu

if ((failures > 0)); then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
