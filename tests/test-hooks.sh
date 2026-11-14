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

checkw() {
  local want=$1 path=$2 got
  jq -n --arg p "$path" '{tool_input:{file_path:$p}}' | "$HOOKS/guard-write.sh" >/dev/null 2>&1
  got=$?
  if [ "$got" = "$want" ]; then echo "ok    [guard-write.sh] $path"; else echo "FAIL  [guard-write.sh] want=$want got=$got: $path"; fail=1; fi
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
# git-publish route: every other way to push, open a PR, or touch the registry is denied
check guard-bash.sh 2 '/usr/bin/git push'
check guard-bash.sh 2 'bash -c "git push"'
check guard-bash.sh 2 "sh -c 'git push origin x'"
check guard-bash.sh 2 'git -c alias.p=push p'
check guard-bash.sh 2 'git --config-env=alias.p=X p'
check guard-bash.sh 2 'git config alias.p push'
check guard-bash.sh 2 'git config --global alias.p push'
check guard-bash.sh 2 'git send-pack x'
check guard-bash.sh 2 'git http-push x'
check guard-bash.sh 2 'gh pr create'
check guard-bash.sh 2 'gh pr new'
check guard-bash.sh 2 'gh alias set x y'
check guard-bash.sh 2 'gh api -X PUT repos/o/r/pulls/1/merge'
check guard-bash.sh 2 'gh api --method POST repos/o/r/pulls'
check guard-bash.sh 2 'gh api repos/o/r/git/refs -f ref=x'
check guard-bash.sh 2 'gh api repos/o/r/git/refs --input f'
check guard-bash.sh 2 'echo x >> ~/.claude/git-publish.registry'
check guard-bash.sh 2 'cat ~/.claude/git-publish.registry'
check guard-bash.sh 2 '~/.claude/hooks/git-publish.sh enable pr'
check guard-bash.sh 2 '~/.claude/hooks/git-publish.sh disable'
check guard-bash.sh 0 '~/.claude/hooks/git-publish.sh push --expect-sha abc'
check guard-bash.sh 0 '~/.claude/hooks/git-publish.sh pr --expect-sha abc --title-file a --body-file b'
check guard-bash.sh 0 '~/.claude/hooks/git-publish.sh merge --pr 1 --expect-sha abc'
check guard-bash.sh 2 '~/.claude/hooks/git-publish.sh enable merge'
check guard-bash.sh 2 'gh pr merge 1 --squash'
check guard-bash.sh 2 '/opt/homebrew/bin/gh pr merge 1'
check guard-bash.sh 2 'gh pr --repo o/r merge 1'
check guard-bash.sh 2 'cd ~/proj && command rm ~/.claude/hooks/x'
check guard-bash.sh 2 'echo hi; git push'
check guard-bash.sh 2 'bash -c "echo a; gh pr create"'
check guard-bash.sh 2 'git -C . push'
check guard-bash.sh 2 "echo '-m \"' ; git push ; echo '\"'"
check guard-bash.sh 2 'git commit -m "x"; git push'
check guard-bash.sh 2 'git config --get x; git config alias.p push'
check guard-bash.sh 2 'gh api -X GET repos/o/r/pulls -X POST'
check guard-bash.sh 0 'bash ~/.claude/hooks/git-publish.sh push'
check guard-bash.sh 0 'gh api repos/o/r/pulls'
check guard-bash.sh 0 'gh pr view 1'
check guard-bash.sh 0 'gh pr list'
check guard-bash.sh 0 'git commit -m x'
check guard-bash.sh 0 'git commit -m "docs: explain why git push is blocked"'
check guard-bash.sh 0 "git commit -am 'fix gh pr create docs'"
check guard-bash.sh 0 '~/.claude/hooks/git-publish.sh status'
check guard-bash.sh 0 '~/.claude/hooks/git-publish.sh plan'
check guard-bash.sh 0 '~/.claude/hooks/git-publish.sh plan --title-file a --body-file b'
check guard-bash.sh 0 'git config --get alias.p'
check guard-bash.sh 0 'gh api -X GET repos/o/r/pulls'
# commit messages that expand to a denied command must not hide it
check guard-bash.sh 2 'git commit -m "$(git push origin HEAD)"'
check guard-bash.sh 2 'git commit -m "$(gh pr merge 1)"'
check guard-bash.sh 2 'git commit --allow-empty -m "$(gh repo delete x --yes)"'
# launcher, separator and grouping forms
check guard-bash.sh 2 'bash -cm " git push x"'
check guard-bash.sh 2 'git push;true'
check guard-bash.sh 2 'git push&&x'
check guard-bash.sh 2 'git push|tee log'
check guard-bash.sh 2 '(git push)'
check guard-bash.sh 2 'echo `git push`'
check guard-bash.sh 2 'git commit -m "`git push origin HEAD`"'
# quoting, IFS and line-continuation obfuscation
check guard-bash.sh 2 'git "push" origin x'
check guard-bash.sh 2 'git${IFS}push'
check guard-bash.sh 2 $'git \\\npush'
check guard-bash.sh 2 'gh "pr" create'
check guard-bash.sh 2 'gh "api" -X POST x'
# absolute paths to the binaries
check guard-bash.sh 2 '/opt/homebrew/bin/gh pr create'
check guard-bash.sh 2 '/usr/local/bin/gh api -X POST x'
# aliases and git config through other channels
check guard-bash.sh 2 "git config 'alias.p' push"
check guard-bash.sh 2 'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=alias.p GIT_CONFIG_VALUE_0=push git p'
# command or subcommand from a variable
check guard-bash.sh 2 'p=push; git $p'
check guard-bash.sh 2 'g=git; $g push'
check guard-bash.sh 2 'M=PUT; gh api --method "$M" x'
# gh api flag clusters and other gh mutations or token access
check guard-bash.sh 2 'gh api -if a=b x'
check guard-bash.sh 2 'gh api -iX POST x'
check guard-bash.sh 2 'gh repo create x --push'
check guard-bash.sh 2 'gh auth token'
check guard-bash.sh 2 'git credential fill'
# git-publish.sh: quoted subcommand, variable path, terminal emulation, registry globs
check guard-bash.sh 2 '~/.claude/hooks/git-publish.sh "enable" pr'
check guard-bash.sh 2 'f=~/.claude/hooks/git-publish.sh; "$f" push'
check guard-bash.sh 2 'script -q /dev/null ~/.claude/hooks/git-publish.sh plan'
check guard-bash.sh 2 'expect -c "spawn ~/.claude/hooks/git-publish.sh plan"'
check guard-bash.sh 2 'script -q /dev/null ~/.claude/hooks/git-publish.sh enable merge'
check guard-bash.sh 2 'expect -c "spawn ~/.claude/hooks/git-publish.sh enable merge"'
check guard-bash.sh 2 'unbuffer ~/.claude/hooks/git-publish.sh plan'
check guard-bash.sh 2 'python3 -c "import pty; pty.spawn([\"x/git-publish.sh\",\"plan\"])"'
check guard-bash.sh 2 'cat ~/.claude/git-publish.regist*'
# writes to protected configuration
check guard-bash.sh 2 'cp x ~/.claude/hooks/git-publish.sh'
check guard-bash.sh 2 "sed -i '' s/a/b/ ~/.claude/settings.json"
check guard-bash.sh 2 'echo x >> ~/.gitconfig'
check guard-bash.sh 2 'git config --global core.sshCommand x'
# harmless commands that merely mention the same words stay allowed
check guard-bash.sh 0 'grep -n "git push" README.md'
check guard-bash.sh 0 'echo "git push"'
check guard-bash.sh 0 'cat hooks/git-publish.sh'
check guard-bash.sh 0 'bash tests/test-git-publish.sh'
check guard-bash.sh 0 'git add hooks/git-publish.sh'
check guard-bash.sh 0 'gh pr comment 1 --body x'
check guard-bash.sh 0 'gh pr close 1'
check guard-bash.sh 0 'gh issue list'
# final round: quoted binaries, piped or here-string shells, repo flags before the subcommand
check guard-bash.sh 2 '"git" push x'
check guard-bash.sh 2 "'/usr/bin/git' push"
check guard-bash.sh 2 '\git push'
check guard-bash.sh 2 'git pu"sh"'
check guard-bash.sh 2 '"gh" pr create'
check guard-bash.sh 2 'echo "git push origin HEAD" | bash'
check guard-bash.sh 2 "bash <<< 'git push'"
check guard-bash.sh 2 'GIT_CONFIG_GLOBAL=/tmp/c git p'
check guard-bash.sh 2 'printf x >> .git/config'
check guard-bash.sh 2 'gh pr -R o/r create'
check guard-bash.sh 2 'gh pr --repo o/r merge 1'
check guard-bash.sh 2 'gh release -R o/r create'
check guard-bash.sh 2 'gh workflow -R o/r run'
check guard-bash.sh 2 'gh secret -R o/r set'
check guard-bash.sh 2 'gh -R o/r "pr" create'
# credential helpers and stores
check guard-bash.sh 2 'gh auth git-credential get'
check guard-bash.sh 2 'git credential-osxkeychain get'
check guard-bash.sh 2 'git credential "fill"'
check guard-bash.sh 2 'cat ~/.git-credentials'
check guard-bash.sh 2 'security find-internet-password -w'
# global git config includes and protected paths reached through $HOME, //, cd or mv
check guard-bash.sh 2 'git config --global include.path /tmp/c'
check guard-bash.sh 2 'git config --global includeIf.gitdir:/x.path /tmp/c'
check guard-bash.sh 2 'cp /tmp/x "$HOME"/.claude/hooks/git-publish.sh'
check guard-bash.sh 2 'echo x >> "$HOME"/.gitconfig'
check guard-bash.sh 2 'cp /tmp/x ~/.claude//hooks/x'
check guard-bash.sh 2 'cd ~/.claude/hooks && cp /tmp/x git-publish.sh'
check guard-bash.sh 2 'cd ~ && echo x >> .gitconfig'
check guard-bash.sh 2 'mv ~/.claude /tmp/x'
check guard-bash.sh 2 'git push>log'
# near misses that stay allowed
check guard-bash.sh 0 'git add push_service.py'
check guard-bash.sh 0 'git switch push-notifications'
# branch-per-task: worktree add/move denied, other branch commands allowed
check guard-bash.sh 2 'git worktree add ../x'
check guard-bash.sh 2 'git worktree add -b feat/x ../x main'
check guard-bash.sh 2 'git -C repo worktree add x'
check guard-bash.sh 2 'cd a && git worktree add x'
check guard-bash.sh 2 'git worktree move a b'
check guard-bash.sh 2 'git worktree  add x'
check guard-bash.sh 2 'git -c x=y worktree add x'
check guard-bash.sh 0 'git worktree list'
check guard-bash.sh 0 'git worktree list --porcelain'
check guard-bash.sh 0 'git switch -c feat/x origin/main'
check guard-bash.sh 0 'git switch -c feat/x --no-track origin/main'
check guard-bash.sh 0 'git checkout -b feat/x origin/main'
check guard-bash.sh 0 'git fetch origin main'
check guard-bash.sh 0 'git log --oneline pushed'
check guard-bash.sh 0 'gh pr -R o/r view 1'
check guard-bash.sh 0 'gh pr -R o/r list'
check guard-bash.sh 0 'cd /tmp && cp a b'
check guard-bash.sh 0 'cd ~/project && npm test'
check guard-bash.sh 0 'cd ~/project && cp a b'
# registry and enable reached through quote splitting, globs, env prefixes and terminal emulators
check guard-bash.sh 2 "printf x >> ~/.claude/git-pub''lish.registry"
check guard-bash.sh 2 'echo x >> ~/.claude/"git-publish.registry"'
check guard-bash.sh 2 'cd ~/.claude && echo x >> git-pub*'
check guard-bash.sh 2 "env script -q /dev/null ~/.claude/hooks/git-publish.sh en''able merge"
check guard-bash.sh 2 'FOO=1 expect -c x ~/.claude/hooks/git-publish.sh enable merge'
check guard-bash.sh 2 '~/.claude/hooks/git-publish.sh en"able" pr'
# terminal emulation through pipes and globs, directory changes before a glob, tee, brace expansion, trailing commands
check guard-bash.sh 2 "printf name | env script -q /dev/null bash -c \"~/.claude/hooks/git-publish.sh en''able merge\""
check guard-bash.sh 2 'script -q /dev/null ~/.claude/hooks/git-pub*.sh enable merge'
check guard-bash.sh 2 'cd ~/.claude; cp /tmp/row ./git-pub*'
check guard-bash.sh 2 'pushd ~/.claude; cp /tmp/row git-pub*'
check guard-bash.sh 2 'cd ~; cd .claude; tee git-pub* </tmp/row'
check guard-bash.sh 2 'tee ~/.claude/git-publ{ish,ish}.registry </tmp/row'
check guard-bash.sh 2 'env script -q /dev/null ~/.claude/hooks/git-publish.sh disable;true'
# the grafts file hides commits from the history scan, so writing it is denied like the git config
check guard-bash.sh 2 'printf x >> .git/info/grafts'
# read-only mentions of git-publish stay allowed
check guard-bash.sh 0 'grep -n "git-publish.sh enable" README.md'
check guard-bash.sh 0 'rg -n "git-publish.sh enable" README.md'
check guard-bash.sh 0 '~/.claude/hooks/git-publish.sh merge --mark-ready-only --pr 1 --expect-sha abc'
check guard-bash.sh 0 '~/.claude/hooks/git-publish.sh ci --pr 1'
check guard-bash.sh 0 '~/.claude/hooks/git-publish.sh ci --pr 1 --after-ready'
check guard-bash.sh 0 '~/.claude/hooks/git-publish.sh status'
check guard-bash.sh 0 'grep -n git-publish README.md'
check guard-bash.sh 0 'cat hooks/git-publish.sh'
# home config under HOME=/root: the registry and writes through $HOME stay denied
HOME=/root check guard-bash.sh 2 'cat /root/.claude/git-publish.registry'
HOME=/root check guard-bash.sh 2 'echo x >> /root/.claude/git-publish.registry'
HOME=/root check guard-bash.sh 2 'echo x > $HOME/.claude/settings.json'
HOME=/root check guard-bash.sh 2 'cp /tmp/x "$HOME"/.claude/hooks/guard-bash.sh'
HOME=/root check guard-bash.sh 2 'cp /tmp/x /root/.claude/hooks/guard-bash.sh'
# a project's committed .claude/hooks and .claude/settings*.json: writes denied at any prefix
check guard-bash.sh 2 'echo x > .claude/settings.json'
check guard-bash.sh 2 'echo x >> ./.claude/settings.json'
check guard-bash.sh 2 'echo x >../app/.claude/hooks/guard-bash.sh'
check guard-bash.sh 2 'printf x > /srv/app/.claude/settings.json'
check guard-bash.sh 2 'printf x >| .claude/settings.json'
check guard-bash.sh 2 'cat <<EOF > .claude/hooks/x.sh'
check guard-bash.sh 2 'echo x | tee .claude/settings.json'
check guard-bash.sh 2 'echo x | tee -a /srv/app/.claude/hooks/x.sh'
check guard-bash.sh 2 "sed -i '' s/a/b/ .claude/settings.json"
check guard-bash.sh 2 'sed -i s/a/b/ ./.claude/hooks/guard-bash.sh'
check guard-bash.sh 2 "perl -pi -e s/a/b/ .claude/settings.json"
check guard-bash.sh 2 'truncate -s 0 .claude/hooks/guard-bash.sh'
check guard-bash.sh 2 'chmod -x .claude/hooks/guard-bash.sh'
check guard-bash.sh 2 'cp /tmp/x .claude/hooks/guard-bash.sh'
check guard-bash.sh 2 'cp /tmp/x ./.claude/settings.json'
check guard-bash.sh 2 'cp /tmp/x /srv/app/.claude/hooks/'
check guard-bash.sh 2 'cp -t .claude/hooks /tmp/x'
check guard-bash.sh 2 'cp /tmp/settings.json .claude/'
check guard-bash.sh 2 'rsync -a /tmp/h/ .claude/hooks'
check guard-bash.sh 2 'ln -sf /tmp/x .claude/hooks/guard-bash.sh'
check guard-bash.sh 2 'rm .claude/hooks/guard-bash.sh'
check guard-bash.sh 2 'rm -f /srv/app/.claude/settings.json'
check guard-bash.sh 2 'git rm .claude/hooks/guard-bash.sh'
check guard-bash.sh 2 'mv .claude/hooks /tmp/h'
check guard-bash.sh 2 'mv .claude /tmp/c'
check guard-bash.sh 2 'mv /tmp/x .claude/settings.json'
check guard-bash.sh 2 'rm .claude/hoo*/guard-bash.sh'
check guard-bash.sh 2 'dd if=/tmp/x of=.claude/settings.json'
check guard-bash.sh 2 'cd .claude && echo x > settings.json'
check guard-bash.sh 2 'cd /srv/app/.claude/hooks && rm guard-bash.sh'
check guard-bash.sh 2 'cd .claude; cd hooks; cp /tmp/x .'
check guard-bash.sh 2 'echo x > ".claude/settings.json"'
# reads of those paths, and copies from them to elsewhere, stay allowed
check guard-bash.sh 0 'cat .claude/settings.json'
check guard-bash.sh 0 'grep -n PreToolUse .claude/settings.json'
check guard-bash.sh 0 'rg -n deny ./.claude/hooks'
check guard-bash.sh 0 'ls -la .claude/hooks'
check guard-bash.sh 0 'diff -u .claude/hooks/guard-bash.sh hooks/guard-bash.sh'
check guard-bash.sh 0 'head -n 20 /srv/app/.claude/settings.json'
check guard-bash.sh 0 'wc -l .claude/hooks/guard-bash.sh'
check guard-bash.sh 0 'git add .claude/hooks .claude/settings.json'
check guard-bash.sh 0 'git diff .claude/settings.json'
check guard-bash.sh 0 'cp .claude/settings.json /tmp/settings.json'
check guard-bash.sh 0 'cp -r .claude/hooks /tmp/h'
check guard-bash.sh 0 'cat .claude/settings.json > /tmp/s.json'
check guard-bash.sh 2 'echo x > .claude/agents/a.md'
check guard-bash.sh 2 'echo x > .claude/rules/a.md'
check guard-bash.sh 0 'echo x > agents/a.md'
check guard-bash.sh 0 'echo x > skills/s/SKILL.md'
check guard-bash.sh 0 'cp .claude/agents/a.md /tmp/a.md'
# download, extract and restore destinations
check guard-bash.sh 2 'curl -o .claude/hooks/x.sh https://example.com/x'
check guard-bash.sh 2 'curl -sSLo .claude/settings.json https://example.com/x'
check guard-bash.sh 2 'curl --output .claude/rules/x.md https://example.com/x'
check guard-bash.sh 0 'curl -o /tmp/x https://example.com/x'
check guard-bash.sh 0 'curl -O https://example.com/.claude/hooks/x'
check guard-bash.sh 2 'curl -o .claude/hooks/x https://e'
check guard-bash.sh 2 'curl --output .claude/settings.json https://e'
check guard-bash.sh 2 'wget -O .claude/hooks/x.sh https://example.com/x'
check guard-bash.sh 2 'wget --output-document=.claude/agents/x.md https://example.com/x'
check guard-bash.sh 0 'wget -O /tmp/x https://example.com/x'
check guard-bash.sh 2 'tar -xf x.tgz -C .claude/hooks'
check guard-bash.sh 2 'tar xzf x.tgz --directory=.claude/agents'
check guard-bash.sh 0 'tar -xf x.tgz -C /tmp'
check guard-bash.sh 0 'tar -czf x.tgz -C .claude/hooks .'
check guard-bash.sh 2 'unzip x.zip -d .claude/hooks'
check guard-bash.sh 0 'unzip x.zip -d /tmp/x'
check guard-bash.sh 2 'git checkout -- .claude/settings.json'
check guard-bash.sh 2 'git checkout main -- .claude/rules/x.md'
check guard-bash.sh 2 'git restore .claude/hooks/x.sh'
check guard-bash.sh 0 'git restore --staged .claude/settings.json'
check guard-bash.sh 2 'git restore --staged --worktree .claude/settings.json'
check guard-bash.sh 2 'git restore -W .claude/hooks/x.sh'
check guard-bash.sh 2 'git restore --source=main --staged --worktree .claude/hooks/x.sh'
check guard-bash.sh 0 'git checkout main'
check guard-bash.sh 2 'patch .claude/hooks/x.sh < x.diff'
check guard-bash.sh 0 'patch src/x.js < x.diff'
# git restore of the working tree stays denied by the older rule, so this also denies
check guard-bash.sh 2 'git restore src/x'
check guard-bash.sh 2 'git restore -s HEAD .claude/settings.json'
check guard-bash.sh 2 'git restore --source=HEAD .claude/hooks/x.sh'
check guard-bash.sh 2 'echo --staged; git restore -s HEAD~1 .claude/hooks/guard-bash.sh'
check guard-bash.sh 2 'git restore -SW .claude/hooks/x.sh'
check guard-bash.sh 0 'git restore -S .claude/settings.json'
check guard-bash.sh 2 'curl -o.claude/hooks/guard-bash.sh https://e'
check guard-bash.sh 2 'curl --output=.claude/hooks/guard-bash.sh https://e'
check guard-bash.sh 2 'curl -sSLo.claude/hooks/guard-bash.sh https://e'
# missing or malformed input fails closed; valid input without a command stays allowed
check guard-bash.sh 0 'echo hi'
check_input() {
  local hook=$1 want=$2 input=$3 got
  printf '%s' "$input" | "$HOOKS/$hook" >/dev/null 2>&1
  got=$?
  if [ "$got" = "$want" ]; then echo "ok    [$hook] input: $input"; else echo "FAIL  [$hook] want=$want got=$got: input: $input"; fail=1; fi
}
for h in guard-bash.sh guard-write.sh readonly-bash.sh; do
  check_input "$h" 2 '{bad json'
  check_input "$h" 2 '{"tool_input":'
  check_input "$h" 0 '{}'
  check_input "$h" 0 '{"tool_input":{}}'
done
# jq missing: run with an empty PATH directory
NOJQ=$(mktemp -d)
BASH_BIN=$(command -v bash)
for h in guard-bash.sh guard-write.sh readonly-bash.sh; do
  printf '%s' '{"tool_input":{"command":"ls","file_path":"/x/y"}}' | PATH="$NOJQ" "$BASH_BIN" "$HOOKS/$h" >/dev/null 2>&1
  got=$?
  if [ "$got" = 2 ]; then echo "ok    [$h] jq missing"; else echo "FAIL  [$h] jq missing: want=2 got=$got"; fail=1; fi
done
rmdir "$NOJQ"
check guard-bash.sh 0 'cp /tmp/x .claude/skills/s/SKILL.md'
check guard-bash.sh 0 'cp .claude/settings.json .claude/settings.json.bak'
check guard-bash.sh 0 'cd .claude && cat settings.json'

checkw 2 '/x/.claude/git-publish.registry'
checkw 0 '/x/git-publish.registry'
checkw 2 '/Users/x/.CLAUDE/hooks/y'
checkw 2 '/x/.claude/z/../hooks/y'
# the global git config guard compares against $HOME, so pin HOME for the fixed paths
HOME=/Users/x checkw 2 '/Users/x/.gitconfig'
HOME=/Users/x checkw 2 '/Users/x/.config/git/config'
HOME=/Users/x checkw 2 '/Users/X/.GitConfig'
HOME=/Users/x checkw 0 '/Users/y/.gitconfig'
checkw 2 "$HOME/.gitconfig"
checkw 2 "$HOME/.config/git/config"
checkw 2 '/x/.claude/agents/a.md'
checkw 2 '/x/.claude/rules/a.md'
checkw 0 '/x/agents/a.md'
checkw 0 '/x/skills/s/SKILL.md'
checkw 0 '/x/.claude/skills/s/SKILL.md'

check readonly-bash.sh 2 'sort -o out.txt a.txt'
check readonly-bash.sh 2 'git diff --output=out.txt'
check readonly-bash.sh 2 'find . -fls out.txt'
check readonly-bash.sh 2 "sed -n 'w out.txt' a.txt"
check readonly-bash.sh 2 'uniq a.txt out.txt'
check readonly-bash.sh 2 'tree -o out.txt'
check readonly-bash.sh 0 'git log -1'
check readonly-bash.sh 0 'sort a.txt'
check readonly-bash.sh 0 'uniq -c'

# ---- filter-test-output.sh (fail-open PreToolUse rewriter, not part of the fail-closed loops) ----
FHOOK="$HOOKS/filter-test-output.sh"
FSELF="$(cd "$HOOKS" && pwd -P)/filter-test-output.sh"
FT=$(mktemp -d "${TMPDIR:-/tmp}/filter-hook-test.XXXXXX")
fnote() { # fnote <ok|fail> <label> [detail]
  if [ "$1" = ok ]; then echo "ok    [filter-test-output.sh] $2"; else echo "FAIL  [filter-test-output.sh] $2 ${3:-}"; fail=1; fi
}
fhook_out() { # fhook_out <command>: prints hook stdout for a command with description and timeout
  jq -n --arg c "$1" '{tool_input:{command:$c,description:"desc",timeout:5000}}' | "$FHOOK" 2>/dev/null
}
checkf_rewrite() {
  local cmd=$1 out rc want
  out=$(jq -n --arg c "$cmd" '{tool_input:{command:$c,description:"desc",timeout:5000}}' | "$FHOOK" 2>/dev/null); rc=$?
  want="( set -o pipefail; $cmd 2>&1 | '$FSELF' --filter )"
  if [ "$rc" = 0 ] \
    && [ "$(jq -r '.hookSpecificOutput.updatedInput.command' <<<"$out")" = "$want" ] \
    && jq -e '.hookSpecificOutput.hookEventName == "PreToolUse"
              and .hookSpecificOutput.updatedInput.description == "desc"
              and .hookSpecificOutput.updatedInput.timeout == 5000
              and (tostring | contains("permissionDecision") | not)' <<<"$out" >/dev/null; then
    fnote ok "rewrite: $cmd"
  else
    fnote fail "rewrite: $cmd" "rc=$rc out=$out"
  fi
}
checkf_none() { # checkf_none <command> [env assignment]
  local cmd=$1 out rc
  out=$(jq -n --arg c "$cmd" '{tool_input:{command:$c}}' | env ${2:-X_UNUSED=1} "$FHOOK" 2>/dev/null); rc=$?
  if [ "$rc" = 0 ] && [ "$out" = '{}' ]; then fnote ok "no rewrite: ${2:+$2 }$(printf '%s' "$cmd" | tr '\n' '~')"; else fnote fail "no rewrite: $cmd" "rc=$rc out=$out"; fi
}

for c in 'npm test' 'npm test -- --watch=false' 'npm run test' 'npm run build' 'npm run lint:fix' 'npm run test:unit-fast' 'npm run test:unit' \
         'pnpm test' 'pnpm run test' 'pnpm run build' 'pnpm run lint' 'yarn test' 'yarn build' 'yarn lint' \
         'npx jest' 'npx vitest run src/a.test.ts' 'pytest' 'pytest -q tests/test_a.py::test_x' 'python -m pytest -x' 'python3 -m pytest' \
         'go test ./...' 'go build ./cmd/x' 'go vet ./...' 'cargo test' 'cargo build --release' 'cargo clippy' \
         'make test' 'make build' 'make lint' 'make check' 'bash tests/test-hooks.sh' 'python3 tests/lint.py'; do
  checkf_rewrite "$c"
done

for c in 'npm test; rm x' 'npm test && echo hi' 'npm test | cat' 'npm test > out' 'npm test < in' 'npm test &' \
         'npm test $(id)' 'npm test `id`' 'npm test "quoted"' "npm test 'q'" $'npm test\nrm x' 'npm test #c' 'npm test \x' \
         'npm install' 'rm -rf build' 'curl x' 'npm run deploy' 'npm runtest' 'pytestx' 'go run main.go' 'make install' \
         'bash tests/../evil.sh' 'bash tests/sub/a.sh' 'python3 tests/a.sh' \
         "'/x/filter-test-output.sh' '--run' 'npm test'" '/x/filter-test-output.sh --run npm' '' \
         ' npm test' 'FOO=1 npm test' 'cd x && npm test' \
         'npm run buildx' 'npm run lint-and-deploy' 'npm run test-e2e' \
         "( set -o pipefail; pytest 2>&1 | '$FSELF' --filter )"; do
  checkf_none "$c"
done
checkf_none 'npm test' CLAUDE_FILTER_OUTPUT=0
out=$(jq -n '{tool_input:{command:"npm test",run_in_background:true}}' | "$FHOOK" 2>/dev/null); rc=$?
if [ "$rc" = 0 ] && [ "$out" = '{}' ]; then fnote ok "no rewrite: run_in_background true"; else fnote fail "no rewrite: run_in_background true" "rc=$rc out=$out"; fi
out=$(jq -n '{tool_input:{command:"npm test",run_in_background:false}}' | "$FHOOK" 2>/dev/null)
if jq -e '.hookSpecificOutput.updatedInput.run_in_background == false and (.hookSpecificOutput.updatedInput.command | startswith("( set -o pipefail; npm test 2>&1 | "))' <<<"$out" >/dev/null 2>&1; then
  fnote ok "rewrite: run_in_background false"
else
  fnote fail "rewrite: run_in_background false" "out=$out"
fi

# fail-open: bad input and missing jq print {} (or nothing) and exit 0, never 2
for in in '{bad json' '{"tool_input":' '' '{}' '{"tool_input":{}}' '{"tool_input":{"command":123}}'; do
  out=$(printf '%s' "$in" | "$FHOOK" 2>/dev/null); rc=$?
  if [ "$rc" = 0 ] && [ "$out" = '{}' ]; then fnote ok "fail-open input: $in"; else fnote fail "fail-open input: $in" "rc=$rc out=$out"; fi
done
NOJQ2=$(mktemp -d)
out=$(printf '%s' '{"tool_input":{"command":"npm test"}}' | PATH="$NOJQ2" "$BASH_BIN" "$FHOOK" 2>/dev/null); rc=$?
if [ "$rc" = 0 ] && [ "$out" = '{}' ]; then fnote ok "jq missing: exit 0, {}"; else fnote fail "jq missing" "rc=$rc out=$out"; fi
rmdir "$NOJQ2"

# non-executable SELF: a copy of the hook without the exec bit must not rewrite anything
mkdir "$FT/noexec"
cp "$FHOOK" "$FT/noexec/filter-test-output.sh"; chmod 644 "$FT/noexec/filter-test-output.sh"
out=$(jq -n '{tool_input:{command:"npm test"}}' | "$BASH_BIN" "$FT/noexec/filter-test-output.sh" 2>/dev/null); rc=$?
if [ "$rc" = 0 ] && [ "$out" = '{}' ]; then fnote ok "non-executable SELF: exit 0, {}"; else fnote fail "non-executable SELF" "rc=$rc out=$out"; fi

# --filter mode usage: anything but exactly --filter prints usage, exits 2, runs nothing
out=$(TMPDIR="$FT" "$FHOOK" --run 'echo X' </dev/null 2>&1); rc=$?
if [ "$rc" = 2 ] && ! grep -qx X <<<"$out" && grep -q '^usage:' <<<"$out"; then fnote ok "--run 'echo X': usage, exit 2, nothing executed"; else fnote fail "--run 'echo X'" "rc=$rc out=$out"; fi
out=$(echo hi | TMPDIR="$FT" "$FHOOK" --filter extra 2>&1); rc=$?
if [ "$rc" = 2 ] && ! grep -qx hi <<<"$out"; then fnote ok "--filter extra: usage, exit 2"; else fnote fail "--filter extra" "rc=$rc out=$out"; fi
out=$(TMPDIR="$FT" "$FHOOK" --run </dev/null 2>&1); rc=$?
if [ "$rc" = 2 ]; then fnote ok "--run without command: usage, exit 2"; else fnote fail "--run without command" "rc=$rc"; fi
if [ -z "$(ls -A "$FT" | grep '^filter-test-output\.')" ]; then fnote ok "usage errors leave no log"; else fnote fail "usage errors leave no log"; fi

# rewritten command executed under bash -c and zsh -c, with a stub pytest first on PATH
mkdir "$FT/bin"
printf '%s\n' '#!/bin/sh' 'sh -c "$STUB_BODY"' 'exit "$STUB_RC"' > "$FT/bin/pytest"
chmod +x "$FT/bin/pytest"
REWRITTEN=$(jq -n '{tool_input:{command:"pytest -q tests/test_a.py"}}' | "$FHOOK" | jq -r '.hookSpecificOutput.updatedInput.command')
frun_sh() { # frun_sh <shell> <stub body> <stub exit code>: output to $FT/o, status in $rc
  STUB_BODY="$2" STUB_RC="$3" PATH="$FT/bin:$PATH" TMPDIR="$FT" "$1" -c "$REWRITTEN" >"$FT/o" 2>&1; rc=$?
}
flogs() { find "$FT" -maxdepth 1 -type f -name 'filter-test-output.*'; }
LONGBODY='seq 1 500 | sed "250s/.*/FAIL: the middle test/"'
for sh in bash zsh; do
  if ! command -v "$sh" >/dev/null 2>&1; then echo "skip  [filter-test-output.sh] $sh not installed"; continue; fi
  for code in 0 1 3 127; do
    for kind in short long; do
      if [ $kind = short ]; then body='seq 1 10'; else body=$LONGBODY; fi
      rm -f "$FT"/filter-test-output.*
      frun_sh "$sh" "$body" "$code"
      if [ "$rc" = "$code" ]; then fnote ok "$sh -c rewritten: exit $code preserved ($kind output)"; else fnote fail "$sh -c rewritten exit $code ($kind)" "got=$rc"; fi
    done
  done

  rm -f "$FT"/filter-test-output.*
  frun_sh "$sh" 'printf "a\nb\n"; echo err >&2; printf "last-no-newline"' 0
  printf 'a\nb\nerr\nlast-no-newline' > "$FT/want"
  if cmp -s "$FT/o" "$FT/want" && [ -z "$(flogs)" ]; then fnote ok "$sh -c rewritten: short output byte-identical with stderr merged, no log left"; else fnote fail "$sh -c short output byte-identical" "$(od -c "$FT/o" | head -3)"; fi

  rm -f "$FT"/filter-test-output.*
  frun_sh "$sh" 'seq 1 200' 0
  if cmp -s "$FT/o" <(seq 1 200) && [ -z "$(flogs)" ]; then fnote ok "$sh -c rewritten: exactly 200 lines unfiltered, no log"; else fnote fail "$sh -c exactly 200 lines unfiltered"; fi

  rm -f "$FT"/filter-test-output.*
  frun_sh "$sh" "$LONGBODY" 1
  logs=$(flogs)
  lines=$(wc -l <"$FT/o" | tr -d ' ')
  footer=$(tail -1 "$FT/o")
  if [ "$(printf '%s\n' "$logs" | grep -c .)" = 1 ] \
    && grep -qF 'FAIL: the middle test' "$FT/o" \
    && [ "$lines" -lt 200 ] \
    && [ "$footer" = "[filter-test-output] 500 lines total; full log: $logs" ] \
    && [ "$(ls -l "$logs" | cut -c1-10)" = "-rw-------" ] \
    && [ "$(wc -l < "$logs" | tr -d ' ')" = 500 ] \
    && [ "$(sed -n 1p "$FT/o")" = 1 ] && grep -qx 20 "$FT/o" && ! grep -qx 21 "$FT/o" \
    && grep -qx 500 "$FT/o" && grep -qx 441 "$FT/o" && ! grep -qx 440 "$FT/o" && ! grep -qx 100 "$FT/o"; then
    fnote ok "$sh -c rewritten: 500 lines -> head, FAIL, tail, exact footer, log mode 600, < 200 lines"
  else
    fnote fail "$sh -c rewritten long output filtered" "lines=$lines logs=$logs footer=$footer"
  fi
done
rm -f "$FT"/filter-test-output.*

# new failure markers survive filtering of long output (filler lines match none of them)
MK='i=1; while [ $i -le 300 ]; do case $i in
  60) echo "src/a.ts(3,4): error TS2322: Type x is not assignable";;
  100) echo "  12:5  error  no-unused-vars  rule";;
  140) echo "thread main panicked at src/lib.rs:9";;
  180) echo "3 failing";;
  220) echo "not ok 7 - thing";;
  *) echo "filler line $i";; esac; i=$((i+1)); done'
