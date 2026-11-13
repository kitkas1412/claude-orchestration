#!/usr/bin/env bash
# Tests install.sh --project (repo-level export). Writes only to temp dirs.
# Usage: bash tests/test-project-install.sh
REPO="$(cd "$(dirname "$0")/.." && pwd)"
INSTALL="$REPO/install.sh"
pass=0
fail=0

ROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-project-install-test.XXXXXX")"
cleanup() {
  case "$ROOT" in
    ""|"/"|"$HOME") return ;;
  esac
  case "$(basename "$ROOT")" in
    claude-project-install-test.*) [ -d "$ROOT" ] && rm -rf "$ROOT" ;;
  esac
}
trap cleanup EXIT

ok() { pass=$((pass+1)); }
bad() { fail=$((fail+1)); echo "FAIL  $1"; }
assert() { # assert <name> <command...>
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then ok; else bad "$name"; fi
}
assert_not() {
  local name="$1"; shift
  if "$@" >/dev/null 2>&1; then bad "$name"; else ok; fi
}
eq() { # eq <name> <expected> <actual>
  if [ "$2" = "$3" ]; then ok; else bad "$1 (expected '$2', got '$3')"; fi
}

new_repo() { # new_repo <name> -> prints path
  local d="$ROOT/$1"
  mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" -c user.name=t -c user.email=t@example.invalid commit -q --allow-empty -m init
  printf '%s' "$d"
}

run_guard() { # run_guard <repo> <hook> <json>; prints exit code
  local rc
  printf '%s' "$3" | CLAUDE_PROJECT_DIR="$1" bash "$1/.claude/hooks/$2" >/dev/null 2>&1
  rc=$?
  printf '%s' "$rc"
}

# ---- 1. basic export -------------------------------------------------------
A="$(new_repo a)"
printf 'my claude md\n' > "$A/CLAUDE.md"
mkdir -p "$A/.claude/worktrees/x"
printf 'wt\n' > "$A/.claude/worktrees/x/file"
printf '{"local":true}\n' > "$A/.claude/settings.local.json"
cp "$A/CLAUDE.md" "$ROOT/CLAUDE.md.expected"
cp "$A/.claude/worktrees/x/file" "$ROOT/wt.expected"
cp "$A/.claude/settings.local.json" "$ROOT/local.expected"

assert "export into git repo succeeds" bash "$INSTALL" --project "$A"
C="$A/.claude"

for f in ORCHESTRATION.md rules/orchestration.md settings.json .orchestration-manifest \
         agents/orchestrator.md hooks/guard-bash.sh hooks/guard-write.sh \
         hooks/readonly-bash.sh hooks/stop-verify-reminder.sh; do
  assert "exists: $f" test -f "$C/$f"
done
assert "skills dir populated" test -n "$(find "$C/skills" -type f 2>/dev/null | head -1)"
assert "third_party skills exported" test -n "$(cd "$REPO/third_party" && find skills -type f -not -name .DS_Store | head -1 | sed "s|^|$C/|" | xargs -I{} sh -c 'test -f "{}" && echo y')"
assert "exists: hooks/filter-test-output.sh" test -f "$C/hooks/filter-test-output.sh"
assert "Bash PreToolUse entry references filter-test-output.sh" \
  jq -e '[.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[].command | select(contains("hooks/filter-test-output.sh") and contains("$CLAUDE_PROJECT_DIR"))] | length == 1' "$C/settings.json"
for h in guard-bash guard-write readonly-bash stop-verify-reminder filter-test-output; do
  assert "executable: $h.sh" test -x "$C/hooks/$h.sh"
done
eq "no git-publish.sh under .claude" "" "$(find "$C" -name 'git-publish.sh' | head -1)"
assert_not "no apple-design" test -e "$C/skills/apple-design"
eq "no backup dir created in HOME by test (no .claude/backup)" "" "$(find "$C" -iname '*backup*' | head -1)"

assert "settings.json is valid JSON" jq empty "$C/settings.json"
assert "hook commands use CLAUDE_PROJECT_DIR" \
  jq -e '[.hooks.PreToolUse[].hooks[].command] | length > 0 and all(contains("$CLAUDE_PROJECT_DIR"))' "$C/settings.json"
assert_not "no \$HOME hook commands left" grep -q '\$HOME/\.claude/hooks' "$C/settings.json"
assert_not "no model key" jq -e 'has("model")' "$C/settings.json"
assert_not "no defaultMode" jq -e '.permissions | has("defaultMode")' "$C/settings.json"
for d in 'Edit(./.claude/hooks/**)' 'Write(./.claude/hooks/**)' \
         'Edit(./.claude/settings.json)' 'Write(./.claude/settings.json)'; do
  assert "deny contains $d" jq -e --arg d "$d" '.permissions.deny | index($d) != null' "$C/settings.json"
done
assert_not "no agent key without --set-agent" jq -e 'has("agent")' "$C/settings.json"
assert "manifest has 40-hex SHA" grep -Eq '^source-commit: [0-9a-f]{40}$' "$C/.orchestration-manifest"
assert_not "manifest has no timestamp line" grep -Eiq 'date|time|generated at' "$C/.orchestration-manifest"

