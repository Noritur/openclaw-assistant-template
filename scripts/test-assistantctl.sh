#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

help_output="$("$ROOT_DIR/assistantctl" --allow-unsupported --help)"
grep -Fq -- '--allow-unsupported' <<<"$help_output"

if "$ROOT_DIR/assistantctl" setup restore >/dev/null 2>&1; then
  echo "assistantctl accepted multiple commands" >&2
  exit 1
fi
if "$ROOT_DIR/assistantctl" help setup >/dev/null 2>&1; then
  echo "assistantctl accepted help plus another command" >&2
  exit 1
fi
if "$ROOT_DIR/assistantctl" --unknown >/dev/null 2>&1; then
  echo "assistantctl accepted an unknown argument" >&2
  exit 1
fi

base_env=(
  ASSISTANT_CONFIG_FILE="$ROOT_DIR/.test-missing-config.env"
  ASSISTANT_ID=test-assistant
  ASSISTANT_NAME=test-assistant
  OWNER_NAME=test-owner
  SERVER_IP=127.0.0.1
  ADMIN_SSH_USER=root
  SSH_USER=assistant
  BOT_USER=assistant
  TELEGRAM_USER_ID=123456789
  CLAWD_WORKSPACE=/home/assistant/clawd
  RAW_MEMORY_CONSENT=no
  ENABLE_GITHUB_MCP=no
  ENABLE_TAILDRIVE=yes
)

if env "${base_env[@]}" bash -c 'source "$1/scripts/lib.sh"' _ "$ROOT_DIR" >/dev/null 2>&1; then
  echo "Taildrive validation accepted missing parameters" >&2
  exit 1
fi

taildrive_env=(
  TAILDRIVE_TAILNET=example.ts.net
  TAILDRIVE_DEVICE=source-device
  TAILDRIVE_SHARE=assistant-share
)

env "${base_env[@]}" "${taildrive_env[@]}" \
  bash -c 'source "$1/scripts/lib.sh"' _ "$ROOT_DIR"

# An unset host key pin is allowed, but must warn: silently trusting the first
# host key is the failure this option exists to remove.
warning="$(env "${base_env[@]}" "${taildrive_env[@]}" \
  bash -c 'source "$1/scripts/lib.sh"' _ "$ROOT_DIR" 2>&1 >/dev/null)"
grep -Fq 'SERVER_SSH_HOST_KEY is unset' <<<"$warning" || {
  echo "missing host key pin did not warn" >&2
  exit 1
}

# A malformed pin must fail rather than be silently ignored.
if env "${base_env[@]}" "${taildrive_env[@]}" \
  SERVER_SSH_HOST_KEY='SHA256:not-a-host-key-line' \
  bash -c 'source "$1/scripts/lib.sh"' _ "$ROOT_DIR" >/dev/null 2>&1; then
  echo "a malformed SERVER_SSH_HOST_KEY was accepted" >&2
  exit 1
fi

# A well-formed pin is accepted and produces a strict known_hosts entry.
pinned_key="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFakeKeyForUnitTestingOnly000000000000"
args="$(env "${base_env[@]}" "${taildrive_env[@]}" \
  SERVER_SSH_HOST_KEY="$pinned_key" \
  bash -c 'source "$1/scripts/lib.sh" 2>/dev/null; printf "%s\n" "${SSH_ARGS[@]}"' _ "$ROOT_DIR")"
grep -Fq 'StrictHostKeyChecking=yes' <<<"$args" || {
  echo "a pinned host key did not enable strict checking" >&2
  exit 1
}
known_hosts_file="$(grep -F 'UserKnownHostsFile=' <<<"$args" | cut -d= -f2-)"
[[ -s "$known_hosts_file" ]] || {
  echo "no known_hosts file was written for the pinned key" >&2
  exit 1
}
grep -Fq "$pinned_key" "$known_hosts_file" || {
  echo "the pinned key is missing from the generated known_hosts" >&2
  exit 1
}
rm -f "$known_hosts_file"

echo "assistantctl interface test passed"
