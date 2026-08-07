#!/usr/bin/env bash
set -euo pipefail
umask 077

if [[ "$#" -ne 1 ]]; then
  echo "usage: assistant-hostctl status|logs|resources|tailscale" >&2
  exit 64
fi

redact_logs() {
  sed -E \
    -e 's/((token|secret|api[_-]?key|authorization|bearer|password|credential)[=:][[:space:]]*)[^[:space:]]+/\1[redacted]/Ig' \
    -e 's/[0-9]{8,12}:[A-Za-z0-9_-]{20,}/[redacted-telegram-token]/g' \
    -e 's/AIza[A-Za-z0-9_-]{20,}/[redacted-google-api-key]/g' \
    -e 's/AQ\.[A-Za-z0-9_-]{30,}/[redacted-google-api-key]/g' \
    -e 's/github_pat_[A-Za-z0-9_]{20,}/[redacted-github-token]/g' \
    -e 's/gh[pousr]_[A-Za-z0-9]{20,}/[redacted-github-token]/g'
}

case "$1" in
  status)
    printf 'gateway_service='
    systemctl --user is-active openclaw-gateway.service
    export PATH="$HOME/.npm-global/bin:/usr/local/bin:/usr/bin:$PATH"
    openclaw health
    ;;
  logs)
    journalctl --user-unit openclaw-gateway.service \
      --no-pager --lines 120 --output short-iso 2>&1 \
      | redact_logs \
      | tail -c 24576
    ;;
  resources)
    uptime -p
    df -h /
    free -h
    ;;
  tailscale)
    /usr/bin/tailscale status 2>&1 | redact_logs | sed -n '1,100p'
    ;;
  *)
    echo "unsupported host capability" >&2
    exit 64
    ;;
esac
