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

echo "omarchy-rain: installed continuous Matrix rain. Log out and log in before testing."