frun_sh bash "$MK" 1
miss=""
for m in 'error TS2322' '  12:5  error  no-unused-vars' 'panicked at src/lib.rs' '3 failing' 'not ok 7'; do
  grep -qF "$m" "$FT/o" || miss="$miss [$m]"
done
if [ -z "$miss" ] && ! grep -qx 'filler line 30' "$FT/o"; then fnote ok "TS error, ESLint column, panicked at, N failing, not ok survive filtering"; else fnote fail "failure markers survive filtering" "missing:$miss"; fi
rm -f "$FT"/filter-test-output.*
frun_sh bash 'seq 1 300 | sed "150s/.*/E   assert 1 == 2/"' 1
if grep -qF 'E   assert 1 == 2' "$FT/o"; then fnote ok "pytest '^E ' line survives filtering"; else fnote fail "pytest '^E ' line survives filtering"; fi
rm -f "$FT"/filter-test-output.*

# a single 1 MB line is truncated, with a marker, and the output stays small
head -c 1048576 /dev/zero | tr '\0' x | TMPDIR="$FT" "$FHOOK" --filter >"$FT/o" 2>&1; rc=$?
if [ "$rc" = 0 ] && grep -qF '... [filter-test-output: line truncated, 1048576 chars]' "$FT/o" \
  && [ "$(wc -c <"$FT/o" | tr -d ' ')" -lt 4000 ] && [ -z "$(flogs)" ]; then
  fnote ok "1 MB single line truncated with marker"
