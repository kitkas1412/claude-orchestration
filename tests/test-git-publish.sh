#!/usr/bin/env bash
# Tests for hooks/git-publish.sh. Run this yourself.
# Usage: bash tests/test-git-publish.sh
#
# Safety model:
#  - Everything lives in one mktemp -d directory; only that directory is removed on exit.
#  - The script under test is copied into it and patched with sed (REGISTRY, require_tty, and PATH for
#    the stub-git copy). The production script is never edited and has no test backdoor.
#  - The real ~/.claude/git-publish.registry is never read or written: the patched copy points at a temp
#    registry, and the unpatched script is only run outside any repository with no arguments, where it
#    refuses before it can reach a registry.
#  - Remotes are local bare repositories. GitHub paths use stub git/gh executables. No network.
SRC="$(cd "$(dirname "$0")/../hooks" && pwd)/git-publish.sh"
[ -f "$SRC" ] || { echo "FATAL: $SRC not found"; exit 1; }

REAL_GIT=$(command -v git) || { echo "FATAL: git not found"; exit 1; }
BASE_TMP=$(cd "${TMPDIR:-/tmp}" && pwd -P) || exit 1
T=$(mktemp -d "$BASE_TMP/git-publish-test.XXXXXX") || { echo "FATAL: mktemp failed"; exit 1; }
case "$T" in "$BASE_TMP"/git-publish-test.*) ;; *) echo "FATAL: unexpected temp dir $T"; exit 1 ;; esac
cleanup() { cd / && rm -rf -- "$T"; }
trap cleanup EXIT

REG="$T/reg"
mkdir -p "$T/c1" "$T/c2" "$T/c3" "$T/stub" "$T/stubfail" "$T/stubgrep" "$T/c4" "$T/norepo" "$T/tmp"
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); echo "FAIL: $*"; }

# Keep the test's own git calls independent of the user's global config.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
# The script's private input copies go to $TMPDIR, so keep them inside the test directory.
export TMPDIR="$T/tmp"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE

# --- patching: fail loudly if the script no longer has the lines we patch ---
patch_fatal() { echo "FATAL: sed patch of git-publish.sh did not apply: $*"; echo "RESULT pass=$PASS fail=$((FAIL + 1))"; exit 1; }

count_lines() { grep -c -- "$1" "$SRC"; }
[ "$(count_lines '^REGISTRY=')" = 1 ] || patch_fatal "expected exactly one line starting with REGISTRY="
[ "$(count_lines '^require_tty() {$')" = 1 ] || patch_fatal "expected exactly one line 'require_tty() {'"
[ "$(count_lines '^PATH=')" = 1 ] || patch_fatal "expected exactly one line starting with PATH="
# The script unsets these so a user's global git config cannot change what it does. The patched copy
# keeps them (set to /dev/null above) so the tests never read the real ~/.gitconfig.
[ "$(count_lines ' GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM ')" = 1 ] || patch_fatal "expected the GIT_CONFIG_GLOBAL unset list entry once"

mk_copy() { # $1 dest, $2 PATH prefix (may be empty)
  local dest=$1 pre=$2
  sed -e 's/^require_tty() {$/require_tty() { return 0; }; require_tty_original_unused() {/' \
    -e 's/ GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM / /' \
    -e "s|^REGISTRY=.*|REGISTRY=\"$REG\"|" \
    -e "s|^PATH=.*|PATH=${pre}/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin|" \
    "$SRC" >"$dest" || patch_fatal "sed failed"
  chmod +x "$dest"
  grep -qxF "REGISTRY=\"$REG\"" "$dest" || patch_fatal "REGISTRY line was not rewritten"
  [ "$(grep -c '^REGISTRY=' "$dest")" = 1 ] || patch_fatal "REGISTRY assignments changed count"
  grep -q '^require_tty() { return 0; }; require_tty_original_unused() {$' "$dest" || patch_fatal "require_tty was not stubbed"
  grep -qxF "PATH=${pre}/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin" "$dest" || patch_fatal "PATH line was not rewritten"
  ! grep -q 'GIT_CONFIG_GLOBAL' "$dest" || patch_fatal "GIT_CONFIG_GLOBAL is still unset by the patched copy"
  bash -n "$dest" || patch_fatal "patched copy has a syntax error"
}
C="$T/c1/git-publish.sh"; mk_copy "$C" ""
G="$T/c2/git-publish.sh"; mk_copy "$G" "$T/stub:"
F="$T/c3/git-publish.sh"; mk_copy "$F" "$T/stubfail:"
H="$T/c4/git-publish.sh"; mk_copy "$H" "$T/stubgrep:"

# --- stubs (no network) ---
cat >"$T/stub/gh" <<E
#!/bin/bash
for a in "\$@"; do printf '[%s] ' "\$a"; done >>"$T/gh.log"; echo >>"$T/gh.log"
prev=""; for a in "\$@"; do [ "\$prev" = --body-file ] && cat "\$a" >"$T/gh.body"; prev=\$a; done
exit 0
E
cat >"$T/stub/git" <<E
#!/bin/bash
case "\$1" in
  push) echo "PUSH \$*" >>"$T/push.log"; printf '%s|%s\n' "\${GIT_SSH_COMMAND:-}" "\${GIT_NO_LAZY_FETCH:-}" >"$T/push.env"; touch "$T/pushed"; exit 0 ;;
  ls-remote)
    if [ "\$2" = --symref ]; then printf 'ref: refs/heads/main\tHEAD\n'; exit 0; fi
    case "\$4" in
      refs/heads/main)
        # With $T/ahead.remote present, the default branch is read from that real bare repository.
        if [ -e "$T/ahead.remote" ]; then exec "$REAL_GIT" ls-remote -- "\$(cat "$T/ahead.remote")" "\$4"; fi
        printf '%s\t%s\n' "\$("$REAL_GIT" rev-parse refs/heads/main)" "\$4" ;;
      *) [ -e "$T/pushed" ] && printf '%s\t%s\n' "\$("$REAL_GIT" rev-parse HEAD)" "\$4" ;;
    esac
    exit 0 ;;
esac
exec "$REAL_GIT" "\$@"
E
chmod +x "$T/stub/gh" "$T/stub/git"
# Fails any git call whose argument text contains $GP_FAIL; everything else goes to the real git.
cat >"$T/stubfail/git" <<E
#!/bin/bash
[ -n "\${GP_FAIL:-}" ] && case "\$*" in *"\$GP_FAIL"*) echo "stub git: forced failure" >&2; exit 1 ;; esac
exec "$REAL_GIT" "\$@"
E
chmod +x "$T/stubfail/git"
# Exits 2 (a grep error, not "no match") when its first argument equals $GP_GREP_FAIL; otherwise real grep.
REAL_GREP=$(command -v grep)
cat >"$T/stubgrep/grep" <<E
#!/bin/bash
if [ -n "\${GP_GREP_FAIL:-}" ] && [ "\$1" = "\$GP_GREP_FAIL" ]; then echo "stub grep: forced failure" >&2; exit 2; fi
exec "$REAL_GREP" "\$@"
E
chmod +x "$T/stubgrep/grep"

# --- helpers ---
refused() { # name, stderr substring, cmd...
  local n=$1 want=$2 err rc
  shift 2
  err=$("$@" 2>&1 >/dev/null </dev/null); rc=$?
  if [ "$rc" = 2 ] && printf '%s' "$err" | grep -qF -- "$want"; then ok; else bad "$n: rc=$rc err=$err"; fi
}
refused_noleak() { # name, stderr substring, secret that must not appear anywhere in the output, cmd...
  local n=$1 want=$2 secret=$3 out rc
  shift 3
  out=$("$@" 2>&1 </dev/null); rc=$?
  if [ "$rc" = 2 ] && printf '%s' "$out" | grep -qF -- "$want"; then ok; else bad "$n: rc=$rc out=$out"; fi
  if printf '%s' "$out" | grep -qF -- "$secret"; then bad "$n: secret value was printed: $out"; else ok; fi
}
passes() { # name, cmd...
  local n=$1 out rc
  shift
  out=$("$@" 2>&1 </dev/null); rc=$?
  if [ "$rc" = 0 ]; then ok; else bad "$n: rc=$rc out=$out"; fi
}
commit() { # file content subject
  mkdir -p "$(dirname "$1")"
  printf '%s\n' "$2" >>"$1"
  git add -f -- "$1"
  git commit -q -m "$3"
}
branch() { git checkout -q -B "$1" main; }
sha() { git rev-parse HEAD; }
file_mode() { stat -f %Lp "$1" 2>/dev/null || stat -c %a "$1"; }

# Fake secrets, built by concatenation so this file does not match the script's own secret patterns.
FAKE_AWS="AKI""AABCDEFGHIJKLMNOP"
AT="@"
FAKE_PW="FAKE""VALUE123"

# --- unpatched script: the TTY lock must refuse enable and disable without a terminal ---
# push, pr and merge are agent-run and bounded by the registered level instead of a terminal, so they must
# not hit the TTY lock. Run outside any repository with no arguments, so nothing can reach a registry.
for sub in enable disable; do
  err=$(cd "$T/norepo" && GIT_CEILING_DIRECTORIES="$T" "$SRC" "$sub" 2>&1 >/dev/null </dev/null); rc=$?
  if [ "$rc" = 2 ] && printf '%s' "$err" | grep -qF "own terminal"; then ok; else bad "unpatched $sub without TTY: rc=$rc err=$err"; fi
done
for sub in push pr merge; do
  err=$(cd "$T/norepo" && GIT_CEILING_DIRECTORIES="$T" "$SRC" "$sub" 2>&1 >/dev/null </dev/null); rc=$?
  if [ "$rc" = 2 ] && ! printf '%s' "$err" | grep -qF "own terminal"; then ok; else bad "unpatched $sub must not need a terminal: rc=$rc err=$err"; fi
done
err=$(cd "$T/norepo" && GIT_CEILING_DIRECTORIES="$T" "$SRC" 2>&1 >/dev/null </dev/null); [ $? = 2 ] && ok || bad "no subcommand: $err"
err=$(cd "$T/norepo" && GIT_CEILING_DIRECTORIES="$T" "$SRC" bogus 2>&1 >/dev/null </dev/null); [ $? = 2 ] && ok || bad "unknown subcommand: $err"
# The patched copy must really differ: it gets past the TTY lock and fails on arguments instead.
err=$(cd "$T/norepo" && GIT_CEILING_DIRECTORIES="$T" "$C" push 2>&1 >/dev/null </dev/null); rc=$?
if [ "$rc" = 2 ] && ! printf '%s' "$err" | grep -qF "own terminal"; then ok; else bad "patched copy still hits require_tty: rc=$rc err=$err"; fi

# --- setup: local bare remote ---
git init -q -b main "$T/work"
cd "$T/work" || exit 1
git config user.email t@example.invalid
git config user.name t
git config commit.gpgsign false
commit README.md hello "chore: init"
git clone -q --bare "$T/work" "$T/remote.git"
git remote add origin "$T/remote.git"
git fetch -q origin

