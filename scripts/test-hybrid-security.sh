#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

: "${TELEGRAM_USER_ID:?TELEGRAM_USER_ID is required in .env}"

ssh_remote \
  "CLAWD_WORKSPACE='$CLAWD_WORKSPACE' TELEGRAM_USER_ID='$TELEGRAM_USER_ID' TAILDRIVE_TAILNET='${TAILDRIVE_TAILNET:-}' TAILDRIVE_DEVICE='${TAILDRIVE_DEVICE:-}' TAILDRIVE_SHARE='${TAILDRIVE_SHARE:-}' bash -s" <<'REMOTE'
set -euo pipefail
export PATH="$HOME/.npm-global/bin:/usr/local/bin:/usr/bin:$PATH"

echo "== docker =="
docker info --format 'server={{.ServerVersion}}'
docker image inspect openclaw-sandbox:bookworm-slim \
  --format 'image={{index .RepoTags 0}}'

echo
echo "== effective sandbox =="
openclaw sandbox explain
openclaw config get \
  plugins.entries.codex.config.appServer.experimental.sandboxExecServer \
  --json | jq -e '. == true' >/dev/null
openclaw config get tools.alsoAllow --json \
  | jq -e 'index("message") != null' >/dev/null
openclaw config get tools.alsoAllow --json \
  | jq -e 'index("assistant-host-bridge") != null' >/dev/null
openclaw config get tools.sandbox.tools.alsoAllow --json \
  | jq -e 'index("assistant-host-bridge") != null' >/dev/null
openclaw config get tools.elevated.enabled --json \
  | jq -e '. == false' >/dev/null
# Permitted as well as installed. These are separate lists, and a restore that
# wrote the allowlist before installing the plugin left them disagreeing.
openclaw config get plugins.allow --json \
  | jq -e 'index("assistant-host-bridge") != null' >/dev/null

echo
echo "== enforced sandbox boundary =="
# Everything above reads configuration back, which only proves the config says
# what we set. These check the container the agent actually runs in, and try to
# cross the boundary rather than asking whether it is declared.
sandbox_container="$(docker ps --filter 'name=openclaw-sbx-' --format '{{.Names}}' | head -1)"

if [[ -z "$sandbox_container" ]]; then
  echo "WARNING: no sandbox container is running, so the enforced checks below" >&2
  echo "         were skipped. Run an agent turn, then re-run this test." >&2
