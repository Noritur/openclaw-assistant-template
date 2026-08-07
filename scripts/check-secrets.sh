#!/usr/bin/env bash
set -euo pipefail
umask 077

patterns=(
  'sk-(proj-|ant-)?[A-Za-z0-9_-]{20,}'
  'AIza[A-Za-z0-9_-]{20,}'
  'AQ\.[A-Za-z0-9_-]{30,}'
  'gh[pousr]_[A-Za-z0-9]{20,}'
  'github_pat_[A-Za-z0-9_]{20,}'
  '[0-9]{8,12}:[A-Za-z0-9_-]{20,}'
  '"(apiKey|api_key|botToken|bot_token|token)"[[:space:]]*:[[:space:]]*"[A-Za-z0-9._-]{20,}"'
  '-----BEGIN (OPENSSH|RSA|EC|DSA) PRIVATE KEY-----'
)

found=0
scan_file() {
  local file="$1"
  local label="${2:-$file}"
  local pattern lines
  [[ -f "$file" ]] || return 0
  for pattern in "${patterns[@]}"; do
    lines="$(grep -InE "$pattern" "$file" 2>/dev/null | cut -d: -f1 | sort -nu | paste -sd, - || true)"
    if [[ -n "$lines" ]]; then
      printf 'possible secret: %s line(s) %s\n' "$label" "$lines" >&2
      found=1
    fi
  done
}

scan_staged_file() {
  local file="$1"
  local staged
  staged="$(mktemp)"
  if ! git show ":$file" > "$staged" 2>/dev/null; then
    printf 'could not inspect staged file: %s\n' "$file" >&2
    rm -f "$staged"
    found=1
    return
  fi
  if [[ -s "$staged" ]] && ! grep -Iq . "$staged"; then
    printf 'cannot secret-scan staged binary file: %s\n' "$file" >&2
    rm -f "$staged"
    found=1
    return
  fi
  scan_file "$staged" "$file"
  rm -f "$staged"
}

if [[ "${1:-}" == "--staged" ]]; then
  git rev-parse --is-inside-work-tree >/dev/null
  while IFS= read -r -d '' file; do
    scan_staged_file "$file"
  done < <(git diff --cached --name-only --diff-filter=ACMR -z)
elif [[ $# -gt 0 ]]; then
  for file in "$@"; do
    scan_file "$file"
  done
else
  while IFS= read -r file; do
    scan_file "$file"
  done < <(git ls-files)
fi

exit "$found"