# --- enable ---
refused "not registered plan" "not registered" "$C" plan
out=$(printf 'wrong\n' | "$C" enable push 2>&1); [ $? = 2 ] && ok || bad "enable wrong name: $out"
[ ! -e "$REG" ] && ok || bad "registry written despite wrong confirmation"
refused "enable bad level" "enable level" "$C" enable admin
refused "enable bad style" "--style" "$C" enable push --style loose
out=$(printf 'remote\n' | "$C" enable push 2>&1); [ $? = 0 ] && ok || bad "enable: $out"
[ "$(file_mode "$REG")" = 600 ] && ok || bad "registry mode"
[ "$(awk -F'\t' '{print NF}' "$REG")" = 6 ] && ok || bad "registry columns"
[ "$(awk -F'\t' '{print $6}' "$REG")" = - ] && ok || bad "registry ci column without the flag: $(cat "$REG")"
"$C" status | grep -qx 'ci changes: refused' && ok || bad "status ci changes default"
"$C" status | grep -q '^level: push$' && ok || bad "status level"
"$C" status | grep -q '^default branch: main$' && ok || bad "status default"
"$C" status | grep -q '^style: conventional$' && ok || bad "status style"
git worktree add -q -b wt/one "$T/wt" main
(cd "$T/wt" && "$C" status | grep -q '^level: push$') && ok || bad "worktree status"
refused "status takes no args" "no arguments" "$C" status x
# enable always writes six columns; --allow-ci-changes sets the last one to ci, and re-enabling resets it.
out=$(printf 'remote\n' | "$C" enable push --allow-ci-changes 2>&1); rc=$?
[ "$rc" = 0 ] && printf '%s' "$out" | grep -qF 'CI changes : allowed' && ok || bad "enable with --allow-ci-changes: rc=$rc out=$out"
[ "$(awk -F'\t' '{print NF " " $6}' "$REG")" = "6 ci" ] && ok || bad "registry row with the flag: $(cat "$REG")"
"$C" status | grep -qx 'ci changes: allowed' && ok || bad "status after enable --allow-ci-changes"
out=$(printf 'remote\n' | "$C" enable push --style project 2>&1); rc=$?
[ "$rc" = 0 ] && printf '%s' "$out" | grep -qF 'CI changes : refused' && ok || bad "enable without the flag: rc=$rc out=$out"
[ "$(awk -F'\t' '{print NF " " $5 " " $6}' "$REG")" = "6 project -" ] && ok || bad "re-enable did not reset the ci column: $(cat "$REG")"
"$C" status | grep -qx 'ci changes: refused' && ok || bad "status after re-enable without the flag"
out=$(printf 'remote\n' | "$C" enable push --allow-ci-changes --allow-ci-changes 2>&1); rc=$?
[ "$rc" = 2 ] && printf '%s' "$out" | grep -qF 'duplicate' && ok || bad "duplicate --allow-ci-changes: rc=$rc out=$out"
# A sixth column other than ci or - makes the row unregistered.
awk -F'\t' -v OFS='\t' '{$6 = "yes"; print}' "$REG" >"$REG.new" && mv "$REG.new" "$REG"
refused "unknown sixth column means unregistered" "not registered" "$C" plan
"$C" status | grep -qx 'level: off' && ok || bad "status with an unknown sixth column"
printf 'remote\n' | "$C" enable push >/dev/null 2>&1
"$C" status | grep -qx 'level: push' && ok || bad "re-enable after the unknown sixth column"

# --- happy path: only the current branch reaches the remote, no tags, no repo hooks ---
branch feat/ok; commit a.txt one "feat(core): add a"
SHA_OK=$(sha)
out=$("$C" plan 2>&1); rc=$?
[ "$rc" = 0 ] && ok || bad "plan: $out"
for w in "branch: feat/ok" "head: $SHA_OK" "feat(core): add a" "1 file changed" "push --expect-sha $SHA_OK"; do
  printf '%s' "$out" | grep -qF -- "$w" && ok || bad "plan output missing: $w"
done
printf '#!/bin/sh\ntouch %s/hook-ran\n' "$T" >.git/hooks/pre-push; chmod +x .git/hooks/pre-push
git tag -a -m v v-should-stay-local
git tag light-should-stay-local
git config push.followTags true
git branch feat/other-local "$SHA_OK"
refused "wrong sha" "does not match" "$C" push --expect-sha 1111111111111111111111111111111111111111
refused "short sha" "40-hex" "$C" push --expect-sha abc123
[ -z "$(git -C "$T/remote.git" for-each-ref refs/heads/feat)" ] && ok || bad "remote had feat refs before push"
passes "push" "$C" push --expect-sha "$SHA_OK"
[ "$(git -C "$T/remote.git" rev-parse refs/heads/feat/ok)" = "$SHA_OK" ] && ok || bad "remote ref"
[ ! -e "$T/hook-ran" ] && ok || bad "pre-push hook ran"
[ "$(git -C "$T/remote.git" for-each-ref --format='%(refname)' | sort | tr '\n' ' ')" = "refs/heads/feat/ok refs/heads/main " ] && ok || bad "remote refs after push: $(git -C "$T/remote.git" for-each-ref --format='%(refname)' | tr '\n' ' ')"
[ -z "$(git -C "$T/remote.git" tag -l)" ] && ok || bad "tags reached the remote: $(git -C "$T/remote.git" tag -l)"
git config --unset push.followTags; git tag -d v-should-stay-local light-should-stay-local >/dev/null; git branch -q -D feat/other-local; rm -f .git/hooks/pre-push

# --- refused arguments ---
S=$(sha)
for a in HEAD:main --force -f --mirror --all --delete --tags --force-with-lease; do
  refused "push arg $a" "allowed here" "$C" push --expect-sha "$S" "$a"
  refused "push arg first $a" "allowed here" "$C" push "$a" --expect-sha "$S"
done
refused "dup flag" "duplicate" "$C" push --expect-sha "$S" --expect-sha "$S"
refused "missing value" "needs a value" "$C" push --expect-sha
refused "equals form" "allowed here" "$C" push "--expect-sha=$S"
refused "one of title/body" "together" "$C" plan --title-file x

# --- level ---
printf 'remote\n' | "$C" enable commit >/dev/null 2>&1
refused "level commit plan" "too low" "$C" plan
refused "level commit push" "too low" "$C" push --expect-sha "$S"
printf 'remote\n' | "$C" enable push >/dev/null 2>&1

# --- branches ---
git checkout -q main; refused "on main" "protected" "$C" plan
for b in master develop trunk production release/1.0; do
  branch "$b"; commit b.txt x "feat: b"; refused "branch $b" "protected" "$C" plan
done
git checkout -q --detach main; refused "detached" "detached" "$C" plan
git checkout -q main; git checkout -q -b 'feat/a;b'; commit b.txt x "feat: b"; refused "charset" "safe character" "$C" plan
git checkout -q main; git symbolic-ref refs/heads/alias-main refs/heads/main; git symbolic-ref HEAD refs/heads/alias-main
refused "symref to main" "protected" "$C" plan
git checkout -q main; git symbolic-ref -d refs/heads/alias-main

# --- remote identity and config ---
branch feat/url; commit c.txt x "feat: c"; S=$(sha)
git remote set-url origin "$T/other.git"; refused "url differs" "differs" "$C" plan; git remote set-url origin "$T/remote.git"
git config url."$T/evil.git".pushInsteadOf "$T/remote.git"; refused "pushInsteadOf" "differs" "$C" push --expect-sha "$S"; git config --remove-section url."$T/evil.git"
git config --add remote.origin.pushurl "$T/remote.git"; git config --add remote.origin.pushurl "$T/evil.git"
refused "second pushurl" "differs" "$C" plan; git config --unset-all remote.origin.pushurl
for kv in core.sshCommand=/bin/false credential.helper=x http.proxy=http://127.0.0.1:1 remote.origin.vcs=x remote.origin.mirror=true; do
  git config "${kv%%=*}" "${kv#*=}"; refused "config ${kv%%=*}" "not allowed on this route" "$C" plan; git config --unset "${kv%%=*}"
done
printf '[core]\n\tsshCommand = /bin/false\n' >"$T/inc"; git config include.path "$T/inc"
refused "config via include" "section 'core' has a setting that is not allowed" "$C" plan
err=$("$C" plan 2>&1); printf '%s' "$err" | grep -qi "sshcommand" && bad "config refusal printed the key name: $err" || ok
git config --unset include.path
passes "clean after config" "$C" plan

# --- standards ---
branch feat/msg; commit d.txt x "add stuff"; refused "subject format" "Conventional" "$C" plan
branch feat/msg2; commit d.txt x "feat: d"; commit d.txt y "fixup! feat: d"; refused "fixup" "fixup" "$C" plan
branch feat/msg3; commit d.txt x "squash! feat: d"; refused "squash" "fixup" "$C" plan
branch feat/msg4; commit d.txt x "feat(a b): d"; refused "scope with space" "Conventional" "$C" plan
branch feat/msg5; commit d.txt x "feat!: breaking"; passes "bang" "$C" plan
branch feat/msg6; commit d.txt x "feat(api)!: breaking"; passes "scope bang" "$C" plan
branch feat/msg7; refused "no commits" "no commits" "$C" plan
printf 'remote\n' | "$C" enable push --style project >/dev/null 2>&1
branch feat/proj; commit d.txt x "add stuff freely"; passes "project style skips regex" "$C" plan
branch feat/proj2; commit d.txt x "fixup! still refused"; refused "project keeps fixup" "fixup" "$C" plan
printf 'remote\n' | "$C" enable push >/dev/null 2>&1

# --- secret scan ---
branch feat/leak; printf 'first\nkey=%s\n' "$FAKE_AWS" >leak.txt; git add leak.txt; git commit -q -m "feat: leak"
err=$("$C" plan 2>&1); rc=$?
[ "$rc" = 2 ] && printf '%s' "$err" | grep -qF "leak.txt:2" && ok || bad "secret location: $err"
printf '%s' "$err" | grep -qF "$FAKE_AWS" && bad "secret value printed" || ok
git update-ref refs/remotes/origin/main HEAD
refused "moved origin/main cannot hide leak online" "secret pattern" "$C" push --expect-sha "$(sha)"
git update-ref refs/remotes/origin/main main

branch feat/trick; printf 'a\n++ b/fake-name.txt\n%s\n' "$FAKE_AWS" >"real name.txt"; git add .; git commit -q -m "feat: trick"
err=$("$C" plan 2>&1); printf '%s' "$err" | grep -qF "real name.txt:3" && ok || bad "+++ trick: $err"
branch feat/msgleak; git commit -q --allow-empty -m "feat: x" -m "$FAKE_AWS"; commit z.txt x "feat: z"
err=$("$C" plan 2>&1); [ $? = 2 ] && ok || bad "message scan rc"; printf '%s' "$err" | grep -qF "$FAKE_AWS" && bad "message secret printed" || ok
branch feat/rename; printf '%s\n' "$FAKE_AWS" >"sec.txt"; git add .; git -c core.hooksPath=/dev/null commit -q -m "feat: s"
git update-ref refs/remotes/origin/main HEAD; git update-ref refs/heads/main HEAD
git mv sec.txt moved.txt; git commit -q -m "feat: rename"
err=$("$C" plan 2>&1); printf '%s' "$err" | grep -qF "moved.txt:1" && ok || bad "rename scan: $err"
git update-ref refs/heads/main "$(git rev-parse HEAD~2)"; git update-ref refs/remotes/origin/main refs/heads/main
for f in .envrc server.key sub/id_rsa cert.PEM store.p12; do
  branch feat/file; commit "$f" x "feat: file"; refused "forbidden $f" "forbidden file" "$C" plan
done
branch feat/del; commit gone.key x "feat: add"; git update-ref refs/heads/main HEAD; git update-ref refs/remotes/origin/main HEAD
git rm -q gone.key; git commit -q -m "fix: remove key"; passes "deleting forbidden name is fine" "$C" plan
git update-ref refs/heads/main "$(git rev-parse HEAD~2)"; git update-ref refs/remotes/origin/main refs/heads/main

# --- disable ---
passes "disable" "$C" disable
"$C" status | grep -q '^level: off$' && ok || bad "off after disable"
passes "disable twice" "$C" disable
refused "disable with args" "no arguments" "$C" disable x
printf 'remote\n' | "$C" enable push >/dev/null 2>&1

# --- every commit is scanned on its own: added-then-removed content is still refused ---
short_of() { git rev-parse "$1" | cut -c1-7; }
branch feat/addrm; commit s.txt "key=$FAKE_AWS" "feat: add"; git rm -q s.txt; git commit -q -m "fix: remove"
refused_noleak "secret added then removed" "secret pattern at s.txt:1 (commit $(short_of HEAD~1))" "$FAKE_AWS" "$C" plan
refused_noleak "secret added then removed, online push" "secret pattern at s.txt:1" "$FAKE_AWS" "$C" push --expect-sha "$(sha)"
branch feat/fadd; commit gone.key x "feat: add"; git rm -q gone.key; git commit -q -m "fix: remove"
refused "forbidden file added then removed" "forbidden file in commit $(short_of HEAD~1): gone.key" "$C" plan

