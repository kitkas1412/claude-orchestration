#!/usr/bin/env bash
# Global PreToolUse guard for the official Figma MCP server (mcp__figma__*) and ReadMcpResourceTool, main session AND subagents.
# Exit 2 = block. Requires jq.
# Default-deny: only the allowlisted Figma tools pass, so unknown future Figma tools are blocked. Tools that spend Figma AI or
# Weave credits (generate_image, generate_vector_illustration, weave_*) are denied by user decision.
# Figma is a remote service: whatever is in the arguments leaves the machine. Arguments are checked against a per-tool allowlist
# of keys (taken from the live server schemas), strict shapes (fileKey, nodeId, sessionId, planKey, skillNames) and secret-like
# content filters on free text. use_figma code gets a length cap and string tripwires for network/eval/import primitives and
# plugin APIs the server forbids; these
# tripwires are trivially bypassable by obfuscation and are NOT a sandbox. Deny reasons name a category only and never echo
# the input. ReadMcpResourceTool on server figma is limited to Figma skill documents. Defense in depth, NOT a sandbox.
set -f
command -v jq >/dev/null 2>&1 || { echo "BLOCKED by guard-mcp-figma: jq is required" >&2; exit 2; }
INPUT=$(cat)
TOOL=$(printf '%s' "$INPUT" | jq -r 'if (.tool_name | type) == "string" then .tool_name else empty end' 2>/dev/null) || { echo "BLOCKED by guard-mcp-figma: could not parse its JSON input" >&2; exit 2; }
[ -z "$TOOL" ] && { echo "BLOCKED by guard-mcp-figma: empty input or no string tool_name" >&2; exit 2; }

deny() {
  echo "BLOCKED by guard-mcp-figma: $1 ($TOOL). Do not retry or work around this. Report it to the orchestrator or ask the user." >&2
  exit 2
}

# ReadMcpResourceTool branch. server must be a string. For server "figma", only Figma skill documents
# (skill://figma/<skill>/<path>.md) pass, and keys other than server and uri are refused. Other servers: subagent calls are
# denied, main-session calls pass through with no decision (unchanged behavior).
# Per https://code.claude.com/docs/en/hooks, agent_id is present only when the hook fires inside a subagent/teammate, while
# agent_type is also present in the main session when it runs with --agent; so only a non-empty agent_id marks a subagent call.
if [ "$TOOL" = "ReadMcpResourceTool" ]; then
  RES='
  def set($k): (.[$k] | type) == "string" and (.[$k] | length) > 0;
  if (has("tool_input") | not) or (.tool_input | type) != "object" then "type"
  else .tool_input as $in
  | (($in | keys_unsorted) - ["server","uri"]) as $extra
  | if ($in.server | type) != "string" then "server"
    elif $in.server != "figma" then (if set("agent_id") then "subagent" else "pass" end)
    elif ($extra | length) > 0 then "extra"
    elif ($in.uri | type) != "string" or ($in.uri | length) > 300 then "uri"
    elif ($in.uri | test("\\Askill://figma/[a-z0-9-]+/[A-Za-z0-9_./-]+\\.md\\z") | not) then "uri"
    elif ($in.uri | test("\\.\\.")) or ($in.uri | ltrimstr("skill://") | test("//")) then "uri"
    else "ok" end
  end'
  VERDICT=$(printf '%s' "$INPUT" | jq -r "$RES" 2>/dev/null) || deny "could not parse its JSON input"
  case "$VERDICT" in
    ok|pass) exit 0 ;;
    type) deny "tool_input must be an object" ;;
    server) deny "ReadMcpResourceTool needs a string server argument" ;;
    subagent) deny "subagents may read MCP resources only from the figma server (skill documents); ask the orchestrator" ;;
    extra) deny "ReadMcpResourceTool accepts only server and uri" ;;
    uri) deny "only Figma skill documents (skill://figma/<skill>/<file>.md) may be read" ;;
    *) deny "argument check failed" ;;
  esac
fi

