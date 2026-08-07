#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tmp_dir="$(mktemp -d)"
cleanup() {
  [[ "$tmp_dir" == /tmp/* || "$tmp_dir" == /var/folders/* ]] || return 0
  find "$tmp_dir" -depth -delete
}
trap cleanup EXIT

test_bin="$tmp_dir/bin"
capture="$tmp_dir/curl-invocation.txt"
mkdir -p "$test_bin"

secrets="$tmp_dir/secrets.json"
fake_token="123456789:$(printf 'T%.0s' {1..30})" # template-generic-ok
cat > "$secrets" <<EOF
{"TELEGRAM_BOT_TOKEN": "$fake_token", "GEMINI_API_KEY": "unused"}
EOF

# Records how curl was invoked, resolves the text@file body the real curl would
# read, then answers as the Telegram API would.
cat > "$test_bin/curl" <<EOF
#!/usr/bin/env bash
config="\$(cat)"
{
  printf 'ARGV: %s\n' "\$*"
  printf 'CONFIG:\n%s\n' "\$config"
  body_path="\$(sed -n 's/.*data-urlencode = "text@\(.*\)"\$/\1/p' <<<"\$config")"
  if [[ -n "\$body_path" && -f "\$body_path" ]]; then
    printf 'BODY:\n'
    cat "\$body_path"
    printf '\n'
  fi
} >> "$capture"
printf '200'
EOF
chmod +x "$test_bin/curl"

run_notify() {
  TELEGRAM_USER_ID=123456789 \
  OPENCLAW_SECRETS_FILE="$secrets" \
  PATH="$test_bin:$PATH" \
    "$SCRIPT_DIR/notify-owner.sh" "$@"
}

output="$(run_notify --text 'backup failed on host' 2>&1)"
grep -Fq 'alert delivered' <<<"$output" || {
  echo "notify-owner did not report delivery" >&2
  exit 1
}

# The token must never appear in the argument vector: arguments are readable by
# any local process through the process list.
argv_lines="$(grep '^ARGV: ' "$capture")"
if grep -Fq "$fake_token" <<<"$argv_lines"; then
  echo "bot token was passed to curl as an argument" >&2
  exit 1
fi
grep -Fq -- '-K' <<<"$argv_lines" || {
  echo "curl was not driven through a config file" >&2
  exit 1
}
grep -Fq "$fake_token" "$capture" || {
  echo "the token never reached curl at all" >&2
  exit 1
}

# Nor may it reach this script's own output.
if grep -Fq "$fake_token" <<<"$output"; then
  echo "bot token leaked into notify-owner output" >&2
  exit 1
fi

# Message text is redacted before it is forwarded off-host.
: > "$capture"
leaky="gemini key AIza$(printf 'C%.0s' {1..30}) in the log"
run_notify --text "$leaky" >/dev/null
if grep -Fq "AIzaCCC" "$capture"; then
  echo "an api key was forwarded to Telegram unredacted" >&2
  exit 1
fi
grep -Fq 'redacted' "$capture" || {
  echo "redaction marker missing from the forwarded message" >&2
  exit 1
}

# A non-200 response has to fail, otherwise a silent alert path looks healthy.
cat > "$test_bin/curl" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf '401'
EOF
chmod +x "$test_bin/curl"
if run_notify --text 'should fail' >/dev/null 2>&1; then
  echo "notify-owner reported success on a failed API call" >&2
  exit 1
fi

# An empty message is refused rather than sent.
cat > "$test_bin/curl" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
printf '200'
EOF
chmod +x "$test_bin/curl"
if run_notify --text '' >/dev/null 2>&1; then
  echo "notify-owner sent an empty message" >&2
  exit 1
fi

# Without an owner id there is nowhere to send: fail rather than pretend.
if TELEGRAM_USER_ID='' OPENCLAW_SECRETS_FILE="$secrets" PATH="$test_bin:$PATH" \
  "$SCRIPT_DIR/notify-owner.sh" --text 'nowhere' >/dev/null 2>&1; then
  echo "notify-owner claimed success with no owner configured" >&2
  exit 1
fi

echo "owner notification test passed"
