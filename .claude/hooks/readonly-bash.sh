#!/usr/bin/env bash
# Allowlist guard for read-only agents. Exit code 2 = block the Bash call.
# Defense-in-depth, NOT a sandbox. Requires jq.
set -f
command -v jq >/dev/null 2>&1 || { echo "BLOCKED: jq is required by readonly-bash" >&2; exit 2; }
INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty') || { echo "BLOCKED: readonly-bash could not parse its JSON input" >&2; exit 2; }
[ -z "$CMD" ] && exit 0

block() { echo "Blocked by readonly-bash: $1" >&2; exit 2; }

# No redirection, command substitution, process substitution
case "$CMD" in
  *'>'*|*'<('*|*'`'*|*'$('*) block "redirection or substitution not allowed" ;;
esac
# Fail closed on expansion: outside single quotes no $ (any form), backtick, ( ) { } or \; double quotes only
# without $, backtick and \. Words are rebuilt (quotes removed) into WV, with their segment in WS.
WV=(); WS=(); SEGN=0; cur=''; have=0; i=0; len=${#CMD}
pushw() { if [ "$have" = 1 ]; then WV+=("$cur"); WS+=("$SEGN"); fi; cur=''; have=0; }
while [ "$i" -lt "$len" ]; do
  c=${CMD:i:1}
  case "$c" in
    "'") rest=${CMD:i+1}; body=${rest%%\'*}; cur+=$body; have=1; i=$((i+${#body}+1)) ;;
    '"') rest=${CMD:i+1}; body=${rest%%\"*}
         case "$body" in *'$'*|*'`'*|*'\'*) block "\$, backtick or backslash inside double quotes (use single quotes)" ;; esac
         cur+=$body; have=1; i=$((i+${#body}+1)) ;;
    '$'|'`'|'('|')'|'{'|'}'|'\') block "$c outside single quotes is not allowed (no expansion, substitution, grouping or escapes)" ;;
    ' '|$'\t') pushw ;;
    '|'|';'|'&'|$'\n') pushw; SEGN=$((SEGN+1)) ;;
    *) cur+=$c; have=1 ;;
  esac
  i=$((i+1))
done
pushw
# Never touch secret-bearing files via shell
if printf '%s' "$CMD" | grep -Eiq '(\.env|\.pem|id_rsa|id_ed25519|\.aws/credentials|\.npmrc|\.netrc|\.pypirc)'; then
  block "secret-bearing file"
fi
# AWS credential directory (also when spelled with quotes or backslashes), and globs or expansions inside a hidden
# path component outside quotes (~/.a?s, ~/.a[w]s, [.]aws, $HOME/.a${x}ws)
# (a backslash can only sit inside single quotes now, so '\.aws' is a search pattern, not the directory)
if printf '%s' "$CMD" | tr -d "\"'" | grep -Eiq '(^|[^[:alnum:]_\\-])\.aws([^[:alnum:]_-]|$)'; then
  block "AWS credential directory"
fi
if printf '%s' "$CMD" | sed -E "s/'[^']*'//g; s/\"[^\"]*\"//g" \
   | grep -Eq '(^|[[:space:]/=:])\.[^/[:space:]]*[][*?{}$\\]|(^|[[:space:]/=:])\[[^]/[:space:]]*\.|\.[Aa][][*?]'; then
  block "glob or expansion in a hidden path"
fi

NORM=$(printf '%s' "$CMD" | sed -e 's/&&/\n/g' -e 's/||/\n/g' -e 's/;/\n/g' -e 's/|/\n/g')
case "$NORM" in *'&'*) block "background execution" ;; esac

