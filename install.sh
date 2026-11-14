#!/usr/bin/env bash
# Installs this orchestration setup into ~/.claude. Run this yourself.
# Usage: install.sh --dry-run            show what would change, write nothing
#        install.sh                      back up, then install
#        install.sh --no-apple-design    skip the optional apple-design clone
#        install.sh --no-backup          skip the backup of ~/.claude
#        install.sh --project <repo>     export into <repo>/.claude (for cloud sessions);
#                                        no backup, no apple-design
#        install.sh --project <repo> --set-agent   also set "agent": "orchestrator"
# <repo> must be the root of a git work tree. It refuses symlinks under <repo>/.claude
# and a settings.json with disableAllHooks, and warns about risky existing settings.
# It never deletes files. Project export does not remove files that were removed
# upstream; tests/check-project-export.sh reports them as drift.
set -euo pipefail

REPO="$(cd "$(dirname "$0")" && pwd)"
TARGET="$HOME/.claude"
APPLE_DESIGN_URL="https://github.com/dickwu/apple-design-skill.git"
APPLE_DESIGN_COMMIT="904b0ee"

DRY=0
APPLE=1
BACKUP_ON=1
PROJECT=""
SET_AGENT=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --no-apple-design) APPLE=0 ;;
    --no-backup) BACKUP_ON=0 ;;
    --set-agent) SET_AGENT=1 ;;
    --project)
      [ $# -ge 2 ] || { echo "--project needs a repository path" >&2; exit 1; }
      PROJECT="$2"; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
  shift
done

if [ -n "$PROJECT" ]; then
  [ -d "$PROJECT" ] && [ "$(git -C "$PROJECT" rev-parse --is-inside-work-tree 2>/dev/null)" = "true" ] \
    || { echo "--project needs a git work tree: $PROJECT" >&2; exit 1; }
  TOP="$(git -C "$PROJECT" rev-parse --show-toplevel)"
  [ "$(cd "$TOP" && pwd -P)" = "$(cd "$PROJECT" && pwd -P)" ] \
    || { echo "--project must be the root of a git work tree: $PROJECT" >&2; exit 1; }
  PROJECT="$(cd "$PROJECT" && pwd)"
  TARGET="$PROJECT/.claude"
  BACKUP_ON=0
  APPLE=0
elif [ "$SET_AGENT" = 1 ]; then
  echo "--set-agent only works with --project" >&2; exit 1
fi

REQUIRED="jq"
if [ "$BACKUP_ON" = 1 ] && [ "$DRY" = 0 ]; then REQUIRED="jq rsync"; fi
for tool in $REQUIRED; do
  command -v "$tool" >/dev/null || { echo "Missing required tool: $tool" >&2; exit 1; }
done

MANAGED="$REPO/settings.managed.json"
STAGE=""
cleanup() { if [ -n "$STAGE" ]; then rm -rf "$STAGE"; fi; }
trap cleanup EXIT

current_settings() {
  if [ -f "$TARGET/settings.json" ]; then cat "$TARGET/settings.json"; else echo '{}'; fi
}

# Managed values win; other existing settings stay. Lists only gain entries.
merge_settings() {
  current_settings | jq --slurpfile managed "$MANAGED" '
    . as $cur
    | $managed[0] as $m
    | ($cur * ($m | del(.permissions, .hooks)))
    | .permissions = (($cur.permissions // {}) * ($m.permissions | del(.deny)))
    | .permissions.deny = (($cur.permissions.deny // []) + ($m.permissions.deny - ($cur.permissions.deny // [])))
    | .hooks = (reduce ($m.hooks | to_entries[]) as $e
        (($cur.hooks // {}); .[$e.key] = ((.[$e.key] // []) + ($e.value - (.[$e.key] // [])))))
  '
}

# Rewrites user-level paths for a repo-level export (stdin to stdout). Lines that
# mention git-publish, .claude/plugins, apple-design or ~/.claude/settings.json keep
# ~/.claude: those are about the user-level install.
rewrite_paths() {
  sed -e 's|command: "\$HOME/\.claude/hooks/\([^"]*\)"|command: '"'"'"$CLAUDE_PROJECT_DIR"/.claude/hooks/\1'"'"'|' \
      -e '/git-publish/b' -e '/\.claude\/plugins/b' -e '/apple-design/b' \
      -e '/~\/\.claude\/settings\.json/b' -e '/<HOME>\/\.claude\/settings\.json/b' \
      -e 's|~/\.claude/|<REPO_ROOT>/.claude/|g' \
      -e 's|<HOME>/\.claude/|<REPO_ROOT>/.claude/|g'
}

# Copies a file into the stage, rewriting paths in markdown files.
stage_file() {
  mkdir -p "$STAGE/$(dirname "$2")"
  case "$2" in
    *.md)
      if ! { rewrite_paths < "$1" > "$STAGE/$2.tmp" && mv -f "$STAGE/$2.tmp" "$STAGE/$2"; }; then
        rm -f "$STAGE/$2.tmp"
        echo "Failed to stage: $2" >&2; exit 1
      fi ;;
    *) cp "$1" "$STAGE/$2" ;;
  esac
}

# Builds the project export under $STAGE and the project-level managed settings.
build_project_stage() {
  STAGE="$(mktemp -d "${TMPDIR:-/tmp}/claude-orchestration-stage.XXXXXX")"
  ( cd "$REPO" && find agents skills -type f -not -name '.DS_Store' | sort ) | while IFS= read -r f; do
    stage_file "$REPO/$f" "$f"
  done
  ( cd "$REPO/third_party" && find skills -type f -not -name '.DS_Store' | sort ) | while IFS= read -r f; do
    stage_file "$REPO/third_party/$f" "$f"
  done
  for h in guard-bash.sh guard-write.sh readonly-bash.sh stop-verify-reminder.sh filter-test-output.sh guard-mcp-serena.sh; do
    stage_file "$REPO/hooks/$h" "hooks/$h"
  done
  stage_file "$REPO/ORCHESTRATION.md" ORCHESTRATION.md
  mkdir -p "$STAGE/rules"
  cat "$REPO/project/rules-preamble.md" "$REPO/CLAUDE.md" | rewrite_paths > "$STAGE/rules/orchestration.md"
  {
    echo "Generated by install.sh --project from claude-orchestration."
    echo "Do not edit these files by hand; re-run the export instead."
    echo "source-commit: $(git -C "$REPO" rev-parse HEAD 2>/dev/null || echo unknown)"
  } > "$STAGE/.orchestration-manifest"

  MANAGED="$STAGE/settings.managed.json"
  jq --slurpfile p "$REPO/project/settings.project.json" --argjson setagent "$SET_AGENT" '
    del(.model, .permissions.defaultMode)
    | .hooks.PreToolUse |= map(.hooks |= map(
        .command |= sub("^\\$HOME/\\.claude/hooks/(?<n>.*)$"; "\"$CLAUDE_PROJECT_DIR\"/.claude/hooks/\(.n)")))
    | .permissions.deny += ($p[0].permissions.deny - .permissions.deny)
    | if $setagent == 1 then .agent = "orchestrator" else . end
  ' "$REPO/settings.managed.json" > "$MANAGED"
}

# Refuses symlinks in the export target (copies would write through them).
check_target_symlinks() {
  local found="" p d
  if [ -L "$TARGET" ]; then found="$TARGET"; fi
  for p in settings.json ORCHESTRATION.md .orchestration-manifest; do
    if [ -L "$TARGET/$p" ]; then found="$found
$TARGET/$p"; fi
  done
  if [ -z "$found" ]; then
    for d in agents skills hooks rules; do
      if [ -L "$TARGET/$d" ]; then found="$found
$TARGET/$d"
      elif [ -d "$TARGET/$d" ]; then found="$found
$(find "$TARGET/$d" -type l)"
      fi
    done
  fi
  found="$(printf '%s\n' "$found" | sed '/^$/d')"
  if [ -n "$found" ]; then
    echo "Refusing to export: symlinks in the target:" >&2
    printf '%s\n' "$found" | sed 's/^/  /' >&2
    exit 1
  fi
}

# Refuses or warns about existing settings that weaken the guards (never edits them).
check_existing_settings() {
  local f="$TARGET/settings.json" w
  [ -f "$f" ] || return 0
  if [ "$(jq -r '.disableAllHooks // false' "$f")" = "true" ]; then
    echo "Refusing to export: $f has disableAllHooks: true, so the guards would be inert." >&2
    exit 1
  fi
  w="$(jq -r --slurpfile m "$MANAGED" '
    ([$m[0].hooks[][].hooks[].command]) as $mc
    | ((.permissions.allow // [])[] | "permissions.allow: \(.)"),
      (if .permissions.defaultMode == "bypassPermissions" then "permissions.defaultMode: bypassPermissions" else empty end),
      ((.hooks // {}) | to_entries[] | .key as $k | (.value[]? | (.hooks // [])[]? | .command // empty)
        | select(. as $c | ($mc | index($c)) == null) | "hook (\($k)) not managed: \(.)")
  ' "$f")"
  if [ -n "$w" ]; then
    echo "WARNING: existing $f has settings that may weaken the guards (kept; merge only adds):" >&2
    printf '%s\n' "$w" | sed 's/^/  /' >&2
  fi
}

# Prints "<source path> <path relative to the target>".
list_files() {
  if [ -n "$PROJECT" ]; then
    (cd "$STAGE" && find . -type f -not -name 'settings.managed.json' | sed 's|^\./||' | sort | while IFS= read -r f; do
      printf '%s\t%s\n' "$STAGE/$f" "$f"
    done)
    return
  fi
  (cd "$REPO" && find agents hooks skills CLAUDE.md ORCHESTRATION.md -type f -not -name '.DS_Store' | sort | while IFS= read -r f; do
    printf '%s\t%s\n' "$REPO/$f" "$f"
  done)
  (cd "$REPO/third_party" && find skills -type f -not -name '.DS_Store' | sort | while IFS= read -r f; do
    printf '%s\t%s\n' "$REPO/third_party/$f" "$f"
  done)
}

if [ -n "$PROJECT" ]; then
  check_target_symlinks
  build_project_stage
  check_existing_settings
fi

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

if [ "$BACKUP_ON" = 1 ] && [ -d "$TARGET" ]; then
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
  if [ -n "$PROJECT" ]; then
    # Copy then rename, so a destination symlink is replaced, never written through.
    # Each step must abort: a failing cp inside an && list would not trigger set -e.
    if ! cp -- "$src" "$TARGET/$rel.tmp.$$"; then
      rm -f "$TARGET/$rel.tmp.$$"
      echo "Failed to copy: $rel" >&2; exit 1
    fi
    if ! mv -f -- "$TARGET/$rel.tmp.$$" "$TARGET/$rel"; then
      rm -f "$TARGET/$rel.tmp.$$"
      echo "Failed to install: $rel" >&2; exit 1
    fi
  else
    cp "$src" "$TARGET/$rel"
  fi
done
if [ -n "$PROJECT" ]; then
  for h in guard-bash.sh guard-write.sh readonly-bash.sh stop-verify-reminder.sh filter-test-output.sh guard-mcp-serena.sh; do
    chmod +x "$TARGET/hooks/$h"
  done
else
  chmod +x "$TARGET"/hooks/*.sh
fi

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

if [ -n "$PROJECT" ]; then
  echo "Exported to $TARGET. Review and commit .claude/ and any CLAUDE.md changes yourself."
  exit 0
fi

echo "Installed. Run bash tests/verify-installed.sh, then check /status and /agents in Claude Code."
if [ -n "${BACKUP:-}" ]; then
  echo "To restore changed files: rsync -a \"$BACKUP/\" \"$TARGET/\""
fi
