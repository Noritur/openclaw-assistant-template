#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp_dir="$(mktemp -d)"
cleanup() {
  [[ "$tmp_dir" == /tmp/* || "$tmp_dir" == /var/folders/* ]] || return 0
  find "$tmp_dir" -depth -delete
}
trap cleanup EXIT

mkdir -p "$tmp_dir/raw/telegram" "$tmp_dir/raw-indexed/sessions"
telegram_a="123456789:$(printf 'A%.0s' {1..30})"
telegram_b="123456789:$(printf 'B%.0s' {1..30})"
google_key="AQ.$(printf 'A%.0s' {1..40})"
github_token="ghp_$(printf 'A%.0s' {1..36})"
cat > "$tmp_dir/raw/telegram/day.jsonl" <<EOF
{"action":"received","content":"hello $telegram_a"}
{"action":"preprocessed","body":"duplicate","cfg":{"channels":{"telegram":{"botToken":"$telegram_b"}},"gateway":{"auth":{"token":"$(printf 'a%.0s' {1..64})"}}}}
{"action":"sent","metadata":{"api_key":"$google_key"},"content":"done"}
EOF
cat > "$tmp_dir/raw-indexed/sessions/day.md" <<EOF
token=$github_token
EOF

node "$SCRIPT_DIR/sanitize-memory-history.mjs" "$tmp_dir"

grep -Fq '[redacted:telegram-token]' "$tmp_dir/raw/telegram/day.jsonl"
grep -Fq '"api_key":"[redacted]"' "$tmp_dir/raw/telegram/day.jsonl"
grep -Fq 'token=[redacted]' "$tmp_dir/raw-indexed/sessions/day.md"
if grep -Fq 'preprocessed' "$tmp_dir/raw/telegram/day.jsonl"; then
  echo "internal config snapshot was retained" >&2
  exit 1
fi
if grep -Eq '[0-9]{8,12}:[A-Za-z0-9_-]{20,}|AQ\.[A-Za-z0-9_-]{30,}|gh[pousr]_[A-Za-z0-9]{20,}' "$tmp_dir/raw/telegram/day.jsonl" "$tmp_dir/raw-indexed/sessions/day.md"; then
  echo "credential pattern remains after sanitization" >&2
  exit 1
fi

echo "memory history sanitizer test passed"
