#!/usr/bin/env bash
# Global PreToolUse guard for Edit/Write/NotebookEdit. Exit 2 = block. Requires jq.
set -f
INPUT=$(cat)
P=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')
[ -z "$P" ] && exit 0

deny() {
  echo "BLOCKED by guard-write: $1 ($P). Do not work around this. Report it to the orchestrator; the user must make this change manually." >&2
  exit 2
}
CLEAN=$(printf '%s' "$P" | sed -E 's/\.env\.(example|sample|template|dist)$/ALLOWED/')

case "$CLEAN" in
  .env|.env.*|*/.env|*/.env.*)                          deny "secret env file" ;;
  .git/*|*/.git/*)                                      deny ".git internals" ;;
  */.ssh/*|*/.aws/*|*/.gnupg/*|*/.kube/*)               deny "credential directory" ;;
  *.pem|*/id_rsa*|*/id_ed25519*|*/.npmrc|*/.netrc|*/.pypirc) deny "credential file" ;;
  */.claude/settings*.json|*/.claude/hooks/*)           deny "guard-rail configuration is protected" ;;
  "$HOME"/.claude/agents/*|"$HOME"/.claude/CLAUDE.md|"$HOME"/.claude/skills/*) deny "user-level agent configuration is protected; edit it manually" ;;
esac
exit 0