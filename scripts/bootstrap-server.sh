#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

: "${ALLOW_UNSUPPORTED_PLATFORM:=no}"

ssh_admin \
  "BOT_USER='$BOT_USER' CLAWD_WORKSPACE='$CLAWD_WORKSPACE' OPENCLAW_NPM_PACKAGE='$OPENCLAW_NPM_PACKAGE' OPENCLAW_VERSION='$OPENCLAW_VERSION' NODE_MAJOR='$NODE_MAJOR' ALLOW_UNSUPPORTED_PLATFORM='$ALLOW_UNSUPPORTED_PLATFORM' bash -s" <<'REMOTE'
set -euo pipefail

SUDO=""
if [[ "$(id -u)" -ne 0 ]]; then
  SUDO="sudo"
fi

# shellcheck disable=SC1091
source /etc/os-release
if [[ "${ID:-}" != "ubuntu" || "${VERSION_ID:-}" != "24.04" ]]; then
  if [[ "$ALLOW_UNSUPPORTED_PLATFORM" != "yes" ]]; then
    echo "unsupported platform: ${ID:-unknown} ${VERSION_ID:-unknown}" >&2
    echo "supported target is Ubuntu 24.04; see docs/platforms.md" >&2
    exit 2
  fi
  command -v systemctl >/dev/null
  command -v loginctl >/dev/null
  command -v apt-get >/dev/null
  echo "warning: continuing on an unverified systemd/apt platform" >&2
fi

if ! id -u "$BOT_USER" >/dev/null 2>&1; then
  $SUDO useradd -m -s /bin/bash "$BOT_USER"
fi
$SUDO loginctl enable-linger "$BOT_USER"

$SUDO install -d -o "$BOT_USER" -g "$BOT_USER" -m 700 "/home/$BOT_USER/.ssh"
if [[ -f "$HOME/.ssh/authorized_keys" ]]; then
  $SUDO install -o "$BOT_USER" -g "$BOT_USER" -m 600 \
    "$HOME/.ssh/authorized_keys" "/home/$BOT_USER/.ssh/authorized_keys"
fi

$SUDO apt-get update
$SUDO apt-get install -y \
  ca-certificates curl gnupg git jq openssh-client openssl rsync util-linux

installed_node_major="$(node --version 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/' || true)"
if [[ "$installed_node_major" != "$NODE_MAJOR" ]]; then
  # Register the NodeSource key and repository explicitly. The previous
  # `curl … | bash -` handed an unreviewed remote script full root on a host
  # whose whole point is pinned, reviewable runtime versions. Going through
  # apt means package signatures are actually checked.
  keyring="/usr/share/keyrings/nodesource.gpg"
  curl -fsSL --proto '=https' --tlsv1.2 \
    https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key |
    $SUDO gpg --batch --yes --dearmor -o "$keyring"
  $SUDO chmod 644 "$keyring"
  printf 'deb [signed-by=%s] https://deb.nodesource.com/node_%s.x nodistro main\n' \
    "$keyring" "$NODE_MAJOR" |
    $SUDO tee /etc/apt/sources.list.d/nodesource.list >/dev/null
  $SUDO apt-get update
  $SUDO apt-get install -y nodejs
fi

$SUDO install -d -o "$BOT_USER" -g "$BOT_USER" \
  "$CLAWD_WORKSPACE" \
  "/home/$BOT_USER/.openclaw" \
  "/home/$BOT_USER/.npm-global" \
  "/home/$BOT_USER/.local/state/openclaw-assistant" \
  "/home/$BOT_USER/logs"

$SUDO runuser -u "$BOT_USER" -- env \
  HOME="/home/$BOT_USER" \
  npm config set prefix "/home/$BOT_USER/.npm-global"
$SUDO runuser -u "$BOT_USER" -- env \
  HOME="/home/$BOT_USER" \
  PATH="/home/$BOT_USER/.npm-global/bin:/usr/local/bin:/usr/bin:/bin" \
  npm install -g "${OPENCLAW_NPM_PACKAGE}@${OPENCLAW_VERSION}"

profile="/home/$BOT_USER/.profile"
path_line='export PATH="$HOME/.npm-global/bin:$PATH"'
if ! $SUDO grep -Fqx "$path_line" "$profile" 2>/dev/null; then
  printf '%s\n' "$path_line" | $SUDO tee -a "$profile" >/dev/null
fi
$SUDO chown "$BOT_USER:$BOT_USER" "$profile"

$SUDO runuser -u "$BOT_USER" -- env \
  HOME="/home/$BOT_USER" \
  PATH="/home/$BOT_USER/.npm-global/bin:/usr/local/bin:/usr/bin:/bin" \
  openclaw --version
node --version
REMOTE

ssh_remote true
echo "bootstrap complete for $SERVER"