# The server must be registered as exactly "figma"; the hook matcher also routes other servers' figma-looking tools here
# (for example mcp__plugin_figma_figma__* or mcp__figma-desktop__*).
LTOOL=$(printf '%s' "$TOOL" | tr '[:upper:]' '[:lower:]')
case "$TOOL" in
  mcp__figma__*) ;;
  *) case "$LTOOL" in *figma*) deny "Figma tool under an unexpected server name; register the official server as exactly figma" ;; esac
     deny "not a Figma tool; register the official server as exactly figma" ;;
esac

case "${TOOL#mcp__figma__}" in
  create_session|whoami|get_metadata|get_design_context|get_screenshot|get_variable_defs|search_design_system|get_libraries|get_code_connect_map|create_new_file|use_figma) ;;
  generate_image|generate_vector_illustration|weave_*) deny "Figma tool spends paid AI or Weave credits and is disabled by user decision" ;;
  *) deny "Figma tool is not on the allowlist" ;;
esac

# Prints "ok" or a short category. Per-tool required and optional keys from the live schemas; any other key is refused.
CHECK='
def text_ok($max): type == "string" and length >= 1 and length <= $max
  and (gsub("[\n\t]"; "") | test("[\\p{Cc}\u2028\u2029\u0085]") | not);
def oneline($max): type == "string" and length >= 1 and length <= $max and (test("[\\p{Cc}\u2028\u2029\u0085]") | not);
# Secret checks are tripwires, not detection. Long runs cover base64/base64url; hex up to 40 chars passes here so code can hold
# image hashes, and free text additionally flags hex runs of 32+.
def long_run: any(match("[A-Za-z0-9+=_-]{32,}"; "g").string;
  test("[0-9]") and test("[A-Za-z]") and (test("\\A[0-9A-Fa-f]+\\z") and length <= 40 | not));
def url_cred: test("://[^/\\s:]+:[^@\\s]+@");
def tok_prefix:
  test("(^|[^A-Za-z0-9])sk-") or test("(^|[^A-Za-z0-9])sk_(live|test)_") or test("(^|[^A-Za-z0-9])(ghp_|gho_|github_pat_)")
  or test("AKIA[0-9A-Z]{16}") or test("xox[abp]-") or test("-----BEGIN") or test("(^|[^A-Za-z0-9])figd_") or long_run or url_cred;