else
  echo "container=$sandbox_container"

  network_mode="$(docker inspect "$sandbox_container" --format '{{.HostConfig.NetworkMode}}')"
  [[ "$network_mode" == "none" ]] || {
    echo "sandbox network mode is '$network_mode', expected none" >&2
    exit 1
  }

  container_user="$(docker inspect "$sandbox_container" --format '{{.Config.User}}')"
  [[ -n "$container_user" && "$container_user" != "root" && "$container_user" != 0:* ]] || {
    echo "sandbox runs as '$container_user'" >&2
    exit 1
  }

  privileged="$(docker inspect "$sandbox_container" --format '{{.HostConfig.Privileged}}')"
  [[ "$privileged" == "false" ]] || {
    echo "sandbox container is privileged" >&2
    exit 1
  }

  added_caps="$(docker inspect "$sandbox_container" --format '{{.HostConfig.CapAdd}}')"
  [[ "$added_caps" == "[]" || -z "$added_caps" ]] || {
    echo "sandbox container adds capabilities: $added_caps" >&2
    exit 1
  }

  # Credentials and root-owned runtime code must not be reachable from inside.
  mounts="$(docker inspect "$sandbox_container" --format '{{range .Mounts}}{{.Source}}
{{end}}')"
  while IFS= read -r source; do
    [[ -n "$source" ]] || continue
    case "$source" in
      "$HOME"/.openclaw/sandbox*) ;;
      "$HOME"/.openclaw|"$HOME"/.openclaw/*)
        echo "sandbox mounts OpenClaw state, which holds secrets.json: $source" >&2
        exit 1
        ;;
      /opt/openclaw-assistant|/opt/openclaw-assistant/*)
        echo "sandbox mounts root-owned runtime code: $source" >&2
        exit 1
        ;;
      /|/etc|/etc/*|/root|/root/*)
        echo "sandbox mounts a sensitive host path: $source" >&2
        exit 1
        ;;
    esac
  done <<<"$mounts"
  echo "mounts=ok"

  # Now actually try to cross it. Each of these must fail.
  if docker exec "$sandbox_container" \
    timeout 10 curl -sS --max-time 8 https://api.github.com/meta >/dev/null 2>&1; then
    echo "sandbox reached the network despite network=none" >&2
    exit 1
  fi
  echo "network_egress=blocked"

  if docker exec "$sandbox_container" \
    cat "$HOME/.openclaw/secrets.json" >/dev/null 2>&1; then
    echo "sandbox read the secrets file from inside the container" >&2
    exit 1
  fi
  echo "secrets_unreachable=ok"

  if docker exec "$sandbox_container" \
    cat /opt/openclaw-assistant/runtime/auto-backup.sh >/dev/null 2>&1; then
    echo "sandbox read root-owned runtime code from inside the container" >&2
    exit 1
  fi
  echo "runtime_code_unreachable=ok"

  # The workspace is deliberately writable; confirm it is, so a future change
  # that silently breaks the agent's own storage is caught here too.
  docker exec "$sandbox_container" test -w /workspace || {
    echo "sandbox workspace is not writable, which breaks agent storage" >&2
    exit 1
  }
  echo "workspace_writable=ok"
fi

echo
echo "== host bridge plugin =="
openclaw plugins inspect assistant-host-bridge --runtime --json \
  | jq -e '
      .plugin.status == "loaded"
      and .plugin.activated == true
      and (.diagnostics | length) == 0
      and (.plugin.toolNames | sort) == ([
        "assistant_gateway_restart",
        "assistant_host_logs",
        "assistant_host_resources",
        "assistant_host_status",
        "assistant_tailscale_status"
      ] | sort)
      and any(.typedHooks[]; .name == "before_tool_call")
      and any(.typedHooks[]; .name == "message_sending")
    ' >/dev/null

echo
echo "== effective approvals =="
openclaw approvals get
openclaw config get approvals.plugin --json \
  | jq -e --arg owner "$TELEGRAM_USER_ID" '
      .enabled == true
      and .mode == "targets"
      and (.agentFilter | index("main") != null)
      and any(.targets[]; .channel == "telegram" and .to == $owner)
    ' >/dev/null

echo
echo "== fixed host capabilities =="
stat -c '%a %U:%G %n' \
  /usr/local/libexec/assistant-hostctl \
  /usr/local/libexec/assistant-restart-gateway \
  /opt/openclaw-assistant/assistant-host-bridge \
  /opt/openclaw-assistant/assistant-host-bridge/index.js
/usr/local/libexec/assistant-hostctl status
/usr/local/libexec/assistant-hostctl resources
/usr/local/libexec/assistant-hostctl tailscale

if /usr/local/libexec/assistant-hostctl unsupported >/dev/null 2>&1; then
  echo "unsupported host capability unexpectedly succeeded" >&2
  exit 1
else
  code="$?"
  [[ "$code" -eq 64 ]] || {
    echo "unexpected hostctl failure code: $code" >&2
    exit 1
  }
fi

echo
echo "== gateway and channel =="
systemctl --user is-active openclaw-gateway.service
openclaw channels status

echo
echo "== security audit =="
openclaw security audit --deep || true

echo
echo "== file bridge =="
if [[ -n "$TAILDRIVE_TAILNET" && -n "$TAILDRIVE_DEVICE" && -n "$TAILDRIVE_SHARE" ]]; then
  CLAWD_WORKSPACE="$CLAWD_WORKSPACE" \
  TAILDRIVE_TAILNET="$TAILDRIVE_TAILNET" \
  TAILDRIVE_DEVICE="$TAILDRIVE_DEVICE" \
  TAILDRIVE_SHARE="$TAILDRIVE_SHARE" \
    /opt/openclaw-assistant/runtime/sync-taildrive-inbox.sh
  echo "file bridge sync ok"
else
  echo "skipped: TAILDRIVE_* not configured"
fi
REMOTE