else
  fnote fail "1 MB single line truncated" "rc=$rc size=$(wc -c <"$FT/o")"
fi

# TMPDIR unusable: input passes through unchanged, exit 0
seq 1 300 | TMPDIR="$FT/does-not-exist" "$FHOOK" --filter >"$FT/o" 2>/dev/null; rc=$?
if [ "$rc" = 0 ] && cmp -s "$FT/o" <(seq 1 300); then fnote ok "missing TMPDIR: input passes through, exit 0"; else fnote fail "missing TMPDIR passthrough" "rc=$rc"; fi

# TMPDIR injection: a value starting with "-" or a relative path is never handed to find; nothing in cwd is deleted
mkdir -p "$FT/cwd/relative/dir"
touch "$FT/cwd/sentinel" "$FT/cwd/filter-test-output.SENTINEL" "$FT/cwd/relative/dir/filter-test-output.SENTINEL"
touch -t 202001010000 "$FT/cwd/sentinel" "$FT/cwd/filter-test-output.SENTINEL" "$FT/cwd/relative/dir/filter-test-output.SENTINEL"
for td in -delete relative/dir; do
  out=$(cd "$FT/cwd" && seq 1 5 | TMPDIR="$td" "$FHOOK" --filter 2>/dev/null); rc=$?
  if [ "$rc" = 0 ] && [ "$out" = "$(seq 1 5)" ] && [ -f "$FT/cwd/sentinel" ] && [ -f "$FT/cwd/filter-test-output.SENTINEL" ] \
    && [ -f "$FT/cwd/relative/dir/filter-test-output.SENTINEL" ]; then
    fnote ok "TMPDIR=$td: output passes through, exit 0, nothing in cwd deleted"
  else
    fnote fail "TMPDIR=$td" "rc=$rc $(ls -A "$FT/cwd" | tr '\n' ' ')"
  fi
