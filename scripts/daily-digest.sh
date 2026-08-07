#!/usr/bin/env bash
set -euo pipefail

: "${CLAWD_WORKSPACE:?CLAWD_WORKSPACE is required}"
: "${ASSISTANT_NAME:=assistant}"
: "${ASSISTANT_RUNTIME_DIR:=/opt/openclaw-assistant/runtime}"
: "${ASSISTANT_RUNTIME_TRUST:=optional}"

# The analyzer reads the Gemini key out of the secrets file and sends workspace
# content to a third party, so it must not be replaceable by the account that
# runs it. See the same guard in auto-backup.sh.
if [[ "$ASSISTANT_RUNTIME_TRUST" == "required" ]]; then
  runtime_owner="$(stat -c '%U' "$ASSISTANT_RUNTIME_DIR" 2>/dev/null || true)"
  runtime_mode="$(stat -c '%a' "$ASSISTANT_RUNTIME_DIR" 2>/dev/null || true)"
  [[ "$runtime_owner" == "root" ]] || {
    echo "refusing to run: $ASSISTANT_RUNTIME_DIR is not root-owned" >&2
    exit 1
  }
  [[ -n "$runtime_mode" && $((8#$runtime_mode & 8#022)) -eq 0 ]] || {
    echo "refusing to run: $ASSISTANT_RUNTIME_DIR is group- or world-writable" >&2
    exit 1
  }
fi

day="${1:-$(date +%F)}"
export PATH="$HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
export ASSISTANT_NAME CLAWD_WORKSPACE

node "$ASSISTANT_RUNTIME_DIR/daily-digest-analyzer.mjs" \
  "$day" --workspace "$CLAWD_WORKSPACE"

openclaw memory index --force --agent main || true