while IFS= read -r seg; do
  seg=$(printf '%s' "$seg" | sed -e 's/^[[:space:]]*//')
  [ -z "$seg" ] && continue
  set -- $seg
  bin=$1; sub=${2:-}
  case "$bin" in
    ls|cat|head|tail|wc|grep|cut|tr|diff|stat|file|pwd|echo|basename|dirname|which|date) ;;
    rg)   for tok in $seg; do
            case "$tok" in
              --pre|--pre=*|--pre-glob*|--hostname-bin*|--search-zip|-z|-[!-]*z*) block "rg preprocessor or decompression option" ;;
            esac
          done ;;
    jq)   for tok in $seg; do
            case "$tok" in --rawfile|--slurpfile|-L*|--library-path*) block "jq file or module option" ;; esac
          done
          printf '%s' "$seg" | grep -Eq '\$[[:space:]]*(ENV|__loc__)|(^|[^A-Za-z0-9_.$])env([^A-Za-z0-9_]|$)|#.*\$' && block "jq environment access" ;;
    sort) for tok in $seg; do
            case "$tok" in
              --reverse|--numeric-sort|--unique|--ignore-case|--human-numeric-sort|--version-sort|--general-numeric-sort|\
              --month-sort|--stable|--ignore-leading-blanks|--dictionary-order|--random-sort|--zero-terminated|--check|\
              --field-separator|--field-separator=*|--key|--key=*) ;;
              --*) block "sort long option not allowed: $tok" ;;
              -*o*) block "sort -o" ;;
            esac
          done ;;
    uniq) n=0; skip=0
          for tok in $seg; do
            [ "$skip" = 1 ] && { skip=0; continue; }
            case "$tok" in
              uniq) ;;
              -f|-s) skip=1 ;;
              -*) ;;
              *) n=$((n+1)) ;;
            esac
          done
          [ "$n" -gt 1 ] && block "uniq output file" ;;
    tree) case "$seg" in *' -o'*) block "tree -o" ;; esac ;;
    sed)  case "$seg" in *' -i'*|*'--in-place'*) block "sed -i" ;; esac
          printf '%s' "$seg" | grep -Eq "[/0-9\$,'\"]w[[:space:]]" && block "sed write command" ;;
    find) case "$seg" in *'-delete'*|*'-exec'*|*'-fprint'*|*'-fls'*|*'-ok'*) block "find with write/exec" ;; esac ;;
    git)  case "$sub" in
            log|diff|show|status|blame|ls-files|ls-tree|grep|rev-parse|shortlog|describe|cat-file) ;;
            *) block "git $sub" ;;
          esac
          case "$seg" in *'--output'*|*'--ext-diff'*|*'--open-files-in-pager'*|*' -O'*) block "git output or external program option" ;; esac ;;
    npm|pnpm|yarn)
          [ "$sub" = "audit" ] || block "$bin $sub"
          case "$seg" in *' fix'*) block "audit fix" ;; esac ;;
    pip-audit|cargo|govulncheck|gitleaks|osv-scanner)
          [ "$bin" = "cargo" ] && [ "$sub" != "audit" ] && block "cargo $sub" ;;
    *) block "command not in allowlist: $bin" ;;
  esac
done <<< "$NORM"

# Token-level checks for sed (only print, delete, quit and plain s/// scripts) and git (no pager, output, external
# diff, textconv or filter options, including abbreviations; no git grep -O).
SED_ADDR='([0-9]+|\$|/([^/\\]|\\.)*/)'
SED_OK1="^(${SED_ADDR}(,(${SED_ADDR}|\\+[0-9]+))?)?[pdq=]\$"
SED_OK2="^(${SED_ADDR}(,${SED_ADDR})?)?s/([^/\\\\]|\\\\.)*/([^/\\\\]|\\\\.)*/[gpiI0-9]*\$"
check_sed() {
  local t havee=0 script=1
  shift
  while [ $# -gt 0 ]; do
    t=$1; shift
    case "$t" in
      -e|--expression) [ $# -ge 1 ] || block "sed -e needs a script"; havee=1; sed_script "$1"; shift ;;
      -e?*) havee=1; sed_script "${t#-e}" ;;
      --expression=*) havee=1; sed_script "${t#*=}" ;;
      --quiet|--silent|--regexp-extended) ;;
      --*) block "sed option $t is not allowed" ;;
      -?*) case "${t#-}" in *[!nErs]*) block "sed option $t is not allowed" ;; esac ;;
      *) if [ "$havee" = 0 ] && [ "$script" = 1 ]; then script=0; sed_script "$t"; fi ;;
    esac
  done
}
sed_script() { [[ $1 =~ $SED_OK1 || $1 =~ $SED_OK2 ]] || block "sed script must be a plain p, d, q, = or s/// command (no e, w, W, r)"; }
GIT_BAD='open-files-in-pager output ext-diff textconv filters exec upload-pack receive-pack config-env'
check_git() {
  local sub=${2:-} t name d
  shift 2
  for t in "$@"; do
    case "$t" in
      --*) name=${t#--}; name=${name%%=*}
           [ -n "$name" ] || continue
           for d in $GIT_BAD; do case "$d" in "$name"*) block "git option --$name (pager, output, external diff, textconv or filters, or an abbreviation of one)" ;; esac; done ;;
      -?*) [ "$sub" = grep ] && case "$t" in *O*) block "git grep -O runs a pager program" ;; esac ;;
    esac
  done
  return 0
}
k=0; nw=${#WV[@]}
for ((s=0; s<=SEGN; s++)); do
  args=()
  while [ "$k" -lt "$nw" ] && [ "${WS[k]}" = "$s" ]; do args+=("${WV[k]}"); k=$((k+1)); done
  [ "${#args[@]}" -gt 0 ] || continue
  case "${args[0]}" in
    sed) check_sed "${args[@]}" ;;
    git) check_git "${args[@]}" ;;
  esac
done
exit 0