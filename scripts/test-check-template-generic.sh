#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
GUARD="$SCRIPT_DIR/check-template-generic.sh"
EXAMPLE="$ROOT_DIR/instance/config.env.example"

tmp_dir="$(mktemp -d)"
cleanup() {
  [[ "$tmp_dir" == /tmp/* || "$tmp_dir" == /var/folders/* ]] || return 0
  find "$tmp_dir" -depth -delete
}
trap cleanup EXIT

config="$tmp_dir/config.env"
tree="$tmp_dir/tree"
mkdir -p "$tree"

# Fixture values are deliberately unrelated to any real instance: this test
# ships in the public template.
cat > "$config" <<'EOF'
ASSISTANT_ID=quux-fixture
ASSISTANT_NAME=quux-fixture
OWNER_NAME=Zzyzx
SERVER_IP=203.0.113.77
SSH_USER=fixtureuser
BOT_USER=fixtureuser
SSH_KEY_NAME=id_ed25519_openclaw
TELEGRAM_USER_ID=123456789
TAILDRIVE_TAILNET=fixture99.ts.net
TAILDRIVE_DEVICE=fixture-device
TAILDRIVE_SHARE=fixture-share
INFRA_REPO_SLUG=FixtureOwner/fixture-infra
MEMORY_REPO_SLUG=FixtureOwner/fixture-memory
EOF

run_guard() {
  ASSISTANT_CONFIG_FILE="$config" \
  ASSISTANT_CONFIG_EXAMPLE="$EXAMPLE" \
  ASSISTANT_SCAN_ROOT="$tree" \
    "$GUARD"
}

run_guard_without_config() {
  ASSISTANT_CONFIG_FILE="$tmp_dir/absent.env" \
  ASSISTANT_CONFIG_EXAMPLE="$EXAMPLE" \
  ASSISTANT_SCAN_ROOT="$tree" \
    "$GUARD"
}

# a clean tree passes
printf 'generic docs with no owner values\n' > "$tree/README.md"
run_guard >/dev/null 2>&1 || {
  echo "guard rejected a clean tree" >&2
  exit 1
}

# an owner value in the tree is refused, and reported by key
printf 'assistant id: quux-fixture\n' > "$tree/leak.md"
output="$(run_guard 2>&1)" && {
  echo "guard accepted a tree containing an owner value" >&2
  exit 1
}
grep -Fq 'ASSISTANT_ID' <<<"$output" || {
  echo "guard did not name the offending config key" >&2
  exit 1
}
grep -Fq 'leak.md' <<<"$output" || {
  echo "guard did not name the offending file" >&2
  exit 1
}

# the value itself must never reach the log: these findings are printed in CI
# output that may be public, and echoing the value repeats the leak
if grep -Fq 'quux-fixture' <<<"$output"; then
  echo "guard printed the private value into its own output" >&2
  exit 1
fi
rm -f "$tree/leak.md"

# the repo owner derived from the slug is covered too
printf 'clone git@github.com:FixtureOwner/something.git\n' > "$tree/slug.md"
output="$(run_guard 2>&1)" && {
  echo "guard accepted a tree containing the repo owner" >&2
  exit 1
}
grep -Fq 'INFRA_REPO_OWNER' <<<"$output" || {
  echo "guard did not attribute the repo owner match" >&2
  exit 1
}
rm -f "$tree/slug.md"

# values shared with the placeholder baseline are not private
printf 'default key name: id_ed25519_openclaw\n' > "$tree/placeholder.md"
run_guard >/dev/null 2>&1 || {
  echo "guard treated a documented placeholder as private" >&2
  exit 1
}
rm -f "$tree/placeholder.md"

# the generic scan works with no instance config at all. A routable address
# outside every documentation and private range is what a real leak looks like.
printf 'reach the box at 93.184.216.34\n' > "$tree/address.md" # template-generic-ok
output="$(run_guard_without_config 2>&1)" && {
  echo "generic scan accepted a routable IPv4 literal" >&2
  exit 1
}
grep -Fq 'address.md' <<<"$output" || {
  echo "generic scan did not name the offending file" >&2
  exit 1
}
rm -f "$tree/address.md"

# a long digit run is caught the same way
printf 'owner id 6120094411\n' > "$tree/numeric.md" # template-generic-ok
run_guard_without_config >/dev/null 2>&1 && {
  echo "generic scan accepted an unexpected digit run" >&2
  exit 1
}
rm -f "$tree/numeric.md"

# addresses drawn from the documentation and private ranges stay allowed, so
# examples and fixtures do not need a per-value exemption
cat > "$tree/allowed.md" <<'EOF'
loopback 127.0.0.1
tailscale magicdns 100.100.100.100
rfc 1918 gateway 192.168.1.1
rfc 5737 documentation 203.0.113.10 198.51.100.4 192.0.2.7
openclaw version 2026.6.8
fake telegram id 123456789
EOF
run_guard_without_config >/dev/null 2>&1 || {
  echo "generic scan rejected a documented generic literal" >&2
  exit 1
}
rm -f "$tree/allowed.md"

# the inline marker exempts a deliberately fake value
printf 'sample owner id 6120094411 template-generic-ok\n' > "$tree/marked.md"
run_guard_without_config >/dev/null 2>&1 || {
  echo "generic scan ignored the inline exemption marker" >&2
  exit 1
}
rm -f "$tree/marked.md"

echo "template generic guard test passed"
