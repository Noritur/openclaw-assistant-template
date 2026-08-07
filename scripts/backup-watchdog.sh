#!/usr/bin/env bash
set -euo pipefail

# Reports when the last verified memory backup is older than the recovery
# target promised in README.
#
# OnFailure alerts only fire when a unit actually runs and exits non-zero. This
# catches everything that produces no failure at all: lock contention, a
# disabled or masked timer, a stopped user manager, a host that was off.
#
#   backup-watchdog.sh --check   exit non-zero when stale, print nothing extra
#   backup-watchdog.sh           same, and alert the owner when stale

: "${ASSISTANT_STATE_DIR:=$HOME/.local/state/openclaw-assistant}"
: "${ASSISTANT_RUNTIME_DIR:=/opt/openclaw-assistant/runtime}"
: "${BACKUP_MAX_AGE_SECONDS:=900}"

check_only=no
[[ "${1:-}" == "--check" ]] && check_only=yes

state_file="$ASSISTANT_STATE_DIR/last-backup.json"

fail() {
  local message="$1"
  echo "$message" >&2
  if [[ "$check_only" == "no" && -x "$ASSISTANT_RUNTIME_DIR/notify-owner.sh" ]]; then
    "$ASSISTANT_RUNTIME_DIR/notify-owner.sh" --text "memory backup watchdog: $message" || true
  fi
  exit 1
}

[[ -f "$state_file" ]] || fail "no verified backup has ever been recorded"

status="$(jq -r '.status // empty' "$state_file" 2>/dev/null || true)"
timestamp="$(jq -r '.timestamp // empty' "$state_file" 2>/dev/null || true)"
sha="$(jq -r '.sha // empty' "$state_file" 2>/dev/null || true)"

[[ "$status" == "ok" ]] || fail "last backup state is not ok"
[[ ${#sha} -eq 40 ]] || fail "last backup state has no commit sha"
[[ -n "$timestamp" ]] || fail "last backup state has no timestamp"

last_epoch="$(date -d "$timestamp" +%s 2>/dev/null || true)"
[[ -n "$last_epoch" ]] || fail "last backup timestamp is unreadable"

age="$(( $(date -u +%s) - last_epoch ))"
if [[ "$age" -gt "$BACKUP_MAX_AGE_SECONDS" ]]; then
  fail "last verified backup is ${age}s old, over the ${BACKUP_MAX_AGE_SECONDS}s target"
fi

echo "backup_age_seconds=$age sha=$sha"