# --- a scan that cannot run refuses (fail closed) ---
branch feat/failclosed; commit fc.txt x "feat: fc"
passes "stub-git copy works when nothing is forced to fail" "$F" plan
refused "git log failure" "cannot read commit" env GP_FAIL="log -1" "$F" plan
refused "git diff --name-only failure" "cannot list files of commit" env GP_FAIL="--diff-filter=d" "$F" plan
refused "git diff content failure" "cannot scan commit" env GP_FAIL="--unified=0" "$F" plan
refused "git rev-list failure" "REFUSED" env GP_FAIL="rev-list" "$F" plan
branch feat/order; commit o.txt "key=$FAKE_AWS" "feat: o"
branch feat/order2; commit o.txt clean "feat: o2"
git config diff.orderFile "$T/no-such-order-file"
git diff main HEAD >/dev/null 2>&1 && bad "precondition: git diff should fail with a missing diff.orderFile" || ok
passes "missing diff.orderFile with a clean branch" "$C" plan
git checkout -q feat/order
refused_noleak "missing diff.orderFile does not blank the scan" "secret pattern at o.txt:1" "$FAKE_AWS" "$C" plan
git config --unset diff.orderFile

# --- Git LFS is not supported ---
branch feat/lfs1; commit .gitattributes "*.bin filter=lfs diff=lfs merge=lfs -text" "feat: attrs"
refused "lfs via root .gitattributes" "Git LFS repositories are not supported" "$C" plan
refused "lfs via root .gitattributes on push" "Git LFS repositories are not supported" "$C" push --expect-sha "$(sha)"
branch feat/lfs2; commit sub/dir/.gitattributes "*.psd filter=lfs -text" "feat: nested attrs"
refused "lfs via nested .gitattributes" "Git LFS repositories are not supported" "$C" plan
branch feat/lfs3; commit .gitattributes "*.txt text eol=lf" "feat: attrs"
passes "unrelated .gitattributes" "$C" plan
branch feat/lfs4; commit l.txt x "feat: l"
git config filter.lfs.clean "git-lfs clean -- %f"
refused "lfs via filter config" "Git LFS repositories are not supported" "$C" plan
refused "enable refuses lfs config" "Git LFS repositories are not supported" "$C" enable push
git config --unset filter.lfs.clean
git config lfs.url "https://example.invalid/lfs"
refused "lfs via lfs.* config" "Git LFS repositories are not supported" "$C" plan
git config --unset lfs.url
passes "clean after lfs config" "$C" plan

# --- pre-push hook: warned about in plan, never run on push ---
branch feat/hookwarn; commit h.txt x "feat: h"
out=$("$C" plan 2>&1); printf '%s' "$out" | grep -qF "pre-push hook" && bad "plan warned without a hook: $out" || ok
printf '#!/bin/sh\ntouch %s/hook-ran-2\n' "$T" >.git/hooks/pre-push; chmod +x .git/hooks/pre-push
out=$("$C" plan 2>&1)
printf '%s' "$out" | grep -qF "warning: this repository has a pre-push hook; it will NOT run on this route" && ok || bad "plan lacks the pre-push warning: $out"
passes "push with a pre-push hook present" "$C" push --expect-sha "$(sha)"
[ "$(git -C "$T/remote.git" rev-parse refs/heads/feat/hookwarn)" = "$(sha)" ] && ok || bad "hookwarn ref not on remote"
[ ! -e "$T/hook-ran-2" ] && ok || bad "pre-push hook ran on push"
rm -f .git/hooks/pre-push
mkdir -p "$T/hk"; printf '#!/bin/sh\ntouch %s/hook-ran-3\n' "$T" >"$T/hk/pre-push"; chmod +x "$T/hk/pre-push"
git config core.hooksPath "$T/hk"; commit h2.txt x "feat: h2"
out=$("$C" plan 2>&1)
printf '%s' "$out" | grep -qF "pre-push hook; it will NOT run" && ok || bad "plan lacks the warning for core.hooksPath hooks: $out"
passes "push with a core.hooksPath pre-push hook" "$C" push --expect-sha "$(sha)"
[ ! -e "$T/hook-ran-3" ] && ok || bad "core.hooksPath pre-push hook ran on push"
git config --unset core.hooksPath

# --- conventional style applies to branch names; style project skips it ---
for b in wip/thing feat/Bad_Name feat/x--y feat/a/b feat-only feat/-x; do
  git checkout -q -B "$b" main; commit c.txt x "feat: c"
  refused "bad conventional branch $b" "<type>/<kebab-summary>" "$C" plan
done
for b in fix/handle-null-input docs/readme chore/a1-b2; do
  git checkout -q -B "$b" main; commit c.txt x "feat: c"
  passes "conventional branch $b" "$C" plan
done
printf 'remote\n' | "$C" enable push --style project >/dev/null 2>&1
git checkout -q -B wip/anything main; commit c.txt x "whatever"
passes "style project skips the branch format" "$C" plan
printf 'remote\n' | "$C" enable push >/dev/null 2>&1
refused "conventional again after re-enable" "<type>/<kebab-summary>" "$C" plan

# --- Revert subject and merge commits ---
branch feat/revert; commit r.txt x 'Revert "feat: add a"'
passes "Revert commit subject" "$C" plan
branch feat/revert2; commit r.txt x 'Revert the thing'
refused "Revert without a quoted subject" "Conventional" "$C" plan
branch feat/merge; commit m1.txt x "feat: m1"
git checkout -q -B feat/side main; commit m2.txt y "feat: m2"
git checkout -q feat/merge; git merge -q --no-ff -m "Merge branch 'feat/side' into feat/merge" feat/side
[ "$(git rev-list --parents -1 HEAD | wc -w | tr -d ' ')" = 3 ] && ok || bad "test setup: HEAD is not a merge commit"
passes "merge commit subject skips the subject check" "$C" plan
branch feat/nomerge; commit n.txt x "Merge branch 'feat/side' into feat/merge"
refused "same subject on a normal commit" "Conventional" "$C" plan

# --- forbidden names ---
branch feat/envex; commit .env.example "FOO=bar" "feat: example"; passes ".env.example" "$C" plan
branch feat/envsample; commit app/.env.sample "FOO=bar" "feat: sample"; passes "nested .env.sample" "$C" plan
for f in .env .env.local app/.env prod.tfvars infra/terraform.tfvars PROD.TFVARS; do
  branch feat/envbad; commit "$f" x "feat: bad"; refused "forbidden $f" "forbidden file in commit" "$C" plan
done

# --- repo config: benign http keys pass, redirecting settings are refused without printing the key ---
branch feat/cfg; commit cfg.txt x "feat: cfg"
for kv in http.postBuffer=524288000 http.lowSpeedLimit=1000; do
  git config "${kv%%=*}" "${kv#*=}"; passes "config ${kv%%=*} allowed" "$C" plan; git config --unset "${kv%%=*}"
done
git config http.sslVerify false
refused "other http key" "section 'http' has a setting that is not allowed on this route; remove it first" "$C" plan
git config --unset http.sslVerify
git config http.postBuffer 524288000; git config http.sslVerify false
refused "allowed http key does not mask a bad one" "section 'http'" "$C" plan
git config --unset http.postBuffer; git config --unset http.sslVerify
git config "http.https://u:${FAKE_PW}${AT}host.invalid/.proxy" x
refused_noleak "token inside an http config key" "section 'http'" "$FAKE_PW" "$C" plan
git config --unset-all "http.https://u:${FAKE_PW}${AT}host.invalid/.proxy"
git config "url.https://u:${FAKE_PW}${AT}host.invalid/.insteadOf" "https://unrelated.invalid/"
refused_noleak "token inside a url config key" "section 'url'" "$FAKE_PW" "$C" plan
git config --unset-all "url.https://u:${FAKE_PW}${AT}host.invalid/.insteadOf"
git config url."$T/other.git".insteadOf "https://unrelated.invalid/"
refused "repo-local url.*.insteadOf" "section 'url'" "$C" plan
git config --unset-all url."$T/other.git".insteadOf
git config protocol.file.allow always
refused "repo-local protocol.*" "section 'protocol'" "$C" plan
git config --unset protocol.file.allow
passes "clean after config cases" "$C" plan

# --- enable commit does not need or store a remote ---
git init -q -b main "$T/noorigin"; cd "$T/noorigin" || exit 1
git config user.email t@example.invalid; git config user.name t; git config commit.gpgsign false; commit f x "chore: i"
out=$(printf 'noorigin\n' | "$C" enable commit 2>&1); [ $? = 0 ] && ok || bad "enable commit without origin: $out"
row=$(awk -F'\t' -v k="$(cd .git && pwd -P)" '$1 == k {print $2 "|" $3 "|" $4 "|" $5}' "$REG")
[ "$row" = "-|commit|-|conventional" ] && ok || bad "registry row for no-origin repo: $row"
"$C" status | grep -q '^level: commit$' && ok || bad "status after enable commit without origin"
"$C" status | grep -q '^default branch: -$' && ok || bad "default branch should be - at level commit"
passes "disable the no-origin repo again" "$C" disable
cd "$T/work" || exit 1
printf 'remote\n' | "$C" enable commit >/dev/null 2>&1
row=$(awk -F'\t' -v k="$(cd .git && pwd -P)" '$1 == k {print $2 "|" $3 "|" $4}' "$REG")
[ "$row" = "-|commit|-" ] && ok || bad "enable commit stored a URL or default branch: $row"
printf 'remote\n' | "$C" enable push >/dev/null 2>&1

# --- enable commit ignores LFS, credential and http config; enable push refuses it ---
for kv in filter.lfs.clean=x lfs.url=https://example.invalid/lfs credential.helper=x http.sslVerify=false; do
  git config "${kv%%=*}" "${kv#*=}"
done
out=$(printf 'remote\n' | "$C" enable commit 2>&1); [ $? = 0 ] && ok || bad "enable commit with lfs/credential/http config: $out"
"$C" status | grep -q '^level: commit$' && ok || bad "status after enable commit with config"
for k in filter.lfs.clean lfs.url credential.helper http.sslVerify; do git config --unset "$k"; done
for kv in filter.lfs.clean=x lfs.url=https://example.invalid/lfs credential.helper=x http.sslVerify=false; do
  git config "${kv%%=*}" "${kv#*=}"
  out=$(printf 'remote\n' | "$C" enable push 2>&1); rc=$?
  [ "$rc" = 2 ] && ok || bad "enable push with ${kv%%=*} set: rc=$rc out=$out"
  git config --unset "${kv%%=*}"
done
"$C" status | grep -q '^level: commit$' && ok || bad "refused enable push changed the level"
printf 'remote\n' | "$C" enable push >/dev/null 2>&1
"$C" status | grep -q '^level: push$' && ok || bad "enable push after removing the config"

# --- control characters in the repository path ---
cp "$REG" "$T/reg.bak"
for d in "$T/tab"$'\t'"dir" "$T/nl"$'\n'"dir"; do
  mkdir -p "$d"; git init -q -b main "$d"; cd "$d" || exit 1
  refused "enable in a path with control characters" "repository path contains control characters" "$C" enable commit
  cd "$T/work" || exit 1
done
cmp -s "$REG" "$T/reg.bak" && ok || bad "registry changed after a refused enable"

# --- unquoted password assignment ---
branch feat/pw; commit app.conf "password=$FAKE_PW" "feat: pw"
refused_noleak "unquoted password line" "secret pattern at app.conf:1" "$FAKE_PW" "$C" plan
branch feat/pwok; commit ok.conf 'password=$DB_PASSWORD' "feat: ok"
passes "password taken from a variable is not a secret" "$C" plan
# Assignments whose right side is another identifier are code, not secrets.
n=0
for line in 'this.password = password;' 'connect(password=password, host=h)' 'self.access_token = access_token' 'password = hashed_password'; do
  n=$((n + 1)); branch "feat/pwcode$n"; commit "code$n.txt" "$line" "feat: code $n"
  passes "identifier on the right of password is not a secret: $line" "$C" plan
done
for line in "pass""word=$FAKE_PW" "DB_PASS""WORD=a1b2c3d4e5"; do
  n=$((n + 1)); branch "feat/pwsec$n"; commit "sec$n.conf" "$line" "feat: sec $n"
  refused_noleak "unquoted literal password is refused: ${line%%=*}" "secret pattern at sec$n.conf:1" "${line#*=}" "$C" plan
done

