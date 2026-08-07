#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTANCE_CONFIG="${ASSISTANT_CONFIG_FILE:-$ROOT_DIR/instance/config.env}"
LOCAL_ENV="$ROOT_DIR/.env"
TEMPLATE_LOCK="$ROOT_DIR/template.lock"

if [[ -f "$TEMPLATE_LOCK" ]]; then
  # shellcheck disable=SC1090
  source "$TEMPLATE_LOCK"
fi
if [[ -f "$INSTANCE_CONFIG" ]]; then
  # shellcheck disable=SC1090
  source "$INSTANCE_CONFIG"
fi
if [[ -f "$LOCAL_ENV" ]]; then
  # shellcheck disable=SC1090
  source "$LOCAL_ENV"
fi

: "${ASSISTANT_ID:?ASSISTANT_ID is required in instance/config.env}"
: "${ASSISTANT_NAME:?ASSISTANT_NAME is required in instance/config.env}"
: "${OWNER_NAME:?OWNER_NAME is required in instance/config.env}"
: "${SERVER_IP:?SERVER_IP is required in instance/config.env}"
: "${ADMIN_SSH_USER:=root}"
: "${SSH_USER:?SSH_USER is required in instance/config.env}"
: "${BOT_USER:=assistant}"
: "${OPENCLAW_NPM_PACKAGE:=openclaw}"
: "${OPENCLAW_VERSION:=2026.6.8}"
: "${NODE_MAJOR:=24}"
: "${CLAWD_WORKSPACE:=/home/${BOT_USER}/clawd}"
: "${RAW_MEMORY_CONSENT:=no}"
: "${ENABLE_GITHUB_MCP:=no}"
: "${ENABLE_TAILDRIVE:=no}"

[[ "$ASSISTANT_ID" =~ ^[a-z][a-z0-9-]{1,31}$ ]] || {
  echo "ASSISTANT_ID must match ^[a-z][a-z0-9-]{1,31}$" >&2
  exit 1
}
[[ "$ASSISTANT_NAME" =~ ^[A-Za-z0-9._[:space:]-]{1,64}$ ]] || {
  echo "ASSISTANT_NAME contains unsupported characters" >&2
  exit 1
}
[[ "$OWNER_NAME" =~ ^[A-Za-z0-9._[:space:]-]{1,64}$ ]] || {
  echo "OWNER_NAME contains unsupported characters" >&2
  exit 1
}
[[ "$SERVER_IP" =~ ^[A-Za-z0-9.-]+$ ]] || {
  echo "SERVER_IP must be an IPv4 address or DNS hostname" >&2
  exit 1
}
for user_name in "$ADMIN_SSH_USER" "$SSH_USER" "$BOT_USER"; do
  [[ "$user_name" =~ ^[a-z_][a-z0-9_-]*$ ]] || {
    echo "invalid system user: $user_name" >&2
    exit 1
  }
done
[[ "$ADMIN_SSH_USER" == "root" ]] || {
  echo "ADMIN_SSH_USER must be root for this hardened installer" >&2
  exit 1
}
[[ "$OPENCLAW_VERSION" =~ ^[0-9]{4}\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || {
  echo "OPENCLAW_VERSION must be exact, not latest or a range" >&2
  exit 1
}
[[ "$CLAWD_WORKSPACE" == "/home/$BOT_USER/"* ]] || {
  echo "CLAWD_WORKSPACE must be under /home/$BOT_USER" >&2
  exit 1
}
if [[ -n "${TELEGRAM_USER_ID:-}" && ! "$TELEGRAM_USER_ID" =~ ^[0-9]+$ ]]; then
  echo "TELEGRAM_USER_ID must be numeric" >&2
  exit 1
fi
for consent in "$RAW_MEMORY_CONSENT" "$ENABLE_GITHUB_MCP" "$ENABLE_TAILDRIVE"; do
  [[ "$consent" == "yes" || "$consent" == "no" ]] || {
    echo "boolean instance values must be yes or no" >&2
    exit 1
  }
done
if [[ "$ENABLE_TAILDRIVE" == "yes" ]]; then
  : "${TAILDRIVE_TAILNET:?TAILDRIVE_TAILNET is required when Taildrive is enabled}"
  : "${TAILDRIVE_DEVICE:?TAILDRIVE_DEVICE is required when Taildrive is enabled}"
  : "${TAILDRIVE_SHARE:?TAILDRIVE_SHARE is required when Taildrive is enabled}"
  [[ "$TAILDRIVE_TAILNET" =~ ^[A-Za-z0-9.-]+$ ]] || {
    echo "invalid TAILDRIVE_TAILNET" >&2
    exit 1
  }
  [[ "$TAILDRIVE_DEVICE" =~ ^[a-z0-9-]+$ ]] || {
    echo "invalid TAILDRIVE_DEVICE" >&2
    exit 1
  }
  [[ "$TAILDRIVE_SHARE" =~ ^[a-z0-9_-]+$ ]] || {
    echo "invalid TAILDRIVE_SHARE" >&2
    exit 1
  }
fi

SSH_ARGS=(-o BatchMode=yes)

# Restore is exactly when the host key is unknown, and it is also when the
# Telegram, Gemini and Gateway credentials travel over this connection. With a
# pinned host key the first connection is verified; without one it is trust on
# first use, which is why the absence is warned about rather than silent.
if [[ -n "${SERVER_SSH_HOST_KEY:-}" ]]; then
  [[ "$SERVER_SSH_HOST_KEY" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp[0-9]+)[[:space:]][A-Za-z0-9+/=]+$ ]] || {
    echo "SERVER_SSH_HOST_KEY must be a public host key line, e.g. 'ssh-ed25519 AAAA...'" >&2
    exit 1
  }
  ASSISTANT_KNOWN_HOSTS="${TMPDIR:-/tmp}/openclaw-assistant-known-hosts-${ASSISTANT_ID}"
  printf '%s %s\n' "$SERVER_IP" "$SERVER_SSH_HOST_KEY" > "$ASSISTANT_KNOWN_HOSTS"
  chmod 600 "$ASSISTANT_KNOWN_HOSTS"
  SSH_ARGS+=(
    -o StrictHostKeyChecking=yes
    -o UserKnownHostsFile="$ASSISTANT_KNOWN_HOSTS"
  )
else
  SSH_ARGS+=(-o StrictHostKeyChecking=accept-new)
  echo "warning: SERVER_SSH_HOST_KEY is unset; accepting the host key on first use" >&2
  echo "         record it in instance/config.env to verify future connections" >&2
fi

if [[ -n "${SSH_KEY_NAME:-}" && -f "$HOME/.ssh/$SSH_KEY_NAME" ]]; then
  SSH_ARGS+=(-i "$HOME/.ssh/$SSH_KEY_NAME")
fi

SERVER="${SSH_USER}@${SERVER_IP}"
ADMIN_SERVER="${ADMIN_SSH_USER}@${SERVER_IP}"

ssh_remote() {
  ssh "${SSH_ARGS[@]}" "$SERVER" "$@"
}

ssh_admin() {
  ssh "${SSH_ARGS[@]}" "$ADMIN_SERVER" "$@"
}

scp_from_remote() {
  scp "${SSH_ARGS[@]}" "$SERVER:$1" "$2"
}

scp_to_remote() {
  scp "${SSH_ARGS[@]}" "$1" "$SERVER:$2"
}

scp_to_admin() {
  scp "${SSH_ARGS[@]}" "$1" "$ADMIN_SERVER:$2"
}
