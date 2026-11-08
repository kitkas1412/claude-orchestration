#!/usr/bin/env bash
# Run this yourself. It pipes sample commands to the staged hooks as text; the samples never execute.
# Usage: bash tests/test-hooks.sh
HOOKS="$(cd "$(dirname "$0")/../hooks" && pwd)"
fail=0
check() {
  local hook=$1 want=$2 cmd=$3 got
  jq -n --arg c "$cmd" '{tool_input:{command:$c}}' | "$HOOKS/$hook" >/dev/null 2>&1
  got=$?
  if [ "$got" = "$want" ]; then echo "ok    [$hook] $cmd"; else echo "FAIL  [$hook] want=$want got=$got: $cmd"; fail=1; fi
}

check guard-bash.sh 0 'git branch -d merged-branch'
check guard-bash.sh 2 'git branch -D some-branch'
check guard-bash.sh 2 'git push origin main'
check guard-bash.sh 0 'grep -n "drop table" schema.sql'
check guard-bash.sh 0 'rg "truncate table" migrations'
check guard-bash.sh 2 'psql -c "drop table users"'
check guard-bash.sh 2 'grep -n x a.sql; psql -c "drop table users"'
check guard-bash.sh 2 'echo "delete from users" | psql'
check guard-bash.sh 2 'terraform apply'
check readonly-bash.sh 2 'sort -o out.txt a.txt'
check readonly-bash.sh 2 'git diff --output=out.txt'
check readonly-bash.sh 2 'find . -fls out.txt'
check readonly-bash.sh 2 "sed -n 'w out.txt' a.txt"
check readonly-bash.sh 2 'uniq a.txt out.txt'
check readonly-bash.sh 2 'tree -o out.txt'
check readonly-bash.sh 0 'git log -1'
check readonly-bash.sh 0 'sort a.txt'
check readonly-bash.sh 0 'uniq -c'

[ "$fail" = 0 ] && echo "All hook checks passed." || { echo "Some hook checks failed."; exit 1; }