# --- scanner desync: diff config must not change what the scanner reads ---
MAIN_SHA=$(git rev-parse main)
branch feat/desync1
printf 'a\n\n\nb\n' >d1.txt; git add d1.txt; git commit -q -m "feat: d1"
git update-ref refs/heads/main HEAD; git update-ref refs/remotes/origin/main HEAD
printf 'A\n\n\nB\n' >d1.txt; printf 'k=%s\n' "$FAKE_AWS" >d2.txt; git add d1.txt d2.txt; git commit -q -m "feat: d2"
git config diff.interHunkContext 4; git config diff.suppressBlankEmpty true
refused_noleak "diff config cannot desync the scanner" "secret pattern at d2.txt:1" "$FAKE_AWS" "$C" plan
git config --unset diff.interHunkContext; git config --unset diff.suppressBlankEmpty
git update-ref refs/heads/main "$MAIN_SHA"; git update-ref refs/remotes/origin/main "$MAIN_SHA"

# --- a grep error (rc 2) in the secret check refuses instead of passing ---
branch feat/grepfail; commit gf.txt x "feat: gf"
passes "stub-grep copy works when nothing is forced to fail" "$H" plan
refused "grep error while scanning added lines" "cannot scan commit" env GP_GREP_FAIL=-anEi "$H" plan
refused "grep error while scanning the commit message" "secret pattern in the commit message" env GP_GREP_FAIL=-aEiq "$H" plan

# --- push from a linked worktree ---
git worktree add -q -b feat/linked "$T/wt2" main
cd "$T/wt2" || exit 1
commit w.txt x "feat: w"
passes "plan from a linked worktree" "$C" plan
passes "push from a linked worktree" "$C" push --expect-sha "$(sha)"
[ "$(git -C "$T/remote.git" rev-parse refs/heads/feat/linked)" = "$(sha)" ] && ok || bad "linked worktree push did not reach the remote"
cd "$T/work" || exit 1
[ -z "$(ls -A "$T/tmp")" ] && ok || bad "private temp copies left behind: $(ls "$T/tmp")"

# --- URL policy at enable ---
git init -q -b main "$T/u"; cd "$T/u" || exit 1
git config user.email t@example.invalid; git config user.name t; git config commit.gpgsign false; commit f x "chore: i"
git update-ref refs/remotes/origin/main HEAD; git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
for u in "https://u:${FAKE_PW}${AT}github.com/o/r.git" "https://${FAKE_PW}${AT}github.com/o/r.git" "ssh://u:${FAKE_PW}${AT}example.invalid/o/r.git"; do
  git remote add origin "$u"; err=$(printf 'r\n' | "$C" enable push 2>&1); rc=$?
  [ "$rc" = 2 ] && printf '%s' "$err" | grep -qF "credentials" && ok || bad "cred url: $err"
  printf '%s' "$err" | grep -qF "$FAKE_PW" && bad "credential printed" || ok
  git remote remove origin
done
git remote add origin "ext::sh -c x"; refused "ext transport" "helper" "$C" enable push; git remote remove origin
git remote add origin "git@gitlab.example.invalid:o/r.git"; err=$(printf 'r\n' | "$G" enable pr 2>&1); [ $? = 2 ] && printf '%s' "$err" | grep -qF "github.com" && ok || bad "non-github pr: $err"
git remote remove origin

# --- PR flow (stub git/gh, no network) ---
git init -q -b main "$T/g"; cd "$T/g" || exit 1
git config user.email t@example.invalid; git config user.name t; git config commit.gpgsign false; commit f x "chore: i"
git remote add origin "git@github.com:acme/widget.git"; git update-ref refs/remotes/origin/main HEAD
out=$(printf 'widget\n' | "$G" enable pr 2>&1); [ $? = 0 ] && ok || bad "enable pr: $out"
[ "$(wc -l <"$REG" | tr -d ' ')" = 2 ] && ok || bad "registry keeps other rows"
branch feat/pr; commit p.txt x "feat: pr"; S=$(sha)
printf 'feat: add pr\n' >"$T/title"
printf '## What\nx\n## Why\nx\n## How tested\nx\n## Risks\nx\n' >"$T/body"
out=$("$G" plan --title-file "$T/title" --body-file "$T/body" 2>&1); rc=$?
[ "$rc" = 0 ] && printf '%s' "$out" | grep -qF "pr --expect-sha $S" && ok || bad "plan pr: $out"
CONTENT=$(printf '%s\n' "$out" | sed -n 's/^content sha256: //p')
[ "$CONTENT" = "$(cat "$T/title" "$T/body" | shasum -a 256 | awk '{print $1}')" ] && ok || bad "content hash is not sha256(title line + body): $CONTENT"
printf '%s' "$out" | grep -qF -- "--expect-content $CONTENT --title-file $T/title --body-file $T/body" && ok || bad "plan command lacks --expect-content: $out"
printf '%s' "$out" | grep -qF "pr title: feat: add pr" && ok || bad "plan lacks the pr title line"
printf '%s' "$out" | grep -qF "pr body preview:" && ok || bad "plan lacks the body preview"
printf 'bad title\n' >"$T/t2"; refused "title format" "PR title" "$G" plan --title-file "$T/t2" --body-file "$T/body"
printf 'feat: a\nfeat: b\n' >"$T/t3"; refused "title two lines" "single line" "$G" plan --title-file "$T/t3" --body-file "$T/body"
: >"$T/t4"; refused "title empty" "empty" "$G" plan --title-file "$T/t4" --body-file "$T/body"
printf '## What\nx\n' >"$T/b2"; refused "missing heading" "## Risks" "$G" plan --title-file "$T/title" --body-file "$T/b2"
ln -s "$T/title" "$T/tl"; refused "symlink title" "symlink" "$G" plan --title-file "$T/tl" --body-file "$T/body"
ln -s "$T/body" "$T/bl"; refused "symlink body" "symlink" "$G" plan --title-file "$T/title" --body-file "$T/bl"
head -c 65537 /dev/zero | tr '\0' a >"$T/big"; refused "big body" "64KB" "$G" plan --title-file "$T/title" --body-file "$T/big"
{ cat "$T/body"; printf '%s\n' "$FAKE_AWS"; } >"$T/b3"
err=$("$G" plan --title-file "$T/title" --body-file "$T/b3" 2>&1); [ $? = 2 ] && printf '%s' "$err" | grep -qF "body:9" && ok || bad "body secret: $err"
printf '%s' "$err" | grep -qF "$FAKE_AWS" && bad "body secret printed" || ok
printf 'feat: %s\n' "$FAKE_AWS" >"$T/t5"; refused "title secret" "title:1" "$G" plan --title-file "$T/t5" --body-file "$T/body"
refused "body is dash" "dash" "$G" plan --title-file "$T/title" --body-file -
refused "pr needs files" "required" "$G" pr --expect-sha "$S"
refused "pr without --expect-content" "64-hex" "$G" pr --expect-sha "$S" --title-file "$T/title" --body-file "$T/body"
out=$("$G" pr --expect-sha "$S" --expect-content "$CONTENT" --title-file "$T/title" --body-file "$T/body" 2>&1); [ $? = 0 ] && ok || bad "pr: $out"
# The push refspec is the verified commit, not a ref name that could move.
grep -qxF "PUSH push --no-follow-tags --recurse-submodules=no origin $S:refs/heads/feat/pr" "$T/push.log" && ok || bad "push argv: $(cat "$T/push.log")"
# gh gets a private temp copy of the body, never the caller's file.
want="[pr] [create] [--draft] [--repo] [acme/widget] [--base] [main] [--head] [feat/pr] [--title] [feat: add pr] [--body-file] [$T/tmp/git-publish."
case "$(cat "$T/gh.log")" in
  "$want"??????"] ") ok ;;
  *) bad "gh argv: $(cat "$T/gh.log")" ;;
esac
cmp -s "$T/gh.body" "$T/body" && ok || bad "gh received a body that differs from the planned body"
[ -z "$(ls -A "$T/tmp")" ] && ok || bad "private temp copies were not removed: $(ls "$T/tmp")"
: >"$T/push.log"
out=$("$G" pr --expect-sha "$S" --expect-content "$CONTENT" --title-file "$T/title" --body-file "$T/body" 2>&1); [ $? = 0 ] && ok || bad "pr again: $out"
[ ! -s "$T/push.log" ] && ok || bad "pr pushed again though remote already at SHA"

# --- --expect-content binds the PR text approved in plan ---
: >"$T/gh.log"; : >"$T/push.log"
ZERO=$(printf '%064d' 0)
refused "expect-content mismatch" "changed since plan" "$G" pr --expect-sha "$S" --expect-content "$ZERO" --title-file "$T/title" --body-file "$T/body"
refused "expect-content not hex" "64-hex" "$G" pr --expect-sha "$S" --expect-content abc --title-file "$T/title" --body-file "$T/body"
refused "expect-content duplicate" "duplicate" "$G" pr --expect-sha "$S" --expect-content "$CONTENT" --expect-content "$CONTENT" --title-file "$T/title" --body-file "$T/body"
printf 'feat: add pr changed\n' >"$T/title_m"
{ cat "$T/body"; printf 'extra line\n'; } >"$T/body_m"
{ cat "$T/body"; printf '\n'; } >"$T/body_ws"
refused "title changed after plan" "changed since plan" "$G" pr --expect-sha "$S" --expect-content "$CONTENT" --title-file "$T/title_m" --body-file "$T/body"
refused "body changed after plan" "changed since plan" "$G" pr --expect-sha "$S" --expect-content "$CONTENT" --title-file "$T/title" --body-file "$T/body_m"
refused "body whitespace change after plan" "changed since plan" "$G" pr --expect-sha "$S" --expect-content "$CONTENT" --title-file "$T/title" --body-file "$T/body_ws"
[ ! -s "$T/gh.log" ] && [ ! -s "$T/push.log" ] && ok || bad "a refused pr still reached gh or push: $(cat "$T/gh.log" "$T/push.log")"
out2=$("$G" plan --title-file "$T/title_m" --body-file "$T/body" 2>&1)
C2=$(printf '%s\n' "$out2" | sed -n 's/^content sha256: //p')
[ -n "$C2" ] && [ "$C2" != "$CONTENT" ] && ok || bad "a changed title did not change the plan hash: $out2"
out=$("$G" pr --expect-sha "$S" --expect-content "$C2" --title-file "$T/title_m" --body-file "$T/body" 2>&1); [ $? = 0 ] && ok || bad "pr with the hash printed for the new title: $out"
grep -qF "[feat: add pr changed]" "$T/gh.log" && ok || bad "gh did not get the approved title: $(cat "$T/gh.log")"

# --- symlinked parent directories of the PR text files ---
mkdir -p "$T/realdir"; cp "$T/title" "$T/body" "$T/realdir/"; ln -s "$T/realdir" "$T/linkdir"
refused "symlinked parent of title" "symlinked parent" "$G" plan --title-file "$T/linkdir/title" --body-file "$T/body"
refused "symlinked parent of body" "symlinked parent" "$G" plan --title-file "$T/title" --body-file "$T/linkdir/body"

# --- level pr is required for pr and for plan with PR text ---
printf 'widget\n' | "$G" enable push >/dev/null 2>&1
"$G" status | grep -q '^level: push$' && ok || bad "level push after enable"
: >"$T/gh.log"; : >"$T/push.log"
refused "pr at level push" "too low" "$G" pr --expect-sha "$S" --expect-content "$CONTENT" --title-file "$T/title" --body-file "$T/body"
refused "plan with pr text at level push" "too low" "$G" plan --title-file "$T/title" --body-file "$T/body"
passes "plan without pr text at level push" "$G" plan
[ ! -s "$T/gh.log" ] && [ ! -s "$T/push.log" ] && ok || bad "pr at level push reached gh or push"
printf 'widget\n' | "$G" enable pr >/dev/null 2>&1

# --- Revert subjects: fine as a commit subject, not as a PR title ---
branch feat/revert; commit r.txt x 'Revert "feat: add a"'
passes "Revert commit subject" "$G" plan
printf 'Revert "feat: add a"\n' >"$T/t_rev"
refused "Revert as pr title" "PR title is not Conventional" "$G" plan --title-file "$T/t_rev" --body-file "$T/body"
branch feat/revert2; commit r.txt x 'Revert the thing'
refused "Revert without quoted subject" "Conventional" "$G" plan
branch feat/revert3; commit r.txt x 'Revert "feat: add a" and more'
refused "Revert with trailing text" "Conventional" "$G" plan

