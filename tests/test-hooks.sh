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

[ "$fail" = 0 ] && echo "All hook checks passed." || { echo "Some hook checks failed."; exit 1; }
