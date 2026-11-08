#!/usr/bin/env bash
# Checks that every file managed by this repository is installed unchanged.
# Usage: bash tests/verify-installed.sh
REPO="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${CLAUDE_TARGET:-$HOME/.claude}"
checked=0
fail=0

check() {
  checked=$((checked+1))
  if [ ! -f "$2" ]; then echo "MISSING  $3"; fail=1
  elif ! cmp -s "$1" "$2"; then echo "CHANGED  $3"; fail=1; fi
}

while IFS= read -r f; do
  check "$REPO/$f" "$TARGET/$f" "$f"
done < <(cd "$REPO" && find agents hooks skills CLAUDE.md ORCHESTRATION.md -type f -not -name '.DS_Store')

while IFS= read -r f; do
  check "$REPO/third_party/$f" "$TARGET/$f" "$f"
done < <(cd "$REPO/third_party" && find skills -type f -not -name '.DS_Store')

if [ "$fail" = 0 ]; then
  echo "All $checked managed files match this repository."
else
  echo "Some managed files differ from this repository."
  exit 1
fi