done

# old-log cleanup: only this user's old regular files are removed
mkdir "$FT/clean"
touch "$FT/clean/filter-test-output.OLD" "$FT/clean/filter-test-output.FRESH"
mkdir "$FT/clean/filter-test-output.DIR"
touch -t 202001010000 "$FT/clean/filter-test-output.OLD" "$FT/clean/filter-test-output.DIR"
echo hi | TMPDIR="$FT/clean" "$FHOOK" --filter >/dev/null 2>&1; rc=$?
if [ "$rc" = 0 ] && [ ! -e "$FT/clean/filter-test-output.OLD" ] && [ -f "$FT/clean/filter-test-output.FRESH" ] \
  && [ -d "$FT/clean/filter-test-output.DIR" ]; then
  fnote ok "cleanup deletes old log, keeps fresh log and same-named directory"
else
  fnote fail "old-log cleanup" "rc=$rc $(ls -A "$FT/clean" | tr '\n' ' ')"
fi

# cap: patched copy with CAP_KB=64 stores at most ~64 KB, drains the rest, marks it, keeps the producer's status
mkdir "$FT/cap"
sed 's/CAP_KB=51200/CAP_KB=64/' "$FHOOK" > "$FT/cap/filter-test-output.sh"; chmod +x "$FT/cap/filter-test-output.sh"
if grep -q 'CAP_KB=64 ' "$FT/cap/filter-test-output.sh"; then
  ( set -o pipefail; sh -c 'seq 1 200000; exit 7' 2>&1 | TMPDIR="$FT" "$FT/cap/filter-test-output.sh" --filter ) >"$FT/o" 2>&1; rc=$?
  logs=$(flogs)
  if [ "$rc" = 7 ] && grep -q 'log capped at' "$FT/o" && [ "$(printf '%s\n' "$logs" | grep -c .)" = 1 ] \
    && [ "$(wc -c <"$logs" | tr -d ' ')" -lt 200000 ] && [ "$(wc -l <"$FT/o" | tr -d ' ')" -lt 300 ]; then
    fnote ok "cap: large output capped, marker present, producer exit 7 preserved"
    if grep -q 'log capped at 64 KB;' "$FT/o"; then fnote ok "cap marker shows KB below 1 MB"; else fnote fail "cap marker units" "$(grep 'log capped' "$FT/o")"; fi
  else
    fnote fail "cap" "rc=$rc logsize=$(wc -c <"$logs" 2>/dev/null) out=$(tail -3 "$FT/o")"
  fi
else
  fnote fail "cap: could not patch CAP_KB in the hook copy"
fi
rm -f "$FT"/filter-test-output.*

# signal: TERM during a slow producer prints the view so far, an interrupted footer, and exits 143
sh -c 'echo $$ > "$1"; seq 1 300; exec sleep 30' sh "$FT/prod.pid" 2>/dev/null | TMPDIR="$FT" "$FHOOK" --filter >"$FT/sig.out" 2>&1 &
fpid=$!
n=0
while [ $n -lt 100 ]; do
  lg=$(flogs | head -1)
  [ -n "$lg" ] && [ "$(wc -l <"$lg" | tr -d ' ')" -ge 300 ] && break
  sleep 0.1; n=$((n+1))
done
kill -TERM "$fpid" 2>/dev/null
wait "$fpid" 2>/dev/null; rc=$?
[ -s "$FT/prod.pid" ] && kill "$(cat "$FT/prod.pid")" 2>/dev/null
if [ "$rc" = 143 ] && grep -q '^\[filter-test-output\] interrupted after 300 lines; full log: ' "$FT/sig.out" \
  && grep -qx 300 "$FT/sig.out" && grep -qx 1 "$FT/sig.out"; then
  fnote ok "TERM during slow producer: filtered view, interrupted footer, exit 143"
else
  fnote fail "TERM handling" "rc=$rc out=$(tail -2 "$FT/sig.out")"
fi
rm -f "$FT"/filter-test-output.*

# signal: INT, same flow, exit 130. Background jobs ignore SIGINT when job control is off, so the
# filter runs in the foreground and a background helper sends INT. The producer gets explicit stdin.
if ! "$BASH_BIN" -c 'trap "exit 0" INT; kill -INT $$; exit 1' 2>/dev/null; then
  echo "skip  [filter-test-output.sh] SIGINT is ignored in this test shell; INT test not run"
else
  rm -f "$FT/prod.pid" "$FT/filt.pid"
  ( n=0
    while [ $n -lt 100 ]; do
      lg=$(flogs | head -1)
      [ -s "$FT/filt.pid" ] && [ -n "$lg" ] && [ "$(wc -l <"$lg" | tr -d ' ')" -ge 300 ] && break
      sleep 0.1; n=$((n+1))
    done
    [ -s "$FT/filt.pid" ] && kill -INT "$(cat "$FT/filt.pid")" 2>/dev/null
    sleep 0.5
    [ -s "$FT/prod.pid" ] && kill "$(cat "$FT/prod.pid")" 2>/dev/null ) &
  helper=$!
  sh -c 'echo $$ > "$1"; seq 1 300; exec sleep 30' sh "$FT/prod.pid" </dev/null 2>/dev/null \
    | TMPDIR="$FT" sh -c 'echo $$ > "$1"; exec "$2" --filter' sh "$FT/filt.pid" "$FHOOK" >"$FT/int.out" 2>&1
  rc=$?
  wait "$helper" 2>/dev/null
  if [ "$rc" = 130 ] && grep -q '^\[filter-test-output\] interrupted after 300 lines; full log: ' "$FT/int.out" \
    && grep -qx 300 "$FT/int.out" && grep -qx 1 "$FT/int.out"; then
    fnote ok "INT during slow producer: filtered view, interrupted footer, exit 130"
  else
    fnote fail "INT handling" "rc=$rc out=$(tail -2 "$FT/int.out")"
  fi
fi
rm -f "$FT"/filter-test-output.*

case "$FT" in */filter-hook-test.*) rm -rf "$FT" ;; esac

# ---- guard-mcp-serena.sh (default-deny allowlist for Serena MCP tools; fail closed) ----
SHOOK="$HOOKS/guard-mcp-serena.sh"
# Temp project root with fixtures; SOUT is a directory outside it. Removed at the end of this section.
SROOT=$(mktemp -d "${TMPDIR:-/tmp}/serena-hook-test.XXXXXX")
SOUT=$(mktemp -d "${TMPDIR:-/tmp}/serena-hook-test.XXXXXX")
mkdir -p "$SROOT/src" "$SROOT/.git"   # .git pins the root here even if an ancestor of the temp dir has markers
touch "$SROOT/src/app.py" "$SROOT/src/a..b.py" "$SROOT/.env.local" "$SOUT/secret-target.txt"
ln -s "$SROOT/does-not-exist-target" "$SROOT/link_dangling"
ln -s "$SOUT" "$SROOT/link_out"
ln -s "$SOUT/secret-target.txt" "$SROOT/link_file_out"
ln -s "$SROOT/src/app.py" "$SROOT/link_ok"
ln -s "$SROOT/.env.local" "$SROOT/link_secret"
SPD=$SROOT   # CLAUDE_PROJECT_DIR for checks; set to "" to run with no env root
SCWD=""      # optional cwd field in the input JSON
checks() { # checks <want exit> <tool name> <tool_input JSON>; a deny must also print BLOCKED on stderr
  local want=$1 tool=$2 ti=$3 got err
  err=$(jq -n --arg t "$tool" --argjson i "$ti" --arg c "$SCWD" \
    '{tool_name:$t,tool_input:$i} + (if $c == "" then {} else {cwd:$c} end)' | CLAUDE_PROJECT_DIR="$SPD" "$SHOOK" 2>&1 >/dev/null); got=$?
  if [ "$got" = "$want" ] && { [ "$want" = 0 ] || grep -q '^BLOCKED' <<<"$err"; }; then
    echo "ok    [guard-mcp-serena.sh] $tool $ti${SCWD:+ cwd=set}${SPD:+ env-root}"
  else
    echo "FAIL  [guard-mcp-serena.sh] want=$want got=$got: $tool $ti stderr=$err"; fail=1
  fi
}
checks_raw() { # checks_raw <want exit> <raw stdin>
  local want=$1 input=$2 got err
  err=$(printf '%s' "$input" | CLAUDE_PROJECT_DIR="$SPD" "$SHOOK" 2>&1 >/dev/null); got=$?
  if [ "$got" = "$want" ] && { [ "$want" = 0 ] || grep -q '^BLOCKED' <<<"$err"; }; then
    echo "ok    [guard-mcp-serena.sh] raw input: $input"
  else
    echo "FAIL  [guard-mcp-serena.sh] want=$want got=$got: raw input: $input stderr=$err"; fail=1
  fi
}
SF=mcp__serena__find_symbol
# allowed
checks 0 $SF '{"name_path":"Foo","relative_path":"src/app.py"}'
checks 0 mcp__serena__get_symbols_overview '{"relative_path":"src"}'
checks 0 mcp__serena__find_referencing_symbols '{"name_path":"Foo/bar","relative_path":"src/app.py"}'
checks 0 mcp__serena__find_implementations '{"name_path":"Foo","relative_path":"src/app.py"}'
checks 0 $SF '{"name_path":"Foo","within_relative_path":"src"}'
checks 0 $SF '{}'
checks 0 $SF '{"name_path":"Foo"}'
checks 0 $SF '{"name_path":"a/../b"}'
checks 0 $SF '{"name_path_pattern":"../x"}'
checks 0 $SF '{"relative_path":"src/a..b.py"}'
checks 0 Read '{"file_path":"/etc/passwd"}'
checks 0 mcp__other__read_file '{"relative_path":"/etc/passwd"}'
# paths that leave the project or are absolute
checks 2 $SF '{"relative_path":"/etc/passwd"}'
checks 2 $SF '{"relative_path":"~/x"}'
checks 2 $SF '{"relative_path":"a/../../b"}'
checks 2 $SF '{"relative_path":".."}'
checks 2 $SF '{"relative_path":"src\\app.py"}'
checks 2 $SF '{"within_relative_path":"/etc"}'
checks 2 $SF '{"name_path":"Foo","relative_path":"//etc/passwd"}'
# secret paths
checks 2 $SF '{"relative_path":".env"}'
checks 2 $SF '{"relative_path":"config/.env.local"}'
checks 2 $SF '{"relative_path":"certs/server.pem"}'
checks 2 $SF '{"relative_path":"Cert.PEM"}'
checks 2 $SF '{"relative_path":"tls/server.key"}'
checks 2 $SF '{"relative_path":".ssh/id_ed25519"}'
checks 2 $SF '{"relative_path":"keys/id_rsa.pub"}'
checks 2 $SF '{"relative_path":".npmrc"}'
checks 2 $SF '{"relative_path":"aws/credentials.json"}'
checks 2 $SF '{"relative_path":".aws"}'
checks 2 $SF '{"relative_path":"app/secrets/db.yml"}'
checks 2 $SF '{"relative_path":".config/gh/hosts.yml"}'
checks 2 $SF '{"relative_path":".docker/config.json"}'
checks 2 $SF '{"relative_path":"x/git-publish.registry"}'
# a bad path hidden behind a good one, or under a non-standard path key
checks 2 $SF '{"relative_path":"src","within_relative_path":"/etc"}'
checks 2 $SF '{"name_path":"Foo","some_other_path":"../x"}'
# every other Serena tool is denied, including unknown future ones
for t in find_declaration execute_shell_command replace_symbol_body read_file jet_brains_debug brand_new_tool; do
  checks 2 "mcp__serena__$t" '{"relative_path":"src/app.py"}'
