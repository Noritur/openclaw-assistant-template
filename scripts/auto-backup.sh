#!/usr/bin/env bash
set -euo pipefail

: "${CLAWD_WORKSPACE:?CLAWD_WORKSPACE is required}"
: "${RAW_MEMORY_CONSENT:=no}"
: "${ASSISTANT_RUNTIME_DIR:=/opt/openclaw-assistant/runtime}"
: "${ASSISTANT_STATE_DIR:=$HOME/.local/state/openclaw-assistant}"
: "${ASSISTANT_RUNTIME_TRUST:=optional}"

# This script executes check-secrets.sh out of ASSISTANT_RUNTIME_DIR, and that
# scan is the gate that keeps credentials out of the memory repository. If the
# directory were writable by the account this runs as, the gate could be
# replaced by whatever it is meant to catch. The installed units set
# ASSISTANT_RUNTIME_TRUST=required; the unit tests run from a checkout and
# leave it unset.
if [[ "$ASSISTANT_RUNTIME_TRUST" == "required" ]]; then
  runtime_owner="$(stat -c '%U' "$ASSISTANT_RUNTIME_DIR" 2>/dev/null || true)"
  runtime_mode="$(stat -c '%a' "$ASSISTANT_RUNTIME_DIR" 2>/dev/null || true)"
  [[ "$runtime_owner" == "root" ]] || {
    echo "refusing to run: $ASSISTANT_RUNTIME_DIR is not root-owned" >&2
    exit 1
  }
  [[ -n "$runtime_mode" && $((8#$runtime_mode & 8#022)) -eq 0 ]] || {
    echo "refusing to run: $ASSISTANT_RUNTIME_DIR is group- or world-writable" >&2
    exit 1
  }
fi

export PATH="$HOME/.npm-global/bin:/usr/local/bin:/usr/bin:/bin:$PATH"
mkdir -p "$ASSISTANT_STATE_DIR"

command -v flock >/dev/null 2>&1 || {
  echo "flock is required for memory backup" >&2
  exit 1
}
exec 9>"$ASSISTANT_STATE_DIR/backup.lock"
flock -n 9 || exit 0

cd "$CLAWD_WORKSPACE"
[[ -d .git ]] || {
  echo "memory workspace is not a git repository" >&2
  exit 1
}

if [[ "$RAW_MEMORY_CONSENT" == "yes" ]]; then
  CLAWD_WORKSPACE="$CLAWD_WORKSPACE" \
    node "$ASSISTANT_RUNTIME_DIR/export-sessions.mjs"
fi

git fetch --quiet origin main
if ! git merge-base --is-ancestor origin/main HEAD; then
  echo "remote memory branch is ahead or divergent; refusing automatic merge" >&2
  exit 1
fi

# Refusing used to leave the offending entry staged, so every later run failed
# on the same index and the backup stopped forever. Clearing the index lets the
# next run re-evaluate from scratch: a genuinely bad file fails again, a stale
# staged entry does not.
refuse() {
  printf '%s\n' "$1" >&2
  git reset --quiet || true
  exit 1
}

# The persona files are the model-layer policy, and they sit in the workspace
# the agent can write. Anything able to steer the agent can therefore rewrite
# the agent's own stated rules and have them pushed within five minutes. The
# enforcing boundary (sandbox, approvals, file ownership) is unaffected, but
# the written rules do not protect themselves.
#
# A changed policy file is withheld from the commit rather than failing the
# whole backup: durable notes keep flowing, the persona change does not land,
# and the owner is told once per distinct change instead of every five minutes.
POLICY_FILES=(AGENTS.md IDENTITY.md SECURITY.md SOUL.md)
POLICY_BASELINE="$ASSISTANT_RUNTIME_DIR/policy-digests.txt"
POLICY_ALERTED="$ASSISTANT_STATE_DIR/policy-alerted.txt"

alert_policy_change() {
  local file="$1"
  [[ -x "$ASSISTANT_RUNTIME_DIR/notify-owner.sh" ]] || return 0
  "$ASSISTANT_RUNTIME_DIR/notify-owner.sh" --text \
    "$(printf 'policy file changed and was withheld from backup: %s\napprove with: assistantctl policy-approve' "$file")" ||
    true
}

check_policy_files() {
  [[ -f "$POLICY_BASELINE" ]] ||
    refuse "policy baseline is missing: $POLICY_BASELINE"

  local file staged_digest expected
  local withheld=()
  for file in "${POLICY_FILES[@]}"; do
    git diff --cached --quiet -- "$file" 2>/dev/null && continue

    staged_digest="$(git show ":$file" 2>/dev/null | sha256sum | cut -d' ' -f1 || true)"
    [[ -n "$staged_digest" ]] || {
      refuse "policy file is staged for deletion: $file"
    }
    expected="$(awk -v want="$file" '$2 == want {print $1}' "$POLICY_BASELINE")"
    [[ "$staged_digest" == "$expected" ]] && continue

    git reset --quiet -- "$file" || true
    withheld+=("$file")

    if ! grep -Fqx "$staged_digest  $file" "$POLICY_ALERTED" 2>/dev/null; then
      printf '%s  %s\n' "$staged_digest" "$file" >> "$POLICY_ALERTED"
      alert_policy_change "$file"
    fi
  done

  [[ ${#withheld[@]} -eq 0 ]] ||
    printf 'policy files withheld from backup: %s\n' "${withheld[*]}" >&2
}

backup_paths=(
  AGENTS.md
  HEARTBEAT.md
  IDENTITY.md
  SECURITY.md
  SOUL.md
  TOOLS.md
  USER.md
  custom
  memory
  meta
)
# Consent gates the upload, not just the export. Without this, flipping consent
# back to no stopped new transcripts from being written but kept committing and
# pushing everything already on disk.
if [[ "$RAW_MEMORY_CONSENT" == "yes" ]]; then
  backup_paths+=(raw raw-indexed)
fi

existing_paths=()
for path in "${backup_paths[@]}"; do
  [[ -e "$path" ]] && existing_paths+=("$path")
done
[[ ${#existing_paths[@]} -gt 0 ]] || {
  echo "memory workspace has no configured backup paths" >&2
  exit 1
}
git add -- "${existing_paths[@]}"

while IFS= read -r -d '' staged_path; do
  case "$staged_path" in
    AGENTS.md|HEARTBEAT.md|IDENTITY.md|SECURITY.md|SOUL.md|TOOLS.md|USER.md) ;;
    custom/*|memory/*|meta/*) ;;
    raw/*|raw-indexed/*)
      [[ "$RAW_MEMORY_CONSENT" == "yes" ]] ||
        refuse "backup refused raw transcript without consent: $staged_path"
      ;;
    *)
      refuse "backup refused unexpected staged path: $staged_path"
      ;;
  esac
done < <(git diff --cached --name-only -z)

check_policy_files

"$ASSISTANT_RUNTIME_DIR/check-secrets.sh" --staged || refuse "backup refused a staged secret"

if ! git diff --cached --quiet; then
  git commit -m "memory backup: $(date -u +'%Y-%m-%d %H:%M UTC')"
fi

git push origin HEAD:main
local_sha="$(git rev-parse HEAD)"
remote_sha="$(git ls-remote origin refs/heads/main | cut -f1)"
[[ "$local_sha" == "$remote_sha" ]] || {
  echo "memory backup verification failed" >&2
  exit 1
}

jq -n \
  --arg timestamp "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  --arg sha "$local_sha" \
  '{status:"ok", timestamp:$timestamp, sha:$sha}' \
  > "$ASSISTANT_STATE_DIR/last-backup.json.tmp"
mv "$ASSISTANT_STATE_DIR/last-backup.json.tmp" \
  "$ASSISTANT_STATE_DIR/last-backup.json"

if [[ "${1:-}" == "--verify" ]]; then
  cat "$ASSISTANT_STATE_DIR/last-backup.json"
fi
