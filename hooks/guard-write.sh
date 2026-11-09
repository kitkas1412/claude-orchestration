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
lower() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]'; }
# Match case-insensitively (default macOS filesystem) and after removing "." and ".." segments.
NORM=$(lower "$P" | sed -e 's#//*#/#g' -e ':a' -e 's#/\./#/#' -e 'ta' -e ':b' -e 's#/[^/][^/]*/\.\./#/#' -e 'tb')
H=$(lower "$HOME")
CLEAN=$(printf '%s' "$NORM" | sed -E 's/\.env\.(example|sample|template|dist)$/ALLOWED/')

case "$CLEAN" in
  .env|.env.*|*/.env|*/.env.*)                          deny "secret env file" ;;
  .git/*|*/.git/*)                                      deny ".git internals" ;;
  */.ssh/*|*/.aws/*|*/.gnupg/*|*/.kube/*)               deny "credential directory" ;;
  *.pem|*/id_rsa*|*/id_ed25519*|*/.npmrc|*/.netrc|*/.pypirc) deny "credential file" ;;
  */.claude/settings*.json|*/.claude/hooks/*)           deny "guard-rail configuration is protected" ;;
  */.claude/git-publish.registry)                       deny "git-publish registry is protected; use git-publish.sh in your own terminal" ;;
  "$H"/.gitconfig|"$H"/.config/git/config)              deny "global git configuration is protected" ;;
  "$H"/.claude/agents/*|"$H"/.claude/claude.md|"$H"/.claude/skills/*) deny "user-level agent configuration is protected; edit it manually" ;;
esac
exit 0
