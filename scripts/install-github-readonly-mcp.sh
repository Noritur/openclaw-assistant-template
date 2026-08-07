#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

: "${GITHUB_MCP_VERSION:?GITHUB_MCP_VERSION is required in template.lock}"
: "${GITHUB_MCP_ARCHIVE:?GITHUB_MCP_ARCHIVE is required in template.lock}"
: "${GITHUB_MCP_SHA256:?GITHUB_MCP_SHA256 is required in template.lock}"

[[ "$GITHUB_MCP_SHA256" =~ ^[a-f0-9]{64}$ ]] || {
  echo "GITHUB_MCP_SHA256 must be a lowercase sha256 digest" >&2
  exit 1
}

ADMIN_STAGING="/root/.cache/openclaw-assistant-github-mcp"
RUNTIME_DIR="/opt/openclaw-assistant/runtime"
LIBEXEC_DIR="/usr/local/libexec"
WRAPPER_PATH="$LIBEXEC_DIR/openclaw-assistant-github-mcp"
TOKEN_HELPER_PATH="$LIBEXEC_DIR/set-openclaw-github-token"

ssh_admin "install -d -o root -g root -m 700 '$ADMIN_STAGING'"
scp_to_admin "$SCRIPT_DIR/github-mcp-wrapper.sh" "$ADMIN_STAGING/github-mcp-wrapper.sh"
scp_to_admin "$SCRIPT_DIR/set-github-mcp-token.sh" "$ADMIN_STAGING/set-github-mcp-token.sh"

# The binary and both wrappers are executable runtime code, so they are
# installed root-owned outside the runtime user's home. The wrapper reads the
# GitHub PAT out of the secrets file; leaving it writable by the account it
# runs as would put the token one file write away from any code running as
# that user.
ssh_admin "ADMIN_STAGING='$ADMIN_STAGING' RUNTIME_DIR='$RUNTIME_DIR' LIBEXEC_DIR='$LIBEXEC_DIR' WRAPPER_PATH='$WRAPPER_PATH' TOKEN_HELPER_PATH='$TOKEN_HELPER_PATH' GITHUB_MCP_VERSION='$GITHUB_MCP_VERSION' GITHUB_MCP_ARCHIVE='$GITHUB_MCP_ARCHIVE' GITHUB_MCP_SHA256='$GITHUB_MCP_SHA256' bash -s" <<'REMOTE_ROOT'
set -euo pipefail
umask 077

release_url="https://github.com/github/github-mcp-server/releases/download/v${GITHUB_MCP_VERSION}"
install_binary="$RUNTIME_DIR/github-mcp-server"
archive_file="$ADMIN_STAGING/$GITHUB_MCP_ARCHIVE"

cleanup() {
  rm -f \
    "$archive_file" \
    "${install_binary}.tmp" \
    "$ADMIN_STAGING/github-mcp-wrapper.sh" \
    "$ADMIN_STAGING/set-github-mcp-token.sh"
}
trap cleanup EXIT

curl -fsSL --retry 3 --proto '=https' --tlsv1.2 \
  "$release_url/$GITHUB_MCP_ARCHIVE" -o "$archive_file"

# Verified against the digest committed in template.lock. A checksum file
# fetched alongside the artifact would only prove the download was intact,
# not that the release is the one this template was reviewed against.
printf '%s  %s\n' "$GITHUB_MCP_SHA256" "$archive_file" | sha256sum -c - >/dev/null || {
  echo "github mcp archive does not match the digest pinned in template.lock" >&2
  exit 1
}

binary_path="$(tar -tzf "$archive_file" | grep -Em 1 '(^|/)github-mcp-server$' || true)"
if [[ -z "$binary_path" ]]; then
  echo "github mcp release did not contain its binary" >&2
  exit 1
fi

install -d -o root -g root -m 755 "$RUNTIME_DIR" "$LIBEXEC_DIR"
tar -xOzf "$archive_file" "$binary_path" > "${install_binary}.tmp"
install -o root -g root -m 755 "${install_binary}.tmp" "$install_binary"
install -o root -g root -m 755 \
  "$ADMIN_STAGING/github-mcp-wrapper.sh" "$WRAPPER_PATH"
install -o root -g root -m 755 \
  "$ADMIN_STAGING/set-github-mcp-token.sh" "$TOKEN_HELPER_PATH"
REMOTE_ROOT

# The runtime user owns only the MCP registration, which is configuration.
ssh_remote "WRAPPER_PATH='$WRAPPER_PATH' TOKEN_HELPER_PATH='$TOKEN_HELPER_PATH' bash -s" <<'REMOTE_USER'
set -euo pipefail
export PATH="$HOME/.npm-global/bin:/usr/local/bin:/usr/bin:$PATH"

[[ -x "$WRAPPER_PATH" ]] || {
  echo "github mcp wrapper is missing: $WRAPPER_PATH" >&2
  exit 1
}

# Remove the pre-hardening copies from the runtime user's home so a stale
# writable binary cannot be reached first through a shell PATH. This runs as
# the runtime user because that is whose $HOME they live in.
for stale in \
  "$HOME/.local/lib/openclaw-assistant/github-mcp-server" \
  "$HOME/.local/bin/openclaw-assistant-github-mcp" \
  "$HOME/.local/bin/set-openclaw-github-token"; do
  rm -f "$stale"
done

openclaw mcp set github \
  "{\"command\":\"$WRAPPER_PATH\",\"timeout\":30,\"connectTimeout\":15}"
openclaw mcp reload >/dev/null 2>&1 || true
openclaw mcp status --verbose || true
REMOTE_USER

echo "github read-only mcp installed root-owned at $WRAPPER_PATH"
