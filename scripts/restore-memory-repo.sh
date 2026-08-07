#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

: "${MEMORY_REPO_SSH:?MEMORY_REPO_SSH is required}"

# Fetch GitHub's published host keys here rather than on the server: this side
# has a trusted CA store and an already-authenticated gh, so the keys arrive
# over verified TLS instead of being accepted sight-unseen by a fresh VPS.
GITHUB_KNOWN_HOSTS="$(mktemp)"
trap 'rm -f "$GITHUB_KNOWN_HOSTS"' EXIT

if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
  gh api meta --jq '.ssh_keys[]' | sed 's|^|github.com |' > "$GITHUB_KNOWN_HOSTS"
else
  curl -fsSL --proto '=https' --tlsv1.2 https://api.github.com/meta |
    jq -r '.ssh_keys[]' | sed 's|^|github.com |' > "$GITHUB_KNOWN_HOSTS"
fi

[[ -s "$GITHUB_KNOWN_HOSTS" ]] || {
  echo "could not retrieve GitHub host keys; refusing to fall back to trust-on-first-use" >&2
  exit 1
}
echo "pinning $(wc -l < "$GITHUB_KNOWN_HOSTS" | tr -d ' ') GitHub host key(s)"

scp_to_remote "$GITHUB_KNOWN_HOSTS" /tmp/openclaw-github-known-hosts

ssh_remote \
  "ASSISTANT_ID='$ASSISTANT_ID' ASSISTANT_NAME='$ASSISTANT_NAME' MEMORY_REPO_SSH='$MEMORY_REPO_SSH' CLAWD_WORKSPACE='$CLAWD_WORKSPACE' bash -s" <<'REMOTE'
set -euo pipefail

KEY="$HOME/.ssh/openclaw_memory_ed25519"
KNOWN_HOSTS="$HOME/.ssh/github_known_hosts"
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
install -m 600 /tmp/openclaw-github-known-hosts "$KNOWN_HOSTS"
rm -f /tmp/openclaw-github-known-hosts

export GIT_SSH_COMMAND="ssh -i $KEY -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$KNOWN_HOSTS"

if [[ -d "$CLAWD_WORKSPACE/.git" ]]; then
  cd "$CLAWD_WORKSPACE"
  git remote set-url origin "$MEMORY_REPO_SSH"
  git fetch origin main
  git checkout main
  git pull --ff-only origin main
else
  mkdir -p "$(dirname "$CLAWD_WORKSPACE")"
  git clone "$MEMORY_REPO_SSH" "$CLAWD_WORKSPACE"
fi

cd "$CLAWD_WORKSPACE"
git config user.name "$ASSISTANT_NAME"
git config user.email "$ASSISTANT_ID@localhost"
mkdir -p custom meta memory/context/daily raw raw-indexed
git status --short --branch
REMOTE
