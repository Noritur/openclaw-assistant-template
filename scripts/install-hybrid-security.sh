#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

: "${TELEGRAM_USER_ID:?TELEGRAM_USER_ID is required in .env}"
: "${ADMIN_SSH_USER:=root}"

[[ "$TELEGRAM_USER_ID" =~ ^[0-9]+$ ]] || {
  echo "TELEGRAM_USER_ID must be numeric" >&2
  exit 1
}
[[ "$BOT_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || {
  echo "invalid BOT_USER" >&2
  exit 1
}

ADMIN_SERVER="${ADMIN_SSH_USER}@${SERVER_IP}"
ADMIN_STAGING="/root/.cache/openclaw-assistant"
ADMIN_PLUGIN_DIR="/opt/openclaw-assistant/assistant-host-bridge"
HOSTCTL_LOCAL="$SCRIPT_DIR/assistant-hostctl.sh"
RESTART_LOCAL="$SCRIPT_DIR/assistant-restart-gateway.sh"
APPROVALS_LOCAL="$ROOT_DIR/config/exec-approvals.hybrid.json"
PLUGIN_LOCAL="$ROOT_DIR/plugins/assistant-host-bridge"

tmp_dir="$(mktemp -d)"
batch_file="$tmp_dir/hybrid-security.batch.json"

cleanup() {
  rm -f "$batch_file"
  rmdir "$tmp_dir"
}
trap cleanup EXIT

jq -n --arg owner "$TELEGRAM_USER_ID" '[
  {
    path: "agents.defaults.sandbox",
    value: {
      mode: "all",
      backend: "docker",
      scope: "agent",
      workspaceAccess: "rw",
      docker: {
        image: "openclaw-sandbox:bookworm-slim",
        network: "none"
      }
    }
  },
  {path: "tools.profile", value: "coding"},
  {path: "tools.alsoAllow", value: ["message", "assistant-host-bridge"]},
  {
    path: "plugins.entries.codex.config.appServer.experimental.sandboxExecServer",
    value: true
  },
  {path: "tools.fs.workspaceOnly", value: true},
  {
    path: "tools.exec",
    value: {
      host: "auto",
      security: "allowlist",
      ask: "on-miss",
      strictInlineEval: true,
      commandHighlighting: true
    }
  },
  {
    path: "tools.elevated",
    value: {
      enabled: false
    }
  },
  {
    path: "tools.sandbox.tools.alsoAllow",
    value: ["group:memory", "group:messaging", "group:plugins", "group:web", "bundle-mcp", "assistant-host-bridge"]
  },
  {
    path: "approvals.exec",
    value: {
      enabled: true,
      mode: "targets",
      agentFilter: ["main"],
      targets: [{channel: "telegram", to: $owner}]
    }
  },
  {
    path: "approvals.plugin",
    value: {
      enabled: true,
      mode: "targets",
      agentFilter: ["main"],
      targets: [{channel: "telegram", to: $owner}]
    }
  },
  {
    path: "channels.telegram.execApprovals",
    value: {
      enabled: true,
      approvers: [$owner],
      target: "dm"
    }
  },
  {
    path: "commands.ownerAllowFrom",
    value: [("telegram:" + $owner)]
  }
]' > "$batch_file"

ssh "${SSH_ARGS[@]}" "$ADMIN_SERVER" \
  "install -d -o root -g root -m 700 '$ADMIN_STAGING'"

scp "${SSH_ARGS[@]}" \
  "$HOSTCTL_LOCAL" \
  "$RESTART_LOCAL" \
  "$ADMIN_SERVER:$ADMIN_STAGING/"
scp "${SSH_ARGS[@]}" -r \
  "$PLUGIN_LOCAL" \
  "$ADMIN_SERVER:$ADMIN_STAGING/"

ssh "${SSH_ARGS[@]}" "$ADMIN_SERVER" \
  "BOT_USER='$BOT_USER' ADMIN_STAGING='$ADMIN_STAGING' ADMIN_PLUGIN_DIR='$ADMIN_PLUGIN_DIR' bash -s" <<'REMOTE_ROOT'
set -euo pipefail

apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y docker.io
systemctl enable --now docker.service

install -d -o root -g root -m 755 /usr/local/libexec
install -o root -g root -m 755 \
  "$ADMIN_STAGING/assistant-hostctl.sh" /usr/local/libexec/assistant-hostctl