# --- registered default branch with a non-protected name ---
git init -q -b stable "$T/d"; cd "$T/d" || exit 1
git config user.email t@example.invalid; git config user.name t; git config commit.gpgsign false; commit f x "chore: i"
git clone -q --bare "$T/d" "$T/stable-remote.git"; git remote add origin "$T/stable-remote.git"; git fetch -q origin
out=$(printf 'stable-remote\n' | "$C" enable push 2>&1); [ $? = 0 ] && ok || bad "enable stable: $out"
"$C" status | grep -q '^default branch: stable$' && ok || bad "stable default captured"
refused "on registered default" "default branch" "$C" plan
git checkout -q -b feat/s; commit g x "feat: g"; passes "feature from stable" "$C" plan

# --- environment hardening ---
cd "$T/work" || exit 1
branch feat/env; commit e.txt x "feat: env"
out=$(GIT_DIR=/nonexistent GIT_SSH_COMMAND=/bin/false "$C" status 2>&1); printf '%s' "$out" | grep -q '^level: push$' && ok || bad "GIT_DIR not scrubbed: $out"

# --- agent-run push, pr and merge: bounded by the registered level, never by a terminal ---
# L0 (real git) and K0 (stub git/gh) keep the real require_tty, so every success below also proves that
# these commands need no terminal. Only the registry path and PATH are patched.
mk_lockcopy() { # $1 dest, $2 PATH prefix (may be empty)
  mkdir -p "$(dirname "$1")"
  sed -e 's/ GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM / /' \
    -e "s|^REGISTRY=.*|REGISTRY=\"$REG\"|" \
    -e "s|^PATH=.*|PATH=$2/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin|" \
    "$SRC" >"$1" || patch_fatal "sed failed (lock copy)"
  chmod +x "$1"
  grep -qxF "REGISTRY=\"$REG\"" "$1" || patch_fatal "REGISTRY line was not rewritten (lock copy)"
  grep -q '^require_tty() {$' "$1" || patch_fatal "lock copy lost require_tty"
  bash -n "$1" || patch_fatal "lock copy has a syntax error"
}
MS="$T/ms"; mkdir -p "$MS" "$T/stubm"
export MS_DIR="$MS"
L0="$T/c5/git-publish.sh"; mk_lockcopy "$L0" ""
K0="$T/c6/git-publish.sh"; mk_lockcopy "$K0" "$T/stubm:"
cp "$T/stub/git" "$T/stubm/git"
# Stub gh: logs argv, serves the pr view fixture, fails on demand (fail.view, fail.ready, fail.merge).
cat >"$T/stubm/gh" <<'E'
#!/bin/bash
for a in "$@"; do printf '[%s] ' "$a"; done >>"$MS_DIR/gh.log"; echo >>"$MS_DIR/gh.log"
case "$1 $2" in
  "pr view") [ -e "$MS_DIR/fail.view" ] && { echo "stub view failure" >&2; exit 1; }; cat "$MS_DIR/pr.json" ;;
  "pr ready") [ -e "$MS_DIR/fail.ready" ] && exit 1 ;;
  "pr merge") [ -e "$MS_DIR/fail.merge" ] && exit 1 ;;
  "pr create") : ;;
  *) exit 1 ;;
esac
exit 0
E
chmod +x "$T/stubm/gh" "$T/stubm/git"
resetgh() { rm -f "$MS"/gh.log "$MS"/fail.*; : >"$MS/gh.log"; rm -f "$T/pushed"; : >"$T/push.log"; }
ghcalled() { grep -qF -- "$1" "$MS/gh.log"; }
nomut() { # name: neither gh pr ready nor gh pr merge ran
  if ghcalled '[pr] [merge]' || ghcalled '[pr] [ready]'; then bad "$1: mutating gh call happened: $(cat "$MS/gh.log")"; else ok; fi
}
remote_refs() { git -C "$T/m-remote.git" for-each-ref --format='%(refname) %(objectname)'; }

git init -q -b main "$T/m"; cd "$T/m" || exit 1
git config user.email t@example.invalid; git config user.name t; git config commit.gpgsign false
commit README.md hello "chore: init"
git clone -q --bare "$T/m" "$T/m-remote.git"
git remote add origin "$T/m-remote.git"; git fetch -q origin
MKEY=$(cd "$(git rev-parse --git-common-dir)" && pwd -P)
TAB=$'\t'
setrow() { # url level default [ci [style]]: replace only this repository's registry row; no ci means a five-column row
  { [ -f "$REG" ] && awk -F'\t' -v k="$MKEY" '$1 != k' "$REG"; printf '%s\t%s\t%s\t%s\t%s%s\n' "$MKEY" "$1" "$2" "$3" "${5:-conventional}" "${4:+$TAB$4}"; } >"$REG.new" && mv "$REG.new" "$REG"
}
delrow() { awk -F'\t' -v k="$MKEY" '$1 != k' "$REG" >"$REG.new" && mv "$REG.new" "$REG"; }
GHURL=git@github.com:acme/widget.git
branch feat/widget; commit a.txt a "feat: add widget"; S=$(sha)
printf 'feat: add widget\n' >"$T/mtitle"
printf '## What\nw\n## Why\ny\n## How tested\nt\n## Risks\nr\n' >"$T/mbody"
PRFILES=(--title-file "$T/mtitle" --body-file "$T/mbody")

# A repository that was never set up is blocked: nothing reaches the remote, gh or the push stub.
delrow; resetgh; REFS_BEFORE=$(remote_refs)
[ -f "$REG" ] && ! awk -F'\t' -v k="$MKEY" '$1 == k {f = 1} END {exit !f}' "$REG" && ok || bad "precondition: repository must have no registry row"
refused "unregistered push" "not registered" "$L0" push --expect-sha "$S"
refused "unregistered pr" "not registered" "$K0" pr --expect-sha "$S" --expect-content "$ZERO" "${PRFILES[@]}"
refused "unregistered merge" "not registered" "$K0" merge --pr 7 --expect-sha "$S"
[ "$(remote_refs)" = "$REFS_BEFORE" ] && ok || bad "unregistered repository changed the remote: $(remote_refs)"
[ ! -e "$T/pushed" ] && [ ! -s "$T/push.log" ] && [ ! -s "$MS/gh.log" ] && ok || bad "unregistered repository reached push or gh: $(cat "$T/push.log" "$MS/gh.log")"

# push: no terminal, level push or higher, refused one level below.
setrow - commit -
refused "push at level commit" "too low" "$L0" push --expect-sha "$S"
[ "$(remote_refs)" = "$REFS_BEFORE" ] && ok || bad "push at level commit changed the remote"
setrow "$T/m-remote.git" push main
out=$("$L0" push --expect-sha "$S" 2>&1 </dev/null); rc=$?
[ "$rc" = 0 ] && ok || bad "push at level push without a terminal: rc=$rc out=$out"
[ "$(git -C "$T/m-remote.git" rev-parse refs/heads/feat/widget)" = "$S" ] && ok || bad "push did not reach the bare remote"
setrow "$T/m-remote.git" merge main
passes "push at level merge" "$L0" push --expect-sha "$S"

# pr: no terminal, level pr or higher, refused one level below (stub git/gh).
git remote set-url origin "$GHURL"; git update-ref refs/remotes/origin/main main
setrow "$GHURL" pr main
out=$("$K0" plan "${PRFILES[@]}" 2>&1 </dev/null); rc=$?
MCS=$(printf '%s\n' "$out" | sed -n 's/^content sha256: //p')
[ "$rc" = 0 ] && [ "${#MCS}" = 64 ] && ok || bad "plan with pr text: rc=$rc out=$out"
printf '%s\n' "$out" | grep -qx 'Next command:' && ok || bad "plan footer is not 'Next command:': $out"
printf '%s' "$out" | grep -qF "pr --expect-sha $S --expect-content $MCS" && ok || bad "plan command lacks pr arguments: $out"
PRARGS=(--expect-sha "$S" --expect-content "$MCS" "${PRFILES[@]}")
setrow "$GHURL" push main; resetgh
refused "pr at level push" "too low" "$K0" pr "${PRARGS[@]}"
[ ! -e "$T/pushed" ] && [ ! -s "$MS/gh.log" ] && ok || bad "pr at level push reached push or gh"
setrow "$GHURL" pr main; resetgh
out=$("$K0" pr "${PRARGS[@]}" 2>&1 </dev/null); rc=$?
[ "$rc" = 0 ] && ok || bad "pr at level pr without a terminal: rc=$rc out=$out"
ghcalled '[pr] [create] [--draft] [--repo] [acme/widget] [--base] [main] [--head] [feat/widget]' && ok || bad "pr did not create a draft: $(cat "$MS/gh.log")"
[ -e "$T/pushed" ] && ok || bad "pr did not push"
setrow "$GHURL" merge main; resetgh
passes "pr at level merge" "$K0" pr "${PRARGS[@]}"

# merge: stub gh serves the pull request fixture.
BASEJ=$(jq -n --arg s "$S" --arg b "$(cat "$T/mbody")" '{state:"OPEN",isDraft:false,isCrossRepository:false,headRefName:"feat/widget",headRefOid:$s,baseRefName:"main",title:"feat: add widget",body:$b,statusCheckRollup:[{__typename:"CheckRun",name:"ci",status:"COMPLETED",conclusion:"SUCCESS"},{__typename:"StatusContext",context:"x",state:"SUCCESS"}]}')
fx() { printf '%s' "$BASEJ" | jq "$1" >"$MS/pr.json"; }
MERGE=("$K0" merge --pr 7 --expect-sha "$S")
mr() { # name, stderr substring, fixture filter
  resetgh; fx "$3"; refused "merge $1" "$2" "${MERGE[@]}"; nomut "merge $1"
}

resetgh; fx .
out=$("${MERGE[@]}" 2>"$T/merge.err" </dev/null); rc=$?
[ "$rc" = 0 ] && ok || bad "merge at level merge without a terminal: rc=$rc err=$(cat "$T/merge.err")"
[ "$out" = "7 $S" ] && ok || bad "merge stdout is not '<n> <sha>': '$out'"
want="[pr] [merge] [7] [--repo] [acme/widget] [--squash] [--match-head-commit] [$S] [--subject] [feat: add widget] [--body] [] "
grep -qxF -- "$want" "$MS/gh.log" && ok || bad "merge argv: $(cat "$MS/gh.log")"
[ "$(sed -n 1p "$MS/gh.log")" = "[pr] [view] [7] [--repo] [acme/widget] [--json] [state,isDraft,isCrossRepository,headRefName,headRefOid,baseRefName,title,body,statusCheckRollup] " ] && ok || bad "view argv: $(sed -n 1p "$MS/gh.log")"
ghcalled '[pr] [ready]' && bad "gh pr ready ran for a non-draft" || ok
for flag in --admin --auto --delete-branch; do ghcalled "[$flag]" && bad "merge passed $flag" || ok; done