done
checks 2 mcp__serena__ '{}'
# fail closed on bad input and missing jq
checks_raw 2 '{bad json'
checks_raw 2 '{"tool_name":'
checks_raw 2 ''
checks_raw 0 '{"tool_name":"Read","tool_input":{"file_path":"x"}}'
checks_raw 2 '{}'
checks_raw 2 '{"tool_name":123}'
# project root resolution: no root
SPD=""
checks 2 $SF '{"relative_path":"src/app.py"}'
checks 0 $SF '{"name_path":"Foo"}'
checks 0 $SF '{}'
checks 0 Read '{"file_path":"x"}'
# root from the input cwd instead of the environment
SCWD=$SROOT
checks 0 $SF '{"relative_path":"src/app.py"}'
checks 2 $SF '{"relative_path":"link_out"}'
checks 2 $SF '{"relative_path":"link_out/secret-target.txt"}'
checks 2 $SF '{"relative_path":"link_file_out"}'
checks 2 $SF '{"relative_path":"../x"}'
checks 2 $SF '{"relative_path":"/etc/passwd"}'
SCWD=""
SPD=$SROOT
# symlinks, via the environment root
checks 2 $SF '{"relative_path":"link_out"}'
checks 2 $SF '{"relative_path":"link_out/secret-target.txt"}'
checks 2 $SF '{"relative_path":"link_file_out"}'
checks 0 $SF '{"relative_path":"link_ok"}'
checks 2 $SF '{"relative_path":"link_secret"}'
# absolute paths: allowed only when they exist and resolve to the root or below
mkdir -p "$SROOT/certs"; touch "$SROOT/certs/server.pem"
ln -s "$SOUT" "$SROOT/abs_link_out"
abs() { jq -nc --arg p "$1" '{relative_path:$p}'; }
checks 0 $SF "$(abs "$SROOT/src/app.py")"
checks 0 $SF "$(abs "$SROOT")"
checks 0 $SF "$(abs "$SROOT/src")"
checks 2 $SF "$(abs "$SOUT/secret-target.txt")"
checks 2 $SF "$(abs "$SROOT/src/not-yet-created.py")"
checks 2 $SF "$(abs "$SROOT/abs_link_out")"
# sibling whose name starts with the root's name: the prefix check must compare "root/", not "root"
SSIB="$SROOT-sib"; mkdir "$SSIB"; touch "$SSIB/f.txt"
checks 2 $SF "$(abs "$SSIB/f.txt")"
checks 2 $SF "$(abs "$SROOT/abs_link_out/secret-target.txt")"
checks 2 $SF "$(abs "$SROOT/certs/server.pem")"
checks 2 $SF "$(abs "$SROOT/src/../src/app.py")"
checks 2 $SF '{"relative_path":"/tmp/x\\y"}'
checks 2 $SF '{"relative_path":"~/x"}'
checks 2 $SF '{"relative_path":"/etc/passwd"}'
# macOS: /tmp is a symlink to /private/tmp, and both spellings of the root must work
if [ "$(uname -s)" = Darwin ] && [ -d /private/tmp ]; then
  SMAC=$(mktemp -d /private/tmp/serena-hook-test.XXXXXX)
  mkdir "$SMAC/.git"; touch "$SMAC/f.txt"
  SMACB=/tmp/${SMAC#/private/tmp/}
  SPD=$SMACB
  checks 0 $SF '{"relative_path":"f.txt"}'
  checks 0 $SF "$(abs "$SMACB/f.txt")"
  checks 0 $SF "$(abs "$SMAC/f.txt")"
  SPD=$SMAC
  checks 0 $SF "$(abs "$SMACB/f.txt")"
  SPD=$SROOT
else
  echo "skip  [guard-mcp-serena.sh] not macOS; /tmp vs /private/tmp cases not run"
fi
checks 2 $SF '{"relative_path":"src/not-yet-created.py"}'
checks 2 $SF '{"relative_path":"newdir/newfile.py"}'
checks 2 $SF '{"relative_path":"link_dangling"}'
checks 0 $SF '{"relative_path":"src"}'
checks 0 $SF '{"relative_path":"src/app.py"}'
checks 0 $SF '{"relative_path":"."}'
# non-string, null and multi-line path values
checks 2 $SF '{"relative_path":5}'
checks 2 $SF '{"relative_path":{"a":"b"}}'
checks 2 $SF '{"relative_path":["src"]}'
checks 2 $SF '{"relative_path":true}'
checks 0 $SF '{"relative_path":null}'
checks 2 $SF '{"relative_path":"src\napp.py"}'
checks 2 $SF '{"within_relative_path":"src\n/etc"}'
# Serena-looking tool names that are not exactly mcp__serena__*
checks 2 mcp__my-serena__find_symbol '{}'
checks 2 mcp__Serena__find_symbol '{}'
checks 2 mcp__plugin_x_serena__read_file '{}'
checks 2 mcp__plugin_x_serena__find_symbol '{"relative_path":"src"}'
# root detection: .serena/project.yml ancestor, else .git (dir or file) ancestor, else the start dir
RA=$(mktemp -d "${TMPDIR:-/tmp}/serena-hook-test.XXXXXX")   # .serena/project.yml marker
mkdir -p "$RA/.serena" "$RA/pkg/sub"; touch "$RA/.serena/project.yml" "$RA/top.txt" "$RA/pkg/sub/only-here.txt"
RG=$(mktemp -d "${TMPDIR:-/tmp}/serena-hook-test.XXXXXX")   # .git directory marker
mkdir -p "$RG/.git" "$RG/a/b"; touch "$RG/top.txt" "$RG/a/b/only-here.txt"
RF=$(mktemp -d "${TMPDIR:-/tmp}/serena-hook-test.XXXXXX")   # .git file marker (worktree or submodule form)
mkdir -p "$RF/a/b"; printf 'gitdir: /nonexistent/gitdir\n' > "$RF/.git"; touch "$RF/top.txt" "$RF/a/b/only-here.txt"
RN=$(mktemp -d "${TMPDIR:-/tmp}/serena-hook-test.XXXXXX")   # no markers: root is the start dir
touch "$RN/x.txt"
RW=$(mktemp -d "${TMPDIR:-/tmp}/serena-hook-test.XXXXXX")   # worktree-shaped layout
mkdir -p "$RW/.serena" "$RW/src" "$RW/.claude/worktrees/x"; touch "$RW/.serena/project.yml" "$RW/src/ok.txt"
ln -s "$SOUT" "$RW/src/escape"
SPD=$RA/pkg/sub
checks 0 $SF '{"relative_path":"top.txt"}'
checks 2 $SF '{"relative_path":"only-here.txt"}'
SPD=$RG/a/b
checks 0 $SF '{"relative_path":"top.txt"}'
checks 2 $SF '{"relative_path":"only-here.txt"}'
SPD=$RF/a/b
checks 0 $SF '{"relative_path":"top.txt"}'
checks 2 $SF '{"relative_path":"only-here.txt"}'
SPD=$RN
checks 0 $SF '{"relative_path":"x.txt"}'
SPD=$RW/.claude/worktrees/x
checks 0 $SF '{"relative_path":"src/ok.txt"}'
checks 2 $SF '{"relative_path":"src/escape"}'
checks 2 $SF '{"relative_path":"src/escape/secret-target.txt"}'
SPD=""; SCWD=$RA/pkg/sub   # same detection when the start comes from the input cwd
checks 0 $SF '{"relative_path":"top.txt"}'
checks 2 $SF '{"relative_path":"only-here.txt"}'
SCWD=""; SPD=$SROOT

# resolver fallbacks, each with a restricted PATH holding only the named tools
rpath() { # rpath <want> <label> <dir> <relative_path>; the dir holds the tools linked by mkpath
  local want=$1 label=$2 dir=$3 rp=$4 got
  jq -n --arg p "$rp" '{tool_name:"mcp__serena__find_symbol",tool_input:{relative_path:$p}}' | CLAUDE_PROJECT_DIR="$SROOT" PATH="$dir" "$BASH_BIN" "$SHOOK" >/dev/null 2>&1; got=$?
  if [ "$got" = "$want" ]; then echo "ok    [guard-mcp-serena.sh] $label: $rp"; else echo "FAIL  [guard-mcp-serena.sh] $label: $rp want=$want got=$got"; fail=1; fi
}
mkpath() { # mkpath <dir> <extra tool>...: link the base tools plus extras that exist; prints nothing
  local d=$1 b; shift
  for b in jq tr sed cat dirname uname "$@"; do ln -s "$(command -v $b)" "$d/$b" 2>/dev/null; done
}
NOPERL=$(mktemp -d "${TMPDIR:-/tmp}/serena-hook-test.XXXXXX"); mkpath "$NOPERL" python3
NOPYT=$(mktemp -d "${TMPDIR:-/tmp}/serena-hook-test.XXXXXX"); mkpath "$NOPYT" perl
if command -v perl >/dev/null 2>&1; then
  rpath 0 "perl only" "$NOPYT" src/app.py
  rpath 0 "perl only" "$NOPYT" src
  rpath 2 "perl only" "$NOPYT" link_out
  rpath 2 "perl only" "$NOPYT" link_dangling
  rpath 2 "perl only" "$NOPYT" src/not-yet-created.py
else
  echo "skip  [guard-mcp-serena.sh] perl not installed; perl-only cases not run"
fi
if command -v python3 >/dev/null 2>&1 && python3 -I -c 'pass' >/dev/null 2>&1; then
  rpath 0 "python3 only" "$NOPERL" src/app.py
  rpath 0 "python3 only" "$NOPERL" src
  rpath 2 "python3 only" "$NOPERL" link_out
  rpath 2 "python3 only" "$NOPERL" link_dangling
  rpath 2 "python3 only" "$NOPERL" src/not-yet-created.py
else
  echo "skip  [guard-mcp-serena.sh] python3 not usable; python3-only cases not run"
fi

# neither python3 nor perl on PATH: a non-empty path fails closed, no path still passes
NOPY=$(mktemp -d "${TMPDIR:-/tmp}/serena-hook-test.XXXXXX")
for b in jq tr sed cat dirname uname; do ln -s "$(command -v $b)" "$NOPY/$b"; done
printf '%s' '{"tool_name":"mcp__serena__find_symbol","tool_input":{"relative_path":"src/app.py"}}' | CLAUDE_PROJECT_DIR="$SROOT" PATH="$NOPY" "$BASH_BIN" "$SHOOK" >/dev/null 2>&1; got=$?
if [ "$got" = 2 ]; then echo "ok    [guard-mcp-serena.sh] no python3/perl: path denied"; else echo "FAIL  [guard-mcp-serena.sh] no python3/perl path: want=2 got=$got"; fail=1; fi
printf '%s' '{"tool_name":"mcp__serena__find_symbol","tool_input":{"name_path":"Foo"}}' | CLAUDE_PROJECT_DIR="$SROOT" PATH="$NOPY" "$BASH_BIN" "$SHOOK" >/dev/null 2>&1; got=$?
if [ "$got" = 0 ]; then echo "ok    [guard-mcp-serena.sh] no python3/perl: no path allowed"; else echo "FAIL  [guard-mcp-serena.sh] no python3/perl no path: want=0 got=$got"; fail=1; fi
NOJQ3=$(mktemp -d)
printf '%s' '{"tool_name":"Read"}' | PATH="$NOJQ3" "$BASH_BIN" "$SHOOK" >/dev/null 2>&1; got=$?
if [ "$got" = 2 ]; then echo "ok    [guard-mcp-serena.sh] jq missing"; else echo "FAIL  [guard-mcp-serena.sh] jq missing: want=2 got=$got"; fail=1; fi
rmdir "$NOJQ3"
for d in "$NOPY" "$NOPERL" "$NOPYT"; do
  for b in jq tr sed cat dirname uname perl python3; do rm -f "$d/$b"; done
  rmdir "$d"
done
# fixture cleanup: only the dirs created above, only with the expected name
for d in "$SROOT" "$SOUT" "$RA" "$RG" "$RF" "$RN" "$RW" "${SMAC:-}" "${SSIB:-}"; do
  [ -n "$d" ] || continue
  case "$d" in */serena-hook-test.*) rm -rf "$d" ;; esac
done

# ---- guard-bash.sh: .serena/ write protection ----
check guard-bash.sh 2 'echo x > .serena/project.yml'
check guard-bash.sh 2 'echo x >> .serena/project.yml'
check guard-bash.sh 2 'echo x | tee .serena/project.yml'
check guard-bash.sh 2 'cp a.yml .serena/project.yml'
check guard-bash.sh 2 'mv a.yml ./.serena/'
check guard-bash.sh 2 'sed -i s/a/b/ .serena/project.yml'
check guard-bash.sh 0 'cat .serena/project.yml'
check guard-bash.sh 0 'ls .serena'
check guard-bash.sh 0 'echo x > .serenax/a'
check guard-bash.sh 0 'cp a foo.serena'

