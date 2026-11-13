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
# Never touch secret-bearing files via shell
if printf '%s' "$CMD" | grep -Eiq '(\.env|\.pem|id_rsa|id_ed25519|\.aws/credentials|\.npmrc|\.netrc|\.pypirc)'; then
  block "secret-bearing file"
fi

NORM=$(printf '%s' "$CMD" | sed -e 's/&&/\n/g' -e 's/||/\n/g' -e 's/;/\n/g' -e 's/|/\n/g')
case "$NORM" in *'&'*) block "background execution" ;; esac

while IFS= read -r seg; do
  seg=$(printf '%s' "$seg" | sed -e 's/^[[:space:]]*//')
  [ -z "$seg" ] && continue
  set -- $seg
  bin=$1; sub=${2:-}
  case "$bin" in
    ls|cat|head|tail|wc|grep|rg|cut|tr|diff|stat|file|pwd|echo|basename|dirname|jq|which|date) ;;
    sort) for tok in $seg; do
            case "$tok" in
              --o*|--compress*) block "sort output or program option" ;;
              --*) ;;
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
exit 0