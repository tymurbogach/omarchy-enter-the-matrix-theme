#!/usr/bin/env bash

set -euo pipefail

SHARE_DIR="$HOME/.local/share/omarchy-rain"
COMMAND="$HOME/.local/bin/omarchy-screensaver"
DERIVED="$SHARE_DIR/bin/omarchy-screensaver"
ENV_FILE="$HOME/.config/uwsm/env.d/50-omarchy-rain-path.sh"
ENV_MARKER="# Managed by omarchy-rain."
OWNERSHIP_FILE="$SHARE_DIR/.omarchy-rain"

if [[ -L $COMMAND ]] && [[ $(readlink -f "$COMMAND") == "$DERIVED" ]]; then
  rm -f "$COMMAND"
fi

if [[ -f $ENV_FILE ]] && grep -qxF "$ENV_MARKER" "$ENV_FILE"; then
  rm -f "$ENV_FILE"
fi

if [[ -f $OWNERSHIP_FILE ]] && grep -qxF "$ENV_MARKER" "$OWNERSHIP_FILE"; then
  rm -rf "$SHARE_DIR"
fi
echo "omarchy-rain: removed. Log out and log in before using Omarchy's screensaver."
