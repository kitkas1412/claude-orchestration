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
checkw 0 '/x/.claude/agents/a.md'
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
