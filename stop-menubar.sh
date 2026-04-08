#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Viska"

if pgrep -x "$APP_NAME" >/dev/null 2>&1; then
  pkill -x "$APP_NAME"
fi
