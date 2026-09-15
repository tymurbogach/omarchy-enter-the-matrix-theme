#!/usr/bin/env bash
# tools/check.sh -- the cheap checks and the coherence checks. No Omarchy
# session needed: what needs the real session (screenshots, toggles, the boot
# preview) lives in CONTRIBUTING.md's clean-room test instead.
#
#   ./tools/check.sh                the main repo
#   ./tools/check.sh --widget DIR   the widget repo
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

WIDGET_DIR=""
if [[ ${1:-} == "--widget" ]]; then
  WIDGET_DIR="${2:-}"
  [[ -n $WIDGET_DIR && -d $WIDGET_DIR ]] || { echo "usage: check.sh --widget DIR" >&2; exit 1; }
fi

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
import json, pathlib, re, sys
root = pathlib.Path(sys.argv[1])
errors = []
def bad(message):
    errors.append(message)
provider = json.loads((root / "provider.json").read_text())
slug, cli = provider["slug"], provider["cli"]
service = (root / "Service.qml").read_text()
manifest = json.loads((root / "manifest.json").read_text())
# The settings file: QML cannot read the provider, so the name is written by
# hand here and verified here (B1).
m = re.search(r'configPath: home \+ "([^"]+)"', service)
if not m or m.group(1) != f"/.config/omarchy/{slug}.json":
    bad(f"Service.qml configPath is {m.group(1) if m else 'missing'}, want /.config/omarchy/{slug}.json")
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
# The widget pin is a full commit SHA, never a branch.
if not re.fullmatch(r"[0-9a-f]{40}", provider["widget"].get("ref", "")):
    bad(f"widget.ref is {provider['widget'].get('ref')!r}, want 40 hex")
# License: the manifest says MIT and the file to back it is there.
if manifest.get("license") != "MIT":
    bad(f"manifest license is {manifest.get('license')!r}, want 'MIT'")
if not (root / "LICENSE").is_file():
    bad("LICENSE is missing")
# The update pulls from a URL written out in the CLI, not read from the
# provider: see the updates section of bin/omarchy-matrix for why. It must stay
# the provider's own repository.
cli = (root / "bin" / "omarchy-matrix").read_text()
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
 "plugin": {"id": "check.rain"}, "widget": {"id": "check.widget"}}
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
    action=$(python3 - "$menu" <<'PY'
import json, re, sys
raw = open(sys.argv[1], encoding="utf-8").read()
raw = re.sub(r"^\s*//[^\n]*(\n|$)", "", raw, flags=re.M)
raw = re.sub(r",(\s*[}\]])", r"\1", raw)
print(json.loads(raw)["style.unlock"]["action"])
PY
    ) || { echo "  FAIL: the menu does not parse the way Omarchy parses it" >&2; exit 1; }

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

# --- coherence: widget repo ----------------------------------------------------

check_widget_coherence() {
  section "widget coherence in $WIDGET_DIR"
  MAIN_VERSION=$(python3 -c "import json; print(json.load(open('$ROOT/manifest.json'))['version'])")
  python3 - "$WIDGET_DIR" "$MAIN_VERSION" <<'PY' || failures=$((failures + 1))
import json, pathlib, re, sys
w = pathlib.Path(sys.argv[1])
errors = []
def bad(message):
    errors.append(message)
manifest = json.loads((w / "manifest.json").read_text())
panel = (w / "Panel.qml").read_text() if (w / "Panel.qml").is_file() else ""
if manifest.get("kinds") != ["bar-widget"]:
    bad(f"kinds is {manifest.get('kinds')}, want ['bar-widget']")
for kind, path in manifest.get("entryPoints", {}).items():
    if not (w / path).is_file():
        bad(f"entryPoint {kind} points at missing {path}")
if manifest.get("barWidget", {}).get("defaultSection") != "right":
    bad("barWidget.defaultSection is not 'right'")
# The one name the panel writes down: the CLI it shells out to, as the
# absolute path W1 pins it to -- no PATH lookup, no shell.
m = re.search(r'readonly property string cli:.*?/\.local/bin/omarchy-matrix', panel, re.S)
if not m:
    bad("Panel cli is not the absolute ~/.local/bin/omarchy-matrix path")
if manifest.get("license") != "MIT":
    bad(f"manifest license is {manifest.get('license')!r}, want 'MIT'")
if not (w / "LICENSE").is_file():
    bad("LICENSE is missing")
if not (w / "preview.png").is_file():
    bad("preview.png is missing")
if not (w / "README.md").is_file():
    bad("README.md is missing")
if manifest.get("version") != sys.argv[2]:
    bad(f"widget version {manifest.get('version')} trails the pack {sys.argv[2]}")
for message in errors:
    print(f"  FAIL: {message}")
sys.exit(1 if errors else 0)
PY
}

# --- main ----------------------------------------------------------------------

if [[ -n $WIDGET_DIR ]]; then
  CHECK_ROOT="$ROOT" check_qml "$WIDGET_DIR/Panel.qml"
  check_validate "$WIDGET_DIR"
  check_widget_coherence
else
  check_shell install.sh uninstall.sh bin/omarchy-matrix lib/pack.sh tools/preview-plymouth.sh \
    tools/capture-showcase.sh tools/check.sh
  check_python lib/*.py tools/*.py
  check_qml Service.qml MatrixRain.qml
  check_validate "$ROOT"
  check_main_coherence
  check_repo_hygiene
  check_ownership
  check_menu
fi

if ((failures > 0)); then
  echo "$failures check(s) failed" >&2
  exit 1
fi
echo "all checks passed"