# A plain merge on a draft is refused (exit 2) and calls neither ready nor merge; marking ready is its own run.
DRAFTWHY="pull request is a draft; run merge --mark-ready-only first, then merge again once CI has finished"
MARK=("$K0" merge --mark-ready-only --pr 7 --expect-sha "$S")
resetgh; fx '.isDraft=true'
out=$("${MERGE[@]}" 2>"$T/merge.err" </dev/null); rc=$?
[ "$rc" = 2 ] && [ -z "$out" ] && grep -qF -- "$DRAFTWHY" "$T/merge.err" && ok || bad "draft merge: rc=$rc out=$out err=$(cat "$T/merge.err")"
nomut "plain merge on a draft"
# --mark-ready-only on a draft with passing CI: exact output, exact ready argv, no merge call.
resetgh; fx '.isDraft=true'
out=$("${MARK[@]}" 2>"$T/merge.err" </dev/null); rc=$?
[ "$rc" = 0 ] && [ "$out" = "marked ready: 7 $S" ] && ok || bad "mark-ready-only: rc=$rc out=$out err=$(cat "$T/merge.err")"
[ ! -s "$T/merge.err" ] && ok || bad "mark-ready-only wrote to stderr: $(cat "$T/merge.err")"
grep -qxF '[pr] [ready] [7] [--repo] [acme/widget] ' "$MS/gh.log" && ok || bad "ready argv: $(cat "$MS/gh.log")"
ghcalled '[pr] [merge]' && bad "mark-ready-only called gh pr merge: $(cat "$MS/gh.log")" || ok
# A draft whose checks are pending, skipped-only or absent may be marked ready (CI may not have run yet).
for spec in 'pending:[{__typename:"CheckRun",status:"IN_PROGRESS",conclusion:""}]' 'skipped only:[{__typename:"CheckRun",status:"COMPLETED",conclusion:"SKIPPED"}]' 'no checks:[]' 'null checks:null'; do
  resetgh; fx ".isDraft=true | .statusCheckRollup=${spec#*:}"
  out=$("${MARK[@]}" 2>&1 </dev/null); rc=$?
  [ "$rc" = 0 ] && [ "$out" = "marked ready: 7 $S" ] && ok || bad "mark-ready-only with ${spec%%:*}: rc=$rc out=$out"
  ghcalled '[pr] [ready]' && ok || bad "mark-ready-only with ${spec%%:*}: gh pr ready not called"
  ghcalled '[pr] [merge]' && bad "mark-ready-only with ${spec%%:*}: gh pr merge called" || ok
  resetgh; fx ".isDraft=true | .statusCheckRollup=${spec#*:}"
  refused "plain merge on a draft with ${spec%%:*}" "--mark-ready-only" "${MERGE[@]}"; nomut "plain merge on a draft with ${spec%%:*}"
done
# --mark-ready-only is for drafts only, needs level merge, and never merges on any path.
resetgh; fx '.isDraft=false'
refused "mark-ready-only on a non-draft" "pull request is not a draft; --mark-ready-only applies to drafts only" "${MARK[@]}"; nomut "mark-ready-only on a non-draft"
for lv in off commit push pr; do
  case "$lv" in
    off) delrow; want="not registered" ;;
    commit) setrow - commit -; want="too low" ;;
    *) setrow "$GHURL" "$lv" main; want="too low" ;;
  esac
  resetgh; fx '.isDraft=true'; refused "mark-ready-only at level $lv" "$want" "${MARK[@]}"; nomut "mark-ready-only at level $lv"
done
setrow "$GHURL" merge main
resetgh; fx '.isDraft=true | .headRefOid="2222222222222222222222222222222222222222"'
refused "mark-ready-only with a different head" "does not match --expect-sha" "${MARK[@]}"; nomut "mark-ready-only with a different head"
refused "mark-ready-only missing sha" "40-hex" "$K0" merge --mark-ready-only --pr 7
refused "mark-ready-only missing pr" "positive integer" "$K0" merge --mark-ready-only --expect-sha "$S"
# After the user's CI finished, the second run (no longer a draft) merges and does not call ready again.
resetgh; fx '.isDraft=false'
out=$("${MERGE[@]}" 2>&1 </dev/null); rc=$?
[ "$rc" = 0 ] && [ "$out" = "7 $S" ] && ok || bad "second merge run after ready: rc=$rc out=$out"
ghcalled '[pr] [merge]' && ok || bad "second merge run did not call gh pr merge"
ghcalled '[pr] [ready]' && bad "second merge run called gh pr ready again" || ok

# Skipped and neutral runs prove nothing: at least one SUCCESS is required.
SKIPPED_ONLY='.statusCheckRollup=[{__typename:"CheckRun",status:"COMPLETED",conclusion:"SKIPPED"}]'
NEUTRAL_ONLY='.statusCheckRollup=[{__typename:"CheckRun",status:"COMPLETED",conclusion:"NEUTRAL"}]'
NOSUCCESS="no successful check: every check was skipped or neutral"
mr "only skipped checks" "$NOSUCCESS" "$SKIPPED_ONLY"
mr "only neutral checks" "$NOSUCCESS" "$NEUTRAL_ONLY"
mr "skipped and neutral checks only" "$NOSUCCESS" '.statusCheckRollup=[{__typename:"CheckRun",status:"COMPLETED",conclusion:"SKIPPED"},{__typename:"CheckRun",status:"COMPLETED",conclusion:"NEUTRAL"}]'
mr "success plus skipped but one pending" "pending" '.statusCheckRollup=[{__typename:"CheckRun",status:"COMPLETED",conclusion:"SUCCESS"},{__typename:"CheckRun",status:"COMPLETED",conclusion:"SKIPPED"},{__typename:"CheckRun",status:"IN_PROGRESS",conclusion:""}]'
mr "skipped status context counts as failing" "failing" '.statusCheckRollup=[{__typename:"StatusContext",context:"x",state:"SKIPPED"}]'
resetgh; fx '.statusCheckRollup=[{__typename:"CheckRun",status:"COMPLETED",conclusion:"SUCCESS"},{__typename:"CheckRun",status:"COMPLETED",conclusion:"SKIPPED"}]'
out=$("${MERGE[@]}" 2>&1 </dev/null); rc=$?
[ "$rc" = 0 ] && [ "$out" = "7 $S" ] && ghcalled '[pr] [merge]' && ok || bad "success plus skipped must merge: rc=$rc out=$out"

# The PR body must carry the four headings under style conventional; style project does not require them.
mr "body without the required headings" "PR body is missing the heading '## What'" '.body="plain body"'
mr "body missing only one heading" "PR body is missing the heading '## Risks'" '.body="## What\nw\n## Why\ny\n## How tested\nt"'
setrow "$GHURL" merge main "" project; resetgh; fx '.body="plain body"'
out=$("${MERGE[@]}" 2>&1 </dev/null); rc=$?
[ "$rc" = 0 ] && [ "$out" = "7 $S" ] && ghcalled '[pr] [merge]' && ok || bad "style project must accept a body without headings: rc=$rc out=$out"
setrow "$GHURL" merge main

resetgh; fx '.statusCheckRollup=[{__typename:"CheckRun",status:"COMPLETED",conclusion:"SKIPPED"},{__typename:"CheckRun",status:"COMPLETED",conclusion:"NEUTRAL"},{__typename:"CheckRun",status:"COMPLETED",conclusion:"SUCCESS"}]'
passes "merge accepts skipped and neutral checks" "${MERGE[@]}"

# merge below level merge, or unregistered: refused before any gh call that changes anything.
for lv in off commit push pr; do
  case "$lv" in
    off) delrow; want="not registered" ;;
    commit) setrow - commit -; want="too low" ;;
    *) setrow "$GHURL" "$lv" main; want="too low" ;;
  esac
  resetgh; fx .; refused "merge at level $lv" "$want" "${MERGE[@]}"; nomut "merge at level $lv"
done
setrow "$GHURL" merge main

# merge: the pull request must be exactly the approved one.
resetgh; fx .; refused "merge sha mismatch" "does not match" "$K0" merge --pr 7 --expect-sha 1111111111111111111111111111111111111111; nomut "merge sha mismatch"
mr "pr head oid differs" "does not match --expect-sha" '.headRefOid="2222222222222222222222222222222222222222"'
mr "wrong head branch" "head branch differs" '.headRefName="feat/other"'
mr "wrong base" "registered default" '.baseRefName="develop"'
mr "cross-repository" "cross-repository" '.isCrossRepository=true'
mr "closed" "not open" '.state="CLOSED"'
mr "merged" "not open" '.state="MERGED"'
mr "ci failing" "failing" '.statusCheckRollup[0].conclusion="FAILURE"'
mr "ci cancelled" "failing" '.statusCheckRollup[0].conclusion="CANCELLED"'
mr "ci status context error" "failing" '.statusCheckRollup[1].state="ERROR"'
mr "ci pending check run" "pending" '.statusCheckRollup[0]={__typename:"CheckRun",status:"IN_PROGRESS",conclusion:""}'
mr "ci pending status context" "pending" '.statusCheckRollup[1].state="PENDING"'
mr "ci unknown check type" "failing" '.statusCheckRollup[0].__typename="Mystery"'
mr "no ci (empty list)" "no CI checks" '.statusCheckRollup=[]'
mr "no ci (null)" "no CI checks" '.statusCheckRollup=null'
mr "plain merge on a draft with failing ci" "--mark-ready-only" '.isDraft=true | .statusCheckRollup[0].conclusion="FAILURE"'
resetgh; fx '.isDraft=true | .statusCheckRollup[0].conclusion="FAILURE"'
refused "mark-ready-only with failing ci" "CI checks are failing" "${MARK[@]}"; nomut "mark-ready-only with failing ci"
resetgh; fx '.isDraft=true | .statusCheckRollup[1].state="ERROR"'
refused "mark-ready-only with a failing status context" "CI checks are failing" "${MARK[@]}"; nomut "mark-ready-only with a failing status context"
mr "title not conventional" "Conventional" '.title="add widget"'
mr "title with newline" "single line" '.title="feat: a\nb"'
mr "title with control character" "control" '.title="feat: a\u0007b"'
mr "title fixup" "fixup" '.title="fixup! feat: x"'
mr "unexpected shape: missing isDraft" "unexpected" 'del(.isDraft)'
mr "unexpected shape: isDraft as string" "unexpected" '.isDraft="false"'
mr "unexpected shape: rollup as object" "unexpected" '.statusCheckRollup={}'
mr "unexpected shape: array of two" "unexpected" '[., .]'
resetgh; printf '%s' "$BASEJ" | jq --arg t "feat: add $FAKE_AWS" '.title=$t' >"$MS/pr.json"
refused_noleak "merge title secret" "secret pattern at title" "$FAKE_AWS" "${MERGE[@]}"; nomut "merge title secret"
resetgh; fx ".body=\"text $FAKE_AWS\""; refused_noleak "merge body secret" "secret pattern at body" "$FAKE_AWS" "${MERGE[@]}"; nomut "merge body secret"
resetgh; printf 'not json' >"$MS/pr.json"; refused "merge invalid json" "unexpected" "${MERGE[@]}"; nomut "merge invalid json"
resetgh; : >"$MS/pr.json"; refused "merge empty gh output" "unexpected" "${MERGE[@]}"; nomut "merge empty gh output"
resetgh; fx .; touch "$MS/fail.view"; refused "merge gh view error" "cannot read pull request" "${MERGE[@]}"; nomut "merge gh view error"

# gh failing at the mutating step is a refusal, never a success line.
resetgh; fx '.isDraft=true'; touch "$MS/fail.ready"
out=$("${MARK[@]}" 2>"$T/merge.err" </dev/null); rc=$?
[ "$rc" = 2 ] && [ -z "$out" ] && grep -qF "could not mark" "$T/merge.err" && ok || bad "gh pr ready failure: rc=$rc out=$out err=$(cat "$T/merge.err")"
ghcalled '[pr] [merge]' && bad "gh pr merge ran after gh pr ready failed" || ok
resetgh; fx .; touch "$MS/fail.merge"
out=$("${MERGE[@]}" 2>"$T/merge.err" </dev/null); rc=$?
[ "$rc" = 2 ] && [ -z "$out" ] && grep -qF "could not merge" "$T/merge.err" && ok || bad "gh pr merge failure: rc=$rc out=$out err=$(cat "$T/merge.err")"

# merge: --pr and the argument list are strict.
resetgh; fx .
for a in "--pr 0" "--pr -3" "--pr abc" "--pr 07" "--pr 1.5" "--pr 12345678901"; do
  refused "merge bad pr [$a]" "positive integer" "$K0" merge $a --expect-sha "$S"
done
refused "merge pr with a newline" "positive integer" "$K0" merge --pr "$(printf '7\n8')" --expect-sha "$S"
refused "merge missing pr" "positive integer" "$K0" merge --expect-sha "$S"
refused "merge missing sha" "40-hex" "$K0" merge --pr 7
refused "merge duplicate pr" "duplicate" "$K0" merge --pr 7 --pr 8 --expect-sha "$S"
for flag in --admin --auto --delete-branch --squash --title-file; do
  refused "merge unknown argument $flag" "allowed here" "$K0" merge --pr 7 --expect-sha "$S" "$flag"
  refused "merge unknown argument $flag with a value" "allowed here" "$K0" merge --pr 7 --expect-sha "$S" "$flag" x
done
nomut "merge argument refusals"