# untouched files
eq "target CLAUDE.md untouched" "" "$(diff "$A/CLAUDE.md" "$ROOT/CLAUDE.md.expected")"
eq "worktrees untouched" "" "$(diff "$A/.claude/worktrees/x/file" "$ROOT/wt.expected")"
eq "settings.local.json untouched" "" "$(diff "$A/.claude/settings.local.json" "$ROOT/local.expected")"

# ---- 2. rewrite checks -----------------------------------------------------
leaks="$(grep -rnE '~/\.claude/|<HOME>/\.claude/' "$C/agents" "$C/skills" "$C/ORCHESTRATION.md" "$C/rules" 2>/dev/null \
  | grep -v 'git-publish' | grep -v '\.claude/plugins' | grep -v 'apple-design' | grep -v '~/\.claude/settings\.json' || true)"
eq "no user-level .claude paths remain (outside git-publish/plugins)" "" "$leaks"
assert "orchestrator.md uses project hook path" \
  grep -qF '"$CLAUDE_PROJECT_DIR"/.claude/hooks/stop-verify-reminder.sh' "$C/agents/orchestrator.md"
assert "rules/orchestration.md includes CLAUDE.md content" \
  grep -qF "$(grep -m1 -v '^[[:space:]]*$' "$REPO/CLAUDE.md")" "$C/rules/orchestration.md"

# ---- 3. exported guards ----------------------------------------------------
eq "exported guard-bash blocks git push" 2 "$(run_guard "$A" guard-bash.sh '{"tool_name":"Bash","tool_input":{"command":"git push origin main"}}')"
eq "exported guard-bash blocks gh pr create" 2 "$(run_guard "$A" guard-bash.sh '{"tool_name":"Bash","tool_input":{"command":"gh pr create"}}')"
eq "exported guard-bash allows git status" 0 "$(run_guard "$A" guard-bash.sh '{"tool_name":"Bash","tool_input":{"command":"git status"}}')"
edit_json() { jq -nc --arg p "$1" '{tool_name:"Edit",tool_input:{file_path:$p}}'; }
eq "exported guard-write blocks edit of project hook" 2 "$(run_guard "$A" guard-write.sh "$(edit_json "$A/.claude/hooks/guard-bash.sh")")"
eq "exported guard-write allows normal file" 0 "$(run_guard "$A" guard-write.sh "$(edit_json "$A/src/app.js")")"

# ---- 4. idempotent re-export ----------------------------------------------
cp -R "$C" "$ROOT/first-export"
assert "second export succeeds" bash "$INSTALL" --project "$A"
eq "re-export leaves .claude identical" "" "$(diff -r "$ROOT/first-export" "$C" 2>&1)"
eq "deny list length stable" "$(jq '.permissions.deny|length' "$ROOT/first-export/settings.json")" "$(jq '.permissions.deny|length' "$C/settings.json")"
eq "no duplicate denies" "$(jq '.permissions.deny|length' "$C/settings.json")" "$(jq '.permissions.deny|unique|length' "$C/settings.json")"
eq "hook entries stable" "$(jq '[.hooks[][]]|length' "$ROOT/first-export/settings.json")" "$(jq '[.hooks[][]]|length' "$C/settings.json")"

# ---- 5. dry run writes nothing --------------------------------------------
D="$(new_repo dry)"
assert "dry-run succeeds" bash "$INSTALL" --project "$D" --dry-run
assert_not "dry-run writes no .claude" test -e "$D/.claude"

# ---- 6. merge with pre-existing settings.json -----------------------------
M="$(new_repo merge)"
mkdir -p "$M/.claude"
printf '%s\n' '{"customKey":{"a":1},"permissions":{"deny":["Bash(custom:*)"],"allow":["Read(x)"]}}' > "$M/.claude/settings.json"
assert "export over existing settings succeeds" bash "$INSTALL" --project "$M"
S="$M/.claude/settings.json"
assert "custom key preserved" jq -e '.customKey.a == 1' "$S"
assert "custom deny preserved" jq -e '.permissions.deny | index("Bash(custom:*)") != null' "$S"
assert "custom allow preserved" jq -e '.permissions.allow == ["Read(x)"]' "$S"
assert "project deny merged in" jq -e '.permissions.deny | index("Edit(./.claude/hooks/**)") != null' "$S"
assert "hooks merged in" jq -e '.hooks.PreToolUse | length > 0' "$S"
before="$(jq -S . "$S")"
bash "$INSTALL" --project "$M" >/dev/null 2>&1
eq "merge is idempotent" "$before" "$(jq -S . "$S")"

# ---- 7. --set-agent --------------------------------------------------------
B="$(new_repo b)"
assert "export with --set-agent succeeds" bash "$INSTALL" --project "$B" --set-agent
eq "agent is orchestrator" orchestrator "$(jq -r '.agent' "$B/.claude/settings.json")"
assert_not "--set-agent without --project fails" bash "$INSTALL" --set-agent --dry-run

