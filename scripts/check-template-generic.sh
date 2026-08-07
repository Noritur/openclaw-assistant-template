#!/usr/bin/env bash
set -euo pipefail

# Export gate. Refuses to let private instance values reach a shared tree.
#
# Owner-specific values are derived from instance/config.env at run time, so
# this file stores no owner value of its own. Anything that also appears in
# instance/config.env.example is a documented placeholder and is ignored.
#
# Findings report the config key and the file, never the matched value: this
# runs in CI logs that may be public, and echoing the value would repeat the
# leak it exists to prevent.
#
# Run from the root of the tree that is about to be shared:
#   ./scripts/check-template-generic.sh
#
# Environment overrides, used by the export flow and the unit test:
#   ASSISTANT_CONFIG_FILE     private instance config to derive values from
#   ASSISTANT_CONFIG_EXAMPLE  placeholder baseline
#   ASSISTANT_SCAN_ROOT       tree to scan

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="${ASSISTANT_CONFIG_FILE:-$ROOT_DIR/instance/config.env}"
EXAMPLE_FILE="${ASSISTANT_CONFIG_EXAMPLE:-$ROOT_DIR/instance/config.env.example}"
SCAN_ROOT="${ASSISTANT_SCAN_ROOT:-.}"

# Shorter values collide with ordinary English and shell words.
MIN_VALUE_LENGTH=4

# A line carrying this marker is exempt from the always-on scan. Use it for
# deliberately fake identifiers in tests and documentation, next to the value
# itself, so the exemption is visible in review rather than buried in a list.
GENERIC_MARKER='template-generic-ok'

# Non-address literals that are generic by construction. Addresses are handled
# by range instead; see is_generic_ipv4.
GENERIC_LITERALS=(
  123456789
)

CONFIG_KEYS=(
  ASSISTANT_ID
  ASSISTANT_NAME
  OWNER_NAME
  SERVER_IP
  SSH_USER
  BOT_USER
  SSH_KEY_NAME
  TELEGRAM_USER_ID
  TAILDRIVE_TAILNET
  TAILDRIVE_DEVICE
  TAILDRIVE_SHARE
)

SCAN_EXCLUDES=(
  --exclude-dir=.git
  --exclude-dir=instance
  --exclude-dir=checks
)

TAB="$(printf '\t')"
found=0

is_generic_literal() {
  local candidate="$1" literal
  for literal in "${GENERIC_LITERALS[@]}"; do
    [[ "$candidate" == "$literal" ]] && return 0
  done
  return 1
}

# A reachable VPS address is never loopback, private, link-local, CGNAT, or one
# of the RFC 5737 documentation ranges, so those are safe to publish and are
# the ranges every example and test fixture should be drawn from.
is_generic_ipv4() {
  local ip="$1" o1 o2 o3 o4 octet
  IFS=. read -r o1 o2 o3 o4 <<<"$ip"
  for octet in "$o1" "$o2" "$o3" "$o4"; do
    # Not a dotted quad at all, e.g. a version string: not an address to leak.
    [[ "$octet" =~ ^[0-9]{1,3}$ ]] || return 0
    [[ "$octet" -le 255 ]] || return 0
  done

  case "$o1" in
    0|10|127) return 0 ;;                                   # unspecified, RFC 1918, loopback
    100) [[ "$o2" -ge 64 && "$o2" -le 127 ]] && return 0 ;;  # RFC 6598 CGNAT, incl. Tailscale
    169) [[ "$o2" -eq 254 ]] && return 0 ;;                  # link-local
    172) [[ "$o2" -ge 16 && "$o2" -le 31 ]] && return 0 ;;   # RFC 1918
    192)
      [[ "$o2" -eq 168 ]] && return 0                        # RFC 1918
      [[ "$o2" -eq 0 && "$o3" -eq 2 ]] && return 0           # RFC 5737 TEST-NET-1
      ;;
    198) [[ "$o2" -eq 51 && "$o3" -eq 100 ]] && return 0 ;;  # RFC 5737 TEST-NET-2
    203) [[ "$o2" -eq 0 && "$o3" -eq 113 ]] && return 0 ;;   # RFC 5737 TEST-NET-3
    255) [[ "$ip" == "255.255.255.255" ]] && return 0 ;;     # broadcast
  esac

  return 1
}

# Emits "KEY<TAB>VALUE" for every populated key. Sourcing is what decodes the
# printf '%q' quoting assistantctl writes, so it happens in a subshell.
config_pairs() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  (
    set +u
    # shellcheck disable=SC1090
    source "$file" >/dev/null 2>&1 || exit 0
    key=""
    value=""
    for key in "${CONFIG_KEYS[@]}"; do
      value="${!key}"
      [[ -n "$value" ]] && printf '%s\t%s\n' "$key" "$value"
    done
    [[ -n "$INFRA_REPO_SLUG" ]] &&
      printf 'INFRA_REPO_OWNER\t%s\n' "${INFRA_REPO_SLUG%%/*}"
    [[ -n "$MEMORY_REPO_SLUG" ]] &&
      printf 'MEMORY_REPO_OWNER\t%s\n' "${MEMORY_REPO_SLUG%%/*}"
    exit 0
  )
}

# Values the placeholder baseline already contains are not private.
placeholder_values="$(config_pairs "$EXAMPLE_FILE" | cut -f2)"

is_placeholder() {
  [[ -n "$placeholder_values" ]] || return 1
  printf '%s\n' "$placeholder_values" | grep -Fqx -- "$1"
}

instance_scan() {
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "no instance config present; owner-specific scan skipped" >&2
    return 0
  fi

  local key value matches
  while IFS="$TAB" read -r key value; do
    [[ -n "$key" && -n "$value" ]] || continue
    [[ ${#value} -ge $MIN_VALUE_LENGTH ]] || continue
    is_placeholder "$value" && continue
    is_generic_literal "$value" && continue

    matches="$(grep -rIFl "${SCAN_EXCLUDES[@]}" -e "$value" "$SCAN_ROOT" 2>/dev/null || true)"
    if [[ -n "$matches" ]]; then
      printf 'private instance value (%s) present in shared tree:\n' "$key" >&2
      printf '%s\n' "$matches" | sed 's/^/  /' >&2
      found=1
    fi
  done < <(config_pairs "$CONFIG_FILE")
}

# Runs with or without an instance config, so a tree exported without the gate
# still gets a floor of protection.
generic_scan() {
  local class pattern file line text token
  for class in ipv4 digits; do
    case "$class" in
      ipv4) pattern='\b([0-9]{1,3}\.){3}[0-9]{1,3}\b' ;;
      digits) pattern='\b[0-9]{8,12}\b' ;;
    esac

    while IFS=: read -r file line text; do
      [[ -n "$file" && -n "$line" ]] || continue
      [[ "$text" == *"$GENERIC_MARKER"* ]] && continue

      while IFS= read -r token; do
        [[ -n "$token" ]] || continue
        is_generic_literal "$token" && continue
        if [[ "$class" == ipv4 ]] && is_generic_ipv4 "$token"; then
          continue
        fi
        printf 'possible private %s literal: %s:%s\n' "$class" "$file" "$line" >&2
        found=1
      done < <(printf '%s\n' "$text" | grep -oE "$pattern" || true)
    done < <(grep -rIEn "${SCAN_EXCLUDES[@]}" -e "$pattern" "$SCAN_ROOT" 2>/dev/null || true)
  done
}

instance_scan
generic_scan

if [[ "$found" -eq 0 ]]; then
  echo "tree is free of private instance values"
fi

exit "$found"