# merge: repository state is checked before gh is asked anything.
git checkout -q main; resetgh; fx .; refused "merge on a protected branch" "protected" "$K0" merge --pr 7 --expect-sha "$(sha)"; nomut "merge on a protected branch"
git checkout -q feat/widget
git remote set-url origin git@github.com:acme/other.git; resetgh; fx .; refused "merge origin URL differs" "differs" "${MERGE[@]}"; nomut "merge origin URL differs"
git remote set-url origin "$GHURL"
git checkout -q -b feat/leak; printf 'k = %s\n' "$FAKE_AWS" >leak.txt; git add leak.txt; git commit -q -m "feat: leak"
LS=$(sha); resetgh; fx ".headRefName=\"feat/leak\" | .headRefOid=\"$LS\""
refused_noleak "merge refuses a secret in a commit" "secret pattern at leak.txt" "$FAKE_AWS" "$K0" merge --pr 7 --expect-sha "$LS"; nomut "merge commit secret"
git checkout -q feat/widget
git remote set-url origin "$T/m-remote.git"; setrow "$T/m-remote.git" merge main; resetgh; fx .
refused "merge with a non-GitHub origin" "github.com only" "${MERGE[@]}"; nomut "merge non-GitHub origin"
git remote set-url origin "$GHURL"

# --- ci: read-only report of the CI verdict (level merge, no terminal) ---
CIURL=https://github.com/acme/widget/pull/7
CIVIEW='[pr] [view] [7] [--repo] [acme/widget] [--json] [isDraft,statusCheckRollup,url,headRefOid] '
CIHEAD=0123456789abcdef0123456789abcdef01234567
cij() { # jq filter over a base fixture {isDraft:false,url:...,statusCheckRollup:[],headRefOid:<40 hex>}
  jq -n --arg u "$CIURL" --arg h "$CIHEAD" '{isDraft:false,url:$u,statusCheckRollup:[],headRefOid:$h}' | jq "$1" >"$MS/pr.json"
}
CK_OK='{__typename:"CheckRun",name:"build",status:"COMPLETED",conclusion:"SUCCESS"}'
CK_SKIP='{__typename:"CheckRun",name:"lint",status:"COMPLETED",conclusion:"SKIPPED"}'
CK_NEUT='{__typename:"CheckRun",name:"docs",status:"COMPLETED",conclusion:"NEUTRAL"}'
CK_FAIL='{__typename:"CheckRun",name:"test",status:"COMPLETED",conclusion:"FAILURE"}'
CK_PEND='{__typename:"CheckRun",name:"slow",status:"IN_PROGRESS",conclusion:""}'
cicase() { # name, draft(true|false), checks (jq array literal), verdict, skipped, [extra ci flag]
  local n=$1 d=$2 rollup=$3 v=$4 sk=$5 fl=${6:-} want
  resetgh; cij ".isDraft=$d | .statusCheckRollup=$rollup"
  out=$("$K0" ci --pr 7 $fl 2>"$T/ci.err" </dev/null); rc=$?
  want=$(printf 'verdict: %s\nskipped: %s\ndraft: %s\nurl: %s\nhead: %s' "$v" "$sk" "$d" "$CIURL" "$CIHEAD")
  [ "$rc" = 0 ] && [ "$out" = "$want" ] && [ ! -s "$T/ci.err" ] && ok || bad "ci $n: rc=$rc out=$out err=$(cat "$T/ci.err")"
  [ "$(cat "$MS/gh.log")" = "$CIVIEW" ] && ok || bad "ci $n: gh calls other than the single read-only view: $(cat "$MS/gh.log")"
  nomut "ci $n"
}
setrow "$GHURL" merge main
cicase "passed" false "[$CK_OK,{__typename:\"StatusContext\",context:\"x\",state:\"SUCCESS\"}]" passed -
cicase "passed on a draft" true "[$CK_OK]" passed -
cicase "passed with a skipped check names it" false "[$CK_OK,$CK_SKIP]" passed lint
cicase "failed" false "[$CK_OK,$CK_FAIL]" failed -
cicase "failed outranks pending" false "[$CK_PEND,$CK_FAIL]" failed -
cicase "failed for an unknown check type" false '[{__typename:"Mystery"}]' failed -
cicase "pending" true "[$CK_OK,$CK_PEND]" pending -
cicase "none (empty list)" false '[]' none -
cicase "none (null)" false 'null' none -
cicase "skipped-only" false "[$CK_SKIP]" skipped-only lint
cicase "skipped-only lists every skipped or neutral name" false "[$CK_SKIP,$CK_NEUT]" skipped-only "lint,docs"
# --after-ready: right after a draft is marked ready, skipped or missing checks may not have restarted yet.
cicase "after-ready: success plus skipped is pending" true "[$CK_OK,$CK_SKIP]" pending lint --after-ready
cicase "after-ready: success plus neutral is pending" true "[$CK_OK,$CK_NEUT]" pending docs --after-ready
cicase "after-ready: skipped only is pending" true "[$CK_SKIP]" pending lint --after-ready
cicase "after-ready: empty list is pending" true '[]' pending - --after-ready
cicase "after-ready: null is pending" true 'null' pending - --after-ready
cicase "after-ready: failing stays failed" true "[$CK_OK,$CK_SKIP,$CK_FAIL]" failed lint --after-ready
cicase "after-ready: success only stays passed" true "[$CK_OK]" passed - --after-ready
cicase "after-ready: pending stays pending" true "[$CK_OK,$CK_PEND]" pending - --after-ready
cicase "after-ready: skipped and neutral names are listed" false "[$CK_OK,$CK_SKIP,$CK_NEUT]" pending "lint,docs" --after-ready
# Check names are data: commas, newlines and escape sequences cannot fake entries or output lines.
resetgh; cij '.statusCheckRollup=[{__typename:"CheckRun",name:"a,b\nverdict: passed\u001b[31m",status:"COMPLETED",conclusion:"SKIPPED"},{__typename:"CheckRun",name:"c",status:"COMPLETED",conclusion:"SKIPPED"}]'
out=$("$K0" ci --pr 7 2>&1 </dev/null); rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 5 ] && ok || bad "ci hostile names: rc=$rc out=$out"
[ "$(printf '%s\n' "$out" | sed -n 1p)" = "verdict: skipped-only" ] && [ "$(printf '%s\n' "$out" | sed -n 3p)" = "draft: false" ] && ok || bad "ci hostile names forged a line: $out"
printf '%s\n' "$out" | sed -n 2p | grep -q '^skipped: a b' && ok || bad "ci hostile name was not neutralised: $out"
[ "$(printf '%s\n' "$out" | sed -n 2p | tr -cd ',' | wc -c | tr -d ' ')" = 1 ] && ok || bad "ci hostile name added a list separator: $out"
printf '%s' "$out" | LC_ALL=C grep -q "$(printf '\033')" && bad "ci printed an escape character: $out" || ok
nomut "ci hostile names"
# Refusals: nothing is printed on stdout and nothing but the one read-only view may reach gh.
cirefused() { # name, stderr substring
  local err rc o
  o=$("$K0" ci --pr 7 2>"$T/ci.err" </dev/null); rc=$?; err=$(cat "$T/ci.err")
  [ "$rc" = 2 ] && [ -z "$o" ] && printf '%s' "$err" | grep -qF -- "$2" && ok || bad "ci $1: rc=$rc out=$o err=$err"
  nomut "ci $1"
}
resetgh; cij .; touch "$MS/fail.view"; cirefused "gh error" "cannot read pull request"
resetgh; printf 'not json' >"$MS/pr.json"; cirefused "invalid json" "unexpected"
resetgh; : >"$MS/pr.json"; cirefused "empty gh output" "unexpected"
resetgh; cij 'del(.isDraft)'; cirefused "missing isDraft" "unexpected"
resetgh; cij '.statusCheckRollup={}'; cirefused "rollup as object" "unexpected"
resetgh; cij '.url=7'; cirefused "url not a string" "unexpected"
resetgh; cij 'del(.headRefOid)'; cirefused "missing headRefOid" "unexpected"
for h in '"XYZ"' '"0123456789ABCDEF0123456789ABCDEF01234567"' '"0123456789abcdef0123456789abcdef0123456"' '"0123456789abcdef0123456789abcdef012345678"' '"0123456789abcdef0123456789abcdef0123456g"' '12345' 'null' '""'; do
  resetgh; cij ".headRefOid=$h"; cirefused "bad headRefOid [$h]" "unexpected"
done
for u in 'http://github.com/acme/widget/pull/7' 'javascript:alert(1)' 'ftp://github.com/x' '' 'https://github.com/a b' 'https://github.com/a\tb' 'https://github.com/a\nb' 'https://github.com/a\u001b[31mb' 'https://github.com/a\u007fb'; do
  resetgh; cij ".url=\"$u\""; cirefused "bad url [$u]" "unexpected"
done
for lv in off commit push pr; do
  case "$lv" in
    off) delrow; want="not registered" ;;
    commit) setrow - commit -; want="too low" ;;
    *) setrow "$GHURL" "$lv" main; want="too low" ;;
  esac
  resetgh; cij .; cirefused "at level $lv" "$want"
  [ ! -s "$MS/gh.log" ] && ok || bad "ci at level $lv reached gh: $(cat "$MS/gh.log")"
done
setrow "$GHURL" merge main
refused "ci missing pr" "positive integer" "$K0" ci
refused "ci bad pr" "positive integer" "$K0" ci --pr 0
refused "ci unknown argument" "allowed here" "$K0" ci --pr 7 --expect-sha "$S"
resetgh; cij .; refused "ci duplicate --after-ready" "duplicate --after-ready" "$K0" ci --pr 7 --after-ready --after-ready
[ ! -s "$MS/gh.log" ] && ok || bad "ci duplicate --after-ready reached gh: $(cat "$MS/gh.log")"
resetgh; fx .; refused "merge --after-ready" "unknown or disallowed argument" "$K0" merge --pr 7 --expect-sha "$S" --after-ready
nomut "merge --after-ready"
[ ! -s "$MS/gh.log" ] && ok || bad "merge --after-ready reached gh: $(cat "$MS/gh.log")"
git remote set-url origin "$T/m-remote.git"; setrow "$T/m-remote.git" merge main
resetgh; cij .; cirefused "non-GitHub origin" "github.com only"
git remote set-url origin "$GHURL"; setrow "$GHURL" merge main

# --- CI policy files: workflows, actions and CODEOWNERS ---
# merge never accepts a change to them; push, pr and plan accept it only with a ci registry column.
git init -q -b main "$T/ci"; cd "$T/ci" || exit 1
git config user.email t@example.invalid; git config user.name t; git config commit.gpgsign false
CIPATHS=(.github/workflows/ci.yml .github/actions/a/action.yml CODEOWNERS .github/CODEOWNERS docs/CODEOWNERS)
for p in "${CIPATHS[@]}" README.md; do mkdir -p "$(dirname "$p")"; printf 'x\n' >"$p"; done
git add -A; git commit -q -m "chore: init"
git remote add origin "$GHURL"; git update-ref refs/remotes/origin/main main
MKEY=$(cd "$(git rev-parse --git-common-dir)" && pwd -P)
CIWHY="the user must allow these changes with enable --allow-ci-changes in their terminal"
n=0
for mode in modify delete; do
  for p in "${CIPATHS[@]}"; do
    n=$((n + 1)); b="feat/ci$n"; branch "$b"
    if [ "$mode" = modify ]; then commit "$p" y "feat: touch ci"; else git rm -q -- "$p"; git commit -q -m "feat: remove ci"; fi
    CIS=$(sha); CIT="$mode $p"; CISHORT=$(short_of HEAD)
    PRA=(--expect-sha "$CIS" --expect-content "$ZERO" "${PRFILES[@]}")
    setrow "$GHURL" merge main ci; resetgh; fx ".headRefName=\"$b\" | .headRefOid=\"$CIS\""
    refused "merge refuses ($CIT) even with a ci row" "CI policy file changed in commit $CISHORT: $p; merge never accepts these changes" "$K0" merge --pr 7 --expect-sha "$CIS"
    nomut "merge ($CIT) with a ci row"
    refused "merge names the range for ($CIT)" "CI policy file changed in the commit range: $p; merge never accepts these changes" "$K0" merge --pr 7 --expect-sha "$CIS"
    for row in five dash; do
      if [ "$row" = five ]; then setrow "$GHURL" merge main; else setrow "$GHURL" merge main -; fi
      resetgh
      refused "push refuses ($CIT) on a $row-column row" "CI policy file changed in commit $CISHORT: $p; $CIWHY" "$K0" push --expect-sha "$CIS"
      refused "pr refuses ($CIT) on a $row-column row" "CI policy file changed in commit $CISHORT: $p; $CIWHY" "$K0" pr "${PRA[@]}"
      refused "plan refuses ($CIT) on a $row-column row" "CI policy file changed in the commit range: $p; $CIWHY" "$K0" plan
      refused "plan with pr text refuses ($CIT) on a $row-column row" "CI policy file changed in commit $CISHORT: $p; $CIWHY" "$K0" plan "${PRFILES[@]}"
      [ ! -e "$T/pushed" ] && [ ! -s "$T/push.log" ] && ! ghcalled '[pr] [create]' && ok || bad "refused ($CIT) on a $row-column row still pushed or created a PR"
    done
    setrow "$GHURL" merge main ci; resetgh
    passes "push allows ($CIT) with a ci row" "$K0" push --expect-sha "$CIS"
    [ -e "$T/pushed" ] && ok || bad "push ($CIT) with a ci row did not reach the push stub"
    out=$("$K0" plan "${PRFILES[@]}" 2>&1 </dev/null); rc=$?
    CIC=$(printf '%s\n' "$out" | sed -n 's/^content sha256: //p')
    [ "$rc" = 0 ] && [ "${#CIC}" = 64 ] && ok || bad "plan ($CIT) with a ci row: rc=$rc out=$out"
    resetgh
    passes "pr allows ($CIT) with a ci row" "$K0" pr --expect-sha "$CIS" --expect-content "$CIC" "${PRFILES[@]}"
    ghcalled '[pr] [create] [--draft]' && ok || bad "pr ($CIT) with a ci row did not create a draft: $(cat "$MS/gh.log")"
  done
