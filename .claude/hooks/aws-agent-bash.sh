#!/usr/bin/env bash
# Strict per-agent Bash allowlist for the aws-engineer agent. Exit code 2 = block the Bash call. Requires jq.
# Fail-closed token grammar: outside single quotes only [A-Za-z0-9_./:=,@%+-], spaces and tabs are allowed, plus the
# operators |, && and ; standing alone. Single-quoted text may hold anything. Everything else ($ { } # * ? [ ] ~ \ < >
# ( ) ` " ! lone &, newline, control characters) is denied, so there is no expansion, substitution, redirection,
# glob, comment or background job to reason about. Each word's value is the unquoted and single-quoted parts joined.
# The first word of every segment must be: aws jq grep head tail wc cut tr sort uniq echo date, each with its own
# argument rules. No word may be an absolute, home or parent path or name a credential file. aws segments are then
# judged by guard-aws.sh, which this hook runs from its own directory (it also runs globally). Not a sandbox.
set -f
export LC_ALL=C
command -v jq >/dev/null 2>&1 || { echo "BLOCKED by aws-agent-bash: jq is required" >&2; exit 2; }
INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty') || { echo "BLOCKED by aws-agent-bash: could not parse its JSON input" >&2; exit 2; }
[ -z "$CMD" ] && exit 0

block() { echo "BLOCKED by aws-agent-bash: $1. Allowed: aws jq grep head tail wc cut tr sort uniq echo date; literal arguments; single quotes; | && ; only." >&2; exit 2; }

# --- strict tokenizer: WV word values, WS segment index per word ---
WV=(); WS=(); SEGN=0; SEGHAS=0; cur=''; have=0; i=0; len=${#CMD}
pushw() { if [ "$have" = 1 ]; then WV+=("$cur"); WS+=("$SEGN"); SEGHAS=1; fi; cur=''; have=0; }
endseg() { pushw; [ "$SEGHAS" = 1 ] || block "empty command before an operator"; SEGN=$((SEGN+1)); SEGHAS=0; }
while [ "$i" -lt "$len" ]; do
  c=${CMD:i:1}
  case "$c" in
    [A-Za-z0-9_./:=,@%+-]) cur+=$c; have=1 ;;
    ' '|$'\t') pushw ;;
    "'") rest=${CMD:i+1}
         case "$rest" in *"'"*) ;; *) block "unterminated single quote" ;; esac
         body=${rest%%\'*}; cur+=$body; have=1; i=$((i+${#body}+1)) ;;
    '|') case "${CMD:i+1:1}" in '|'|'&') block "only |, && and ; are allowed as operators" ;; esac; endseg ;;
    ';') [ "${CMD:i+1:1}" = ';' ] && block "only |, && and ; are allowed as operators"; endseg ;;
    '&') [ "${CMD:i+1:1}" = '&' ] || block "background & and &> are not allowed"
         i=$((i+1)); endseg ;;
    $'\n'|$'\r') block "newline outside single quotes is not allowed (one command line)" ;;
    [\$\{\}\#\*\?\[\]\~\\\<\>\(\)\`\"\!]) block "character $c outside single quotes is not allowed" ;;
    *) block "character outside single quotes is not allowed" ;;
  esac
  i=$((i+1))
done
pushw
[ "$SEGHAS" = 1 ] || block "empty command after an operator"