# ---- guard-mcp-playwright.sh (allowlist of Playwright MCP tools; loopback-only URLs; no file keys; fail closed) ----
PWHOOK="$HOOKS/guard-mcp-playwright.sh"
# Deterministic environment: a stub lsof that reports no listener on port 9 is prepended to PATH for every pw/pw_raw case.
PWSTUB=$(mktemp -d)
printf '#!/bin/sh\nexit 0\n' > "$PWSTUB/lsof"; chmod +x "$PWSTUB/lsof"
PWPATH="$PWSTUB:$PATH"
pw() { # pw <want exit> <tool name> <tool_input JSON>; a deny must also print BLOCKED on stderr
  local want=$1 tool=$2 ti=$3 got err in
  in=$(jq -n --arg t "$tool" --argjson i "$ti" '{tool_name:$t,tool_input:$i}') || { echo "FAIL  bad test JSON: $tool $ti"; fail=1; return; }
  err=$(printf '%s' "$in" | PATH="$PWPATH" "$PWHOOK" 2>&1 >/dev/null); got=$?
  if [ "$got" = "$want" ] && { [ "$want" = 0 ] || grep -q '^BLOCKED by guard-mcp-playwright' <<<"$err"; }; then
    echo "ok    [guard-mcp-playwright.sh] $tool $ti"
  else
    echo "FAIL  [guard-mcp-playwright.sh] want=$want got=$got: $tool $ti stderr=$err"; fail=1
  fi
}
pw_raw() { # pw_raw <want exit> <raw stdin>
  local want=$1 input=$2 got err
  err=$(printf '%s' "$input" | PATH="$PWPATH" "$PWHOOK" 2>&1 >/dev/null); got=$?
  if [ "$got" = "$want" ] && { [ "$want" = 0 ] || grep -q '^BLOCKED by guard-mcp-playwright' <<<"$err"; }; then
    echo "ok    [guard-mcp-playwright.sh] raw input: $input"
  else
    echo "FAIL  [guard-mcp-playwright.sh] want=$want got=$got: raw input: $input stderr=$err"; fail=1
  fi
}
PN=mcp__playwright__browser_navigate
# allowed URLs (loopback only)
pw 0 $PN '{"url":"http://localhost:5173/a?b#c"}'
pw 0 $PN '{"url":"https://127.0.0.1:8443/"}'
pw 0 $PN '{"url":"http://[::1]:3000/"}'
pw 0 $PN '{"url":"http://localhost"}'
pw 0 $PN '{"url":"http://localhost/"}'
pw 0 $PN '{"url":"http://127.0.0.1:65535/x"}'
pw 0 mcp__playwright__browser_tabs '{"action":"new","url":"http://localhost:3000/"}'
pw 0 mcp__playwright__browser_tabs '{"action":"list"}'
pw 0 mcp__playwright__browser_type '{"text":"multi\nline"}'
pw 0 mcp__playwright__browser_take_screenshot '{}'
# every allowlisted tool passes with a valid input from its own argument list
pw 0 mcp__playwright__browser_navigate '{"url":"http://localhost:3000/"}'
pw 0 mcp__playwright__browser_navigate_back '{}'
pw 0 mcp__playwright__browser_tabs '{"action":"select","index":1}'
pw 0 mcp__playwright__browser_snapshot '{"depth":3}'
pw 0 mcp__playwright__browser_take_screenshot '{"element":"button","fullPage":true}'
pw 0 mcp__playwright__browser_console_messages '{"level":"error"}'
pw 0 mcp__playwright__browser_network_requests '{"static":false}'
pw 0 mcp__playwright__browser_resize '{"width":800,"height":600}'
pw 0 mcp__playwright__browser_wait_for '{"time":1}'
pw 0 mcp__playwright__browser_close '{}'
pw 0 mcp__playwright__browser_handle_dialog '{"accept":true}'
pw 0 mcp__playwright__browser_click '{"element":"button","target":"e1"}'
pw 0 mcp__playwright__browser_hover '{"element":"button"}'
pw 0 mcp__playwright__browser_drag '{"startElement":"a","startTarget":"e1","endElement":"b","endTarget":"e2"}'
pw 0 mcp__playwright__browser_type '{"element":"input","text":"hi","submit":true}'
pw 0 mcp__playwright__browser_press_key '{"key":"Tab"}'
pw 0 mcp__playwright__browser_select_option '{"element":"sel","values":["a"]}'
pw 0 mcp__playwright__browser_fill_form '{"fields":[{"name":"n","type":"textbox","target":"e1","value":"v"}]}'
pw 0 mcp__playwright__browser_emulate_media '{"colorScheme":"dark"}'
# absent tool_input is treated as {}
pw_raw 0 '{"tool_name":"mcp__playwright__browser_close"}'
# '@' kept out of URL literals so the secret scanner does not flag test data
AT='@'
# nested src / loopback values
pw 0 mcp__playwright__browser_fill_form '{"fields":[{"src":"http://localhost:3000/x.png"}]}'
pw 0 $PN "{\"url\":\"http://localhost:3000#${AT}evil.com\"}"
pw 0 $PN '{"url":"http://localhost:3000/?@evil"}'
pw 0 $PN '{"url":"http://[::1]"}'
pw 0 $PN '{"url":"http://localhost:03000/"}'
# unexpected top-level keys, wrong tool_input types
pw 2 mcp__playwright__browser_click '{"foo":1}'
pw 2 mcp__playwright__browser_take_screenshot '{"filename":"x.png"}'
pw 2 mcp__playwright__browser_tabs '{"isolatedContext":true}'
pw 2 mcp__playwright__browser_close '{"element":"x"}'
pw 2 $PN '{"url":"http://localhost/","extra":1}'
pw 2 $PN '{"ＵＲＬ":"http://localhost/"}'
pw_raw 2 '{"tool_name":"mcp__playwright__browser_snapshot","tool_input":"str"}'
pw_raw 2 '{"tool_name":"mcp__playwright__browser_snapshot","tool_input":[]}'
pw_raw 2 '{"tool_name":"mcp__playwright__browser_snapshot","tool_input":null}'
# nested file keys inside fill_form items (any case, suffix forms)
pw 2 mcp__playwright__browser_fill_form '{"fields":[{"file":"/etc/hosts"}]}'
pw 2 mcp__playwright__browser_fill_form '{"fields":[{"Directory":"/tmp"}]}'
pw 2 mcp__playwright__browser_fill_form '{"fields":[{"outputFolder":"/tmp"}]}'
pw 2 mcp__playwright__browser_fill_form '{"fields":[{"saveTo":"/tmp/x"}]}'
# nested URL-like keys must be loopback
pw 2 mcp__playwright__browser_fill_form '{"fields":[{"src":"http://evil.com"}]}'
pw 2 mcp__playwright__browser_fill_form '{"fields":[{"location":"http://evil.com"}]}'
pw 2 mcp__playwright__browser_fill_form '{"fields":[{"origin":"http://evil.com"}]}'
pw 2 mcp__playwright__browser_fill_form '{"fields":[{"host":"http://evil.com"}]}'
pw 2 mcp__playwright__browser_fill_form '{"fields":[{"link":"http://evil.com"}]}'
pw 2 mcp__playwright__browser_fill_form '{"fields":[[{"url":"https://evil.com"}]]}'
pw 2 $PN '{"url":"http://lоcalhost/"}'
# denied URLs
pw 2 $PN '{"url":"https://example.com/"}'
pw 2 $PN '{"url":"http://localhost@evil.com/"}'
pw 2 $PN "{\"url\":\"http://localhost:3000${AT}evil.com/\"}"
pw 2 $PN "{\"url\":\"http://localhost:3000\\t${AT}evil.com\"}"
pw 2 $PN '{"url":"http://localhost/\nevil"}'
pw 2 $PN '{"url":"http://localhost\\evil.com/"}'
pw 2 $PN '{"url":"http://localhost./"}'
pw 2 $PN '{"url":"http://localhost.evil.com/"}'
pw 2 $PN '{"url":"http://127.1/"}'
pw 2 $PN '{"url":"http://2130706433/"}'
pw 2 $PN '{"url":"http://0x7f000001/"}'
pw 2 $PN '{"url":"http://0.0.0.0:3000/"}'
pw 2 $PN '{"url":"http://[::ffff:127.0.0.1]/"}'
pw 2 $PN '{"url":"http://localtest.me:3000/"}'
pw 2 $PN '{"url":"http://127.0.0.1.nip.io/"}'
pw 2 $PN '{"url":"http://%6c%6fcalhost/"}'
pw 2 $PN '{"url":"HTTP://LOCALHOST/"}'
pw 2 $PN '{"url":"http://LOCALHOST/"}'
pw 2 $PN '{"url":"file:///etc/hosts"}'
pw 2 $PN '{"url":"data:text/html,x"}'
pw 2 $PN '{"url":"javascript:alert(1)"}'
pw 2 $PN '{"url":"about:blank"}'
pw 2 $PN '{"url":"view-source:http://localhost/"}'
pw 2 $PN '{"url":"chrome://settings"}'
pw 2 $PN '{"url":"ws://localhost:3000/"}'
pw 2 $PN '{"url":"blob:http://localhost/x"}'
pw 2 $PN '{"url":""}'
pw 2 $PN '{"url":"//localhost/"}'
pw 2 $PN '{"url":"http://localhost:0/"}'
pw 2 $PN '{"url":"http://localhost:65536/"}'
pw 2 $PN '{"url":"http://localhost:99999/"}'
pw 2 $PN '{"url":" http://localhost/"}'
pw 2 $PN '{"url":5}'
pw 2 $PN '{"url":null}'
pw 2 $PN '{"url":["http://localhost/"]}'
pw 2 $PN '{"opts":{"targetUrl":"https://evil.com"}}'
pw 2 mcp__playwright__browser_tabs '{"action":"new","url":"https://example.com"}'
pw 2 mcp__playwright__browser_click '{"href":"https://example.com"}'
pw 2 mcp__playwright__browser_click '{"a":[{"b":{"uri":"file:///etc/hosts"}}]}'
# denied file keys (any depth, any case)
pw 2 mcp__playwright__browser_take_screenshot '{"filename":"x.png"}'
pw 2 mcp__playwright__browser_take_screenshot '{"Filename":"x"}'
pw 2 mcp__playwright__browser_snapshot '{"outputPath":"/tmp/x"}'
pw 2 mcp__playwright__browser_snapshot '{"paths":["/etc/hosts"]}'
pw 2 mcp__playwright__browser_snapshot '{"outputDir":"/tmp"}'
pw 2 mcp__playwright__browser_snapshot '{"a":{"b":[{"FILENAME":"x"}]}}'
# denied tools (not on the allowlist), including unknown future ones
for t in browser_evaluate browser_run_code_unsafe browser_file_upload browser_drop browser_find browser_network_request browser_cookie_get browser_route browser_storage_state browser_pdf_save browser_mouse_click_xy browser_start_tracing browser_get_config browser_verify_text_visible browser_future_tool; do
  pw 2 "mcp__playwright__$t" '{}'
done
pw 2 mcp__playwright__ '{}'
# lookalike prefixes
pw 2 mcp__pw__browser_click '{}'
pw 2 mcp__Playwright__browser_click '{}'
pw 2 mcp__playwright_x__browser_navigate '{"url":"http://localhost/"}'
pw 2 mcp__other__browser_navigate '{"url":"http://localhost/"}'
# fail closed on bad input and missing jq
pw_raw 2 ''
pw_raw 2 '{bad json'
pw_raw 2 '{"tool_name":'
pw_raw 2 '{}'
pw_raw 2 '{"tool_input":{}}'
pw_raw 2 '{"tool_name":123}'
pw_raw 2 '{"tool_name":null,"tool_input":{}}'
pw_raw 0 '{"tool_name":"mcp__playwright__browser_snapshot","tool_input":{}}'
NOJQ4=$(mktemp -d)
printf '%s' '{"tool_name":"mcp__playwright__browser_snapshot","tool_input":{}}' | PATH="$NOJQ4" "$BASH_BIN" "$PWHOOK" >/dev/null 2>&1; got=$?
if [ "$got" = 2 ]; then echo "ok    [guard-mcp-playwright.sh] jq missing"; else echo "FAIL  [guard-mcp-playwright.sh] jq missing: want=2 got=$got"; fail=1; fi
rmdir "$NOJQ4"
# embedded newline in tool_name
pw_raw 2 '{"tool_name":"mcp__playwright__browser_snap\nshot","tool_input":{}}'
# port 9 listener (stub lsof prints a listener line) -> deny, stderr names port 9
PWL=$(mktemp -d)
printf '#!/bin/sh\nprintf "COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\\nnc 123 u 3u IPv4 0t0 TCP 127.0.0.1:9 (LISTEN)\\n"\n' > "$PWL/lsof"; chmod +x "$PWL/lsof"
err=$(printf '%s' '{"tool_name":"mcp__playwright__browser_snapshot","tool_input":{}}' | PATH="$PWL:$PATH" "$PWHOOK" 2>&1 >/dev/null); got=$?
if [ "$got" = 2 ] && grep -q 'port 9' <<<"$err"; then echo "ok    [guard-mcp-playwright.sh] listener on port 9 denied"; else echo "FAIL  [guard-mcp-playwright.sh] port 9 listener: want=2 got=$got stderr=$err"; fail=1; fi
rm -f "$PWL/lsof"; rmdir "$PWL"
# Patched copies of the hook (like test-git-publish.sh): the /dev/tcp target is hard-coded in the hook, so tests rewrite it in a temp copy.
PWIN='{"tool_name":"mcp__playwright__browser_snapshot","tool_input":{}}'
PWP=$(mktemp -d)
grep -q '/dev/tcp/127\.0\.0\.1/9)' "$PWHOOK" || { echo "FAIL  [guard-mcp-playwright.sh] probe line not found for patching"; fail=1; }
# Listener on the probe target (a real one, on an ephemeral port) -> deny, even though the lsof stub reports nothing
if command -v python3 >/dev/null 2>&1; then
  python3 -I -c 'import socket,sys,time
