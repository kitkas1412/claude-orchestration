#!/usr/bin/env bash
# Global PreToolUse guard for the web-scraper's public-web MCP servers (fetch, playwright-web, firecrawl), main session AND
# subagents. Exit 2 = block. Requires jq. Intended matcher:
#   mcp__(.*([Ff][Ii][Rr][Ee][Cc][Rr][Aa][Ww][Ll]|[Pp][Ll][Aa][Yy][Ww][Rr][Ii][Gg][Hh][Tt]-[Ww][Ee][Bb]).*|[Ff][Ee][Tt][Cc][Hh]__.*)
# (fetch only as the exact server name, any case, so other servers' fetch_* tools are not routed here).
# Default-deny: every matched tool name must be exactly on the allowlist below (misnamed or aliased servers are denied),
# every top-level argument must be on that tool's argument list and pass its type check, and every url must be at most
# 2048 characters and a public http(s) DNS name: no IP literal in any form, no userinfo, no port other than 80/443, no
# local/internal/metadata or wildcard-DNS names (a best-effort list; new wildcard services appear), no whitespace,
# control, non-ASCII, backslash or percent sign in the host. Defense in depth, NOT a sandbox: a public name that resolves to a private address (DNS rebinding), redirects and in-page navigation are not
# caught here. browser_handle_dialog may only dismiss (accept false), so a page cannot get a destructive confirm accepted.
set -f
command -v jq >/dev/null 2>&1 || { echo "BLOCKED by guard-mcp-web: jq is required" >&2; exit 2; }
INPUT=$(cat)
TOOL=$(printf '%s' "$INPUT" | jq -r 'if (.tool_name | type) == "string" then .tool_name else empty end' 2>/dev/null) || { echo "BLOCKED by guard-mcp-web: could not parse its JSON input" >&2; exit 2; }
[ -z "$TOOL" ] && { echo "BLOCKED by guard-mcp-web: empty input or no string tool_name" >&2; exit 2; }

deny() {
  echo "BLOCKED by guard-mcp-web: $1 ($TOOL). Do not retry or work around this. Report it to the orchestrator or ask the user." >&2
  exit 2
}

# Tool allowlist. Server names must be exactly fetch, playwright-web and firecrawl (Claude Code keeps the hyphen).
case "$TOOL" in
  mcp__fetch__fetch) ;;
  mcp__playwright-web__browser_navigate|mcp__playwright-web__browser_navigate_back|mcp__playwright-web__browser_snapshot|\
  mcp__playwright-web__browser_wait_for|mcp__playwright-web__browser_click|mcp__playwright-web__browser_press_key|\
  mcp__playwright-web__browser_network_requests|mcp__playwright-web__browser_tabs|mcp__playwright-web__browser_handle_dialog|\
  mcp__playwright-web__browser_close) ;;
  mcp__firecrawl__firecrawl_scrape|mcp__firecrawl__firecrawl_map) ;;
  *) deny "web tool is not on the allowlist, or its server is not registered as exactly fetch, playwright-web or firecrawl" ;;
esac

# $spec: per-tool top-level arguments and their rules; $req: required arguments. Prints "ok" or a deny reason.
CHECK='
{"mcp__fetch__fetch":{"url":"url","max_length":"pos_int","start_index":"nonneg_int","raw":"bool","timeout_ms":"pos_num"},
 "mcp__playwright-web__browser_navigate":{"url":"url"},
 "mcp__playwright-web__browser_navigate_back":{},
 "mcp__playwright-web__browser_snapshot":{"target":"str","depth":"nonneg_int"},
 "mcp__playwright-web__browser_wait_for":{"time":"time30","text":"str","textGone":"str"},
 "mcp__playwright-web__browser_click":{"target":"str","element":"str","doubleClick":"bool","button":"button"},
 "mcp__playwright-web__browser_press_key":{"key":"key"},
 "mcp__playwright-web__browser_network_requests":{"static":"bool","filter":"str","all":"bool"},
 "mcp__playwright-web__browser_tabs":{"action":"tab_action","index":"nonneg_int"},
 "mcp__playwright-web__browser_handle_dialog":{"accept":"false"},
 "mcp__playwright-web__browser_close":{},
 "mcp__firecrawl__firecrawl_scrape":{"url":"url","formats":"formats","onlyMainContent":"bool","redactPII":"bool",
   "includeTags":"strarr","excludeTags":"strarr","waitFor":"nonneg_num","timeout":"pos_num"},
 "mcp__firecrawl__firecrawl_map":{"url":"url","search":"str","limit":"limit200","includeSubdomains":"false","sitemap":"sitemap",
   "ignoreQueryParameters":"bool"}} as $spec
| {"mcp__fetch__fetch":["url"],"mcp__playwright-web__browser_navigate":["url"],"mcp__playwright-web__browser_click":["target"],
   "mcp__playwright-web__browser_press_key":["key"],"mcp__playwright-web__browser_tabs":["action"],
   "mcp__playwright-web__browser_handle_dialog":["accept"],"mcp__firecrawl__firecrawl_scrape":["url"],
   "mcp__firecrawl__firecrawl_map":["url","limit"]} as $req
