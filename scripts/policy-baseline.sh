#!/usr/bin/env bash
set -euo pipefail

# Records the digests of the persona files that auto-backup.sh treats as
# model-layer policy. Rewriting this file is how the owner deliberately accepts
# a persona change; auto-backup withholds any policy file that does not match.
#
#   policy-baseline.sh --write   record current workspace state as approved
#   policy-baseline.sh --show    print the recorded baseline

: "${CLAWD_WORKSPACE:?CLAWD_WORKSPACE is required}"
: "${ASSISTANT_RUNTIME_DIR:=/opt/openclaw-assistant/runtime}"

POLICY_FILES=(AGENTS.md IDENTITY.md SECURITY.md SOUL.md)
baseline="$ASSISTANT_RUNTIME_DIR/policy-digests.txt"

case "${1:-}" in
  --show)
    [[ -f "$baseline" ]] || {
      echo "no policy baseline recorded at $baseline" >&2
      exit 1
    }
    cat "$baseline"
    exit 0
    ;;
  --write) ;;
  *)
    echo "usage: policy-baseline.sh --write|--show" >&2
    exit 64
    ;;
esac

# The baseline lives beside the runtime code, root-owned, so the account the
# agent runs as cannot approve its own persona change.
[[ -w "$(dirname "$baseline")" ]] || {
  echo "policy baseline directory is not writable; run this as root" >&2
  exit 1
}

tmp_file="$(mktemp)"
trap 'rm -f "$tmp_file"' EXIT

for file in "${POLICY_FILES[@]}"; do
  path="$CLAWD_WORKSPACE/$file"
  [[ -f "$path" ]] || continue
  printf '%s  %s\n' "$(sha256sum "$path" | cut -d' ' -f1)" "$file" >> "$tmp_file"
done

[[ -s "$tmp_file" ]] || {
  echo "no policy files found under $CLAWD_WORKSPACE" >&2
  exit 1
}

install -o root -g root -m 644 "$tmp_file" "$baseline"
echo "recorded policy baseline:"
cat "$baseline"
