#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

: "${TELEGRAM_USER_ID:?TELEGRAM_USER_ID is required}"

tmp_dir="$(mktemp -d)"
batch_file="$tmp_dir/core-config.batch.json"
cleanup() {
  rm -f "$batch_file"
  rmdir "$tmp_dir"
}
trap cleanup EXIT

jq -n \
  --arg workspace "$CLAWD_WORKSPACE" \
  --arg model "$ASSISTANT_MODEL" \
  --argjson owner "$TELEGRAM_USER_ID" \
  '[
    {path: "agents.defaults.workspace", value: $workspace},
    {path: "agents.defaults.model", value: {primary: $model}},
    {path: "gateway.mode", value: "local"},
    {path: "channels.telegram.enabled", value: true},
    {path: "channels.telegram.dmPolicy", value: "allowlist"},
    {path: "channels.telegram.allowFrom", value: [$owner]},
    {path: "channels.telegram.groupPolicy", value: "allowlist"},
    {path: "commands.ownerAllowFrom", value: [("telegram:" + ($owner | tostring))]}
  ]' > "$batch_file"

scp_to_remote "$batch_file" /tmp/core-config.batch.json
ssh_remote 'bash -s' <<'REMOTE'
set -euo pipefail
export PATH="$HOME/.npm-global/bin:/usr/local/bin:/usr/bin:$PATH"
openclaw config set --batch-file /tmp/core-config.batch.json --dry-run
openclaw config set --batch-file /tmp/core-config.batch.json
openclaw config validate
rm -f /tmp/core-config.batch.json
REMOTE

echo "core OpenClaw config applied"
