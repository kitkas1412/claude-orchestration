#!/usr/bin/env bash
# Installs this orchestration setup into ~/.claude. Run this yourself.
# Usage: install.sh --dry-run            show what would change, write nothing
#        install.sh                      back up, then install
#        install.sh --no-apple-design    skip the optional apple-design clone
# It never deletes files.
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
TARGET="$HOME/.claude"
APPLE_DESIGN_URL="https://github.com/dickwu/apple-design-skill.git"
APPLE_DESIGN_COMMIT="904b0ee"

DRY=0
APPLE=1
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY=1 ;;
    --no-apple-design) APPLE=0 ;;
    *) echo "Unknown option: $arg" >&2; exit 1 ;;
  esac
done

for tool in jq rsync; do
  command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 1; }
done

current_settings() {
  if [ -f "$TARGET/settings.json" ]; then cat "$TARGET/settings.json"; else echo '{}'; fi
}

# Managed values win; other existing settings stay. Lists only gain entries.
merge_settings() {
  current_settings | jq --slurpfile managed "$REPO/settings.managed.json" '
    . as $cur
    | $managed[0] as $m
    | ($cur * ($m | del(.permissions, .hooks)))
    | .permissions = (($cur.permissions // {}) * ($m.permissions | del(.deny)))
    | .permissions.deny = (($cur.permissions.deny // []) + ($m.permissions.deny - ($cur.permissions.deny // [])))
    | .hooks = (reduce ($m.hooks | to_entries[]) as $e
        (($cur.hooks // {}); .[$e.key] = ((.[$e.key] // []) + ($e.value - (.[$e.key] // [])))))
  '
}

# Prints "<source path> <path relative to ~/.claude>".
list_files() {
  (cd "$REPO" && find agents hooks skills CLAUDE.md ORCHESTRATION.md -type f -not -name '.DS_Store' | sort | while IFS= read -r f; do
    printf '%s\t%s\n' "$REPO/$f" "$f"
  done)
  (cd "$REPO/third_party" && find skills -type f -not -name '.DS_Store' | sort | while IFS= read -r f; do
    printf '%s\t%s\n' "$REPO/third_party/$f" "$f"
  done)
}

if [ "$DRY" = 1 ]; then
  echo "DRY RUN: nothing will be written."
  list_files | while IFS="$(printf '\t')" read -r src rel; do
    if [ ! -e "$TARGET/$rel" ]; then echo "create  $rel"
    elif cmp -s "$src" "$TARGET/$rel"; then echo "same    $rel"
    else echo "modify  $rel"; fi
  done
  echo "--- settings.json diff"
  current_settings | jq . > "${TMPDIR:-/tmp}/claude-orchestration-settings.$$"
  merge_settings | diff -u "${TMPDIR:-/tmp}/claude-orchestration-settings.$$" - || true
  rm -f "${TMPDIR:-/tmp}/claude-orchestration-settings.$$"
  exit 0
fi

if [ -d "$TARGET" ]; then
  BACKUP="$HOME/.claude.backup-$(date +%Y%m%d-%H%M%S)"
  rsync -a \
    --exclude 'projects/' --exclude 'file-history/' --exclude 'paste-cache/' \
    --exclude 'history.jsonl' --exclude 'cache/' --exclude 'telemetry/' \
    --exclude 'shell-snapshots/' --exclude 'session-env/' --exclude 'sessions/' \
    --exclude 'daemon/' --exclude 'daemon.log' --exclude 'state/' --exclude 'jobs/' \
    --exclude 'ide/' --exclude 'downloads/' --exclude 'backups/' --exclude '.DS_Store' \
    "$TARGET/" "$BACKUP/"
  echo "Backup created: $BACKUP"
fi

mkdir -p "$TARGET"
list_files | while IFS="$(printf '\t')" read -r src rel; do
  mkdir -p "$TARGET/$(dirname "$rel")"
  cp "$src" "$TARGET/$rel"
done
chmod +x "$TARGET"/hooks/*.sh

TMP="$(mktemp "$TARGET/settings.json.XXXXXX")"
merge_settings > "$TMP"
jq empty "$TMP"
chmod 644 "$TMP"
mv "$TMP" "$TARGET/settings.json"

if [ "$APPLE" = 1 ] && [ ! -e "$TARGET/skills/apple-design" ]; then
  if git clone -q "$APPLE_DESIGN_URL" "$TARGET/skills/apple-design" \
    && git -C "$TARGET/skills/apple-design" checkout -q "$APPLE_DESIGN_COMMIT"; then
    echo "Installed apple-design at $APPLE_DESIGN_COMMIT"
  else
    echo "Warning: could not install apple-design. Everything else is installed." >&2
  fi
fi

echo "Installed. Run bash tests/verify-installed.sh, then check /status and /agents in Claude Code."
if [ -n "${BACKUP:-}" ]; then
  echo "To restore changed files: rsync -a \"$BACKUP/\" \"$TARGET/\""
fi
