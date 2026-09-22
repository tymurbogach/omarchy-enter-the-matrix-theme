#!/usr/bin/env bash

set -euo pipefail

SHARE_DIR="$HOME/.local/share/omarchy-rain"
COMMAND="$HOME/.local/bin/omarchy-screensaver"
DERIVED="$SHARE_DIR/bin/omarchy-screensaver"
ENV_FILE="$HOME/.config/uwsm/env.d/50-omarchy-rain-path.sh"
ENV_MARKER="# Managed by omarchy-rain."
OWNERSHIP_FILE="$SHARE_DIR/.omarchy-rain"
HYPR_AUTOSTART="$HOME/.config/hypr/autostart.lua"
HYPR_BEGIN="-- BEGIN omarchy-rain (managed by install.sh)"
HYPR_END="-- END omarchy-rain"

if [[ -L $COMMAND ]] && [[ $(readlink -f "$COMMAND") == "$DERIVED" ]]; then
  rm -f "$COMMAND"
fi

if [[ -f $ENV_FILE ]] && grep -qxF "$ENV_MARKER" "$ENV_FILE"; then
  rm -f "$ENV_FILE"
fi

if [[ -f $OWNERSHIP_FILE ]] && grep -qxF "$ENV_MARKER" "$OWNERSHIP_FILE"; then
  rm -rf "$SHARE_DIR"
fi

if [[ -f $HYPR_AUTOSTART ]]; then
  python3 - "$HYPR_AUTOSTART" "$HYPR_BEGIN" "$HYPR_END" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
begin, end = sys.argv[2:]
source = path.read_text()
starts = source.count(begin)
ends = source.count(end)
if starts != ends:
    raise SystemExit("omarchy-rain: malformed managed block in " + str(path))
if starts > 1:
    raise SystemExit("omarchy-rain: repeated managed block in " + str(path))
if starts:
    before, remainder = source.split(begin, 1)
    _, after = remainder.split(end, 1)
    path.write_text((before.rstrip() + "\n\n" + after.lstrip()).rstrip() + "\n")
PY
fi

echo "omarchy-rain: removed. Run hyprctl reload before using Omarchy's screensaver."
