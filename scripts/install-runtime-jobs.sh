#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

ADMIN_STAGING="/root/.cache/openclaw-assistant-runtime"
RUNTIME_DIR="/opt/openclaw-assistant/runtime"

# Single source of truth: staging, install, and cleanup all read this list.
RUNTIME_FILES=(
  auto-backup.sh
  backup-watchdog.sh
  check-secrets.sh
  daily-digest.sh
  daily-digest-analyzer.mjs
  export-sessions.mjs
  notify-owner.sh
  policy-baseline.sh
  sanitize-memory-history.mjs
)

ssh_admin "install -d -o root -g root -m 700 '$ADMIN_STAGING'"
for file in "${RUNTIME_FILES[@]}"; do
  scp_to_admin "$SCRIPT_DIR/$file" "$ADMIN_STAGING/$file"
done

ssh_admin \
  "ADMIN_STAGING='$ADMIN_STAGING' RUNTIME_DIR='$RUNTIME_DIR' RUNTIME_FILES='${RUNTIME_FILES[*]}' CLAWD_WORKSPACE='$CLAWD_WORKSPACE' bash -s" <<'REMOTE_ROOT'
set -euo pipefail
install -d -o root -g root -m 755 "$RUNTIME_DIR"
# shellcheck disable=SC2153,SC2086
for file in $RUNTIME_FILES; do
  install -o root -g root -m 755 "$ADMIN_STAGING/$file" "$RUNTIME_DIR/$file"
  rm -f "$ADMIN_STAGING/$file"
done

# Only seed the policy baseline when there is none. Rewriting it on every
# restore would silently approve whatever the persona files currently say,
# which is exactly the change this baseline exists to catch.
if [[ ! -f "$RUNTIME_DIR/policy-digests.txt" ]]; then
  CLAWD_WORKSPACE="$CLAWD_WORKSPACE" ASSISTANT_RUNTIME_DIR="$RUNTIME_DIR" \
    "$RUNTIME_DIR/policy-baseline.sh" --write
else
  echo "policy baseline already recorded; leaving it untouched"
fi
REMOTE_ROOT

ssh_remote \
  "ASSISTANT_NAME='$ASSISTANT_NAME' CLAWD_WORKSPACE='$CLAWD_WORKSPACE' RAW_MEMORY_CONSENT='$RAW_MEMORY_CONSENT' RUNTIME_DIR='$RUNTIME_DIR' TELEGRAM_USER_ID='$TELEGRAM_USER_ID' bash -s" <<'REMOTE_USER'
set -euo pipefail

unit_dir="$HOME/.config/systemd/user"
state_dir="$HOME/.local/state/openclaw-assistant"
mkdir -p "$unit_dir" "$state_dir" "$HOME/logs"

cat > "$unit_dir/openclaw-memory-backup.service" <<EOF
[Unit]
Description=OpenClaw assistant memory backup
After=network-online.target
Wants=network-online.target
OnFailure=openclaw-assistant-alert@%n.service

[Service]
Type=oneshot
Environment="CLAWD_WORKSPACE=$CLAWD_WORKSPACE"
Environment="RAW_MEMORY_CONSENT=$RAW_MEMORY_CONSENT"
Environment="ASSISTANT_RUNTIME_DIR=$RUNTIME_DIR"
Environment="ASSISTANT_RUNTIME_TRUST=required"
Environment="TELEGRAM_USER_ID=$TELEGRAM_USER_ID"
ExecStart=$RUNTIME_DIR/auto-backup.sh
EOF

cat > "$unit_dir/openclaw-memory-backup.timer" <<'EOF'
[Unit]
Description=Back up OpenClaw assistant memory every five minutes

[Timer]
OnCalendar=*:0/5
Persistent=true
AccuracySec=10s

[Install]
WantedBy=timers.target
EOF

cat > "$unit_dir/openclaw-daily-digest.service" <<EOF
[Unit]
Description=OpenClaw assistant daily digest
After=network-online.target
Wants=network-online.target
OnFailure=openclaw-assistant-alert@%n.service

[Service]
Type=oneshot
Environment="ASSISTANT_NAME=$ASSISTANT_NAME"
Environment="CLAWD_WORKSPACE=$CLAWD_WORKSPACE"
Environment="ASSISTANT_RUNTIME_DIR=$RUNTIME_DIR"
Environment="ASSISTANT_RUNTIME_TRUST=required"
ExecStart=$RUNTIME_DIR/daily-digest.sh
EOF

cat > "$unit_dir/openclaw-daily-digest.timer" <<'EOF'
[Unit]
Description=Run the OpenClaw assistant daily digest

[Timer]
OnCalendar=*-*-* 23:50:00
Persistent=true
AccuracySec=1m

[Install]
WantedBy=timers.target
EOF

cat > "$unit_dir/openclaw-assistant-alert@.service" <<EOF
[Unit]
Description=Alert the assistant owner that %i failed

[Service]
Type=oneshot
Environment="ASSISTANT_RUNTIME_DIR=$RUNTIME_DIR"
Environment="TELEGRAM_USER_ID=$TELEGRAM_USER_ID"
ExecStart=$RUNTIME_DIR/notify-owner.sh --unit %i
EOF

cat > "$unit_dir/openclaw-backup-watchdog.service" <<EOF
[Unit]
Description=Check that the memory backup is current
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment="ASSISTANT_RUNTIME_DIR=$RUNTIME_DIR"
Environment="TELEGRAM_USER_ID=$TELEGRAM_USER_ID"
ExecStart=$RUNTIME_DIR/backup-watchdog.sh
EOF

cat > "$unit_dir/openclaw-backup-watchdog.timer" <<'EOF'
[Unit]
Description=Check memory backup freshness every fifteen minutes

[Timer]
OnCalendar=*:0/15
Persistent=true
AccuracySec=1m

[Install]
WantedBy=timers.target
EOF

if command -v crontab >/dev/null 2>&1; then
  cron_tmp="$(mktemp)"
  crontab -l 2>/dev/null \
    | grep -v 'clawd/scripts/auto-backup.sh' \
    | grep -v 'clawd/scripts/daily-digest.sh' \
    > "$cron_tmp" || true
  crontab "$cron_tmp"
  rm -f "$cron_tmp"
fi

systemctl --user daemon-reload
systemctl --user enable --now \
  openclaw-memory-backup.timer \
  openclaw-daily-digest.timer \
  openclaw-backup-watchdog.timer

CLAWD_WORKSPACE="$CLAWD_WORKSPACE" \
RAW_MEMORY_CONSENT="$RAW_MEMORY_CONSENT" \
ASSISTANT_RUNTIME_DIR="$RUNTIME_DIR" \
ASSISTANT_RUNTIME_TRUST=required \
TELEGRAM_USER_ID="$TELEGRAM_USER_ID" \
  "$RUNTIME_DIR/auto-backup.sh" --verify

systemctl --user list-timers \
  openclaw-memory-backup.timer \
  openclaw-daily-digest.timer \
  openclaw-backup-watchdog.timer \
  --no-pager
REMOTE_USER

echo "runtime services and five-minute memory backup installed"
