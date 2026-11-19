#!/usr/bin/env bash
# Per-agent PreToolUse hook for the web-scraper agent (matcher Write). Exit 2 = block. Requires jq.
# Only Write passes (Edit, MultiEdit, NotebookEdit and anything else are denied), and only to an absolute path under
# "$HOME/scrape-out/" (HOME from the environment; denied if unset, relative or "/") that ends in .json, .jsonl, .csv, .md
# or .py (a .py file must be named scrape_<slug>.py, slug a-z 0-9 _ -, any case), has no "..", "." or empty segment, no
# control character (newline, CR and tab included), no hidden segment below scrape-out, no
# .claude, .git, .config, .ssh or .aws segment, and no basename that tools load or run on their own (checked
# case-insensitively): conftest.py, sitecustomize.py, usercustomize.py, setup.py, __init__.py, __main__.py, noxfile.py,
# test_*.py, *_test.py, claude.md, claude.local.md, agents.md, gemini.md.
# Symlinks: every existing component from "$HOME/scrape-out" down to the file (both included) must not be a symlink, so
# the write cannot leave that directory. Components above it may be symlinks; instead the physical path (pwd -P of the
# nearest existing ancestor plus the rest of the lexical path) must lie under the physical "$HOME/scrape-out/" (cd -P of
# HOME) and pass the same segment checks. Check-then-write race not covered.
set -f
export LC_ALL=C
command -v jq >/dev/null 2>&1 || { echo "BLOCKED by scrape-agent-write: jq is required" >&2; exit 2; }
INPUT=$(cat)
TOOL=$(printf '%s' "$INPUT" | jq -r 'if (.tool_name | type) == "string" then .tool_name else empty end' 2>/dev/null) || { echo "BLOCKED by scrape-agent-write: could not parse its JSON input" >&2; exit 2; }
# Control characters are rejected inside jq: $(...) strips trailing newlines, so a shell check would miss "a.md\n".
CTL=$(printf '%s' "$INPUT" | jq -r 'if (.tool_input.file_path | type) == "string" and any(.tool_input.file_path | explode[]; . < 32 or . == 127) then "y" else "n" end' 2>/dev/null) || { echo "BLOCKED by scrape-agent-write: could not parse its JSON input" >&2; exit 2; }
P=$(printf '%s' "$INPUT" | jq -r 'if (.tool_input.file_path | type) == "string" then .tool_input.file_path else empty end' 2>/dev/null) || { echo "BLOCKED by scrape-agent-write: could not parse its JSON input" >&2; exit 2; }

deny() {
  echo "BLOCKED by scrape-agent-write: $1 (${P:-no file_path}). Write only new .json, .jsonl, .csv, .md or .py files under \$HOME/scrape-out/. Do not work around this; report it to the orchestrator." >&2
  exit 2
}
[ "$TOOL" = Write ] || deny "only the Write tool is allowed for this agent (got ${TOOL:-none})"
[ "$CTL" = n ] || deny "control character in path"
[ -n "$P" ] || deny "missing or non-string file_path"

# HOME: absolute, not "/", no control character; physical form via cd -P.
H=${HOME%/}
[ -n "$H" ] || deny "HOME is unset or /"
case "$H" in /*) ;; *) deny "HOME is not absolute" ;; esac
case "$H" in *[[:cntrl:]]*) deny "control character in HOME" ;; esac
HP=$(cd -P -- "$H" 2>/dev/null && pwd -P) || deny "could not resolve HOME"
[ -n "$HP" ] && [ "$HP" != / ] || deny "HOME resolves to /"
B="$H/scrape-out"

# segment rules, applied to the lexical path and again to the physical path; $2 = required prefix
seg_check() {
  local l
  l=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$1" in *[[:cntrl:]]*) deny "control character in path" ;; esac
  case "$1" in /*) ;; *) deny "path must be absolute" ;; esac
  case "$1" in *//*) deny "empty path segment (//)" ;; esac
  case "$1" in */../*|*/..|*/./*|*/.) deny "dot or dot-dot path segment" ;; esac
  case "$1" in "$2"/scrape-out/*) ;; *) deny "path must be inside \$HOME/scrape-out/" ;; esac
  case "/${1#"$2"/scrape-out/}" in */.*) deny "hidden path segment below \$HOME/scrape-out" ;; esac
  case "$l" in */.claude/*|*/.git/*|*/.config/*|*/.ssh/*|*/.aws/*) deny "protected directory in path" ;; esac
}
seg_check "$P" "$H"
case "$P" in *.json|*.jsonl|*.csv|*.md|*.py) ;; *) deny "file extension must be .json, .jsonl, .csv, .md or .py" ;; esac
BASE=${P##*/}
case "$BASE" in .*) deny "hidden file name" ;; esac
LB=$(printf '%s' "$BASE" | tr '[:upper:]' '[:lower:]')
case "$LB" in
  conftest.py|sitecustomize.py|usercustomize.py|setup.py|__init__.py|__main__.py|noxfile.py|test_*.py|*_test.py|\
  claude.md|claude.local.md|agents.md|gemini.md) deny "file name is loaded or run automatically by tools; use e.g. scrape_<slug>.py" ;;
esac
# .py files must be scrape_<slug>.py (slug: a-z 0-9 _ -, any case), so a page cannot plant httpx.py, argparse.py etc. that
# Python would import first from the script directory.
case "$LB" in
  *.py) S1=${LB%.py}
    case "$S1" in scrape_*) ;; *) deny "a .py file must be named scrape_<slug>.py" ;; esac
    case "${S1#scrape_}" in *[!a-z0-9_-]*) deny "a .py file must be named scrape_<slug>.py (slug: letters, digits, _ and -)" ;; esac ;;
esac

# No existing component from $HOME/scrape-out down to the file may be a symlink.
[ -L "$P" ] && deny "target file is a symlink"
[ -e "$P" ] && [ ! -f "$P" ] && deny "target exists and is not a regular file"
X=${P%/*}
while :; do
  [ -L "$X" ] && deny "symlink inside the scrape-out tree"
  [ "$X" = "$B" ] && break
  X=${X%/*}
  [ -n "$X" ] || deny "could not locate \$HOME/scrape-out"
done

# Physical path: nearest existing ancestor resolved with pwd -P, plus the not-yet-existing rest of the lexical path.
A=${P%/*}
while [ -n "$A" ] && [ ! -e "$A" ]; do A=${A%/*}; done
[ -n "$A" ] || A=/
[ -d "$A" ] || deny "an existing path component is not a directory"
RA=$(cd -P -- "$A" 2>/dev/null && pwd -P) || deny "could not resolve the parent directory"
REST=${P#"$A"}
[ "$A" = / ] && REST=$P
[ "$RA" = / ] && RA=''
seg_check "$RA$REST" "$HP"
exit 0
