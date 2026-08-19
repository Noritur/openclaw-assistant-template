#!/usr/bin/env bash
set -euo pipefail

# Builds the public template tree from this private repository.
#
# This script prepares and verifies. It does not publish: creating or pushing
# to a public repository is a separate, deliberate act.
#
#   ./scripts/export-public-template.sh <output-dir>
#
# The output is a plain directory. Inspect it, then initialise and push it by
# hand when you are satisfied with what it contains.

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${1:-}"

if [[ -z "$OUTPUT_DIR" ]]; then
  echo "usage: export-public-template.sh <output-dir>" >&2
  exit 64
fi

# Paths that describe this specific instance rather than the reusable template.
# instance/config.env.example is deliberately kept: it is the placeholder file.
EXCLUDED_PATHS=(
  instance/config.env
  checks
  # Owner-specific modules. Excluded as a class rather than by name, so adding
  # one never requires remembering to update this list, and so no module name
  # leaks into the public tree.
  scripts/install-optional-*.sh
)

cd "$ROOT_DIR"

# Export what is committed, not what happens to be lying around. A dirty tree
# means the thing being published was never reviewed.
if [[ -n "$(git status --porcelain)" ]]; then
  echo "refusing to export from a dirty working tree" >&2
  echo "commit or stash first, so the export matches a reviewed commit" >&2
  git status --short >&2
  exit 1
fi

source_commit="$(git rev-parse HEAD)"
source_branch="$(git rev-parse --abbrev-ref HEAD)"

if [[ -e "$OUTPUT_DIR" ]]; then
  echo "output directory already exists: $OUTPUT_DIR" >&2
  echo "choose a path that does not exist, so nothing is silently overwritten" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"

is_excluded() {
  local candidate="$1" excluded
  for excluded in "${EXCLUDED_PATHS[@]}"; do
    # Unquoted on purpose: entries may be glob patterns.
    # shellcheck disable=SC2053
    [[ "$candidate" == $excluded || "$candidate" == "$excluded"/* ]] && return 0
  done
  return 1
}

copied=0
skipped=0
while IFS= read -r tracked; do
  if is_excluded "$tracked"; then
    printf '  excluded: %s\n' "$tracked"
    skipped=$((skipped + 1))
    continue
  fi
  mkdir -p "$OUTPUT_DIR/$(dirname "$tracked")"
  cp -p "$tracked" "$OUTPUT_DIR/$tracked"
  copied=$((copied + 1))
done < <(git ls-files)

echo
printf 'exported %s file(s), excluded %s, from %s at %s\n' \
  "$copied" "$skipped" "$source_branch" "${source_commit:0:12}"

# The gate. Patterns come from this repository's private instance config, and
# the tree being checked is the one about to be published.
echo
echo "running the private instance value scan against the export"
if ! ASSISTANT_CONFIG_FILE="$ROOT_DIR/instance/config.env" \
  ASSISTANT_CONFIG_EXAMPLE="$ROOT_DIR/instance/config.env.example" \
  ASSISTANT_SCAN_ROOT="$OUTPUT_DIR" \
  "$ROOT_DIR/scripts/check-template-generic.sh"; then
  echo >&2
  echo "export refused: the tree still contains private instance values" >&2
  echo "the output directory is left in place for inspection: $OUTPUT_DIR" >&2
  exit 1
fi

# A tracked instance config in the export would both leak and disable the CI
# guard downstream, which is exactly how the original leak reproduced.
if [[ -e "$OUTPUT_DIR/instance/config.env" ]]; then
  echo "export refused: instance/config.env is present in the output" >&2
  exit 1
fi

echo
echo "export ready: $OUTPUT_DIR"
echo
echo "next steps are manual and deliberate:"
echo "  1. inspect the tree"
echo "  2. git init, commit, and push it to a NEW public repository"
echo "  3. mark that repository as a template"
