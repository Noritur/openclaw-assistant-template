#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

: "${MEMORY_REPO_SLUG:?MEMORY_REPO_SLUG is required}"
: "${MEMORY_REPO_SSH:?MEMORY_REPO_SSH is required}"

command -v gh >/dev/null
gh auth status >/dev/null

if ! gh repo view "$MEMORY_REPO_SLUG" >/dev/null 2>&1; then
  gh repo create "$MEMORY_REPO_SLUG" --private \
    --description "Private memory for $ASSISTANT_NAME"
fi

visibility="$(gh repo view "$MEMORY_REPO_SLUG" --json visibility --jq .visibility)"
[[ "$visibility" == "PRIVATE" ]] || {
  echo "memory repository must be private" >&2
  exit 1
}

if gh api "repos/$MEMORY_REPO_SLUG/commits/main" >/dev/null 2>&1; then
  echo "memory repository already initialized"
  exit 0
fi

tmp_dir="$(mktemp -d)"
cleanup() {
  [[ "$tmp_dir" == /tmp/* || "$tmp_dir" == /var/folders/* ]] || return 0
  find "$tmp_dir" -depth -delete
}
trap cleanup EXIT

gh repo clone "$MEMORY_REPO_SLUG" "$tmp_dir/memory"
cp -R "$ROOT_DIR/seed-memory/." "$tmp_dir/memory/"

while IFS= read -r -d '' file; do
  sed -i.bak \
    -e "s/__ASSISTANT_NAME__/$ASSISTANT_NAME/g" \
    -e "s/__OWNER_NAME__/$OWNER_NAME/g" \
    -e "s/__RAW_MEMORY_CONSENT__/$RAW_MEMORY_CONSENT/g" \
    "$file"
  rm -f "$file.bak"
done < <(find "$tmp_dir/memory" -type f -name '*.md' -print0)

git -C "$tmp_dir/memory" config user.name "$ASSISTANT_NAME"
git -C "$tmp_dir/memory" config user.email "$ASSISTANT_ID@localhost"
git -C "$tmp_dir/memory" add -- \
  .gitignore AGENTS.md HEARTBEAT.md IDENTITY.md SECURITY.md SOUL.md TOOLS.md USER.md \
  custom memory meta raw raw-indexed
git -C "$tmp_dir/memory" commit -m "Initialize assistant memory"
git -C "$tmp_dir/memory" push -u origin main

echo "initialized private memory repository: $MEMORY_REPO_SLUG"
