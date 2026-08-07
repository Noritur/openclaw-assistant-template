#!/usr/bin/env bash
set -euo pipefail

SECRETS_FILE="${OPENCLAW_SECRETS_FILE:-$HOME/.openclaw/secrets.json}"
MCP_BINARY="${ASSISTANT_GITHUB_MCP_BINARY:-/opt/openclaw-assistant/runtime/github-mcp-server}"
TOKEN_HELPER="/usr/local/libexec/set-openclaw-github-token"

if [[ ! -x "$MCP_BINARY" ]]; then
  echo "github mcp binary is missing: $MCP_BINARY" >&2
  exit 1
fi

if [[ ! -r "$SECRETS_FILE" ]]; then
  echo "github mcp secrets file is unavailable" >&2
  exit 1
fi

token="$(jq -r '.GITHUB_MCP_PAT // empty' "$SECRETS_FILE")"
if [[ -z "$token" ]]; then
  echo "github mcp token is not configured; run $TOKEN_HELPER" >&2
  exit 1
fi

export GITHUB_PERSONAL_ACCESS_TOKEN="$token"
unset token

exec "$MCP_BINARY" stdio --read-only --toolsets repos,issues,pull_requests,actions
