#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

prompt_secret() {
  local name="$1"
  local current="${2:-}"
  if [[ -n "$current" ]]; then
    printf '%s' "$current"
    return
  fi
  local value
  read -rsp "$name: " value
  echo >&2
  printf '%s' "$value"
}

TELEGRAM_VALUE="$(prompt_secret 'telegram bot token' "${TELEGRAM_BOT_TOKEN:-}")"
GEMINI_VALUE="$(prompt_secret 'gemini api key' "${GEMINI_API_KEY:-}")"
GATEWAY_VALUE="${GATEWAY_AUTH_TOKEN:-$(openssl rand -hex 32)}"

[[ "$TELEGRAM_VALUE" =~ ^[0-9]{8,12}:[A-Za-z0-9_-]{20,}$ ]] || {
  echo "invalid Telegram bot token format" >&2
  exit 1
}
[[ ${#GEMINI_VALUE} -ge 20 && "$GEMINI_VALUE" != *[[:space:]]* ]] || {
  echo "Gemini API key is required and cannot contain whitespace" >&2
  exit 1
}
[[ ${#GATEWAY_VALUE} -ge 32 && "$GATEWAY_VALUE" != *[[:space:]]* ]] || {
  echo "Gateway token must be at least 32 characters without whitespace" >&2
  exit 1
}

TMP_JSON="$(mktemp)"
trap 'rm -f "$TMP_JSON"' EXIT
umask 077
jq -n \
  --arg telegram "$TELEGRAM_VALUE" \
  --arg gemini "$GEMINI_VALUE" \
  --arg gateway "$GATEWAY_VALUE" \
  '{
    TELEGRAM_BOT_TOKEN: $telegram,
    GEMINI_API_KEY: $gemini,
    GATEWAY_AUTH_TOKEN: $gateway
  }' > "$TMP_JSON"

ssh_remote 'umask 077; mkdir -p "$HOME/.openclaw"; cat > "$HOME/.openclaw/.managed-secrets.json.tmp"' < "$TMP_JSON"

unset TELEGRAM_VALUE GEMINI_VALUE GATEWAY_VALUE

ssh_remote 'bash -s' <<'REMOTE'
set -euo pipefail
export PATH="$HOME/.npm-global/bin:$PATH"

secrets="$HOME/.openclaw/secrets.json"
managed="$HOME/.openclaw/.managed-secrets.json.tmp"
merged="$(mktemp "$HOME/.openclaw/secrets.json.XXXXXX")"
if [[ -f "$secrets" ]]; then
  jq -s '.[0] * .[1]' "$secrets" "$managed" > "$merged"
else
  jq '.' "$managed" > "$merged"
fi
install -m 600 "$merged" "$secrets"
rm -f "$managed" "$merged"

openclaw config set secrets.providers.local \
  "{\"source\":\"file\",\"path\":\"$HOME/.openclaw/secrets.json\",\"mode\":\"json\"}" \
  --strict-json

openclaw config set channels.telegram.botToken \
  --ref-source file \
  --ref-provider local \
  --ref-id /TELEGRAM_BOT_TOKEN

openclaw config set gateway.auth.token \
  --ref-source file \
  --ref-provider local \
  --ref-id /GATEWAY_AUTH_TOKEN

openclaw config set models.providers.google.apiKey \
  --ref-source file \
  --ref-provider local \
  --ref-id /GEMINI_API_KEY

if [[ -f "$HOME/.openclaw/.env" ]]; then
  tmp="$(mktemp)"
  grep -Ev '^(TELEGRAM_BOT_TOKEN|GEMINI_API_KEY|GATEWAY_AUTH_TOKEN)=' "$HOME/.openclaw/.env" > "$tmp" || true
  install -m 600 "$tmp" "$HOME/.openclaw/.env"
  rm -f "$tmp"
fi

openclaw config validate
openclaw secrets audit --check || true
REMOTE

echo "secret refs configured on $SERVER"
