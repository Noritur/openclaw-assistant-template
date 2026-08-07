#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

REMOTE_KEY=".ssh/openclaw_memory_ed25519"
TITLE_PREFIX="$ASSISTANT_NAME memory"
TITLE="$TITLE_PREFIX ${SERVER_IP} $(date +%F)"
TMP_PUB="$(mktemp)"
trap 'rm -f "$TMP_PUB"' EXIT

# Every restore mints a fresh write-capable key. Nothing ever removed the old
# ones, so after a migration the previous server kept write access to memory
# indefinitely. Deleting a credential is destructive, so this only ever reports
# and asks: it never revokes on its own.
review_stale_deploy_keys() {
  local current_key stale_rows count
  current_key="$(awk '{print $1" "$2}' "$TMP_PUB")"

  stale_rows="$(
    gh api "repos/$MEMORY_REPO_SLUG/keys" --paginate \
      --jq ".[] | select((.key | split(\" \") | .[0:2] | join(\" \")) != \"$current_key\")
            | select(.title | startswith(\"$TITLE_PREFIX\"))
            | [.id, .created_at, .title] | @tsv" 2>/dev/null || true
  )"

  if [[ -z "$stale_rows" ]]; then
    echo "no superseded deploy keys for this assistant"
    return 0
  fi

  count="$(printf '%s\n' "$stale_rows" | wc -l | tr -d ' ')"
  echo
  echo "$count deploy key(s) for this assistant still have write access to $MEMORY_REPO_SLUG:"
  printf '%s\n' "$stale_rows" | while IFS=$'\t' read -r id created title; do
    printf '  id=%s  created=%s  %s\n' "$id" "$created" "$title"
  done
  echo
  echo "these are almost certainly previous servers. a host that no longer runs"
  echo "the assistant should not keep write access to its memory."
  echo

  if [[ ! -t 0 ]]; then
    echo "not an interactive session; leaving them in place. revoke with:" >&2
    printf '%s\n' "$stale_rows" | while IFS=$'\t' read -r id _ _; do
      printf '  gh api -X DELETE repos/%s/keys/%s\n' "$MEMORY_REPO_SLUG" "$id" >&2
    done
    return 0
  fi

  local answer
  read -r -p "revoke all $count? [y/N]: " answer
  if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
    echo "left in place; nothing was revoked"
    return 0
  fi

  printf '%s\n' "$stale_rows" | while IFS=$'\t' read -r id _ title; do
    if gh api -X DELETE "repos/$MEMORY_REPO_SLUG/keys/$id" >/dev/null 2>&1; then
      printf '  revoked id=%s (%s)\n' "$id" "$title"
    else
      printf '  could not revoke id=%s (%s)\n' "$id" "$title" >&2
    fi
  done
}

ssh_remote "ASSISTANT_ID='$ASSISTANT_ID' REMOTE_KEY='$REMOTE_KEY' bash -s" <<'REMOTE'
set -euo pipefail
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
if [[ ! -f "$HOME/$REMOTE_KEY" ]]; then
  ssh-keygen -t ed25519 -N "" -f "$HOME/$REMOTE_KEY" -C "$ASSISTANT_ID-memory@$(hostname)"
fi
chmod 600 "$HOME/$REMOTE_KEY"
chmod 644 "$HOME/$REMOTE_KEY.pub"
cat "$HOME/$REMOTE_KEY.pub"
REMOTE

scp_from_remote "$REMOTE_KEY.pub" "$TMP_PUB"

echo
echo "public deploy key:"
cat "$TMP_PUB"
echo

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1 && [[ -n "${MEMORY_REPO_SLUG:-}" ]]; then
  echo "trying to add deploy key to $MEMORY_REPO_SLUG with write access"
  gh repo deploy-key add "$TMP_PUB" -R "$MEMORY_REPO_SLUG" --title "$TITLE" --allow-write || {
    echo "could not add deploy key automatically; add it manually in GitHub" >&2
  }
  review_stale_deploy_keys
else
  echo "add this key manually to GitHub deploy keys with write access"
fi
