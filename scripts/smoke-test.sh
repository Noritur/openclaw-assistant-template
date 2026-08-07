#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

ssh_remote \
  "CLAWD_WORKSPACE='$CLAWD_WORKSPACE' OPENCLAW_VERSION='$OPENCLAW_VERSION' ENABLE_GITHUB_MCP='$ENABLE_GITHUB_MCP' ENABLE_TAILDRIVE='$ENABLE_TAILDRIVE' bash -s" <<'REMOTE'
set -euo pipefail
export PATH="$HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin:$PATH"

echo "== runtime =="
systemctl --user is-active openclaw-gateway.service
version="$(openclaw --version)"
grep -Fq "$OPENCLAW_VERSION" <<<"$version"
printf '%s\n' "$version"
openclaw config validate

echo "== channel and auth =="
openclaw channels status --channel telegram --probe --timeout 15000
openclaw models status --json \
  | jq -e 'any(.auth.runtimeAuthRoutes[]?; .provider == "openai" and .status == "usable")' \
  >/dev/null

echo "== memory =="
memory_status="$(openclaw memory status --deep --agent main)"
printf '%s\n' "$memory_status"
grep -Fq 'Provider: gemini' <<<"$memory_status"
grep -Fq 'Model: gemini-embedding-001' <<<"$memory_status"
grep -Fq 'Embeddings: ready' <<<"$memory_status"
grep -Fq 'Semantic vectors: ready' <<<"$memory_status"
memory_search="$(openclaw memory search --agent main --json --max-results 1 --min-score 0 'assistant owner context')"
jq -e '((.results // .matches // []) | length) > 0' <<<"$memory_search" >/dev/null
echo "semantic_recall=ok"

echo "== optional integrations =="
if [[ "$ENABLE_GITHUB_MCP" == "yes" ]]; then
  openclaw mcp doctor github --probe
else
  echo "github_mcp=disabled"
fi
if [[ "$ENABLE_TAILDRIVE" == "yes" ]]; then
  systemctl --user is-enabled openclaw-taildrive-sync.timer
  systemctl --user is-active openclaw-taildrive-sync.timer
else
  echo "taildrive=disabled"
fi
systemctl --user is-enabled openclaw-daily-digest.timer
systemctl --user is-active openclaw-daily-digest.timer

echo "== secrets and security =="
secrets_audit="$(openclaw secrets audit --json)"
jq -e '
  .summary.plaintextCount == 0
  and .summary.unresolvedRefCount == 0
  and .summary.shadowedRefCount == 0
' <<<"$secrets_audit" >/dev/null
jq '{summary}' <<<"$secrets_audit"
[[ "$(stat -c '%a' "$HOME/.openclaw")" == "700" ]]
openclaw security audit --deep || true

echo "== durable backup =="
systemctl --user is-enabled openclaw-memory-backup.timer
systemctl --user is-active openclaw-memory-backup.timer
systemctl --user is-enabled openclaw-backup-watchdog.timer
systemctl --user is-active openclaw-backup-watchdog.timer

# Same freshness rule the watchdog enforces on a timer, so the smoke test and
# the running system cannot disagree about what "current" means.
BACKUP_MAX_AGE_SECONDS=600 /opt/openclaw-assistant/runtime/backup-watchdog.sh --check

cd "$CLAWD_WORKSPACE"
local_sha="$(git rev-parse HEAD)"
remote_sha="$(git ls-remote origin refs/heads/main | cut -f1)"
[[ "$local_sha" == "$remote_sha" ]]
printf 'memory_sha=%s\n' "$local_sha"
REMOTE
