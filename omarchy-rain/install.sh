#!/usr/bin/env bash

# Installs a user-owned replacement for Omarchy's random terminal screensaver.
# The replacement is derived from the installed command, never copied from a
# pinned release, so its focus, input and cursor behaviour keep Omarchy's code.

set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SHARE_DIR="$HOME/.local/share/omarchy-rain"
BIN_DIR="$HOME/.local/bin"
COMMAND="$BIN_DIR/omarchy-screensaver"
DERIVED="$SHARE_DIR/bin/omarchy-screensaver"
ENV_DIR="$HOME/.config/uwsm/env.d"
ENV_FILE="$ENV_DIR/50-omarchy-rain-path.sh"
ENV_MARKER="# Managed by omarchy-rain."
HYPR_AUTOSTART="$HOME/.config/hypr/autostart.lua"
HYPR_BEGIN="-- BEGIN omarchy-rain (managed by install.sh)"
HYPR_END="-- END omarchy-rain"
OWNERSHIP_FILE="$SHARE_DIR/.omarchy-rain"

[[ ${1:-} == "" || ${1:-} == "--sync" ]] || {
  echo "Usage: $0 [--sync]" >&2
  exit 1
}

command -v omarchy >/dev/null || {
  echo "omarchy-rain: Omarchy is required" >&2
  exit 1
}
command -v python3 >/dev/null || {
  echo "omarchy-rain: python3 is required" >&2
  exit 1
}

ours() {
  [[ -L $COMMAND ]] && [[ $(readlink -f "$COMMAND") == "$DERIVED" ]]
}

if [[ -e $COMMAND || -L $COMMAND ]] && ! ours; then
  echo "omarchy-rain: $COMMAND already belongs to another customization." >&2
  echo "Remove it yourself or choose one screensaver implementation." >&2
  exit 1
fi

if [[ -e $ENV_FILE ]] && ! grep -qxF "$ENV_MARKER" "$ENV_FILE"; then
  echo "omarchy-rain: $ENV_FILE already belongs to another customization." >&2
  echo "Keep its local-bin PATH rule or remove it before installation." >&2
  exit 1
fi

mkdir -p "$(dirname "$SHARE_DIR")"
staging=$(mktemp -d "$SHARE_DIR.staging.XXXXXX")
cleanup() { rm -rf "$staging"; }
trap cleanup EXIT

mkdir -p "$staging/bin" "$BIN_DIR" "$ENV_DIR"
install -m 755 "$ROOT/lib/derive-screensaver.py" "$staging/derive-screensaver.py"
python3 "$staging/derive-screensaver.py" --output "$staging/bin/omarchy-screensaver"
chmod 755 "$staging/bin/omarchy-screensaver"
printf '%s\n' "$ENV_MARKER" >"$staging/.omarchy-rain"

if [[ -d $SHARE_DIR ]]; then
  retired="$SHARE_DIR.retired"
  rm -rf "$retired"
  mv "$SHARE_DIR" "$retired"
  mv "$staging" "$SHARE_DIR"
  rm -rf "$retired"
  trap - EXIT
else
  mv "$staging" "$SHARE_DIR"
  trap - EXIT
fi

ln -sfn "$DERIVED" "$COMMAND"
cat >"$ENV_FILE" <<EOF
$ENV_MARKER
# Omarchy resolves omarchy-screensaver by name. This puts the user command
# before /usr/share/omarchy/bin for the graphical UWSM session.
export PATH="\$HOME/.local/bin:\$PATH"
EOF

# Omarchy's Hyprland defaults put $OMARCHY_PATH/bin first after UWSM has
# loaded env.d. Reapply the user-bin priority after those defaults. A marked
# block lets uninstall remove only what this installer owns.
mkdir -p "$(dirname "$HYPR_AUTOSTART")"
python3 - "$HYPR_AUTOSTART" "$HYPR_BEGIN" "$HYPR_END" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
begin, end = sys.argv[2:]
block = f'''{begin}
local omarchy_rain_local_bin = os.getenv("HOME") .. "/.local/bin"
local omarchy_rain_paths = {{}}
for entry in (os.getenv("PATH") or ""):gmatch("[^:]+") do
  if entry ~= omarchy_rain_local_bin then table.insert(omarchy_rain_paths, entry) end
end
table.insert(omarchy_rain_paths, 1, omarchy_rain_local_bin)
hl.env("PATH", table.concat(omarchy_rain_paths, ":"))
{end}
'''

source = path.read_text() if path.exists() else ""
starts = source.count(begin)
ends = source.count(end)
if starts != ends:
    raise SystemExit("omarchy-rain: malformed managed block in " + str(path))
if starts > 1:
    raise SystemExit("omarchy-rain: repeated managed block in " + str(path))
if starts:
    before, remainder = source.split(begin, 1)
    _, after = remainder.split(end, 1)
    source = before.rstrip() + "\n\n" + after.lstrip()
path.write_text(source.rstrip() + "\n\n" + block)
PY

echo "omarchy-rain: installed continuous Matrix rain. Run hyprctl reload before testing."
