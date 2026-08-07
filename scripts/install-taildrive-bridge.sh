#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

: "${TAILDRIVE_TAILNET:?TAILDRIVE_TAILNET is required in instance config}"
: "${TAILDRIVE_DEVICE:?TAILDRIVE_DEVICE is required in instance config}"
: "${TAILDRIVE_SHARE:?TAILDRIVE_SHARE is required in instance config}"

[[ "$TAILDRIVE_TAILNET" =~ ^[A-Za-z0-9.-]+$ ]]
[[ "$TAILDRIVE_DEVICE" =~ ^[a-z0-9-]+$ ]]
[[ "$TAILDRIVE_SHARE" =~ ^[a-z0-9_-]+$ ]]

REMOTE_SYNC="/tmp/openclaw-assistant-taildrive-sync.sh"
RUNTIME_SYNC="/opt/openclaw-assistant/runtime/sync-taildrive-inbox.sh"
scp_to_admin "$SCRIPT_DIR/sync-taildrive-inbox.sh" "$REMOTE_SYNC"

ssh_admin \
  "REMOTE_SYNC='$REMOTE_SYNC' RUNTIME_SYNC='$RUNTIME_SYNC' bash -s" <<'REMOTE_ROOT'
set -euo pipefail
command -v tailscale >/dev/null 2>&1 || {
  echo "Tailscale must be installed and enrolled before enabling Taildrive" >&2
  exit 1
}
tailscale status >/dev/null 2>&1 || {
  echo "Tailscale is installed but not connected" >&2
  exit 1
}
if ! command -v rclone >/dev/null 2>&1; then
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y rclone
fi
install -d -o root -g root -m 755 "$(dirname "$RUNTIME_SYNC")"
install -o root -g root -m 755 "$REMOTE_SYNC" "$RUNTIME_SYNC"
rm -f "$REMOTE_SYNC"
REMOTE_ROOT

ssh_remote \
  "CLAWD_WORKSPACE='$CLAWD_WORKSPACE' TAILDRIVE_TAILNET='$TAILDRIVE_TAILNET' TAILDRIVE_DEVICE='$TAILDRIVE_DEVICE' TAILDRIVE_SHARE='$TAILDRIVE_SHARE' RUNTIME_SYNC='$RUNTIME_SYNC' bash -s" <<'REMOTE_USER'
set -euo pipefail

command -v tailscale >/dev/null 2>&1 || {
  echo "tailscale is not installed" >&2
  exit 1
}
command -v rclone >/dev/null 2>&1 || {
  echo "rclone is not installed" >&2
  exit 1
}

mkdir -p "$CLAWD_WORKSPACE/inbox/mac" "$HOME/.config/systemd/user"
chmod 700 "$CLAWD_WORKSPACE/inbox" "$CLAWD_WORKSPACE/inbox/mac"

unit_dir="$HOME/.config/systemd/user"
cat > "$unit_dir/openclaw-taildrive-sync.service" <<EOF
[Unit]
Description=OpenClaw assistant Taildrive inbox sync
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
Environment="CLAWD_WORKSPACE=$CLAWD_WORKSPACE"
Environment="TAILDRIVE_TAILNET=$TAILDRIVE_TAILNET"
Environment="TAILDRIVE_DEVICE=$TAILDRIVE_DEVICE"
Environment="TAILDRIVE_SHARE=$TAILDRIVE_SHARE"
ExecStart=$RUNTIME_SYNC
EOF

cat > "$unit_dir/openclaw-taildrive-sync.timer" <<'EOF'
[Unit]
Description=Sync OpenClaw assistant Taildrive inbox every two minutes

[Timer]
OnCalendar=*:0/2
Persistent=true
AccuracySec=10s

[Install]
WantedBy=timers.target
EOF

if command -v crontab >/dev/null 2>&1; then
  cron_tmp="$(mktemp)"
  crontab -l 2>/dev/null | grep -v 'sync-taildrive-inbox.sh' > "$cron_tmp" || true
  crontab "$cron_tmp"
  rm -f "$cron_tmp"
fi

systemctl --user daemon-reload
systemctl --user enable --now openclaw-taildrive-sync.timer
systemctl --user start openclaw-taildrive-sync.service
result="$(systemctl --user show openclaw-taildrive-sync.service -p Result --value)"
[[ "$result" == "success" ]]
systemctl --user is-enabled openclaw-taildrive-sync.timer
REMOTE_USER

echo "taildrive bridge installed"