s=socket.socket(); s.bind(("127.0.0.1",0)); s.listen(5)
open(sys.argv[1],"w").write(str(s.getsockname()[1])); time.sleep(30)' "$PWP/port" &
  LPID=$!
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do [ -s "$PWP/port" ] && break; sleep 0.1; done
  sed "s#/dev/tcp/127\.0\.0\.1/9)#/dev/tcp/127.0.0.1/$(cat "$PWP/port"))#" "$PWHOOK" > "$PWP/listen.sh"
  err=$(printf '%s' "$PWIN" | PATH="$PWPATH" "$BASH_BIN" "$PWP/listen.sh" 2>&1 >/dev/null); got=$?
  if [ "$got" = 2 ] && grep -q 'port 9' <<<"$err"; then echo "ok    [guard-mcp-playwright.sh] /dev/tcp probe sees a listener"; else echo "FAIL  [guard-mcp-playwright.sh] probe listener: want=2 got=$got stderr=$err"; fail=1; fi
  kill "$LPID" 2>/dev/null; wait "$LPID" 2>/dev/null
else
  echo "SKIP  [guard-mcp-playwright.sh] python3 missing: /dev/tcp listener test"
fi
# lsof missing but /dev/tcp probe works and nothing listens -> allow (PATH has only jq, cat, tr)
NOLSOF=$(mktemp -d)
for b in jq cat tr; do ln -s "$(command -v $b)" "$NOLSOF/$b"; done
err=$(printf '%s' "$PWIN" | PATH="$NOLSOF" "$BASH_BIN" "$PWHOOK" 2>&1 >/dev/null); got=$?
if [ "$got" = 0 ]; then echo "ok    [guard-mcp-playwright.sh] lsof missing, probe ran: allowed"; else echo "FAIL  [guard-mcp-playwright.sh] lsof missing with probe: want=0 got=$got stderr=$err"; fail=1; fi
# lsof missing and no /dev/tcp support (simulated: path rewritten to a missing file) -> deny
sed 's#/dev/tcp/127\.0\.0\.1/9)#/dev/nope/127.0.0.1/9)#' "$PWHOOK" > "$PWP/nodevtcp.sh"
err=$(printf '%s' "$PWIN" | PATH="$NOLSOF" "$BASH_BIN" "$PWP/nodevtcp.sh" 2>&1 >/dev/null); got=$?
if [ "$got" = 2 ] && grep -q 'lsof' <<<"$err"; then echo "ok    [guard-mcp-playwright.sh] no /dev/tcp and no lsof denied"; else echo "FAIL  [guard-mcp-playwright.sh] no /dev/tcp, no lsof: want=2 got=$got stderr=$err"; fail=1; fi
# no /dev/tcp support but lsof stub present and empty -> allow
err=$(printf '%s' "$PWIN" | PATH="$PWPATH" "$BASH_BIN" "$PWP/nodevtcp.sh" 2>&1 >/dev/null); got=$?
if [ "$got" = 0 ]; then echo "ok    [guard-mcp-playwright.sh] no /dev/tcp, lsof empty: allowed"; else echo "FAIL  [guard-mcp-playwright.sh] no /dev/tcp, lsof present: want=0 got=$got stderr=$err"; fail=1; fi
rm -f "$NOLSOF/jq" "$NOLSOF/cat" "$NOLSOF/tr"; rmdir "$NOLSOF"
rm -f "$PWP/port" "$PWP/listen.sh" "$PWP/nodevtcp.sh"; rmdir "$PWP"
rm -f "$PWSTUB/lsof"; rmdir "$PWSTUB"

# ---- guard-mcp-context7.sh (allowlist of 2 Context7 tools; strict arg shapes; query content filter; fail closed) ----
C7HOOK="$HOOKS/guard-mcp-context7.sh"
c7_report() { # c7_report <want> <got> <stderr> <label> <query text or empty>
  local want=$1 got=$2 err=$3 label=$4 q=$5
  if [ "$got" = "$want" ] && { [ "$want" = 0 ] && [ -z "$err" ] || { [ "$want" != 0 ] && grep -q '^BLOCKED by guard-mcp-context7' <<<"$err" && { [ -z "$q" ] || ! grep -qF -- "$q" <<<"$err"; }; }; }; then
    echo "ok    [guard-mcp-context7.sh] $label"
  else
    echo "FAIL  [guard-mcp-context7.sh] want=$want got=$got: $label stderr=$err"; fail=1
  fi
}
c7() { # c7 <want exit> <tool name> <tool_input JSON>; a deny must print BLOCKED on stderr; an allow must print nothing
  local want=$1 tool=$2 ti=$3 got err in
  in=$(jq -n --arg t "$tool" --argjson i "$ti" '{tool_name:$t,tool_input:$i}') || { echo "FAIL  bad test JSON: $tool $ti"; fail=1; return; }
  err=$(printf '%s' "$in" | "$C7HOOK" 2>&1 >/dev/null); got=$?
  c7_report "$want" "$got" "$err" "$tool $ti" ""
}
c7q() { # c7q <want exit> <short tool> <query>: valid other args; a deny must not echo the query
  local want=$1 short=$2 q=$3 in got err
  if [ "$short" = resolve-library-id ]; then
    in=$(jq -n --arg q "$q" '{tool_name:"mcp__context7__resolve-library-id",tool_input:{query:$q,libraryName:"react"}}')
  else
    in=$(jq -n --arg q "$q" '{tool_name:"mcp__context7__query-docs",tool_input:{libraryId:"/facebook/react",query:$q}}')
  fi
  err=$(printf '%s' "$in" | "$C7HOOK" 2>&1 >/dev/null); got=$?
  c7_report "$want" "$got" "$err" "$short query=${q:0:60}" "$q"
}
c7_raw() { # c7_raw <want exit> <raw stdin>
  local want=$1 input=$2 got err
  err=$(printf '%s' "$input" | "$C7HOOK" 2>&1 >/dev/null); got=$?
  c7_report "$want" "$got" "$err" "raw input: $input" ""
}
CR=mcp__context7__resolve-library-id
CQ=mcp__context7__query-docs
# allowed
c7 0 $CR '{"query":"how to use hooks","libraryName":"react"}'
c7 0 $CR '{"query":"routing","libraryName":"@scope/pkg-name.js c++"}'
c7 0 $CQ '{"libraryId":"/facebook/react","query":"useEffect cleanup"}'
c7 0 $CQ '{"libraryId":"/vercel/next.js/v14.3.0","query":"app router"}'
c7 0 $CQ '{"libraryId":"/facebook/react","query":"hooks","language":"TypeScript"}'
c7 0 $CQ '{"libraryId":"/facebook/react","query":"hooks","language":"C++ C# f#"}'
c7 0 $CQ '{"libraryId":"/facebook/react","query":"hooks","language":""}'
c7q 0 query-docs 'how does the task-runner handle multi-step, well-known retries?'
c7q 0 query-docs 'what does the arrow => mean in a type annotation'
c7q 0 query-docs 'use a { placeholder } in the template'
c7q 0 query-docs 'a;b;c separators in a list'
c7q 0 resolve-library-id 'x'
c7q 0 query-docs "$(printf 'how to word %.0s' $(seq 1 30) | cut -c1-300)"
c7q 0 resolve-library-id "$(printf 'ab %.0s' $(seq 1 100) | cut -c1-300)"
# query length and shape boundaries
c7q 2 query-docs ''
c7q 2 resolve-library-id ''
c7q 2 query-docs "$(printf 'ab %.0s' $(seq 1 101) | cut -c1-301)"
c7q 2 query-docs $'first line\nsecond line'
c7q 2 query-docs $'first line\rsecond line'
c7 2 $CQ '{"libraryId":"/facebook/react","query":42}'
c7 2 $CQ '{"libraryId":"/facebook/react","query":["a"]}'
c7 2 $CQ '{"libraryId":"/facebook/react","query":null}'
# query: absolute paths
c7q 2 query-docs 'read /Users/someone/project/file'
c7q 2 query-docs 'look at /home/someone/x'
c7q 2 query-docs 'dump /root/x'
c7q 2 query-docs 'see /private/var/x'
c7q 2 query-docs 'open /etc/hosts please'
c7q 2 query-docs 'open ~/projects/x'
c7q 2 query-docs 'open C:\Users\x'
# query: secret-like content, built from parts so the repo secret scanner does not flag test data
S1='sk-'; S2='ghp_'; S3='gho_'; S4='github_pat_'; S5='AKIA'; S6='xoxb-'; S7='xoxa-'; S8='xoxp-'; S9='-----BEG'; S10='ctx7'; S11='pass'
c7q 2 query-docs "key ${S1}FAKEFAKEFAKE"
S12='sk_'
c7q 2 query-docs "key ${S12}live_FAKEFAKE"
c7q 2 query-docs "key ${S12}test_FAKEFAKE"
c7q 0 query-docs "how does task_live_view update"
c7q 2 query-docs "key ${S2}FAKEFAKEFAKE"
c7q 2 query-docs "key ${S3}FAKEFAKEFAKE"
c7q 2 query-docs "key ${S4}FAKEFAKEFAKE"
c7q 2 query-docs "id ${S5}FAKEFAKEFAKEFAKE"
c7q 2 query-docs "tok ${S6}FAKEFAKE"
c7q 2 query-docs "tok ${S7}FAKEFAKE"
c7q 2 query-docs "tok ${S8}FAKEFAKE"
c7q 2 query-docs "${S9}IN FAKE BLOCK"
c7q 2 query-docs "${S10}sk-FAKEFAKE"
c7q 2 query-docs "${S10}SK-FAKEFAKE"
c7q 2 query-docs "${S11}word=FAKE"
c7q 2 query-docs "PASSWORD = FAKE"
c7q 2 query-docs "my secret=FAKE"
c7q 2 query-docs "the Token=FAKE"
c7q 2 query-docs "set Api_Key=FAKE"
c7q 0 query-docs "blob $(printf 'a%.0s' $(seq 1 32))"
c7q 0 query-docs "blob $(printf '0123456789abcdef%.0s' 1 2)"
c7q 0 query-docs "blob $(printf 'a%.0s' $(seq 1 31))"
c7q 0 query-docs "hex $(printf 'abcdef012345%.0s' 1 2 3)"
c7q 0 query-docs 'AnnotationConfigApplicationContext and UICollectionViewDelegateFlowLayout'
c7q 0 query-docs 'see /facebook/react/blob/main/packages/react'
c7q 0 query-docs 'react/hooks and next.js/app router'
c7q 2 query-docs "run $(printf 'z9%.0s' $(seq 1 16))"
c7q 2 query-docs "run $(printf 'z9%.0s' $(seq 1 16))/path"
c7q 2 query-docs "hex $(printf 'abcdef0123%.0s' 1 2 3 4)"
# query: single-line control characters and Unicode line separators
c7q 2 query-docs $'tab\tseparated'
c7 2 $CQ '{"libraryId":"/facebook/react","query":"nul\u0000byte"}'
c7 2 $CQ '{"libraryId":"/facebook/react","query":"ls sep"}'
c7 2 $CQ '{"libraryId":"/facebook/react","query":"ps sep"}'
c7 2 $CQ '{"libraryId":"/facebook/react","query":"nel\u0085sep"}'
# query: case-insensitive and substring path words
c7q 2 query-docs 'open /TMP/a'
c7q 2 query-docs 'open /Volumes/a'
c7q 2 query-docs 'open x/Users/a'
c7q 2 query-docs 'open /var/log/x'
c7q 2 query-docs 'open /opt/x'
c7q 2 query-docs 'open /mnt/x'
# libraryName path and secret (built from parts)
c7 2 $CR '{"query":"q1","libraryName":"/etc/passwd"}'
c7 2 $CR '{"query":"q1","libraryName":"x/Users/a"}'
c7 2 $CR "{\"query\":\"q1\",\"libraryName\":\"${S5}FAKEFAKEFAKEFAKE\"}"
c7 2 $CR "{\"query\":\"q1\",\"libraryName\":\"${S1}FAKEFAKEFAKE\"}"
c7 0 $CR '{"query":"q1","libraryName":"AnnotationConfigApplicationContext"}'
# libraryId path and secret
c7 2 $CQ '{"libraryId":"/Users/x/y","query":"q1"}'
c7 2 $CQ '{"libraryId":"/HOME/a/b","query":"q1"}'
c7 2 $CQ '{"libraryId":"/tmp/a/b","query":"q1"}'
c7 2 $CQ '{"libraryId":"/Volumes/a","query":"q1"}'
c7 2 $CQ "{\"libraryId\":\"/org/${S1}FAKEFAKEFAKE\",\"query\":\"q1\"}"
c7 2 $CQ "{\"libraryId\":\"/org/$(printf 'z9%.0s' $(seq 1 16))\",\"query\":\"q1\"}"
c7 0 $CQ '{"libraryId":"/facebook/react/v18.2.0","query":"q1"}'
c7 0 $CQ '{"libraryId":"/org/users","query":"q1"}'
# plugin-style server naming is not the exact server name
c7 2 mcp__plugin_context7_context7__query-docs '{"libraryId":"/facebook/react","query":"q1"}'
# query: code-like content
c7q 2 query-docs 'if (a) { b; c; }'
c7q 2 query-docs 'a; b; c;'
c7q 2 query-docs 'const f = (x) => { return x }'
c7q 2 query-docs 'f => }'
# libraryName
c7 2 $CR '{"query":"q1","libraryName":""}'
c7 2 $CR "{\"query\":\"q1\",\"libraryName\":\"$(printf 'a%.0s' $(seq 1 101))\"}"
c7 0 $CR "{\"query\":\"q1\",\"libraryName\":\"$(printf 'a%.0s' $(seq 1 100))\"}"
c7 2 $CR '{"query":"q1","libraryName":"react; rm"}'
c7 2 $CR '{"query":"q1","libraryName":"react\nvue"}'
c7 2 $CR '{"query":"q1","libraryName":"re$act"}'
c7 2 $CR '{"query":"q1","libraryName":5}'
c7 2 $CR '{"query":"q1","libraryName":["react"]}'
# libraryId
c7 2 $CQ '{"libraryId":"facebook/react","query":"q1"}'
c7 2 $CQ '{"libraryId":"/facebook","query":"q1"}'
c7 2 $CQ '{"libraryId":"/a/b/c/d","query":"q1"}'
c7 2 $CQ '{"libraryId":"/facebook/react/","query":"q1"}'
c7 2 $CQ '{"libraryId":"/../react","query":"q1"}'
c7 2 $CQ '{"libraryId":"/facebook/..","query":"q1"}'
c7 2 $CQ '{"libraryId":"/facebook/react/..","query":"q1"}'
c7 2 $CQ '{"libraryId":"/face book/react","query":"q1"}'
c7 2 $CQ '{"libraryId":"/facebook/react\n","query":"q1"}'
c7 2 $CQ '{"libraryId":"","query":"q1"}'
c7 2 $CQ '{"libraryId":7,"query":"q1"}'
c7 2 $CQ '{"libraryId":["/facebook/react"],"query":"q1"}'
# language
c7 2 $CQ "{\"libraryId\":\"/facebook/react\",\"query\":\"q1\",\"language\":\"$(printf 'a%.0s' $(seq 1 41))\"}"
c7 0 $CQ "{\"libraryId\":\"/facebook/react\",\"query\":\"q1\",\"language\":\"$(printf 'a%.0s' $(seq 1 40))\"}"
c7 2 $CQ '{"libraryId":"/facebook/react","query":"q1","language":"js; rm"}'
c7 2 $CQ '{"libraryId":"/facebook/react","query":"q1","language":"js\nts"}'
c7 2 $CQ '{"libraryId":"/facebook/react","query":"q1","language":3}'
c7 2 $CQ '{"libraryId":"/facebook/react","query":"q1","language":["js"]}'
# missing required, extra and unknown keys
c7 2 $CR '{"query":"q1"}'
c7 2 $CR '{"libraryName":"react"}'
c7 2 $CR '{}'
c7 2 $CQ '{"libraryId":"/facebook/react"}'
c7 2 $CQ '{"query":"q1"}'
c7 2 $CR '{"query":"q1","libraryName":"react","extra":1}'
c7 2 $CR '{"query":"q1","libraryName":"react","language":"js"}'
c7 2 $CQ '{"libraryId":"/facebook/react","query":"q1","tokens":5000}'
c7 2 $CQ '{"libraryId":"/facebook/react","query":"q1","Language":"js"}'
c7 2 $CQ '{"libraryId":"/facebook/react","query":"q1","libraryName":"react"}'
c7_raw 2 '{"tool_name":"mcp__context7__query-docs"}'
c7_raw 2 '{"tool_name":"mcp__context7__query-docs","tool_input":"str"}'
c7_raw 2 '{"tool_name":"mcp__context7__query-docs","tool_input":[]}'
c7_raw 2 '{"tool_name":"mcp__context7__query-docs","tool_input":null}'
# server name and tool allowlist
c7 2 mcp__Context7__query-docs '{"libraryId":"/facebook/react","query":"q1"}'
c7 2 mcp__CONTEXT7__query-docs '{"libraryId":"/facebook/react","query":"q1"}'
c7 2 mcp__my_context7__query-docs '{"libraryId":"/facebook/react","query":"q1"}'
c7 2 mcp__context7_x__query-docs '{"libraryId":"/facebook/react","query":"q1"}'
c7 2 mcp__context7__resolve-library-id-x '{"query":"q1","libraryName":"react"}'
c7 2 mcp__context7__Query-Docs '{"libraryId":"/facebook/react","query":"q1"}'
c7 2 mcp__context7__get-library-docs '{}'
c7 2 mcp__context7__future-tool '{}'
c7 2 mcp__context7__ '{}'
c7 2 mcp__other__query-docs '{"libraryId":"/facebook/react","query":"q1"}'
c7 2 Bash '{"command":"ls"}'
# fail closed on bad input and missing jq
c7_raw 2 ''
c7_raw 2 '{bad json'
c7_raw 2 '{"tool_name":'
c7_raw 2 '{}'
c7_raw 2 '{"tool_input":{}}'
c7_raw 2 '{"tool_name":123}'
c7_raw 2 '{"tool_name":null,"tool_input":{}}'
c7_raw 0 '{"tool_name":"mcp__context7__query-docs","tool_input":{"libraryId":"/a/b","query":"q1"}}'
NOJQ5=$(mktemp -d)
printf '%s' '{"tool_name":"mcp__context7__query-docs","tool_input":{"libraryId":"/a/b","query":"q1"}}' | PATH="$NOJQ5" "$BASH_BIN" "$C7HOOK" >/dev/null 2>&1; got=$?
if [ "$got" = 2 ]; then echo "ok    [guard-mcp-context7.sh] jq missing"; else echo "FAIL  [guard-mcp-context7.sh] jq missing: want=2 got=$got"; fail=1; fi
rmdir "$NOJQ5"

