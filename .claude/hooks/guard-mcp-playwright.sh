#!/usr/bin/env bash
# Global PreToolUse guard for Playwright MCP tools (mcp__playwright__*), main session AND subagents. Exit 2 = block. Requires jq.
# Default-deny: only the allowlisted browser tools pass, so unknown future Playwright tools are blocked.
# Checks: a port-9 probe (the dead-proxy trap must stay dead: /dev/tcp connect plus lsof), a per-tool top-level argument allowlist,
# then every tool_input key at any depth: file-like keys are refused and URL-like keys must point at localhost,
# 127.0.0.1 or [::1] over http(s). Defense in depth, NOT a sandbox.
set -f
command -v jq >/dev/null 2>&1 || { echo "BLOCKED by guard-mcp-playwright: jq is required" >&2; exit 2; }
INPUT=$(cat)
TOOL=$(printf '%s' "$INPUT" | jq -r 'if (.tool_name | type) == "string" then .tool_name else empty end' 2>/dev/null) || { echo "BLOCKED by guard-mcp-playwright: could not parse its JSON input" >&2; exit 2; }
[ -z "$TOOL" ] && { echo "BLOCKED by guard-mcp-playwright: empty input or no string tool_name" >&2; exit 2; }

deny() {
  echo "BLOCKED by guard-mcp-playwright: $1 ($TOOL). Do not retry or work around this. Report it to the orchestrator or ask the user." >&2
  exit 2
}

# The server must be registered as exactly "playwright"; the hook matcher also routes other servers' browser tools here.
LTOOL=$(printf '%s' "$TOOL" | tr '[:upper:]' '[:lower:]')
case "$TOOL" in
  mcp__playwright__*) ;;
  *) case "$LTOOL" in *playwright*) deny "Playwright tool under an unexpected server name; register the server as exactly playwright" ;; esac
     deny "not a Playwright tool; register the server as exactly playwright" ;;
esac

case "${TOOL#mcp__playwright__}" in
  browser_navigate|browser_navigate_back|browser_tabs|browser_snapshot|browser_take_screenshot|browser_console_messages|browser_network_requests|browser_resize|browser_wait_for|browser_close|browser_handle_dialog|browser_click|browser_hover|browser_drag|browser_type|browser_press_key|browser_select_option|browser_fill_form|browser_emulate_media) ;;
  *) deny "Playwright tool is not on the allowlist" ;;
esac

# Dead-proxy trap: the server is expected to run with a proxy on port 9 that nothing listens on. If something does, it could become real egress.
# Signal 1: a bash-builtin loopback connect (sees listeners of any user; refusal is immediate). The target is hard-coded on purpose.
# Signal 2: lsof (only sees the current user's sockets on some systems). If bash has no /dev/tcp support, lsof is required (fail closed).
PROBE_ERR=$( (LC_ALL=C; exec 3<>/dev/tcp/127.0.0.1/9) 2>&1 ); PROBE_RC=$?
[ "$PROBE_RC" = 0 ] && deny "something is listening on port 9; the proxy trap would become real egress"
PROBE_OK=1
case "$PROBE_ERR" in *"No such file"*) PROBE_OK=0 ;; esac
if command -v lsof >/dev/null 2>&1; then
  [ -z "$(lsof -nP -iTCP:9 -sTCP:LISTEN 2>/dev/null)" ] || deny "something is listening on port 9; the proxy trap would become real egress"
elif [ "$PROBE_OK" = 0 ]; then
  deny "lsof is required to verify nothing listens on port 9 because bash has no /dev/tcp support (fail closed)"
fi

# Walk every key at any depth (objects inside objects and arrays). Prints "file", "url" or "ok".
# URL values must match the whole string (\A...\z): lowercase http(s) scheme, a loopback host, optional port 1..65535,
# then only printable ASCII without space or backslash (no userinfo possible: "@" can only follow "/", "?" or "#").
# ALLOW: per-tool top-level argument allowlist (0.0.85 inputSchema.properties minus file keys such as filename).
CHECK='
{"browser_navigate":["url"],"browser_navigate_back":[],"browser_tabs":["action","index","url"],"browser_snapshot":["boxes","depth","target"],
 "browser_take_screenshot":["element","fullPage","scale","target","type"],"browser_console_messages":["all","level"],"browser_network_requests":["all","filter","static"],
 "browser_resize":["height","width"],"browser_wait_for":["text","textGone","time"],"browser_close":[],"browser_handle_dialog":["accept","promptText"],
 "browser_click":["button","doubleClick","element","modifiers","target"],"browser_hover":["element","target"],"browser_drag":["endElement","endTarget","startElement","startTarget"],
 "browser_type":["element","slowly","submit","target","text"],"browser_press_key":["key"],"browser_select_option":["element","target","values"],
 "browser_fill_form":["fields"],"browser_emulate_media":["colorScheme","contrast","forcedColors","media","reducedMotion"]} as $allow
| def url_ok:
  type == "string"
  and ([capture("\\Ahttps?://(?:localhost|127\\.0\\.0\\.1|\\[::1\\])(?::(?<p>[0-9]{1,5}))?(?:[/?#][\\x21-\\x5b\\x5d-\\x7e]*)?\\z")]
       | length == 1 and (.[0].p == null or ((.[0].p | tonumber) as $n | $n >= 1 and $n <= 65535)));
if (has("tool_input") and (.tool_input | type) != "object") then "type"
else ((.tool_input // {}) | keys_unsorted - ($allow[$t] // [])) as $extra
  | if ($extra | length) > 0 then "extra:" + $extra[0] else
[(.tool_input // {}) | .. | objects | to_entries[] | (.key | ascii_downcase) as $k
  | if ($k == "filename" or $k == "file" or $k == "files" or $k == "directory" or $k == "outputdirectory" or $k == "saveto" or $k == "output"
        or ($k | endswith("path")) or ($k | endswith("paths")) or ($k | endswith("dir")) or ($k | endswith("file")) or ($k | endswith("files"))
        or ($k | endswith("directory")) or ($k | endswith("folder"))) then "file"
    elif (($k | contains("url")) or ($k | contains("uri")) or ($k | contains("href")) or $k == "src" or $k == "link" or $k == "location" or $k == "origin" or $k == "host") and (.value | url_ok | not) then "url"
    else empty end] | first // "ok" end end'
VERDICT=$(printf '%s' "$INPUT" | jq -r --arg t "${TOOL#mcp__playwright__}" "$CHECK" 2>/dev/null) || deny "could not parse its JSON input"
case "$VERDICT" in
  ok) ;;
  type) deny "tool_input must be an object" ;;
  extra:*) deny "unexpected argument ${VERDICT#extra:} for ${TOOL#mcp__playwright__}" ;;
  file) deny "file arguments are not allowed; output goes to --output-dir" ;;
  url) deny "URL argument must be http(s)://localhost, 127.0.0.1 or [::1] with an optional port 1-65535" ;;
  *) deny "argument check failed" ;;
esac
exit 0
