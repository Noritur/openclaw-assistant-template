#!/usr/bin/env bash
set -euo pipefail

SECRETS_FILE="${OPENCLAW_SECRETS_FILE:-$HOME/.openclaw/secrets.json}"

if [[ ! -r "$SECRETS_FILE" ]]; then
  echo "OpenClaw secrets file is unavailable: $SECRETS_FILE" >&2
  exit 1
fi

read -rsp "github fine-grained token: " token
printf '\n'

if [[ -z "$token" ]]; then
  echo "token was empty; nothing changed" >&2
  exit 1
fi

tmp_file="$(mktemp "${SECRETS_FILE}.tmp.XXXXXX")"
cleanup() {
  rm -f "$tmp_file"
}
trap cleanup EXIT

# Passed through the environment, not as an argument: arguments are visible to
# any local process through the process list, and this is a credential.
GITHUB_MCP_PAT_VALUE="$token" \
  jq '.GITHUB_MCP_PAT = env.GITHUB_MCP_PAT_VALUE' "$SECRETS_FILE" > "$tmp_file"
chmod 600 "$tmp_file"
mv "$tmp_file" "$SECRETS_FILE"
unset token

export PATH="$HOME/.npm-global/bin:/usr/local/bin:/usr/bin:$PATH"
openclaw mcp reload >/dev/null 2>&1 || true
echo "github mcp token saved outside the workspace"
