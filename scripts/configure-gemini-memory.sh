#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

MEMORY_JSON="$(cd "$SCRIPT_DIR/.." && pwd)/config/openclaw-memory-search.json"
TMP_REMOTE="/tmp/openclaw-memory-search.json"

scp_to_remote "$MEMORY_JSON" "$TMP_REMOTE"

ssh_remote "TMP_REMOTE='$TMP_REMOTE' bash -s" <<'REMOTE'
set -euo pipefail
export PATH="$HOME/.npm-global/bin:$PATH"

if ! jq -e '.GEMINI_API_KEY' "$HOME/.openclaw/secrets.json" >/dev/null 2>&1; then
  echo "GEMINI_API_KEY missing in ~/.openclaw/secrets.json" >&2
  exit 1
fi

openclaw config set models.providers.google.apiKey \
  --ref-source file \
  --ref-provider local \
  --ref-id /GEMINI_API_KEY

openclaw config set agents.defaults.memorySearch.remote.apiKey \
  --ref-source file \
  --ref-provider local \
  --ref-id /GEMINI_API_KEY

openclaw config set agents.defaults.memorySearch "$(cat "$TMP_REMOTE")" --strict-json

# Merge rather than replace. A flat overwrite dropped every plugin this step
# does not know about, including assistant-host-bridge, which is installed two
# steps later by install-hybrid-security.sh and would then fail to load. It
# also silently discarded anything the owner had enabled by hand.
current_allow="$(openclaw config get plugins.allow --json 2>/dev/null || true)"
# An unset key prints nothing, and empty is not valid JSON for --argjson.
[[ -n "$current_allow" ]] || current_allow='null'
merged_allow="$(
  jq -cn --argjson current "$current_allow" \
    --argjson required '["codex", "google", "telegram"]' \
    '($current // []) + $required | unique'
)"
openclaw config set plugins.allow "$merged_allow" --strict-json

openclaw config validate

# Indexing is allowed to fail without aborting the restore, but a silent
# failure meant this step reported success while semantic recall was broken.
# smoke-test.sh catches it later; saying so here makes the cause obvious.
openclaw memory status --deep --agent main ||
  echo "warning: memory status failed; semantic recall may be unavailable" >&2
openclaw memory index --force --agent main ||
  echo "warning: memory index failed; run 'openclaw memory index --force' after restore" >&2
rm -f "$TMP_REMOTE"
REMOTE

echo "gemini memory config applied"