| ["localhost","local","internal","lan","home.arpa","arpa","intranet","corp","nip.io","sslip.io","localtest.me","xip.io",
   "lvh.me","localhost.direct","localho.st","vcap.me","local.gd","traefik.me","lacolhost.com"] as $badsuffix
| def url_reason:
    if type != "string" then "url must be a string"
    elif length > 2048 then "url is longer than 2048 characters"
    elif test("\\A[\\x21-\\x7e]*\\z") | not then "url contains whitespace, control or non-ASCII characters"
    elif test("\\\\") then "url contains a backslash"
    else ((capture("\\Ahttps?://(?<a>[^/?#]*)(?:[/?#].*)?\\z") // null) as $m
      | if $m == null then "url must start with lowercase http:// or https://"
        elif ($m.a | contains("@")) then "userinfo (@) in the url authority is not allowed"
        elif ($m.a | test("[\\[\\]]")) then "IP literal hosts are not allowed"
        elif ($m.a | contains("%")) then "percent-encoding in the host is not allowed"
        else ($m.a | capture("\\A(?<h>[^:]*)(?::(?<p>.*))?\\z")) as $hp
        | if $hp.p != null and $hp.p != "80" and $hp.p != "443" then "explicit ports other than 80 and 443 are not allowed"
          else ($hp.h | ascii_downcase | sub("\\.\\z"; "")) as $h
          | ($h | split(".")) as $l
          | if ($h | length) == 0 or ($h | length) > 253 then "url host is empty or too long"
            elif ($l | length) < 2 then "url host must be a DNS name with a dot"
            elif any($l[]; test("\\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\\z") | not) then "url host is not a valid DNS name"
            elif ($l[-1] | test("\\A(?:[a-z]{2,63}|xn--[a-z0-9-]{1,59})\\z") | not) then "IP literal or non-DNS host is not allowed"
            elif $l[0] == "metadata" then "metadata hosts are not allowed"
            elif any($badsuffix[]; . as $s | $h == $s or ($h | endswith("." + $s))) then "local, internal or wildcard-DNS hosts are not allowed"
            else null end end end) end;
  def chk($r):
    if $r == "url" then url_reason
    elif $r == "str" then (if type == "string" then null else "must be a string" end)
    elif $r == "bool" then (if type == "boolean" then null else "must be a boolean" end)
    elif $r == "false" then (if . == false then null else "must be false" end)
    elif $r == "pos_num" then (if type == "number" and . > 0 then null else "must be a positive number" end)
    elif $r == "nonneg_num" then (if type == "number" and . >= 0 then null else "must be a number >= 0" end)
    elif $r == "pos_int" then (if type == "number" and . == floor and . > 0 then null else "must be a positive integer" end)
    elif $r == "nonneg_int" then (if type == "number" and . == floor and . >= 0 then null else "must be an integer >= 0" end)
    elif $r == "time30" then (if type == "number" and . >= 0 and . <= 30 then null else "must be a number from 0 to 30" end)
    elif $r == "limit200" then (if type == "number" and . == floor and . >= 1 and . <= 200 then null else "must be an integer from 1 to 200" end)
    elif $r == "button" then (if . == "left" or . == "right" or . == "middle" then null else "must be left, right or middle" end)
    elif $r == "key" then (if IN("End","PageDown","PageUp","Home","Escape","ArrowDown","ArrowUp") then null else "must be End, PageDown, PageUp, Home, Escape, ArrowDown or ArrowUp" end)
    elif $r == "tab_action" then (if . == "list" or . == "select" then null else "must be list or select" end)
    elif $r == "sitemap" then (if IN("include","skip","only") then null else "must be include, skip or only" end)
    elif $r == "strarr" then (if type == "array" and all(.[]; type == "string") then null else "must be an array of strings" end)
    elif $r == "formats" then (if type == "array" and all(.[]; IN("markdown","html","rawHtml","links")) then null else "must be an array of markdown, html, rawHtml or links" end)
    else "has no rule" end;
  if has("tool_input") and (.tool_input | type) != "object" then "tool_input must be an object"
  else (.tool_input // {}) as $in | $spec[$t] as $s
  | ([$req[$t] // [] | .[] | . as $k | select(($in | has($k)) | not)] | first) as $miss
  | if $miss != null then "missing required argument " + $miss
    else ([$in | to_entries[] | .key as $k
        | if ($s | has($k)) | not then "unexpected argument " + ($k | tojson)
          else $s[$k] as $r | (.value | chk($r)) as $why
          | if $why == null then empty else "argument " + $k + " " + $why end end] | first) // "ok" end end'
VERDICT=$(printf '%s' "$INPUT" | jq -r --arg t "$TOOL" "$CHECK" 2>/dev/null) || deny "could not parse its JSON input"
[ "$VERDICT" = ok ] || deny "${VERDICT:-argument check failed}"
exit 0
