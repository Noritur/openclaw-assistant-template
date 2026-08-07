#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
cleanup() {
  [[ "$tmp" == /tmp/* || "$tmp" == /var/folders/* ]] || return 0
  find "$tmp" -depth -delete
}
trap cleanup EXIT

workspace="$tmp/clawd"
home_dir="$tmp/home"
day="2026-06-19"
gemini_key="AQ.$(printf 'B%.0s' {1..40})"

mkdir -p "$workspace/raw/telegram/chats/test-chat/2026/06"
mkdir -p "$workspace/memory/sessions"
mkdir -p "$workspace/memory/context"
mkdir -p "$workspace/custom"
mkdir -p "$home_dir/.openclaw"

printf '%s\n' \
  '{"timestamp":"2026-06-19T09:00:00Z","event":"message:received","text":"build a smart daily digest for the assistant"}' \
  '{"timestamp":"2026-06-19T09:03:00Z","event":"message:sent","text":"план: gemini api, raw + sessions, update active and action-log"}' \
  > "$workspace/raw/telegram/chats/test-chat/2026/06/19.jsonl"

printf '# active context\n\n- assistant recovery kit is active\n' > "$workspace/memory/context/active.md"
printf '# session summary\n\nwe decided to keep codex subscription for live telegram chat.\n' > "$workspace/memory/sessions/2026-06-19-summary.md"
printf '{"GEMINI_API_KEY":"mock"}\n' > "$home_dir/.openclaw/secrets.json"

mock="$tmp/mock.json"
cat > "$mock" <<JSON
{
    "summary": "the daily digest is a smart analyzer while live chat stays on codex subscription. $gemini_key",
  "topics": [
    {
      "title": "smart daily digest",
      "notes": ["gemini api обраний для nightly cron", "джерела: raw + sessions"]
    }
  ],
  "decisions": ["openai/codex subscription лишається для telegram діалогів"],
  "open_threads": ["після deploy перевірити live raw path"],
  "next_actions": ["запустити daily-digest.sh на vps"],
  "facts_to_remember": ["daily digest не має автоматично правити user-notes.md у v1"],
  "people_mentioned": [{"name": "Test Owner", "context": "assistant owner"}],
  "mood": "focused",
  "risks": ["gemini api може впасти, тоді має бути fallback"],
  "active_context_update": "current focus: smart daily digest for the assistant.",
  "action_log_entries": ["implemented smart daily digest plan in infra repo"],
  "confidence": "high",
  "sources": ["raw/telegram/chats/test-chat/2026/06/19.jsonl", "memory/sessions/2026-06-19-summary.md"]
}
JSON

HOME="$home_dir" ASSISTANT_NAME=test-assistant CLAWD_WORKSPACE="$workspace" DAILY_DIGEST_MOCK_JSON="$mock" \
  node "$ROOT_DIR/scripts/daily-digest-analyzer.mjs" "$day" --workspace "$workspace"

grep -q "smart analyzer" "$workspace/memory/context/daily/$day.md"
grep -q "daily digest active context" "$workspace/memory/context/active.md"
grep -q "implemented smart daily digest plan" "$workspace/custom/action-log.md"
grep -Fq '[redacted:google-api-key]' "$workspace/memory/context/daily/$day.md"
if grep -Fq "$gemini_key" \
  "$workspace/memory/context/daily/$day.md" \
  "$workspace/memory/context/active.md" \
  "$workspace/custom/action-log.md"; then
  echo "Gemini API key leaked into digest output" >&2
  exit 1
fi

HOME="$home_dir" ASSISTANT_NAME=test-assistant CLAWD_WORKSPACE="$workspace" DAILY_DIGEST_MOCK_JSON="$mock" \
  node "$ROOT_DIR/scripts/daily-digest-analyzer.mjs" "$day" --workspace "$workspace"

marker_count="$(grep -c "<!-- daily-digest:$day:start -->" "$workspace/custom/action-log.md")"
if [[ "$marker_count" != "1" ]]; then
  echo "expected one action-log marker, got $marker_count" >&2
  exit 1
fi

echo "daily digest mock test passed"
