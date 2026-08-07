#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp_dir="$(mktemp -d)"
cleanup() {
  [[ "$tmp_dir" == /tmp/* || "$tmp_dir" == /var/folders/* ]] || return 0
  find "$tmp_dir" -depth -delete
}
trap cleanup EXIT

sessions="$tmp_dir/home/.openclaw/agents/main/sessions"
workspace="$tmp_dir/workspace"
mkdir -p "$sessions" "$workspace"
telegram_token="123456789:$(printf 'A%.0s' {1..30})"
gemini_key="AQ.$(printf 'B%.0s' {1..40})"

cat > "$sessions/sessions.json" <<EOF
{"agent:main:test":{"sessionFile":"$sessions/test.jsonl"}}
EOF
cat > "$sessions/test.jsonl" <<EOF
{"type":"message","timestamp":"2026-08-04T10:00:00Z","message":{"role":"user","content":[{"type":"text","text":"hello $telegram_token $gemini_key"}]}}
{"type":"message","timestamp":"2026-08-04T10:00:01Z","message":{"role":"assistant","content":[{"type":"toolCall","name":"bash","arguments":{"command":"secret"}},{"type":"text","text":"done"}]}}
{"type":"message","timestamp":"2026-08-04T10:00:02Z","message":{"role":"toolResult","content":[{"type":"text","text":"must not export"}]}}
EOF

HOME="$tmp_dir/home" \
CLAWD_WORKSPACE="$workspace" \
OPENCLAW_SESSIONS_DIR="$sessions" \
  node "$SCRIPT_DIR/export-sessions.mjs"

output="$workspace/raw/sessions/2026/08/04.jsonl"
indexed="$workspace/raw-indexed/sessions/2026/08/04.md"
test -f "$output"
test -f "$indexed"
grep -Fq '[redacted:telegram-token]' "$output"
grep -Fq '[redacted:google-api-key]' "$output"
if grep -Fq "$gemini_key" "$output" "$indexed"; then
  echo "Gemini API key leaked into raw memory export" >&2
  exit 1
fi
grep -Fq '"text":"done"' "$output"
grep -Fq 'assistant: done' "$indexed"
if grep -Fq 'must not export' "$output"; then
  echo "tool result leaked into raw memory export" >&2
  exit 1
fi

echo "session export test passed"
