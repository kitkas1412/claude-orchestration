#!/usr/bin/env bash
# Stop hook for the orchestrator agent. Non-blocking reminder: never exits 2.
# Prints one reminder per distinct set of changed code files in a session. Requires jq.
set -f
INPUT=$(cat)
[ "$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false')" = "true" ] && exit 0
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty')
SESSION=$(printf '%s' "$INPUT" | jq -r '.session_id // "unknown"')
[ -z "$CWD" ] && exit 0
git -C "$CWD" rev-parse --is-inside-work-tree >/dev/null 2>&1 || exit 0

CHANGED=$(git -C "$CWD" status --porcelain 2>/dev/null \
  | grep -Ev '\.(md|mdx|txt|rst|png|jpe?g|gif|svg|lock)"?$' \
  | sort)
[ -z "$CHANGED" ] && exit 0

STATE="${TMPDIR:-/tmp}/claude-verify-reminder-${SESSION}"
HASH=$(printf '%s' "$CHANGED" | shasum | cut -d' ' -f1)
[ -f "$STATE" ] && [ "$(cat "$STATE")" = "$HASH" ] && exit 0
printf '%s' "$HASH" > "$STATE"

jq -n '{systemMessage: "Code files have uncommitted changes. Confirm test-runner and code-reviewer covered them before reporting done."}'
exit 0