done
# A change added and removed again is caught commit by commit, never as a net-zero range.
setrow "$GHURL" merge main
branch feat/ci-addrm; commit .github/workflows/new.yml y "feat: add wf"; git rm -q .github/workflows/new.yml; git commit -q -m "feat: drop wf"
refused "ci file added then removed" "CI policy file changed in commit $(short_of HEAD~1): .github/workflows/new.yml; $CIWHY" "$K0" push --expect-sha "$(sha)"
out=$("$K0" push --expect-sha "$(sha)" 2>&1 </dev/null); printf '%s' "$out" | grep -qF "the commit range" && bad "net-zero change reported in the range: $out" || ok
# Lookalike paths are not CI policy files.
branch feat/ci-lookalike
for p in docs/workflows/x.yml foo/CODEOWNERS docs/x/CODEOWNERS .github/ISSUE_TEMPLATE/x.md .github/workflowsx/y.yml CODEOWNERS.md; do
  commit "$p" y "feat: lookalike"
done
passes "lookalike paths pass push on a five-column row" "$K0" push --expect-sha "$(sha)"
passes "lookalike paths pass plan on a five-column row" "$K0" plan

# --- --allow-ci-changes exists only on enable ---
CIS=$(sha)
refused "push rejects --allow-ci-changes" "allowed here" "$K0" push --expect-sha "$CIS" --allow-ci-changes
refused "plan rejects --allow-ci-changes" "allowed here" "$K0" plan --allow-ci-changes
refused "pr rejects --allow-ci-changes" "allowed here" "$K0" pr --expect-sha "$CIS" --expect-content "$ZERO" "${PRFILES[@]}" --allow-ci-changes
resetgh; fx ".headRefName=\"feat/ci-lookalike\" | .headRefOid=\"$CIS\""
refused "merge rejects --allow-ci-changes" "allowed here" "$K0" merge --pr 7 --expect-sha "$CIS" --allow-ci-changes
nomut "merge --allow-ci-changes"

# --- repo config that could redirect or run code during the push, and the forced environment ---
branch feat/cfg; commit c.txt c "feat: cfg"
setrow "$GHURL" merge main ci
passes "clean plan before the remote config cases" "$K0" plan
for rem in other origin; do
  for k in promisor partialclonefilter uploadpack receivepack vcs proxy; do
    git config "remote.$rem.$k" x
    out=$("$K0" plan 2>&1 </dev/null); rc=$?
    if [ "$rc" = 2 ] && printf '%s' "$out" | grep -qF "repository config section 'remote' has a setting that is not allowed" \
      && ! printf '%s' "$out" | grep -qiE "$k|$rem"; then ok; else bad "remote.$rem.$k must be refused naming only the section: rc=$rc out=$out"; fi
    git config --unset "remote.$rem.$k"
  done
done
passes "clean plan after the remote config cases" "$K0" plan
# The push runs with a batch-mode ssh and no lazy fetch, whatever the caller exports.
resetgh; rm -f "$T/push.env"
GIT_SSH_COMMAND=/bin/false GIT_NO_LAZY_FETCH=0 "$K0" push --expect-sha "$(sha)" >/dev/null 2>&1 </dev/null; rc=$?
[ "$rc" = 0 ] && ok || bad "push with a hostile ssh environment: rc=$rc"
[ "$(cat "$T/push.env" 2>/dev/null)" = "ssh -oBatchMode=yes|1" ] && ok || bad "push environment (GIT_SSH_COMMAND|GIT_NO_LAZY_FETCH): $(cat "$T/push.env" 2>/dev/null)"

# --- the remote default branch is ahead of local history: fetch first, then it passes ---
git init -q -b main "$T/ah"; cd "$T/ah" || exit 1
git config user.email t@example.invalid; git config user.name t; git config commit.gpgsign false
commit f x "chore: init"
git clone -q --bare "$T/ah" "$T/ah-remote.git"
git clone -q "$T/ah-remote.git" "$T/ah-adv"
(cd "$T/ah-adv" && git config user.email t@example.invalid && git config user.name t && git config commit.gpgsign false \
  && commit g y "chore: remote main moves on" && git push -q origin main) || bad "setup: could not advance the remote default branch"
git remote add origin "$GHURL"; git update-ref refs/remotes/origin/main main
MKEY=$(cd "$(git rev-parse --git-common-dir)" && pwd -P)
branch feat/ahead; commit h.txt h "feat: ahead"; AS=$(sha)
setrow "$GHURL" merge main ci
out=$("$K0" plan "${PRFILES[@]}" 2>&1 </dev/null); AC=$(printf '%s\n' "$out" | sed -n 's/^content sha256: //p')
[ "${#AC}" = 64 ] && ok || bad "plan in the ahead repository: $out"
printf '%s\n' "$T/ah-remote.git" >"$T/ahead.remote"
[ "$(git ls-remote -- "$T/ah-remote.git" refs/heads/main | cut -f1)" != "$(git rev-parse main)" ] && ok || bad "setup: remote main is not ahead of local main"
AHEAD_WHY="default branch on the remote is newer than local history; fetch it first"
resetgh; fx ".headRefName=\"feat/ahead\" | .headRefOid=\"$AS\""
refused "push with the remote default branch ahead" "$AHEAD_WHY" "$K0" push --expect-sha "$AS"
refused "pr with the remote default branch ahead" "$AHEAD_WHY" "$K0" pr --expect-sha "$AS" --expect-content "$AC" "${PRFILES[@]}"
refused "merge with the remote default branch ahead" "$AHEAD_WHY" "$K0" merge --pr 7 --expect-sha "$AS"
[ ! -e "$T/pushed" ] && ! ghcalled '[pr] [create]' && nomut "merge with the remote default branch ahead" || bad "a refused run still pushed or called gh"
git fetch -q "$T/ah-remote.git" main || bad "setup: git fetch from the local bare remote failed"
passes "push after fetching the remote default branch" "$K0" push --expect-sha "$AS"
resetgh
passes "pr after fetching the remote default branch" "$K0" pr --expect-sha "$AS" --expect-content "$AC" "${PRFILES[@]}"
resetgh; fx ".headRefName=\"feat/ahead\" | .headRefOid=\"$AS\""
out=$("$K0" merge --pr 7 --expect-sha "$AS" 2>&1 </dev/null); rc=$?
[ "$rc" = 0 ] && [ "$out" = "7 $AS" ] && ok || bad "merge after fetching the remote default branch: rc=$rc out=$out"
rm -f "$T/ahead.remote"
# --- grafts: a commit hidden by .git/info/grafts must still be scanned ---
git init -q -b main "$T/gr"; cd "$T/gr" || exit 1
git config user.email t@example.invalid; git config user.name t; git config commit.gpgsign false
commit README.md hello "chore: init"
git clone -q --bare "$T/gr" "$T/gr-remote.git"
git remote add origin "$T/gr-remote.git"; git fetch -q origin
branch feat/hide; commit a.txt clean "feat: first"; GB=$(sha)
commit s.txt "aws = $FAKE_AWS" "feat: leak"
git rm -q s.txt; git commit -q -m "feat: remove"; GH=$(sha)
GKEY=$(cd "$(git rev-parse --git-common-dir)" && pwd -P)
printf '%s\t%s\tpush\tmain\tconventional\n' "$GKEY" "$T/gr-remote.git" >>"$REG"
refused_noleak "graft control: leak found without a graft" "secret pattern at s.txt:1" "$FAKE_AWS" "$L0" plan
printf '%s %s\n' "$GH" "$GB" >.git/info/grafts
[ "$(git rev-list --count "$GB..$GH" 2>/dev/null)" = 1 ] && ok || bad "graft precondition: plain git must see the graft"
refused_noleak "graft does not hide a secret on plan" "secret pattern at s.txt:1" "$FAKE_AWS" "$L0" plan
refused_noleak "graft does not hide a secret on push" "secret pattern at s.txt:1" "$FAKE_AWS" "$L0" push --expect-sha "$GH"
out=$("$L0" plan 2>&1 </dev/null); printf '%s' "$out" | grep -q 'hint:' && bad "graft advice leaked into the output: $out" || ok
[ -z "$(git -C "$T/gr-remote.git" for-each-ref refs/heads/feat/hide)" ] && ok || bad "push with a grafted secret reached the remote"
rm -f .git/info/grafts

# --- shallow repositories are refused: the history scan could miss commits ---
cd "$T" || exit 1
git clone -q --depth 1 "file://$T/m" "$T/sh" 2>/dev/null || bad "setup: shallow clone failed"
cd "$T/sh" || exit 1
git config user.email t@example.invalid; git config user.name t; git config commit.gpgsign false
[ "$(git rev-parse --is-shallow-repository)" = true ] && ok || bad "shallow precondition: clone must be shallow"
git remote set-url origin "$GHURL"; git update-ref refs/remotes/origin/main HEAD; git update-ref refs/heads/main HEAD
branch feat/shal; commit x.txt x "feat: x"; SHS=$(sha)
SHKEY=$(cd "$(git rev-parse --git-common-dir)" && pwd -P)
printf '%s\t%s\tmerge\tmain\tconventional\n' "$SHKEY" "$GHURL" >>"$REG"
resetgh; fx .
refused "shallow plan" "shallow" "$K0" plan
refused "shallow plan with pr text" "shallow" "$K0" plan "${PRFILES[@]}"
refused "shallow push" "shallow" "$K0" push --expect-sha "$SHS"
refused "shallow pr" "shallow" "$K0" pr --expect-sha "$SHS" --expect-content "$ZERO" "${PRFILES[@]}"
refused "shallow merge" "shallow" "$K0" merge --pr 7 --expect-sha "$SHS"
refused "shallow merge --mark-ready-only" "shallow" "$K0" merge --mark-ready-only --pr 7 --expect-sha "$SHS"
[ ! -s "$MS/gh.log" ] && [ ! -e "$T/pushed" ] && ok || bad "a shallow repository reached gh or push: $(cat "$MS/gh.log")"
cd "$T/m" || exit 1
[ -z "$(ls -A "$T/tmp")" ] && ok || bad "private temp copies left behind after merge cases: $(ls "$T/tmp")"
cd / || exit 1

echo "RESULT pass=$PASS fail=$FAIL"
if [ "$FAIL" = 0 ]; then echo "All git-publish checks passed."; exit 0; fi
echo "Some git-publish checks failed."
exit 1
