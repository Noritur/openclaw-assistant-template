#!/usr/bin/env bash
set -uo pipefail

# Sends a short operational alert to the owner over Telegram.
#
# Runs as the runtime user from the root-owned runtime directory. The bot token
# is read from the secrets file and passed to curl through a config file on
# stdin, never as an argument: arguments are visible in the process list.
#
# usage:
#   notify-owner.sh --text "message"
#   notify-owner.sh --unit openclaw-memory-backup.service
#   printf 'message' | notify-owner.sh

: "${TELEGRAM_USER_ID:=}"
: "${OPENCLAW_SECRETS_FILE:=$HOME/.openclaw/secrets.json}"

JOURNAL_LINES=6
MAX_MESSAGE_CHARS=1200

unit=""
text=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --unit) unit="${2:-}"; shift 2 ;;
    --text) text="${2:-}"; shift 2 ;;
    *) echo "notify-owner: unknown argument: $1" >&2; exit 64 ;;
  esac
done

if [[ -z "$TELEGRAM_USER_ID" ]]; then
  echo "notify-owner: TELEGRAM_USER_ID is not set; cannot alert" >&2
  exit 1
fi
if [[ ! -r "$OPENCLAW_SECRETS_FILE" ]]; then
  echo "notify-owner: secrets file is unavailable" >&2
  exit 1
fi

# Journal output is untrusted for this purpose: it can carry credentials from
# any component that logged carelessly, and this path forwards it off-host.
redact() {
  sed -E \
    -e 's/((token|secret|api[_-]?key|authorization|bearer|password|credential)[=:][[:space:]]*)[^[:space:]]+/\1[redacted]/Ig' \
    -e 's/[0-9]{8,12}:[A-Za-z0-9_-]{20,}/[redacted-telegram-token]/g' \
    -e 's/AIza[A-Za-z0-9_-]{20,}/[redacted-google-api-key]/g' \
    -e 's/AQ\.[A-Za-z0-9_-]{30,}/[redacted-google-api-key]/g' \
    -e 's/github_pat_[A-Za-z0-9_]{20,}/[redacted-github-token]/g' \
    -e 's/gh[pousr]_[A-Za-z0-9]{20,}/[redacted-github-token]/g'
}

if [[ -n "$unit" ]]; then
  state="$(systemctl --user is-active "$unit" 2>/dev/null || true)"
  result="$(systemctl --user show "$unit" -p Result --value 2>/dev/null || true)"
  recent="$(journalctl --user-unit "$unit" --no-pager --lines "$JOURNAL_LINES" \
    --output cat 2>/dev/null | redact || true)"
  text="$(printf '%s failed\nstate: %s\nresult: %s\n\n%s' \
    "$unit" "${state:-unknown}" "${result:-unknown}" "${recent:-no journal output}")"
elif [[ -z "$text" ]]; then
  text="$(cat)"
fi

text="$(printf '%s' "$text" | redact | cut -c1-"$MAX_MESSAGE_CHARS")"
[[ -n "$text" ]] || {
  echo "notify-owner: refusing to send an empty message" >&2
  exit 1
}

token="$(jq -r '.TELEGRAM_BOT_TOKEN // empty' "$OPENCLAW_SECRETS_FILE")"
[[ -n "$token" ]] || {
  echo "notify-owner: TELEGRAM_BOT_TOKEN is not configured" >&2
  exit 1
}

body_file="$(mktemp)"
trap 'rm -f "$body_file"' EXIT
printf '%s' "$text" > "$body_file"

# -K - keeps the token out of the process list; the response body is discarded
# so an API error cannot echo anything back into the log.
http_code="$(
  printf 'url = "https://api.telegram.org/bot%s/sendMessage"\ndata-urlencode = "chat_id=%s"\ndata-urlencode = "text@%s"\n' \
    "$token" "$TELEGRAM_USER_ID" "$body_file" |
    curl -sS --max-time 15 --retry 2 -o /dev/null -w '%{http_code}' -K - 2>/dev/null
)"
token=""

if [[ "$http_code" != "200" ]]; then
  echo "notify-owner: Telegram API returned ${http_code:-no response}" >&2
  exit 1
fi

echo "notify-owner: alert delivered"