def q_secret: tok_prefix or test("[0-9A-Fa-f]{32,}") or test("(password|passwd|secret|token|api_?key)\\s*[:=]"; "i");
# Code: bare `token =` stays allowed (design-token code); only credential-like names assigned a string literal are flagged.
def code_secret: tok_prefix
  or test("(password|passwd|secret|api_?key|secret_?key|access_?token|auth_?token)\\s*[=:]\\s*[\"'"'"'`]"; "i");
def code_net: test("fetch\\s*\\(") or test("XMLHttpRequest") or test("WebSocket") or test("importScripts")
  or test("(^|[^A-Za-z0-9_$.])eval\\s*\\(") or test("\\(\\s*0\\s*,\\s*eval\\s*\\)") or test("new\\s+Function")
  or test("(^|[^A-Za-z0-9_$.])Function\\s*\\(") or test("\\.(eval|Function)\\s*\\(") or test("(^|[^A-Za-z0-9_$.])import\\s*\\(");
# Plugin APIs the Figma server tells agents never to use in use_figma.
def code_api: test("createImageAsync") or test("loadAllPagesAsync") or test("setPluginData");
def fk_ok: type == "string" and test("\\A[A-Za-z0-9]{22,128}\\z");
# nodeId per live schema: get_screenshot, get_variable_defs and get_code_connect_map take only 1:2; get_design_context and
# get_metadata also take I1:2;3:4... (instance) and T1:2;3:4;5:6 (exactly two ;-segments).
def nid_plain: test("\\A[0-9]+[:-][0-9]+\\z");
def nid_ok($t): type == "string" and length <= 200 and (nid_plain
  or (IN($t; "get_design_context", "get_metadata") and (test("\\AI[0-9]+[:-][0-9]+(;[0-9]+[:-][0-9]+)*\\z")
      or test("\\AT[0-9]+[:-][0-9]+(;[0-9]+[:-][0-9]+){2}\\z"))));
def uuid_ok: type == "string" and test("\\A[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\\z");
def skills_ok($allowed): type == "string" and length >= 1 and length <= 300
  and (split(",") | all(gsub("^\\s+|\\s+$"; "") | ltrimstr("resource:") as $n | $allowed | index([$n]) != null));
def int_in($lo; $hi): type == "number" and . == floor and . >= $lo and . <= $hi;
def list_ok: type == "string" and length <= 200 and test("\\A[A-Za-z0-9 ,._+#-]*\\z");
{
  "create_session":       {"req":["fileKey","description"],"opt":[]},
  "whoami":               {"req":[],"opt":[]},
  "get_metadata":         {"req":["fileKey"],"opt":["nodeId","sessionId"]},
  "get_design_context":   {"req":["nodeId","fileKey"],"opt":["sessionId","clientFrameworks","clientLanguages","disableCodeConnect","excludeScreenshot","forceCode","skillNames"]},
  "get_screenshot":       {"req":["nodeId","fileKey"],"opt":["sessionId","maxDimension","contentsOnly","enableBase64Response"]},
  "get_variable_defs":    {"req":["nodeId","fileKey"],"opt":["sessionId"]},
  "search_design_system": {"req":["fileKey","queries"],"opt":["includeLibraryKeys","disableCodeConnect","sessionId"]},
  "get_libraries":        {"req":["fileKey"],"opt":["offset","sessionId"]},
  "get_code_connect_map": {"req":["nodeId","fileKey"],"opt":["codeConnectLabel","sessionId"]},
  "create_new_file":      {"req":["fileName","planKey","editorType"],"opt":["projectId"]},
  "use_figma":            {"req":["fileKey","code","description"],"opt":["sessionId","skillNames"]}
} as $spec
| (["figma-use","figma-generate-design","figma-generate-library"]) as $skills
| if (has("tool_input") | not) or (.tool_input | type) != "object" then "type"
  else .tool_input as $in
  | (($in | keys_unsorted) - ($spec[$t].req + $spec[$t].opt)) as $extra
  | if ($extra | length) > 0 then "extra"
    elif ($spec[$t].req | any(. as $k | $in | has($k) | not)) then "missing"
    elif ($in | has("fileKey")) and ($in.fileKey | fk_ok | not) then "fileKey"
    elif ($in | has("nodeId")) and ($in.nodeId | nid_ok($t) | not) then "nodeId"
    elif ($in | has("sessionId")) and ($in.sessionId | uuid_ok | not) then "sessionId"
    elif ($in | has("description")) and ($in.description | text_ok(2000) | not) then "description"
    elif ($in | has("description")) and ($in.description | q_secret) then "description-secret"
    elif ($in | has("skillNames")) and ($in.skillNames | skills_ok(if $t == "get_design_context" then $skills + ["figma-design-to-code"] else $skills end) | not) then "skillNames"
    elif ([$in | to_entries[] | select(.key | IN("disableCodeConnect","excludeScreenshot","forceCode","contentsOnly","enableBase64Response")) | .value | type != "boolean"] | any) then "boolean"
    elif ($in | has("maxDimension")) and ($in.maxDimension | int_in(1; 65536) | not) then "number"
    elif ($in | has("offset")) and ($in.offset | int_in(0; 1000000) | not) then "number"
    elif ([$in.clientFrameworks, $in.clientLanguages] | any(. != null and (list_ok | not))) then "client"
    elif ($in | has("codeConnectLabel")) and (($in.codeConnectLabel | oneline(100) | not) or ($in.codeConnectLabel | q_secret)) then "label"
    elif ($in | has("queries")) and ($in.queries | type != "array" or length < 1 or length > 20
           or any(.[]; type != "object" or ((keys_unsorted - ["entity","query"]) | length) > 0
                  or (IN(.entity; "component","variable","style") | not) or (.query | oneline(300) | not))) then "queries"
    elif ($in | has("queries")) and ($in.queries | any(.[]; .query | q_secret)) then "query-secret"
    elif ($in | has("includeLibraryKeys")) and ($in.includeLibraryKeys | type != "array" or length > 50
           or any(.[]; type != "string" or (test("\\A[A-Za-z0-9:_-]{1,128}\\z") | not))) then "libraryKeys"
    elif ($in | has("fileName")) and ($in.fileName | oneline(200) | not) then "fileName"
    elif ($in | has("fileName")) and ($in.fileName | q_secret) then "fileName-secret"
    elif ($in | has("planKey")) and ($in.planKey | type != "string" or (test("\\A(team|organization)::[0-9]+\\z") | not)) then "planKey"
    elif ($in | has("editorType")) and (IN($in.editorType; "design","figjam","slides","figspec","figmake") | not) then "editorType"
    elif ($in | has("projectId")) and ($in.projectId | type != "string" or (test("\\A[A-Za-z0-9:_-]{1,64}\\z") | not)) then "projectId"
    elif ($in | has("code")) and ($in.code | type != "string" or length < 1 or length > 50000) then "code-shape"
    elif ($in | has("code")) and ($in.code | code_net) then "code-net"
    elif ($in | has("code")) and ($in.code | code_api) then "code-api"
    elif ($in | has("code")) and ($in.code | code_secret) then "code-secret"
    else "ok" end
  end'
VERDICT=$(printf '%s' "$INPUT" | jq -r --arg t "${TOOL#mcp__figma__}" "$CHECK" 2>/dev/null) || deny "could not parse its JSON input"
case "$VERDICT" in
  ok) ;;
  type) deny "tool_input must be an object" ;;
  missing) deny "a required argument is missing" ;;
  extra) deny "unexpected argument for ${TOOL#mcp__figma__}; use only the parameters in the live Figma schema" ;;
  fileKey) deny "fileKey must be 22-128 characters from [A-Za-z0-9]" ;;
  nodeId) deny "nodeId must look like 123:456 (I123:456;789:10 and T1:2;3:4;5:6 only for get_design_context and get_metadata)" ;;
  sessionId) deny "sessionId must be a UUID returned by create_session" ;;
  description) deny "description must be 1-2000 characters without control characters" ;;
  description-secret) deny "description looks like it contains a secret or long token" ;;
  skillNames) deny "skillNames may list only figma-use, figma-generate-design, figma-generate-library (optionally prefixed resource:)" ;;
  boolean) deny "a flag argument must be a boolean" ;;
  number) deny "a numeric argument is out of range or not an integer" ;;
  client) deny "clientFrameworks/clientLanguages must be short comma-separated names" ;;
  label) deny "codeConnectLabel must be a single line of at most 100 characters without secrets" ;;
  queries) deny "queries must be 1-20 objects with entity (component|variable|style) and a single-line query of 1-300 characters" ;;
  query-secret) deny "a query looks like it contains a secret or long token" ;;
  libraryKeys) deny "includeLibraryKeys must be up to 50 short key strings" ;;
  fileName) deny "fileName must be a single line of 1-200 characters" ;;
  fileName-secret) deny "fileName looks like it contains a secret or long token" ;;
  planKey) deny "planKey must look like team::<digits> or organization::<digits>" ;;
  editorType) deny "editorType must be design, figjam, slides, figspec or figmake" ;;
  projectId) deny "projectId must be a short id string" ;;
  code-shape) deny "code must be a string of 1-50000 characters" ;;
  code-net) deny "code uses a network, dynamic-eval or dynamic-import primitive (fetch, XMLHttpRequest, WebSocket, importScripts, eval, Function, import())" ;;
  code-api) deny "code uses a Figma API the server forbids in use_figma (createImageAsync, loadAllPagesAsync, setPluginData)" ;;
  code-secret) deny "code looks like it contains a secret or long token" ;;
  *) deny "argument check failed" ;;
esac
exit 0
