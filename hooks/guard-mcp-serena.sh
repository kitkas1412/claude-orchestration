#!/usr/bin/env bash
# Global PreToolUse guard for Serena MCP tools (mcp__serena__*), main session AND subagents. Exit 2 = block. Requires jq.
# Default-deny: only the four symbol read tools pass, so unknown future Serena tools are blocked.
# Path-like arguments must exist, stay inside the project (symlinks resolved) and away from secrets. Defense in depth, NOT a sandbox.
set -f
command -v jq >/dev/null 2>&1 || { echo "BLOCKED: jq is required by guard-mcp-serena" >&2; exit 2; }
INPUT=$(cat)
TOOL=$(printf '%s' "$INPUT" | jq -r 'if (.tool_name | type) == "string" then .tool_name else empty end') || { echo "BLOCKED: guard-mcp-serena could not parse its JSON input" >&2; exit 2; }
[ -z "$TOOL" ] && { echo "BLOCKED: guard-mcp-serena got empty input or no string tool_name" >&2; exit 2; }

deny() {
  echo "BLOCKED by guard-mcp-serena: $1 ($TOOL). Do not retry or work around this. Report it to the orchestrator; use Read/Grep/Glob or ask the user." >&2
  exit 2
}

# The server must be registered as exactly "serena"; any other Serena-looking tool name is refused.
LTOOL=$(printf '%s' "$TOOL" | tr '[:upper:]' '[:lower:]')
case "$TOOL" in
  mcp__serena__*) ;;
  *) case "$LTOOL" in *serena*) deny "Serena tool under an unexpected server name; register the server as exactly serena" ;; esac
     exit 0 ;;
esac

case "${TOOL#mcp__serena__}" in
  find_symbol|find_referencing_symbols|get_symbols_overview|find_implementations) ;;
  *) deny "Serena tool is not on the read-only allowlist" ;;
esac

# Path-like keys: every tool_input key ending in "path" except the symbol paths (name_path, name_path_pattern).
SEL='(.tool_input // {}) | to_entries[] | select((.key | ascii_downcase | endswith("path")) and (.key | ascii_downcase | IN("name_path", "name_path_pattern") | not)) | .value'
BAD=$(printf '%s' "$INPUT" | jq -r "[$SEL | select(. != null and (type != \"string\" or contains(\"\\n\")))] | length") || { echo "BLOCKED: guard-mcp-serena could not parse its JSON input" >&2; exit 2; }
[ "$BAD" != 0 ] && deny "path argument is not a single-line string"
PATHS=$(printf '%s' "$INPUT" | jq -r "$SEL | select(type == \"string\")") || { echo "BLOCKED: guard-mcp-serena could not parse its JSON input" >&2; exit 2; }
[ -z "$PATHS" ] && exit 0

# Real path of an existing file or directory (symlinks resolved). Fails if it does not exist.
# On Darwin perl goes first: /usr/bin/python3 may be the Xcode shim.
resolve_perl() { command -v perl >/dev/null 2>&1 && [ -e "$1" ] && perl -MCwd=realpath -e 'my $p = realpath($ARGV[0]); defined $p or exit 1; print "$p\n"' "$1" 2>/dev/null; }
resolve_py() { command -v python3 >/dev/null 2>&1 && python3 -I -c 'import os,sys;print(os.path.realpath(sys.argv[1], strict=True))' "$1" 2>/dev/null; }
resolve() {
  if [ "$(uname -s)" = Darwin ]; then
    resolve_perl "$1" || resolve_py "$1"
  else
    resolve_py "$1" || resolve_perl "$1"
  fi
}

# Project root, found like Serena 1.3.0 find_project_root: starting at $CLAUDE_PROJECT_DIR (else the input cwd),
# the first ancestor with .serena/project.yml, else the first with .git (file or directory), else the start directory.
START=${CLAUDE_PROJECT_DIR:-}
[ -z "$START" ] && START=$(printf '%s' "$INPUT" | jq -r 'if (.cwd | type) == "string" then .cwd else empty end')
[ -z "$START" ] && deny "cannot determine the project root"
START=$(resolve "$START") || deny "cannot resolve the project root"
[ -z "$START" ] && deny "cannot resolve the project root"
RR=""
D=$START
while :; do
  [ -f "$D/.serena/project.yml" ] && { RR=$D; break; }
  [ "$D" = / ] && break
  D=$(dirname "$D")
done
if [ -z "$RR" ]; then
  D=$START
  while :; do
    [ -e "$D/.git" ] && { RR=$D; break; }
    [ "$D" = / ] && break
    D=$(dirname "$D")
  done
fi
[ -z "$RR" ] && RR=$START

# Secret-looking paths (mirrors the Read deny rules). Argument is lowercased and relative.
secret() {
  case "$1" in
    .env|.env.*|*/.env|*/.env.*)               deny "secret env file ($2)" ;;
    secrets/*|*/secrets/*)                     deny "secrets directory ($2)" ;;
    .ssh|.ssh/*|*/.ssh|*/.ssh/*|.aws|.aws/*|*/.aws|*/.aws/*|.gnupg|.gnupg/*|*/.gnupg|*/.gnupg/*|.kube|.kube/*|*/.kube|*/.kube/*) deny "credential directory ($2)" ;;
    .config/gh|.config/gh/*|*/.config/gh|*/.config/gh/*) deny "gh credential directory ($2)" ;;
    *.pem|*.key|*id_rsa*|*id_ed25519*)         deny "key file ($2)" ;;
    .npmrc|*/.npmrc|.netrc|*/.netrc|.pypirc|*/.pypirc|.git-credentials|*/.git-credentials|.docker/config.json|*/.docker/config.json) deny "credential file ($2)" ;;
    *credentials*)                             deny "credentials file ($2)" ;;
    *git-publish.registry*)                    deny "git-publish registry ($2)" ;;
  esac
}

while IFS= read -r P; do
  [ -z "$P" ] && continue
  L=$(printf '%s' "$P" | tr '[:upper:]' '[:lower:]' | sed -e 's#//*#/#g')
  case "$L" in
    /*|"~"*)                                   deny "absolute or home path ($P)" ;;
    *\\*)                                      deny "backslash in path ($P)" ;;
    ..|../*|*/..|*/../*)                       deny "path leaves the project ($P)" ;;
  esac
  secret "$L" "$P"
  R=$(resolve "$RR/$P") || deny "path does not exist or cannot be resolved ($P)"
  case "$R" in
    "$RR") ;;
    "$RR"/*) secret "$(printf '%s' "${R#"$RR"/}" | tr '[:upper:]' '[:lower:]')" "$P" ;;
    *) deny "path resolves outside the project ($P)" ;;
  esac
done <<EOF
$PATHS
EOF
exit 0
