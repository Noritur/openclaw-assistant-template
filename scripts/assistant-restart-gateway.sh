#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 0 ]]; then
  echo "assistant-restart-gateway accepts no arguments" >&2
  exit 64
fi

systemctl --user restart --no-block openclaw-gateway.service
echo "gateway restart queued"
