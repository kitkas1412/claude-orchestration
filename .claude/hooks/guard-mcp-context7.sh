#!/usr/bin/env bash
# Global PreToolUse guard for Context7 MCP tools (mcp__context7__*), main session AND subagents. Exit 2 = block. Requires jq.
# Default-deny: only resolve-library-id and query-docs pass, so unknown future Context7 tools are blocked.
# Context7 is a remote service: whatever is in the arguments leaves the machine. Arguments are checked against a per-tool
# allowlist of keys, strict shapes (query, libraryName, libraryId, language), and content filters (absolute paths, secret-like strings
# on query, libraryName and libraryId; code-like text on query). Deny reasons name a category only and never echo the input. Defense in depth, NOT a sandbox.
set -f
command -v jq >/dev/null 2>&1 || { echo "BLOCKED by guard-mcp-context7: jq is required" >&2; exit 2; }
INPUT=$(cat)
TOOL=$(printf '%s' "$INPUT" | jq -r 'if (.tool_name | type) == "string" then .tool_name else empty end' 2>/dev/null) || { echo "BLOCKED by guard-mcp-context7: could not parse its JSON input" >&2; exit 2; }
[ -z "$TOOL" ] && { echo "BLOCKED by guard-mcp-context7: empty input or no string tool_name" >&2; exit 2; }

deny() {
  echo "BLOCKED by guard-mcp-context7: $1 ($TOOL). Do not retry or work around this. Report it to the orchestrator or ask the user." >&2
  exit 2
}

# The server must be registered as exactly "context7"; the hook matcher also routes other servers' context7-looking tools here.
LTOOL=$(printf '%s' "$TOOL" | tr '[:upper:]' '[:lower:]')
case "$TOOL" in
  mcp__context7__*) ;;
  *) case "$LTOOL" in *context7*) deny "Context7 tool under an unexpected server name; register the server as exactly context7" ;; esac
     deny "not a Context7 tool; register the server as exactly context7" ;;
esac

case "${TOOL#mcp__context7__}" in
  resolve-library-id|query-docs) ;;
  *) deny "Context7 tool is not on the allowlist" ;;
esac

# Prints "ok" or a short category. Per-tool required keys; any other key is refused.
CHECK='
def oneline: type == "string" and (test("[\\p{Cc}\u2028\u2029\u0085]") | not);
def q_ok:
  oneline and (length >= 1 and length <= 300);
def q_path: test("/(users|home|root|private|etc|var|tmp|opt|volumes|mnt)/"; "i") or test("~/") or test("[A-Za-z]:\\\\");
def long_run: any(match("[A-Za-z0-9+=]{32,}"; "g").string;
  test("[0-9]") and test("[A-Za-z]") and (test("\\A[0-9A-Fa-f]+\\z") and length < 40 | not));
def q_secret:
  test("(^|[^A-Za-z0-9])sk-") or test("(^|[^A-Za-z0-9])sk_(live|test)_") or test("(^|[^A-Za-z0-9])(ghp_|gho_|github_pat_)") or test("AKIA[0-9A-Z]{16}") or test("xox[abp]-")
  or test("-----BEGIN") or test("ctx7sk"; "i") or test("(password|passwd|secret|token|api_key)\\s*="; "i") or long_run;
def id_path: (.[1:] | split("/")[0] | ascii_downcase) as $s | ["users","home","root","private","etc","var","tmp","opt","volumes","mnt"] | index($s) != null;
def q_code: ([match("[;{}]"; "g")] | length) >= 3 or (test("=>") and test("[{}]"));
def lib_ok: oneline and (length >= 1 and length <= 100) and test("\\A[A-Za-z0-9 ._@/+-]+\\z");
def id_ok: type == "string" and test("\\A/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)?\\z")
  and ((split("/") | index("..")) == null);
def lang_ok: type == "string" and length <= 40 and test("\\A[A-Za-z0-9 +#._-]*\\z");
{"resolve-library-id":["query","libraryName"],"query-docs":["libraryId","query"]} as $req
| if (has("tool_input") | not) or (.tool_input | type) != "object" then "type"
  else .tool_input as $in
  | (($in | keys_unsorted) - ($req[$t] + (if $t == "query-docs" then ["language"] else [] end))) as $extra
  | if ($extra | length) > 0 then "extra:" + $extra[0]
    elif ($req[$t] | any(. as $k | $in | has($k) | not)) then "missing"
    elif ($in | has("language")) and ($in.language | lang_ok | not) then "language"
    elif ($in.query | q_ok | not) then "query-shape"
    elif ($in.query | q_path) then "query-path"
    elif ($in.query | q_secret) then "query-secret"
    elif ($in.query | q_code) then "query-code"
    elif $t == "resolve-library-id" and ($in.libraryName | lib_ok | not) then "libraryName"
    elif $t == "resolve-library-id" and ($in.libraryName | q_path) then "libraryName-path"
    elif $t == "resolve-library-id" and ($in.libraryName | q_secret) then "libraryName-secret"
    elif $t == "query-docs" and ($in.libraryId | id_ok | not) then "libraryId"
    elif $t == "query-docs" and ($in.libraryId | id_path) then "libraryId-path"
    elif $t == "query-docs" and ($in.libraryId | q_secret) then "libraryId-secret"
    else "ok" end
  end'
VERDICT=$(printf '%s' "$INPUT" | jq -r --arg t "${TOOL#mcp__context7__}" "$CHECK" 2>/dev/null) || deny "could not parse its JSON input"
case "$VERDICT" in
  ok) ;;
  type) deny "tool_input must be an object" ;;
  missing) deny "a required argument is missing" ;;
  extra:*) deny "unexpected argument ${VERDICT#extra:} for ${TOOL#mcp__context7__}" ;;
  language) deny "language argument is invalid" ;;
  query-shape) deny "query must be a single-line string of 1 to 300 characters" ;;
  query-path) deny "query contains a filesystem path; use only public library names and generic questions" ;;
  query-secret) deny "query looks like it contains a secret or long token" ;;
  query-code) deny "query looks like code; use only generic questions" ;;
  libraryName) deny "libraryName must be 1-100 single-line characters from [A-Za-z0-9 ._@/+-]" ;;
  libraryId) deny "libraryId must look like /org/project or /org/project/version" ;;
  libraryName-path) deny "libraryName contains a filesystem path; use only public library names" ;;
  libraryName-secret) deny "libraryName looks like it contains a secret or long token" ;;
  libraryId-path) deny "libraryId looks like a filesystem path; use only public library ids" ;;
  libraryId-secret) deny "libraryId looks like it contains a secret or long token" ;;
  *) deny "argument check failed" ;;
esac
exit 0