# ---- guard-bash.sh: claude mcp config mutation and MCP config file writes ----
check guard-bash.sh 2 'claude mcp add foo -- npx foo'
check guard-bash.sh 2 "claude mcp add-json foo '{}'"
check guard-bash.sh 2 'claude mcp add-from-claude-desktop'
check guard-bash.sh 2 'claude mcp remove foo'
check guard-bash.sh 2 'claude mcp reset-project-choices'
check guard-bash.sh 2 'cd x && claude mcp add foo'
check guard-bash.sh 2 'ls; claude mcp remove foo'
check guard-bash.sh 2 'FOO=1 claude mcp add foo'
check guard-bash.sh 2 'command claude mcp add foo'
check guard-bash.sh 2 'exec claude mcp add foo'
check guard-bash.sh 2 '/usr/local/bin/claude mcp add foo'
check guard-bash.sh 2 'claude --debug mcp add foo'
check guard-bash.sh 2 'echo hi | claude mcp remove foo'
check guard-bash.sh 2 '"claude" mcp add foo'
check guard-bash.sh 2 'echo {} > ~/.claude.json'
check guard-bash.sh 2 'echo {} >> $HOME/.claude.json'
check guard-bash.sh 2 'echo {} > /Users/neco/.claude.json'
check guard-bash.sh 2 'echo {} > .mcp.json'
check guard-bash.sh 2 'echo {} > ./sub/.mcp.json'
check guard-bash.sh 2 'echo {} | tee .mcp.json'
check guard-bash.sh 2 'sed -i s/a/b/ ~/.claude.json'
check guard-bash.sh 2 'mv x .mcp.json'
check guard-bash.sh 2 'cp evil.json .mcp.json'
check guard-bash.sh 2 'cp evil.json ~/.claude.json'
check guard-bash.sh 2 'cp evil ${HOME}/.claude.json'
check guard-bash.sh 2 'cd ~ && echo {} > .claude.json'
check guard-bash.sh 0 'claude --version'
check guard-bash.sh 0 'claude mcp list'
check guard-bash.sh 0 'claude mcp get foo'
check guard-bash.sh 0 'cat README.md'
check guard-bash.sh 0 'cat ~/.claude.json'
check guard-bash.sh 0 'cat .mcp.json'
check guard-bash.sh 0 'cp ~/.claude.json /tmp/backup.json'
check guard-bash.sh 0 'echo hi > src/app.json'
check guard-bash.sh 0 'sed -i s/a/b/ src/app.json'
# claude through npx-style launchers, variables, substitutions, xargs; >| redirects; other write forms
check guard-bash.sh 2 'npx @anthropic-ai/claude-code mcp add foo'
check guard-bash.sh 2 'npx -y @anthropic-ai/claude-code@latest mcp remove foo'
check guard-bash.sh 2 'bunx @anthropic-ai/claude-code mcp add foo'
check guard-bash.sh 2 'pnpm dlx @anthropic-ai/claude-code mcp add foo'
check guard-bash.sh 2 'c=claude; $c mcp add foo'
check guard-bash.sh 2 '$(echo claude) mcp add foo'
check guard-bash.sh 2 'echo mcp add x y | xargs claude'
check guard-bash.sh 2 'CLAUDE MCP ADD foo'
check guard-bash.sh 2 'claude  mcp   add foo'
check guard-bash.sh 2 'echo {} >| ~/.claude.json'
check guard-bash.sh 2 'echo {} >| .mcp.json'
check guard-bash.sh 2 'echo x >| .serena/project.yml'
check guard-bash.sh 2 'ln -s x ~/.claude.json'
check guard-bash.sh 2 'perl -i -pe s/a/b/ ~/.claude.json'
check guard-bash.sh 2 'cd ~; cp x .claude.json'
check guard-bash.sh 0 'npm view @anthropic-ai/claude-code version'
check guard-bash.sh 0 'npx @anthropic-ai/claude-code --version'
check guard-bash.sh 0 'echo {} >| out.json'

# ---- guard-write.sh: MCP config files ----
checkw 2 "$HOME/.claude.json"
checkw 2 '/Users/neco/Developer/proj/.mcp.json'
checkw 2 '.mcp.json'
checkw 2 '/Users/neco/Developer/proj/sub/../.MCP.json'
checkw 0 'src/app.json'
checkw 0 '/Users/neco/Developer/proj/mcp.json'
checkw 0 'README.md'
for p in "$HOME/.claude.json" '/Users/neco/Developer/proj/.mcp.json' '.mcp.json'; do
  jq -n --arg p "$p" '{tool_input:{notebook_path:$p}}' | "$HOOKS/guard-write.sh" >/dev/null 2>&1; got=$?
  if [ "$got" = 2 ]; then echo "ok    [guard-write.sh] notebook_path $p"; else echo "FAIL  [guard-write.sh] notebook_path want=2 got=$got: $p"; fail=1; fi
done
for p in 'src/app.json' 'README.md'; do
  jq -n --arg p "$p" '{tool_input:{notebook_path:$p}}' | "$HOOKS/guard-write.sh" >/dev/null 2>&1; got=$?
  if [ "$got" = 0 ]; then echo "ok    [guard-write.sh] notebook_path $p"; else echo "FAIL  [guard-write.sh] notebook_path want=0 got=$got: $p"; fail=1; fi
done

[ "$fail" = 0 ] && echo "All hook checks passed." || { echo "Some hook checks failed."; exit 1; }