# ---- 8. error paths --------------------------------------------------------
N="$ROOT/notgit"
mkdir -p "$N"
assert_not "--project on non-git dir fails" bash "$INSTALL" --project "$N"
assert_not "non-git dir left without .claude" test -e "$N/.claude"
assert_not "--project on missing dir fails" bash "$INSTALL" --project "$ROOT/does-not-exist"
assert_not "--project without value fails" bash "$INSTALL" --project
assert_not "unknown option fails" bash "$INSTALL" --bogus --dry-run

SUB="$A/subdir"
mkdir -p "$SUB"
assert_not "subdir of a repo refused" bash "$INSTALL" --project "$SUB"
assert_not "subdir left without .claude" test -e "$SUB/.claude"
BARE="$ROOT/bare.git"
git init -q --bare "$BARE"
assert_not "bare repo refused" bash "$INSTALL" --project "$BARE"
assert_not ".git dir refused" bash "$INSTALL" --project "$A/.git"
assert_not ".git dir left without .claude" test -e "$A/.git/.claude"

# ---- 9. symlinks in the target ---------------------------------------------
L="$(new_repo link)"
mkdir -p "$L/.claude" "$ROOT/outside"
ln -s "$ROOT/outside" "$L/.claude/hooks"
assert_not "symlinked .claude/hooks refused" bash "$INSTALL" --project "$L"
eq "outside dir untouched" "" "$(ls -A "$ROOT/outside")"
assert_not "dry-run also refuses symlinks" bash "$INSTALL" --project "$L" --dry-run
L2="$(new_repo link2)"
mkdir -p "$L2/.claude/agents"
ln -s "$ROOT/outside/x" "$L2/.claude/agents/orchestrator.md"
assert_not "symlinked file under agents refused" bash "$INSTALL" --project "$L2"
L3="$(new_repo link3)"
mkdir -p "$L3/.claude"
ln -s "$ROOT/outside/s.json" "$L3/.claude/settings.json"
assert_not "symlinked settings.json refused" bash "$INSTALL" --project "$L3"
eq "outside dir still untouched" "" "$(ls -A "$ROOT/outside")"

# ---- 10. risky existing settings -------------------------------------------
W="$(new_repo warn)"
mkdir -p "$W/.claude"
printf '%s\n' '{"permissions":{"allow":["Bash(rm:*)"],"defaultMode":"bypassPermissions"},"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"/x/evil.sh"}]}]}}' > "$W/.claude/settings.json"
wout="$(bash "$INSTALL" --project "$W" 2>&1)"; wrc=$?
eq "export with risky settings proceeds" 0 "$wrc"
assert "WARNING printed" grep -q 'WARNING' <<<"$wout"
assert "warning lists allow entry" grep -qF 'Bash(rm:*)' <<<"$wout"
assert "warning lists bypassPermissions" grep -qF 'bypassPermissions' <<<"$wout"
assert "warning lists foreign hook" grep -qF '/x/evil.sh' <<<"$wout"
assert "allow kept" jq -e '.permissions.allow == ["Bash(rm:*)"]' "$W/.claude/settings.json"
H="$(new_repo nohooks)"
mkdir -p "$H/.claude"
printf '%s\n' '{"disableAllHooks":true}' > "$H/.claude/settings.json"
assert_not "disableAllHooks refused" bash "$INSTALL" --project "$H"
assert_not "refused export wrote no hooks" test -e "$H/.claude/hooks"
cwout="$(bash "$INSTALL" --project "$C/.." 2>&1 | grep -c WARNING || true)"
eq "clean re-export has no warning" 0 "$cwout"

# ---- 11. user-level text not rewritten, new denies --------------------------
assert_not "no repo-level apple-design path" grep -rqF '<REPO_ROOT>/.claude/skills/apple-design' "$C"
assert_not "no repo-level settings.json from user-level text" \
  grep -rqF '<REPO_ROOT>/.claude/settings.json' "$C/agents" "$C/skills" "$C/ORCHESTRATION.md"
assert "preamble notes apple-design" grep -qF 'apple-design is not exported' "$C/rules/orchestration.md"
for d in 'Edit(./.claude/settings.local.json)' 'Write(./.claude/settings.local.json)' \
         'Edit(./.claude/rules/**)' 'Write(./.claude/rules/**)' \
         'Edit(./.claude/agents/**)' 'Write(./.claude/agents/**)' \
         'Edit(./.claude/skills/**)' 'Write(./.claude/skills/**)'; do
  assert "deny contains $d" jq -e --arg d "$d" '.permissions.deny | index($d) != null' "$C/settings.json"
done

# ---- 12. copy failure aborts and leaves no temp files ------------------------
if [ "$(id -u)" = 0 ]; then
  echo "SKIP  copy-failure test (running as root)"
else
  chmod a-w "$C/agents"
  bash "$INSTALL" --project "$A" >/dev/null 2>&1
  rc=$?
  chmod u+w "$C/agents"
  if [ "$rc" -ne 0 ]; then ok; else bad "export exits non-zero when a copy fails"; fi
  eq "no temp files left after failed copy" "" "$(find "$C" -name '*.tmp.*' | head -1)"
fi

echo "project install tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