install -o root -g root -m 755 \
  "$ADMIN_STAGING/assistant-restart-gateway.sh" \
  /usr/local/libexec/assistant-restart-gateway
install -d -o root -g root -m 755 "$ADMIN_PLUGIN_DIR"
install -o root -g root -m 644 \
  "$ADMIN_STAGING/assistant-host-bridge/package.json" \
  "$ADMIN_STAGING/assistant-host-bridge/openclaw.plugin.json" \
  "$ADMIN_STAGING/assistant-host-bridge/index.js" \
  "$ADMIN_PLUGIN_DIR/"
rm -f \
  "$ADMIN_STAGING/assistant-hostctl.sh" \
  "$ADMIN_STAGING/assistant-restart-gateway.sh"
rm -f \
  "$ADMIN_STAGING/assistant-host-bridge/package.json" \
  "$ADMIN_STAGING/assistant-host-bridge/openclaw.plugin.json" \
  "$ADMIN_STAGING/assistant-host-bridge/index.js"
rmdir "$ADMIN_STAGING/assistant-host-bridge"

had_docker_group=false
if id -nG "$BOT_USER" | tr ' ' '\n' | grep -qx docker; then
  had_docker_group=true
fi
usermod -aG docker "$BOT_USER"
chmod 700 "/home/$BOT_USER/.openclaw"
loginctl enable-linger "$BOT_USER"

if ! docker image inspect openclaw-sandbox:bookworm-slim >/dev/null 2>&1; then
  docker build --pull -t openclaw-sandbox:bookworm-slim - <<'DOCKERFILE'
FROM debian:bookworm-slim
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
  bash ca-certificates curl git jq python3 ripgrep \
  && find /var/lib/apt/lists -mindepth 1 -delete
RUN useradd --create-home --shell /bin/bash sandbox
USER sandbox
WORKDIR /home/sandbox
CMD ["sleep", "infinity"]
DOCKERFILE
fi

if [[ "$had_docker_group" == false ]]; then
  uid="$(id -u "$BOT_USER")"
  loginctl terminate-user "$BOT_USER" || true
  systemctl start "user@${uid}.service"
fi
REMOTE_ROOT

for _ in {1..30}; do
  if ssh_remote true 2>/dev/null; then
    break
  fi
  sleep 2
done
ssh_remote true

scp_to_remote "$batch_file" /tmp/hybrid-security.batch.json
scp_to_remote "$APPROVALS_LOCAL" /tmp/exec-approvals.hybrid.json

ssh_remote "CLAWD_WORKSPACE='$CLAWD_WORKSPACE' bash -s" <<'REMOTE_USER'
set -euo pipefail
export PATH="$HOME/.npm-global/bin:/usr/local/bin:/usr/bin:$PATH"

docker image inspect openclaw-sandbox:bookworm-slim >/dev/null

if ! openclaw plugins inspect assistant-host-bridge --json >/dev/null 2>&1; then
  openclaw plugins install --link /opt/openclaw-assistant/assistant-host-bridge
fi

# The step that installs the plugin is the step that must allow it. Leaving
# this to an earlier script meant the allowlist was written before the plugin
# existed, so restore ended with the host bridge installed but not permitted.
current_allow="$(openclaw config get plugins.allow --json 2>/dev/null || true)"
# An unset key prints nothing, and empty is not valid JSON for --argjson.
[[ -n "$current_allow" ]] || current_allow='null'
host_bridge_allow="$(
  jq -cn --argjson current "$current_allow" \
    '($current // []) + ["assistant-host-bridge"] | unique'
)"
openclaw config set plugins.allow "$host_bridge_allow" --strict-json

openclaw config set --batch-file /tmp/hybrid-security.batch.json --dry-run
openclaw config set --batch-file /tmp/hybrid-security.batch.json
openclaw approvals set --file /tmp/exec-approvals.hybrid.json
openclaw config validate

rm -f /tmp/hybrid-security.batch.json /tmp/exec-approvals.hybrid.json
openclaw sandbox recreate --all --force || true
systemctl --user restart openclaw-gateway.service

for _ in {1..30}; do
  if systemctl --user is-active --quiet openclaw-gateway.service; then
    break
  fi
  sleep 1
done
chmod 700 "$HOME/.openclaw"
systemctl --user is-active openclaw-gateway.service
REMOTE_USER

echo "hybrid security installed"