# --- path rule for every word value ---
path_ok() {
  case "$1" in
    /*|'~'*) block "absolute or home path" ;;
    *../*|*/..|*=/*|*='~'*|*,/*|*,'~'*) block "parent, absolute or home path" ;;
    *.[Aa][Ww][Ss]*|*.[Ss][Ss][Hh]*|*.[Kk][Uu][Bb][Ee]*|*.[Dd][Oo][Cc][Kk][Ee][Rr]*|*.[Gg][Nn][Uu][Pp][Gg]*|\
    *.[Cc][Oo][Nn][Ff][Ii][Gg]/[Gg][Hh]*|*.[Cc][Oo][Nn][Ff][Ii][Gg]/[Gg][Cc][Ll][Oo][Uu][Dd]*|*.[Aa][Zz][Uu][Rr][Ee]*|\
    *.[Cc][Aa][Rr][Gg][Oo]/[Cc][Rr][Ee][Dd][Ee][Nn][Tt][Ii][Aa][Ll][Ss]*|*.[Nn][Ee][Tt][Rr][Cc]*|*.[Nn][Pp][Mm][Rr][Cc]*|\
    *.[Pp][Yy][Pp][Ii][Rr][Cc]*|*.[Gg][Ii][Tt]-[Cc][Rr][Ee][Dd][Ee][Nn][Tt][Ii][Aa][Ll][Ss]*|*_[Hh][Ii][Ss][Tt][Oo][Rr][Yy]*|\
    *.[Tt][Ff][Ss][Tt][Aa][Tt][Ee]*|*.[Tt][Ff][Vv][Aa][Rr][Ss]*|\
    *.[Pp][Ee][Mm]|*[Ii][Dd]_[Rr][Ss][Aa]*|*[Ii][Dd]_[Ee][Dd]25519*) block "credential or secret-bearing path" ;;
  esac
  # .env only as a file name or path component (jq '.Environment' stays allowed)
  case "$1" in
    .[Ee][Nn][Vv]|.[Ee][Nn][Vv].*|.[Ee][Nn][Vv]/*|*/.[Ee][Nn][Vv]|*/.[Ee][Nn][Vv].*|*/.[Ee][Nn][Vv]/*) block "credential or secret-bearing path" ;;
  esac
}
# --- per-program argument rules; $1 is the program, the rest its arguments ---
JQBAD='(^|[^A-Za-z0-9_."$])(env|input|inputs|input_filename|debug|stderr|halt|halt_error|import|include|modulemeta|get_search_list|get_prog_origin|get_jq_origin)([^A-Za-z0-9_]|$)'
JQVAR='\$[[:space:]]*(ENV|__loc__|__prog_args)'
check_jq() {
  local t f=0 dd=0
  shift
  while [ $# -gt 0 ]; do
    t=$1; shift
    if [ "$dd" = 0 ]; then
      case "$t" in
        --) dd=1; continue ;;
        --arg|--argjson) [ $# -ge 2 ] || block "jq $t needs a name and a value"; shift 2; continue ;;
        --indent) [ $# -ge 1 ] || block "jq --indent needs a number"; shift; continue ;;
        --raw-output|--join-output|--compact-output|--null-input|--exit-status|--slurp|--sort-keys|--color-output|\
        --monochrome-output|--ascii-output|--tab|--raw-input) continue ;;
        --*) block "jq option $t is not allowed" ;;
        -) ;;
        -*) case "${t#-}" in *[!rjcnesSCMaR]*) block "jq option $t is not allowed (no -f, -L, --rawfile, --slurpfile, --args)" ;; esac; continue ;;
      esac
    fi
    if [ "$f" = 0 ]; then
      f=1
      [[ $t =~ $JQBAD || $t =~ $JQVAR ]] && block "jq filter uses env, \$ENV, input, debug, stderr, halt or modules"
      case "$t" in *'#'*'$'*) block "jq filter with a comment before a \$ variable" ;; esac
    fi
  done
  return 0
}
check_grep() {
  local t rest ch
  shift
  while [ $# -gt 0 ]; do
    t=$1; shift
    case "$t" in
      --) return 0 ;;
      --ignore-case|--invert-match|--count|--line-number|--files-with-matches|--files-without-match|--no-filename|\
      --with-filename|--only-matching|--quiet|--silent|--word-regexp|--line-regexp|--extended-regexp|--fixed-strings|\
      --basic-regexp|--text|--color|--colour|--color=*|--colour=*|--max-count=*|--after-context=*|--before-context=*|\
      --context=*|--regexp=*) ;;
      --*) block "grep option $t is not allowed (no -f, -r, -R, -d, -D, --include, --file)" ;;
      -?*) rest=${t#-}
           while [ -n "$rest" ]; do
             ch=${rest:0:1}; rest=${rest:1}
             case "$ch" in
               [ivcnlLhHoqswxEFGaIb]) ;;
               [eABCm]) if [ -z "$rest" ]; then [ $# -ge 1 ] || block "grep -$ch needs a value"; shift; fi; rest='' ;;
               *) block "grep option -$ch is not allowed (no -f, -r, -R, -d, -D, -z, -Z)" ;;
             esac
           done ;;
    esac
  done
  return 0
}
NUM_RE='^[+-]?[0-9]+$'
check_headtail() {
  local p=$1 t v
  shift
  while [ $# -gt 0 ]; do
    t=$1; shift
    case "$t" in
      -n|-c) [ $# -ge 1 ] || block "$p $t needs a number"; v=$1; shift ;;
      -n?*|-c?*) v=${t:2} ;;
      -q) continue ;;
      -[0-9]*) v=${t#-} ;;
      -*) block "$p option $t is not allowed (no -f, -F, --follow)" ;;
      *) continue ;;
    esac
    [[ $v =~ $NUM_RE ]] || block "$p count must be a number"
  done
  return 0
}
check_cluster() { # check_cluster <prog> <flag chars> <chars taking a value> <args...>; returns positional count in POS
  local p=$1 ok=$2 val=$3 t rest ch
  shift 3; shift
  POS=0
  while [ $# -gt 0 ]; do
    t=$1; shift
    case "$t" in
      --*) block "$p long option $t is not allowed" ;;
      -?*) rest=${t#-}
           while [ -n "$rest" ]; do
             ch=${rest:0:1}; rest=${rest:1}
             case "$ok" in *"$ch"*) continue ;; esac
             case "$val" in
               *"$ch"*) if [ -z "$rest" ]; then [ $# -ge 1 ] || block "$p -$ch needs a value"; shift; fi; rest='' ;;
               *) block "$p option -$ch is not allowed" ;;
             esac
           done ;;
      *) POS=$((POS+1)) ;;
    esac
  done
  return 0
}

HAS_AWS=0
check_seg() {
  local v
  for v in "$@"; do path_ok "$v"; done
  case "$1" in
    aws) HAS_AWS=1 ;;
    jq) check_jq "$@" ;;
    grep) check_grep "$@" ;;
    head|tail) check_headtail "$@" ;;
    wc) check_cluster wc clmwL '' "$@" ;;
    cut) check_cluster cut snw bcfd "$@" ;;
    tr) check_cluster tr cdsuC '' "$@"; [ "$POS" -le 2 ] || block "tr takes at most two sets" ;;
    sort) check_cluster sort bdfghiMnRrsuVcCz tk "$@" ;;
    uniq) check_cluster uniq cdui fs "$@"; [ "$POS" -le 1 ] || block "uniq output file" ;;
    echo) ;;
    date) shift; for v in "$@"; do case "$v" in -u|+*) ;; *) block "date takes only -u and +FORMAT" ;; esac; done ;;
    */*) block "path-qualified command" ;;
    [A-Za-z_]*=*) block "variable assignment before a command" ;;
    *) block "command not in allowlist" ;;
  esac
}
k=0; nw=${#WV[@]}
for ((s=0; s<=SEGN; s++)); do
  args=()
  while [ "$k" -lt "$nw" ] && [ "${WS[k]}" = "$s" ]; do args+=("${WV[k]}"); k=$((k+1)); done
  check_seg "${args[@]}"
done

# aws segments: apply the global aws grammar here too, so this agent is covered even if guard-aws is not registered.
if [ "$HAS_AWS" = 1 ]; then
  GA="${0%/*}/guard-aws.sh"
  [ -f "$GA" ] || block "guard-aws.sh is missing next to this hook"
  printf '%s' "$INPUT" | bash "$GA" || exit 2
fi
exit 0
