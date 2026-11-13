#!/usr/bin/env bash
# Drift check: the committed .claude/ of this repo must match a fresh project export.
# Usage: bash tests/check-project-export.sh
# Only git-tracked files under .claude are compared; files missing on either side are reported.
# The manifest's source-commit line is ignored, because the committed export
# always records the commit before the one that contains it.
REPO="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="$REPO/install.sh"

if [ ! -f "$REPO/.claude/settings.json" ]; then
  echo "no committed export"
  exit 1
fi

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-export-check.XXXXXX")"
cleanup() {
  case "$ROOT" in ""|"/"|"$HOME") return ;; esac
  case "$(basename "$ROOT")" in
    claude-export-check.*) [ -d "$ROOT" ] && rm -rf "$ROOT" ;;
  esac
}
trap cleanup EXIT

git -C "$ROOT" init -q || { echo "git init failed"; exit 1; }
bash "$INSTALL" --project "$ROOT" >/dev/null || { echo "export failed"; exit 1; }

# Compare tracked committed files with the fresh export; report files missing on either side.
# Pre-existing files in the committed tree that are not tracked are ignored.
if ! git -C "$REPO" ls-files --error-unmatch .claude/settings.json >/dev/null 2>&1; then
  echo "no committed export"
  exit 1
fi
mkdir -p "$ROOT/cmp-committed"
git -C "$REPO" ls-files .claude | grep -v -e '^\.claude/worktrees/' -e '^\.claude/settings\.local\.json$' \
  | sed 's|^\.claude/||' | sort > "$ROOT/committed.list"
while IFS= read -r f; do
  mkdir -p "$ROOT/cmp-committed/$(dirname "$f")"
  cp "$REPO/.claude/$f" "$ROOT/cmp-committed/$f" 2>/dev/null || true
done < "$ROOT/committed.list"
mkdir -p "$ROOT/cmp-fresh"
( cd "$ROOT/.claude" && tar -cf - . ) | ( cd "$ROOT/cmp-fresh" && tar -xf - )
for d in cmp-fresh cmp-committed; do
  if [ -f "$ROOT/$d/.orchestration-manifest" ]; then
    grep -v '^source-commit:' "$ROOT/$d/.orchestration-manifest" > "$ROOT/$d/m.tmp"
    mv "$ROOT/$d/m.tmp" "$ROOT/$d/.orchestration-manifest"
  fi
done

if out="$(diff -r "$ROOT/cmp-fresh" "$ROOT/cmp-committed" 2>&1)"; then
  echo "Committed .claude/ matches a fresh export."
  exit 0
fi
echo "Committed .claude/ differs from a fresh export (< fresh, > committed):"
printf '%s\n' "$out" | sed -e "s|$ROOT/cmp-fresh|fresh|g" -e "s|$ROOT/cmp-committed|committed|g" | head -40
echo "Re-run: bash install.sh --project <repo>"
exit 1
