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
  # The clean-environment allowlist names GIT_CONFIG_GLOBAL too (so these test settings reach the copy); only the
  # unset list entry must be gone.
  ! grep -qF ' GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM ' "$dest" || patch_fatal "GIT_CONFIG_GLOBAL is still unset by the patched copy"
  [ "$(grep -c 'GIT_CONFIG_GLOBAL' "$dest")" = "$(($(grep -c 'GIT_CONFIG_GLOBAL' "$SRC") - 1))" ] || patch_fatal "the patched copy lost more than the GIT_CONFIG_GLOBAL unset entry"
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
  push)
    # With $T/push.fail present, the push fails and echoes its argv (the URL included) the way git errors may.
    if [ -e "$T/push.fail" ]; then echo "fatal: unable to access \$*" >&2; exit 128; fi
    echo "PUSH \$*" >>"$T/push.log"; printf '%s|%s\n' "\${GIT_SSH_COMMAND:-}" "\${GIT_NO_LAZY_FETCH:-}" >"$T/push.env"; touch "$T/pushed"; exit 0 ;;
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
# The script runs in a clean environment (env -i plus an allowlist), so stubs take their settings from files.
# Fails any git call whose argument text contains the text of $T/gp.fail; everything else goes to the real git.
cat >"$T/stubfail/git" <<E
#!/bin/bash
GP_FAIL=\$(cat "$T/gp.fail" 2>/dev/null)
[ -n "\$GP_FAIL" ] && case "\$*" in *"\$GP_FAIL"*) echo "stub git: forced failure" >&2; exit 1 ;; esac
exec "$REAL_GIT" "\$@"
E
chmod +x "$T/stubfail/git"
# Exits 2 (a grep error, not "no match") when its first argument equals the text of $T/gp.grepfail; otherwise real grep.
REAL_GREP=$(command -v grep)
cat >"$T/stubgrep/grep" <<E
#!/bin/bash
GP_GREP_FAIL=\$(cat "$T/gp.grepfail" 2>/dev/null)
if [ -n "\$GP_GREP_FAIL" ] && [ "\$1" = "\$GP_GREP_FAIL" ]; then echo "stub grep: forced failure" >&2; exit 2; fi
exec "$REAL_GREP" "\$@"
E
chmod +x "$T/stubgrep/grep"

# --- helpers ---
with_trigger() { # file under $T, text, cmd...: runs cmd while the stub trigger file holds the text
  local f="$T/$1" rc
  printf '%s' "$2" >"$f"
  shift 2
  "$@"; rc=$?
  rm -f "$f"
  return "$rc"
}
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
"$C" status | grep -x 'ci changes: refused' >/dev/null && ok || bad "status ci changes default"
"$C" status | grep '^level: push$' >/dev/null && ok || bad "status level"
"$C" status | grep '^default branch: main$' >/dev/null && ok || bad "status default"
"$C" status | grep '^style: conventional$' >/dev/null && ok || bad "status style"
git worktree add -q -b wt/one "$T/wt" main
(cd "$T/wt" && "$C" status | grep '^level: push$' >/dev/null) && ok || bad "worktree status"
refused "status takes no args" "no arguments" "$C" status x
# enable always writes six columns; --allow-ci-changes sets the last one to ci, and re-enabling resets it.
out=$(printf 'remote\n' | "$C" enable push --allow-ci-changes 2>&1); rc=$?
[ "$rc" = 0 ] && printf '%s' "$out" | grep -qF 'CI changes : allowed' && ok || bad "enable with --allow-ci-changes: rc=$rc out=$out"
[ "$(awk -F'\t' '{print NF " " $6}' "$REG")" = "6 ci" ] && ok || bad "registry row with the flag: $(cat "$REG")"
"$C" status | grep -x 'ci changes: allowed' >/dev/null && ok || bad "status after enable --allow-ci-changes"
out=$(printf 'remote\n' | "$C" enable push --style project 2>&1); rc=$?
[ "$rc" = 0 ] && printf '%s' "$out" | grep -qF 'CI changes : refused' && ok || bad "enable without the flag: rc=$rc out=$out"
[ "$(awk -F'\t' '{print NF " " $5 " " $6}' "$REG")" = "6 project -" ] && ok || bad "re-enable did not reset the ci column: $(cat "$REG")"
"$C" status | grep -x 'ci changes: refused' >/dev/null && ok || bad "status after re-enable without the flag"
out=$(printf 'remote\n' | "$C" enable push --allow-ci-changes --allow-ci-changes 2>&1); rc=$?
[ "$rc" = 2 ] && printf '%s' "$out" | grep -qF 'duplicate' && ok || bad "duplicate --allow-ci-changes: rc=$rc out=$out"
# A sixth column other than ci or - makes the row unregistered.
awk -F'\t' -v OFS='\t' '{$6 = "yes"; print}' "$REG" >"$REG.new" && mv "$REG.new" "$REG"
refused "unknown sixth column means unregistered" "not registered" "$C" plan
"$C" status | grep -x 'level: off' >/dev/null && ok || bad "status with an unknown sixth column"
printf 'remote\n' | "$C" enable push >/dev/null 2>&1
"$C" status | grep -x 'level: push' >/dev/null && ok || bad "re-enable after the unknown sixth column"

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
"$C" status | grep '^level: off$' >/dev/null && ok || bad "off after disable"
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
refused "git log failure" "cannot read commit" with_trigger gp.fail "log -1" "$F" plan
refused "git diff --name-only failure" "cannot list files of commit" with_trigger gp.fail "--diff-filter=d" "$F" plan
refused "git diff content failure" "cannot scan commit" with_trigger gp.fail "--unified=0" "$F" plan
refused "git rev-list failure" "REFUSED" with_trigger gp.fail "rev-list" "$F" plan
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
# filter and submodule config is refused only for rows with an account (see the account section); LFS stays refused
git config filter.lfs.clean "git-lfs clean -- %f"
refused "filter.lfs keeps its own message" "Git LFS repositories are not supported" "$C" plan
git config --unset filter.lfs.clean
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
"$C" status | grep '^level: commit$' >/dev/null && ok || bad "status after enable commit without origin"
"$C" status | grep '^default branch: -$' >/dev/null && ok || bad "default branch should be - at level commit"
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
"$C" status | grep '^level: commit$' >/dev/null && ok || bad "status after enable commit with config"
for k in filter.lfs.clean lfs.url credential.helper http.sslVerify; do git config --unset "$k"; done
for kv in filter.lfs.clean=x lfs.url=https://example.invalid/lfs credential.helper=x http.sslVerify=false; do
  git config "${kv%%=*}" "${kv#*=}"
  out=$(printf 'remote\n' | "$C" enable push 2>&1); rc=$?
  [ "$rc" = 2 ] && ok || bad "enable push with ${kv%%=*} set: rc=$rc out=$out"
  git config --unset "${kv%%=*}"
done
"$C" status | grep '^level: commit$' >/dev/null && ok || bad "refused enable push changed the level"
printf 'remote\n' | "$C" enable push >/dev/null 2>&1
"$C" status | grep '^level: push$' >/dev/null && ok || bad "enable push after removing the config"

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
refused "grep error while scanning added lines" "cannot scan commit" with_trigger gp.grepfail -anEi "$H" plan
refused "grep error while scanning the commit message" "secret pattern in the commit message" with_trigger gp.grepfail -aEiq "$H" plan

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
# The push refspec is the verified commit, not a ref name that could move, and the target is the verified
# URL itself, not the remote name `origin` (whose config could be read again after the checks).
grep -qxF "PUSH push --no-follow-tags --recurse-submodules=no -- git@github.com:acme/widget.git $S:refs/heads/feat/pr" "$T/push.log" && ok || bad "push argv: $(cat "$T/push.log")"
grep -qF ' origin ' "$T/push.log" && bad "push still names the remote origin: $(cat "$T/push.log")" || ok
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

# --- chained url rewrites: git rewrites the pushed URL a second time, so the push must be refused ---
# origin uses an alias that one global pushInsteadOf rule turns into the registered URL (the normal case);
# a second global rule that matches the registered URL would send the push to an unchecked URL.
printf '[url "git@github.com:"]\n\tpushInsteadOf = https://alias.invalid/\n' >"$T/chain1.cfg"
{ cat "$T/chain1.cfg"; printf '[url "https://chained.invalid/"]\n\tpushInsteadOf = git@github.com:\n'; } >"$T/chain2.cfg"
git remote set-url origin "https://alias.invalid/acme/widget.git"
rm -f "$T/pushed"; : >"$T/push.log"
out=$(GIT_CONFIG_GLOBAL="$T/chain1.cfg" "$G" pr --expect-sha "$S" --expect-content "$CONTENT" --title-file "$T/title" --body-file "$T/body" 2>&1); [ $? = 0 ] && ok || bad "pr with one global rewrite: $out"
grep -qxF "PUSH push --no-follow-tags --recurse-submodules=no -- git@github.com:acme/widget.git $S:refs/heads/feat/pr" "$T/push.log" && ok || bad "single rewrite push argv: $(cat "$T/push.log")"
rm -f "$T/pushed"; : >"$T/push.log"; : >"$T/gh.log"
out=$(GIT_CONFIG_GLOBAL="$T/chain2.cfg" "$G" pr --expect-sha "$S" --expect-content "$CONTENT" --title-file "$T/title" --body-file "$T/body" 2>&1); rc=$?
[ "$rc" != 0 ] && printf '%s' "$out" | grep -qF "rewrite the push URL again" && ok || bad "chained rewrite not refused: rc=$rc $out"
[ ! -s "$T/push.log" ] && ok || bad "chained rewrite still pushed: $(cat "$T/push.log")"
printf '%s' "$out" | grep -qF -e "chained.invalid" -e "alias.invalid" -e "github.com" && bad "chained rewrite output shows a URL: $out" || ok
git remote set-url origin "git@github.com:acme/widget.git"; touch "$T/pushed"; : >"$T/push.log"; : >"$T/gh.log"

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
"$G" status | grep '^level: push$' >/dev/null && ok || bad "level push after enable"
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
"$C" status | grep '^default branch: stable$' >/dev/null && ok || bad "stable default captured"
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
# The script runs its children in a clean environment, so stubs read their settings from stub.env beside them.
printf 'MS_DIR=%q\n' "$MS" >"$T/stubm/stub.env"
L0="$T/c5/git-publish.sh"; mk_lockcopy "$L0" ""
K0="$T/c6/git-publish.sh"; mk_lockcopy "$K0" "$T/stubm:"
cp "$T/stub/git" "$T/stubm/git"
# Stub gh: logs argv, serves the pr view fixture, fails on demand (fail.view, fail.ready, fail.merge).
cat >"$T/stubm/gh" <<'E'
#!/bin/bash
. "${0%/*}/stub.env"
for a in "$@"; do printf '[%s] ' "$a"; done >>"$MS_DIR/gh.log"; echo >>"$MS_DIR/gh.log"
case "$1 $2" in
  "pr view") [ -e "$MS_DIR/fail.view" ] && { echo "stub view failure" >&2; exit 1; }
    # view.n counts calls. pr.json.N (N = call number) overrides pr.json; past the last one, the last repeats.
    n=$(cat "$MS_DIR/view.n" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" >"$MS_DIR/view.n"
    [ -e "$MS_DIR/fail.view.$n" ] && { echo "stub view failure on call $n" >&2; exit 1; }
    if [ -e "$MS_DIR/pr.json.1" ]; then
      while [ "$n" -gt 1 ] && [ ! -e "$MS_DIR/pr.json.$n" ]; do n=$((n - 1)); done
      cat "$MS_DIR/pr.json.$n"
    else cat "$MS_DIR/pr.json"; fi ;;
  "api "*)
    # Read-only REST fixtures: api.checkruns, api.status, api.log.<job id>; fail.log.<job id> fails that download.
    case "$*" in
      *"/check-runs"*) cat "$MS_DIR/api.checkruns" 2>/dev/null || echo '{"check_runs":[]}' ;;
      *"/actions/jobs/"*"/logs"*) all="$*"; id=${all#*/actions/jobs/}; id=${id%%/*}
        [ -e "$MS_DIR/fail.log.$id" ] && { echo "stub log failure" >&2; exit 1; }
        cat "$MS_DIR/api.log.$id" || exit 1 ;;
      *"/status"*) cat "$MS_DIR/api.status" 2>/dev/null || echo '{"statuses":[]}' ;;
      *) exit 1 ;;
    esac ;;
  "pr ready") [ -e "$MS_DIR/fail.ready" ] && exit 1 ;;
  "pr merge") [ -e "$MS_DIR/fail.merge" ] && exit 1 ;;
  "pr create") : ;;
  *) exit 1 ;;
esac
exit 0
E
# Stub sleep: logs its arguments and returns at once, so no test ever waits.
cat >"$T/stubm/sleep" <<'E'
#!/bin/bash
. "${0%/*}/stub.env"
echo "$*" >>"$MS_DIR/sleep.log"
E
chmod +x "$T/stubm/gh" "$T/stubm/git" "$T/stubm/sleep"
resetgh() { rm -f "$MS"/gh.log "$MS"/fail.* "$MS"/view.n "$MS"/pr.json.* "$MS"/api.*; : >"$MS/gh.log"; : >"$MS/sleep.log"; rm -f "$T/pushed"; : >"$T/push.log"; }
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
  [ ! -s "$MS/sleep.log" ] && ok || bad "ci $n: slept without --wait: $(cat "$MS/sleep.log")"
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
# A skipped check whose name is empty (or only invisible characters) must not look like "no skipped checks".
resetgh; cij '.statusCheckRollup=[{__typename:"CheckRun",name:"",status:"COMPLETED",conclusion:"SKIPPED"},{__typename:"CheckRun",name:"\u200b\u001b",status:"COMPLETED",conclusion:"SKIPPED"},{__typename:"CheckRun",name:"ok",status:"COMPLETED",conclusion:"SUCCESS"}]'
out=$("$K0" ci --pr 7 2>&1 </dev/null); rc=$?
[ "$rc" = 0 ] && [ "$(printf '%s\n' "$out" | sed -n 2p)" = "skipped: (unnamed),(unnamed)" ] && ok || bad "ci empty skipped names: rc=$rc out=$out"
nomut "ci empty skipped names"
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
refused "ci unknown argument" "allowed here" "$K0" ci --pr 7 --bogus
resetgh; cij .; refused "ci duplicate --after-ready" "duplicate --after-ready" "$K0" ci --pr 7 --after-ready --after-ready
[ ! -s "$MS/gh.log" ] && ok || bad "ci duplicate --after-ready reached gh: $(cat "$MS/gh.log")"
resetgh; fx .; refused "merge --after-ready" "unknown or disallowed argument" "$K0" merge --pr 7 --expect-sha "$S" --after-ready
nomut "merge --after-ready"
[ ! -s "$MS/gh.log" ] && ok || bad "merge --after-ready reached gh: $(cat "$MS/gh.log")"
git remote set-url origin "$T/m-remote.git"; setrow "$T/m-remote.git" merge main
resetgh; cij .; cirefused "non-GitHub origin" "github.com only"
git remote set-url origin "$GHURL"; setrow "$GHURL" merge main

# --- ci --wait: polling (stub sleep logs, stub gh serves pr.json.N in sequence), and ci --logs ---
setrow "$GHURL" merge main
sleeps() { grep -c . "$MS/sleep.log"; }
views() { grep -c '^\[pr\] \[view\]' "$MS/gh.log"; }
seqv() { # N draft rollup [headRefOid]: write the Nth pr view response
  jq -n --arg u "$CIURL" --arg h "${4:-$CIHEAD}" --argjson d "$2" "{isDraft:\$d,url:\$u,statusCheckRollup:$3,headRefOid:\$h}" >"$MS/pr.json.$1"
}
wantci() { printf 'verdict: %s\nskipped: %s\ndraft: %s\nurl: %s\nhead: %s' "$1" "$2" "$3" "$CIURL" "${4:-$CIHEAD}"; }
# waitcase name, want verdict, want skipped, want draft, want views, want sleeps, ci args... (fixtures already set)
waitcase() {
  local n=$1 v=$2 sk=$3 d=$4 nv=$5 ns=$6 out rc
  shift 6
  out=$("$K0" ci --pr 7 "$@" 2>"$T/ci.err" </dev/null); rc=$?
  [ "$rc" = 0 ] && [ "$out" = "$(wantci "$v" "$sk" "$d")" ] && ok || bad "ci wait $n: rc=$rc out=$out err=$(cat "$T/ci.err")"
  [ "$(views)" = "$nv" ] && ok || bad "ci wait $n: expected $nv views, got $(views)"
  [ "$(sleeps)" = "$ns" ] && ok || bad "ci wait $n: expected $ns sleeps, got $(sleeps)"
  if [ "$ns" -gt 0 ]; then [ "$(sort -u "$MS/sleep.log")" = 30 ] && ok || bad "ci wait $n: sleep interval is not a constant 30: $(sort -u "$MS/sleep.log" | tr '\n' ' ')"; fi
  nomut "ci wait $n"
}
CKJ_OK="[$CK_OK]"; CKJ_PEND="[$CK_OK,$CK_PEND]"
resetgh; seqv 1 false "$CKJ_PEND"; seqv 2 false "$CKJ_PEND"; seqv 3 false "$CKJ_OK"
waitcase "pending, pending, success" passed - false 3 2 --wait 90
resetgh; seqv 1 false "$CKJ_OK"
waitcase "passed on the first poll never sleeps" passed - false 1 0 --wait 90
resetgh; seqv 1 false "[$CK_OK,$CK_FAIL]"
waitcase "failed on the first poll never sleeps" failed - false 1 0 --wait 90
resetgh; seqv 1 false "$CKJ_PEND"; seqv 2 false "[$CK_OK,$CK_FAIL]"
waitcase "pending then failed stops" failed - false 2 1 --wait 90
resetgh; seqv 1 false "[$CK_SKIP]"
waitcase "skipped-only on the first poll never sleeps" skipped-only lint false 1 0 --wait 90
resetgh; seqv 1 false "$CKJ_PEND"
waitcase "always pending, --wait 60: budget exhausted, 1+floor(60/30) polls, no sleep after the last" pending - false 3 2 --wait 60
resetgh; seqv 1 false "$CKJ_PEND"
waitcase "always pending, --wait 30" pending - false 2 1 --wait 30
resetgh; seqv 1 false "$CKJ_PEND"
waitcase "always pending, --wait 45 (floor)" pending - false 2 1 --wait 45
resetgh; seqv 1 false "$CKJ_PEND"
waitcase "always pending, --wait 480 (max)" pending - false 17 16 --wait 480
# --after-ready: a draft whose skipped checks are not back yet stays pending until they pass.
resetgh; seqv 1 true "[$CK_OK,$CK_SKIP]"; seqv 2 true "$CKJ_OK"
waitcase "after-ready then success" passed - true 2 1 --after-ready --wait 60
resetgh; seqv 1 true "[$CK_SKIP]"
waitcase "after-ready, skipped-only never settles" pending lint true 3 2 --after-ready --wait 60
# none: checks may not be registered yet. ci_wait counts elapsed as max(real time, 30 s per sleep), so stub
# sleeps still advance it: none turns final after the 120 s grace (poll 5), or the budget ends first.
resetgh; seqv 1 false '[]'; seqv 2 false "$CKJ_OK"
waitcase "none then success" passed - false 2 1 --wait 90
resetgh; seqv 1 false '[]'; seqv 2 false "$CKJ_PEND"; seqv 3 false "$CKJ_OK"
waitcase "none then pending then success" passed - false 3 2 --wait 90
resetgh; seqv 1 false '[]'
out=$("$K0" ci --pr 7 --wait 60 2>"$T/ci.err" </dev/null); rc=$?
[ "$rc" = 0 ] && printf '%s\n' "$out" | sed -n 1p | grep -qx 'verdict: none' && [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 5 ] && ok || bad "ci wait none persisting: rc=$rc out=$out err=$(cat "$T/ci.err")"
[ "$(views)" = 3 ] && [ "$(sleeps)" = 2 ] && ok || bad "ci wait none persisting: views=$(views) sleeps=$(sleeps), expected 3 and 2"
nomut "ci wait none persisting"
resetgh; seqv 1 false '[]'
waitcase "none persisting is final after 120 s" none - false 5 4 --wait 480
resetgh; seqv 1 false '[]'
waitcase "after-ready, none persisting stays pending" pending - false 5 4 --after-ready --wait 120
# --expect-sha is checked on every poll.
OTHERHEAD=fedcba9876543210fedcba9876543210fedcba98
resetgh; seqv 1 false "$CKJ_PEND"; seqv 2 false "$CKJ_PEND" "$OTHERHEAD"; seqv 3 false "$CKJ_OK" "$OTHERHEAD"
out=$("$K0" ci --pr 7 --wait 90 --expect-sha "$CIHEAD" 2>"$T/ci.err" </dev/null); rc=$?
[ "$rc" = 2 ] && grep -qF 'pull request head moved' "$T/ci.err" && [ -z "$out" ] && ok || bad "ci wait head moved on poll 2: rc=$rc out=$out err=$(cat "$T/ci.err")"
[ "$(views)" = 2 ] && [ "$(sleeps)" = 1 ] && ok || bad "ci wait head moved: views=$(views) sleeps=$(sleeps), expected 2 and 1"
nomut "ci wait head moved"
resetgh; seqv 1 false "$CKJ_OK" "$OTHERHEAD"
out=$("$K0" ci --pr 7 --expect-sha "$CIHEAD" 2>"$T/ci.err" </dev/null); rc=$?
[ "$rc" = 2 ] && grep -qF 'pull request head moved' "$T/ci.err" && [ -z "$out" ] && ok || bad "ci expect-sha mismatch without --wait: rc=$rc out=$out err=$(cat "$T/ci.err")"
nomut "ci expect-sha mismatch"
resetgh; seqv 1 false "$CKJ_PEND"; seqv 2 false "$CKJ_OK"
waitcase "matching --expect-sha on every poll" passed - false 2 1 --wait 60 --expect-sha "$CIHEAD"
# A gh failure during a poll stops the call.
resetgh; seqv 1 false "$CKJ_PEND"; seqv 2 false "$CKJ_OK"; touch "$MS/fail.view.2"
out=$("$K0" ci --pr 7 --wait 90 2>"$T/ci.err" </dev/null); rc=$?
[ "$rc" != 0 ] && ! printf '%s' "$out" | grep -q '^verdict: passed' && ok || bad "ci wait gh failure on poll 2: rc=$rc out=$out"
[ "$(views)" = 2 ] && [ "$(sleeps)" = 1 ] && ok || bad "ci wait gh failure: views=$(views) sleeps=$(sleeps), expected 2 and 1"
nomut "ci wait gh failure"
# Argument errors: usage error, nothing printed on stdout, no gh call, no sleep.
ciargbad() { # name, ci args...
  local n=$1 out rc
  shift
  resetgh; seqv 1 false "$CKJ_OK"
  out=$("$K0" ci --pr 7 "$@" 2>"$T/ci.err" </dev/null); rc=$?
  [ "$rc" != 0 ] && [ -z "$out" ] && [ -s "$T/ci.err" ] && ok || bad "ci args $n: rc=$rc out=$out err=$(cat "$T/ci.err")"
  [ ! -s "$MS/gh.log" ] && [ ! -s "$MS/sleep.log" ] && ok || bad "ci args $n reached gh or slept: $(cat "$MS/gh.log" "$MS/sleep.log")"
}
for w in 0 29 481 abc 060 030 -30 30.5 1e2 ' 60' ''; do ciargbad "--wait [$w]" --wait "$w"; done
ciargbad "--wait without a value" --wait
ciargbad "duplicate --wait" --wait 60 --wait 90
ciargbad "duplicate --expect-sha" --expect-sha "$CIHEAD" --expect-sha "$CIHEAD"
ciargbad "--logs with --wait" --logs --wait 60
ciargbad "--wait with --logs" --wait 60 --logs
ciargbad "--logs with --after-ready" --logs --after-ready
ciargbad "duplicate --logs" --logs --logs
for h in abc 0123456789ABCDEF0123456789ABCDEF01234567 "${CIHEAD%?}" "${CIHEAD}0" "${CIHEAD%?}g" ''; do ciargbad "--expect-sha [$h]" --expect-sha "$h"; done
# --wait boundaries are accepted.
for w in 30 480; do
  resetgh; seqv 1 false "$CKJ_OK"
  out=$("$K0" ci --pr 7 --wait "$w" 2>&1 </dev/null); rc=$?
  [ "$rc" = 0 ] && ok || bad "ci --wait $w refused: rc=$rc out=$out"
done
# The level still gates the polling form.
for lv in off commit pr; do
  case "$lv" in off) delrow ;; commit) setrow - commit - ;; pr) setrow "$GHURL" pr main ;; esac
  resetgh; seqv 1 false "$CKJ_OK"
  out=$("$K0" ci --pr 7 --wait 60 2>&1 </dev/null); rc=$?
  [ "$rc" = 2 ] && [ ! -s "$MS/gh.log" ] && [ ! -s "$MS/sleep.log" ] && ok || bad "ci --wait at level $lv: rc=$rc out=$out gh=$(cat "$MS/gh.log")"
done
setrow "$GHURL" merge main

# ci --logs: failing job logs, read-only GETs, redacted, bounded.
FAKE_GHP="gh""p_$(printf 'a%.0s' $(seq 1 40))"   # matches the hook's secret pattern; built at runtime
ESC=$(printf '\033')
LOGURL=https://github.com/acme/widget/actions/runs/9/job
EXTURL=https://ci.example.invalid/build/42
cr() { # id name conclusion app-slug url: one check run
  jq -n --argjson i "$1" --arg n "$2" --arg c "$3" --arg a "$4" --arg u "$5" '{id:$i,name:$n,status:"completed",conclusion:$c,html_url:$u,details_url:$u,app:{slug:$a}}'
}
crs() { jq -s '{check_runs:.}'; }
logcmd() { out=$("$K0" ci --pr 7 --logs "$@" 2>"$T/ci.err" </dev/null); rc=$?; }
apimut() { # name: every gh api call is a plain GET (no method override, field, or input flags)
  if grep '^\[api\]' "$MS/gh.log" | sed -e 's/\[--method\] \[GET\]//; s/\[-X\] \[GET\]//' | grep -qE '\[(-X|--method|-f|-F|--field|--raw-field|--input|-d)\]'; then
    bad "$1: non-GET gh api call: $(cat "$MS/gh.log")"
  else ok; fi
  nomut "$1"
}
{ i=0; while [ $i -lt 300 ]; do i=$((i + 1)); case $i in
    250) printf 'deploy key %s\n' "$FAKE_GHP" ;;
    260) printf '%s[31mred text%s[0m\n' "$ESC" "$ESC" ;;
    *) printf 'line %d\n' "$i" ;;
  esac; done; } >"$T/log101"
resetgh; seqv 1 false "[$CK_FAIL]"
{ cr 101 build failure github-actions "$LOGURL/101"; cr 102 test timed_out github-actions "$LOGURL/102"
  cr 103 lint success github-actions "$LOGURL/103"; cr 104 ext-build failure circleci "$EXTURL"; } | crs >"$MS/api.checkruns"
cp "$T/log101" "$MS/api.log.101"; touch "$MS/fail.log.102"
logcmd
[ "$rc" = 0 ] && [ ! -s "$T/ci.err" ] && ok || bad "ci --logs: rc=$rc err=$(cat "$T/ci.err")"
grep -qxF -- "--- job: build (failure) $LOGURL/101" <<<"$out" && ok || bad "ci --logs: missing job header: $out"
grep -qxF 'line 300' <<<"$out" && grep -qxF 'line 101' <<<"$out" && ! grep -qxF 'line 100' <<<"$out" && ok || bad "ci --logs: not the last 200 lines"
grep -qF "$FAKE_GHP" <<<"$out" && bad "ci --logs printed the secret" || ok
grep -qxF '[line redacted by git-publish]' <<<"$out" && ok || bad "ci --logs: secret line was not replaced"
[ "$(grep -cF '[line redacted by git-publish]' <<<"$out")" = 1 ] && ok || bad "ci --logs: redacted more than the secret line"
printf '%s' "$out" | LC_ALL=C grep -q "$ESC" && bad "ci --logs: ANSI escape left in the output" || ok
grep -qxF 'red text' <<<"$out" && ok || bad "ci --logs: ANSI line was not kept as plain text"
grep -qF -- "--- job: test (timed_out) $LOGURL/102" <<<"$out" && grep -qF 'log unavailable' <<<"$out" && ok || bad "ci --logs: failed download must print log unavailable: $out"
grep -qxF "external check: ext-build $EXTURL" <<<"$out" && ok || bad "ci --logs: missing external check line: $out"
grep -qF -- 'job: lint' <<<"$out" && bad "ci --logs listed a passing check" || ok
ghcalled "repos/acme/widget/commits/$CIHEAD/check-runs" && ghcalled "repos/acme/widget/actions/jobs/101/logs" && ok || bad "ci --logs: expected endpoints not called: $(cat "$MS/gh.log")"
ghcalled "repos/acme/widget/commits/$CIHEAD/status" && ok || bad "ci --logs: commit status not read"
ghcalled "actions/jobs/104" && bad "ci --logs downloaded a log of an external check" || ok
[ ! -s "$MS/sleep.log" ] && ok || bad "ci --logs slept"
[ "$(printf '%s\n' "$out" | sed -n 1p)" = "head: $CIHEAD" ] && ok || bad "ci --logs: first line is not the head: $(printf '%s\n' "$out" | sed -n 1p)"
grep -E '^\[api\].*/check-runs' "$MS/gh.log" | grep -qF '[--paginate]' && grep -E '^\[api\].*/check-runs' "$MS/gh.log" | grep -qF 'per_page=100' && ok || bad "ci --logs: check-runs call is not paginated: $(cat "$MS/gh.log")"
grep -E '^\[api\].*/status' "$MS/gh.log" | grep -qF '[--paginate]' && grep -E '^\[api\].*/status' "$MS/gh.log" | grep -qF 'per_page=100' && ok || bad "ci --logs: status call is not paginated: $(cat "$MS/gh.log")"
apimut "ci --logs"
# --expect-sha applies to --logs too.
resetgh; seqv 1 false "[$CK_FAIL]" "$OTHERHEAD"
logcmd --expect-sha "$CIHEAD"
[ "$rc" = 2 ] && grep -qF 'pull request head moved' "$T/ci.err" && ! grep -q '^\[api\]' "$MS/gh.log" && ok || bad "ci --logs --expect-sha mismatch: rc=$rc err=$(cat "$T/ci.err") gh=$(cat "$MS/gh.log")"
nomut "ci --logs head moved"
# A legacy commit status that failed is reported as external; a green rollup run prints nothing.
resetgh; seqv 1 false "[$CK_FAIL]"
printf '{"statuses":[{"context":"ci/legacy","state":"failure","target_url":"%s"}]}' "$EXTURL/legacy" >"$MS/api.status"
{ cr 103 lint success github-actions "$LOGURL/103"; } | crs >"$MS/api.checkruns"
logcmd
[ "$rc" = 0 ] && grep -qxF "external check: ci/legacy $EXTURL/legacy" <<<"$out" && ok || bad "ci --logs legacy status: rc=$rc out=$out"
apimut "ci --logs legacy status"
resetgh; seqv 1 false "$CKJ_OK"
{ cr 103 lint success github-actions "$LOGURL/103"; } | crs >"$MS/api.checkruns"
logcmd
[ "$rc" = 0 ] && ! grep -qF -- '--- job:' <<<"$out" && ! grep -qF 'external check:' <<<"$out" && ok || bad "ci --logs with no failing checks: rc=$rc out=$out"
grep -qxF 'no failing checks' <<<"$out" && ok || bad "ci --logs green run must print no failing checks: $out"
apimut "ci --logs no failing checks"
# At most 5 failing runs are fetched.
resetgh; seqv 1 false "[$CK_FAIL]"
{ for j in 201 202 203 204 205 206 207; do cr $j "job$j" failure github-actions "$LOGURL/$j"; done; } | crs >"$MS/api.checkruns"
for j in 201 202 203 204 205 206 207; do printf 'log of %s\n' "$j" >"$MS/api.log.$j"; done
logcmd
[ "$rc" = 0 ] && [ "$(grep -c -- '^--- job: ' <<<"$out")" = 5 ] && ok || bad "ci --logs: expected exactly 5 job sections, rc=$rc: $(grep -- '^--- job: ' <<<"$out")"
[ "$(grep -c 'actions/jobs/.*/logs' "$MS/gh.log")" = 5 ] && ok || bad "ci --logs: expected 5 log downloads: $(cat "$MS/gh.log")"
grep -qxF 'more failing check runs not shown: 2' <<<"$out" && ok || bad "ci --logs: missing or wrong not-shown count: $out"
apimut "ci --logs five-run cap"
# Total output is capped at 100 KB.
resetgh; seqv 1 false "[$CK_FAIL]"
{ cr 301 big1 failure github-actions "$LOGURL/301"; cr 302 big2 failure github-actions "$LOGURL/302"; } | crs >"$MS/api.checkruns"
BIGLINE=$(printf 'x%.0s' $(seq 1 998))
for j in 301 302; do { i=0; while [ $i -lt 200 ]; do i=$((i + 1)); echo "$BIGLINE"; done; } >"$MS/api.log.$j"; done
logcmd
sz=$(printf '%s\n' "$out" | wc -c | tr -d ' ')
[ "$rc" = 0 ] && [ "$sz" -le 102400 ] && [ "$sz" -gt 50000 ] && ok || bad "ci --logs 100 KB cap: rc=$rc size=$sz"
resetgh; seqv 1 false "[$CK_FAIL]"
{ for j in 311 312 313 314 315; do cr $j "big$j" failure github-actions "$LOGURL/$j"; done; } | crs >"$MS/api.checkruns"
for j in 311 312 313 314 315; do { i=0; while [ $i -lt 200 ]; do i=$((i + 1)); echo "$BIGLINE"; done; } >"$MS/api.log.$j"; done
logcmd
sz=$(printf '%s\n' "$out" | wc -c | tr -d ' ')
[ "$rc" = 0 ] && [ "$sz" -le 102400 ] && grep -qxF '[output truncated by git-publish at 100 KB]' <<<"$out" && ok || bad "ci --logs truncation marker: rc=$rc size=$sz tail=$(printf '%s\n' "$out" | tail -n 2 | cut -c1-80)"
apimut "ci --logs size cap"
# Redaction: private key blocks (even when the tail cuts the BEGIN line), bearer and authorization headers,
# key/token/secret assignments, and invisible characters. Every fixture is built from fragments at runtime.
PEM_B="-----""BEGIN RSA PRIV""ATE KEY-----"; PEM_E="-----""END RSA PRIV""ATE KEY-----"
RV=$(printf 'q%.0s' $(seq 1 24))
{ i=0; while [ $i -lt 300 ]; do i=$((i + 1)); case $i in
    50) printf '%s\n' "$PEM_B" ;;
    [5-9][1-9]|[6-9]0|1[0-2][0-9]|130) printf 'pembody%d\n' "$i" ;;
    131) printf '%s\n' "$PEM_E" ;;
    132) echo 'after pem block' ;;
    200) printf 'Authori''zation: Bea''rer %s\n' "$RV" ;;
    210) printf 'AWS_SECRET_''ACCESS_KEY=%s\n' "$RV" ;;
    220) printf 'MY_TO''KEN: %s\n' "$RV" ;;
    230) printf 'ze\xE2\x80\x8Bro\xEF\xBB\xBFwi\xF3\xA0\x80\x81dth\xE2\x80\xA8x\n' ;;
    *) printf 'line %d\n' "$i" ;;
  esac; done; } >"$T/log401"
resetgh; seqv 1 false "[$CK_FAIL]"
{ cr 401 redact failure github-actions "$LOGURL/401"; } | crs >"$MS/api.checkruns"; cp "$T/log401" "$MS/api.log.401"
logcmd
[ "$rc" = 0 ] && ok || bad "ci --logs redaction: rc=$rc err=$(cat "$T/ci.err")"
grep -qF 'pembody' <<<"$out" && bad "ci --logs: private key body line leaked after the tail cut it" || ok
grep -qF -- "$PEM_E" <<<"$out" && bad "ci --logs: private key END line leaked" || ok
grep -qxF 'after pem block' <<<"$out" && grep -qxF 'line 300' <<<"$out" && grep -qxF 'line 133' <<<"$out" && ok || bad "ci --logs: lines after the key block were not kept"
grep -qF "$RV" <<<"$out" && bad "ci --logs: bearer, assignment or token value leaked" || ok
grep -qxF 'zerowidthx' <<<"$out" && ok || bad "ci --logs: invisible characters not stripped: $(printf '%s' "$out" | grep -a 'zero' | od -c | head -3)"
# 31 key-block lines inside the tail (101..131) plus bearer, AWS and token lines are redacted.
[ "$(grep -cxF '[line redacted by git-publish]' <<<"$out")" = 34 ] && ok || bad "ci --logs redaction: expected 34 redacted lines, got $(grep -cxF '[line redacted by git-publish]' <<<"$out")"
apimut "ci --logs redaction"
# A PGP private key block (header ends in BLOCK) is redacted too.
PGP_B="-----""BEGIN PGP PRIV""ATE KEY BLOCK-----"; PGP_E="-----""END PGP PRIV""ATE KEY BLOCK-----"
{ echo 'before pgp'; printf '%s\n' "$PGP_B"; echo 'pgpbody1'; echo 'pgpbody2'; printf '%s\n' "$PGP_E"; echo 'after pgp'; } >"$MS/api.log.401"
logcmd
[ "$rc" = 0 ] && grep -qxF 'before pgp' <<<"$out" && grep -qxF 'after pgp' <<<"$out" && ok || bad "ci --logs pgp: rc=$rc out=$out"
grep -qF 'pgpbody' <<<"$out" && bad "ci --logs: PGP key body leaked" || ok
grep -qF -- "$PGP_B" <<<"$out" || grep -qF -- "$PGP_E" <<<"$out" && bad "ci --logs: PGP key header or footer leaked" || ok
[ "$(grep -cxF '[line redacted by git-publish]' <<<"$out")" = 4 ] && ok || bad "ci --logs pgp: expected 4 redacted lines"
apimut "ci --logs pgp redaction"

# --- CI/policy files: workflows, actions, CODEOWNERS and Claude Code config (.claude/, CLAUDE.md, .mcp.json) ---
# merge never accepts a change to them; push, pr and plan accept it only with a ci registry column.
git init -q -b main "$T/ci"; cd "$T/ci" || exit 1
git config user.email t@example.invalid; git config user.name t; git config commit.gpgsign false
CIPATHS=(.github/workflows/ci.yml .github/actions/a/action.yml CODEOWNERS .github/CODEOWNERS docs/CODEOWNERS
  .claude/hooks/x.sh .claude/settings.json CLAUDE.md sub/CLAUDE.md CLAUDE.local.md .mcp.json)
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
# Policy paths match case-insensitively and at any depth (nested .claude/, CLAUDE.md, .mcp.json).
# Directories here are new, so a case-insensitive file system cannot fold them into existing ones.
for p in pkg2/.CLAUDE/rules/x.md pkg/.claude/skills/s/SKILL.md other/Claude.Md pkg/.mcp.json pkg/CLAUDE.local.md; do
  branch feat/ci-nested; commit "$p" y "feat: nested policy"
  refused "nested or cased policy path $p on push" "CI policy file changed in commit $(short_of HEAD): $p; $CIWHY" "$K0" push --expect-sha "$(sha)"
done
# Lookalike paths are not CI policy files.
branch feat/ci-lookalike
for p in docs/workflows/x.yml foo/CODEOWNERS docs/x/CODEOWNERS .github/ISSUE_TEMPLATE/x.md .github/workflowsx/y.yml CODEOWNERS.md \
  claude/settings.json .claude-x/y.json CLAUDE.md.bak notCLAUDE.md mcp.json .mcp.json.bak; do
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
# --- cloud-rest backend (CLAUDE_CODE_REMOTE=true): REST via a stub `gh api`, stub git for push, no network ---
# Only `github:<owner>/<repo>` rows count there. GraphQL is blocked in the cloud, so no gh call may be anything
# but `gh api`. The stub git (as in the GitHub PR flow above) records the push; nothing leaves this machine.
CLD_DIR="$T/cld"; export CLD_DIR; mkdir -p "$CLD_DIR" "$T/stubc" "$T/c7" "$T/c8"
printf 'CLD_DIR=%q\n' "$CLD_DIR" >"$T/stubc/stub.env"
CL0="$T/c7/git-publish.sh"; mk_lockcopy "$CL0" "$T/stubc:"   # real require_tty
CP="$T/c8/git-publish.sh"; mk_copy "$CP" "$T/stubc:"         # require_tty stubbed
cp "$T/stub/git" "$T/stubc/git"
cat >"$T/stubc/gh" <<'E'
#!/bin/bash
. "${0%/*}/stub.env"
D="$CLD_DIR"
for a in "$@"; do printf '[%s] ' "$a"; done >>"$D/gh.log"; echo >>"$D/gh.log"
printf '%s|%s\n' "${HOME:-}" "${GH_CONFIG_DIR:-}" >"$D/gh.env"
[ "$1" = api ] || exit 1
case "$*" in
  *"/git/ref/heads/"*)
    # Default: main is the local main, any other branch is at HEAD once the stub git recorded a push.
    # ref.json overrides the answer; fail.ref fails every ref lookup, fail.refbranch only non-main ones.
    all="$*"; b=${all##*/git/ref/heads/}
    [ -e "$D/fail.ref" ] && { echo "stub ref failure" >&2; exit 1; }
    if [ "$b" = main ]; then
      [ -e "$D/ref.json" ] && { cat "$D/ref.json"; exit 0; }
      s=$(git rev-parse refs/heads/main)
    else
      [ -e "$D/fail.refbranch" ] && { echo "stub ref failure" >&2; exit 1; }
      [ -e "$D/refbranch.json" ] && { cat "$D/refbranch.json"; exit 0; }
      [ -e "$D/../pushed" ] || { echo "gh: Not Found (HTTP 404)" >&2; exit 1; }
      s=$(git rev-parse HEAD)
    fi
    printf '{"ref":"refs/heads/%s","node_id":"x","object":{"sha":"%s","type":"commit"}}\n' "$b" "$s" ;;
  *"/files?"*) [ -e "$D/fail.files" ] && { echo "stub files failure" >&2; exit 1; }; cat "$D/files.json" ;;
  *"--method POST"*)
    [ -e "$D/fail.create" ] && { echo "stub create failure" >&2; exit 1; }
    for a in "$@"; do case "$a" in body=@*) cat "${a#body=@}" >"$D/gh.body" ;; esac; done
    cat "$D/create.json" ;;
  *"--method PUT"*)
    if [ -e "$D/merge.err" ]; then cat "$D/merge.err" >&2; exit 1; fi
    echo '{"merged":true}' ;;
  *check-runs*) cat "$D/runs.json" ;;
  *"/status?"*) cat "$D/status.json" ;;
  "api repos/"*"/pulls/"*) [ -e "$D/fail.pr" ] && { echo "stub view failure" >&2; exit 1; }; cat "$D/pr.json" ;;
  *) exit 1 ;;
esac
exit 0
E
chmod +x "$T/stubc/gh" "$T/stubc/git"
CLD=(env CLAUDE_CODE_REMOTE=true "$CP")
LOC=(env -u CLAUDE_CODE_REMOTE "$CP")
cres() {
  rm -f "$CLD_DIR"/gh.log "$CLD_DIR"/gh.body "$CLD_DIR"/gh.env "$CLD_DIR"/fail.* "$CLD_DIR"/merge.err "$CLD_DIR"/ref.json "$CLD_DIR"/refbranch.json "$T/push.fail"
  : >"$CLD_DIR/gh.log"; rm -f "$T/pushed"; : >"$T/push.log"
  printf '[{"filename":"a.txt","status":"added"}]\n' >"$CLD_DIR/files.json"
}
apionly() { # name: every gh call was `gh api` and nothing mentions graphql, pr create or pr merge
  if grep -qv '^\[api\] ' "$CLD_DIR/gh.log" || grep -qiE 'graphql|\[pr\]' "$CLD_DIR/gh.log"; then bad "$1: non-REST gh call: $(cat "$CLD_DIR/gh.log")"; else ok; fi
}
noput() { if grep -qF '[PUT]' "$CLD_DIR/gh.log"; then bad "$1: merge was sent: $(cat "$CLD_DIR/gh.log")"; else ok; fi; }
GROW() { # level [default [style [ci]]]: the only registry row is the github: row
  printf 'github:acme/widget\t-\t%s\t%s\t%s\t%s\n' "$1" "${2:-main}" "${3:-conventional}" "${4:--}" >"$REG"
}
CPROXY='http://local_proxy@127.0.0.1:41234/git/acme/widget'

git init -q -b main "$T/cl"; cd "$T/cl" || exit 1
git config user.email t@example.invalid; git config user.name t; git config commit.gpgsign false
commit README.md hello "chore: init"
git remote add origin "$CPROXY"
CKEY=$(cd "$(git rev-parse --git-common-dir)" && pwd -P)
branch feat/widget; commit a.txt a "feat: add widget"; CS=$(sha)

# status: the backend decides which rows exist.
GROW merge; cres
out=$("${CLD[@]}" status 2>&1); rc=$?
[ "$rc" = 0 ] && [ "$out" = "$(printf 'level: merge\nstyle: conventional\ndefault branch: main\nci changes: refused\naccount: active\nbackend: cloud-rest')" ] && ok || bad "cloud status with a github row: rc=$rc out=$out"
out=$("${LOC[@]}" status 2>&1)
[ "$out" = "$(printf 'level: off\nstyle: -\ndefault branch: -\nci changes: refused\naccount: -\nbackend: local')" ] && ok || bad "local status with only a github row must be off: $out"
printf '%s\thttps://github.com/acme/widget.git\tmerge\tmain\tconventional\t-\n' "$CKEY" >"$REG"
git remote set-url origin https://github.com/acme/widget.git
"${CLD[@]}" status | grep -x 'level: off' >/dev/null && ok || bad "cloud must ignore a local row (a spoofed env gets no local grant): $("${CLD[@]}" status)"
"${CLD[@]}" status | grep -x 'backend: cloud-rest' >/dev/null && ok || bad "cloud status backend line"
refused "cloud ci with only a local row" "not registered" "${CLD[@]}" ci --pr 7
printf '%s\thttps://github.com/acme/widget.git\tpush\tmain\tconventional\t-\ngithub:acme/widget\t-\tmerge\tmain\tconventional\t-\n' "$CKEY" >"$REG"
"${LOC[@]}" status | grep -x 'level: push' >/dev/null && ok || bad "local backend must use its own row, not the github row"
"${CLD[@]}" status | grep -x 'level: merge' >/dev/null && ok || bad "cloud backend must use the github row, not the local row"
GROW commit '-'
"${CLD[@]}" status | grep -x 'level: commit' >/dev/null && ok || bad "cloud commit-level github row with default -"
git remote set-url origin "$CPROXY"

# origin forms: github.com and the loopback proxy are accepted; anything else finds no row.
GROW merge
origin_level() { git remote set-url origin "$1"; "${CLD[@]}" status 2>&1 | sed -n 1p; }
for u in https://github.com/acme/widget https://github.com/acme/widget.git git@github.com:acme/widget.git \
  http://127.0.0.1/git/acme/widget.git https://localhost:8080/git/acme/widget "http://u:${FAKE_PW}${AT}localhost:8080/git/acme/widget.git" \
  'http://[::1]:9/git/acme/widget' "$CPROXY"; do
  [ "$(origin_level "$u")" = "level: merge" ] && ok || bad "cloud origin must be accepted: ${u//$FAKE_PW/<masked>}: $(origin_level "$u")"
done
for u in http://127.0.0.1.evil.com/git/acme/widget http://evil.com/git/acme/widget http://127.0.0.1:1/git/acme/widget/extra \
  'http://127.0.0.1:1/git/acme/widget?x=1' 'http://127.0.0.1:1/git/acme/..' http://127.0.0.1:1/git/acme/widget/ \
  http://127.0.0.1:1/x/git/acme/widget 'http://a@b@127.0.0.1/git/acme/widget' http://127.0.0.1:1/git/acme \
  'http://localhost.evil.com:1/git/acme/widget' https://github.com/acme/other https://github.com/other/widget; do
  [ "$(origin_level "$u")" = "level: off" ] && ok || bad "cloud origin must be rejected: $u: $(origin_level "$u")"
done
git remote set-url origin "$CPROXY"
git config --add remote.origin.pushurl "$CPROXY"; git config --add remote.origin.pushurl https://github.com/acme/widget
[ "$(origin_level "$CPROXY" | head -1)" = "level: off" ] && ok || bad "two push URLs must find no cloud row"
git config --unset-all remote.origin.pushurl
# The userinfo of the proxy URL is never printed.
LEAKURL="http://u:${FAKE_PW}${AT}localhost:8080/git/acme/widget.git"
git remote set-url origin "$LEAKURL"
cres
out=$("${CLD[@]}" status 2>&1); printf '%s' "$out" | grep -qF "$FAKE_PW" && bad "status printed the proxy userinfo" || ok
GROW push
refused_noleak "pr below its level with a userinfo origin" "too low" "$FAKE_PW" "${CLD[@]}" pr --expect-sha "$CS" --expect-content "$ZERO" "${PRFILES[@]}"
git remote set-url origin "$CPROXY"

# invalid github: rows find no registration.
CROWS=(
  'github:acme/widget\t-\tadmin\tmain\tconventional\t-'
  'github:acme/widget\t-\tmerge\tmain\tloose\t-'
  'github:acme/widget\thttps://github.com/acme/widget\tmerge\tmain\tconventional\t-'
  'github:acme/widget\t-\tmerge\tbad;branch\tconventional\t-'
  'github:acme/widget\t-\tmerge\t-\tconventional\t-'
  'github:acme/widget\t-\tmerge\tmain\tconventional\tyes'
  'github:acme/widget/extra\t-\tmerge\tmain\tconventional\t-'
  'github:acme widget\t-\tmerge\tmain\tconventional\t-'
  'github:other/widget\t-\tmerge\tmain\tconventional\t-'
)
for row in "${CROWS[@]}"; do
  printf '%b\n' "$row" >"$REG"; cres
  "${CLD[@]}" status | grep -x 'level: off' >/dev/null && ok || bad "invalid github row must be off: $row"
  refused "ci with invalid github row [$row]" "not registered" "${CLD[@]}" ci --pr 7
  [ ! -s "$CLD_DIR/gh.log" ] && ok || bad "invalid github row reached gh: $row"
done
printf 'github:acme/widget\t-\tmerge\tmain\tconventional\n' >"$REG"
"${CLD[@]}" status | grep -x 'level: merge' >/dev/null && ok || bad "a five-column github row is valid (ci changes default to refused)"

# fixtures for pr, ci and merge
cpj() { # jq filter over the base REST pull request; the body carries the four headings
  jq -n --arg s "$CS" --arg b "$(cat "$T/mbody")" '{state:"open",merged_at:null,draft:false,head:{ref:"feat/widget",sha:$s,repo:{full_name:"acme/widget"}},base:{ref:"main",repo:{full_name:"acme/widget"}},title:"feat: add widget",body:$b,html_url:"https://github.com/acme/widget/pull/7"}' | jq "$1" >"$CLD_DIR/pr.json"
}
R_OK='{"name":"build","status":"completed","conclusion":"success"}'
R_SKIP='{"name":"lint","status":"completed","conclusion":"skipped"}'
R_FAIL='{"name":"test","status":"completed","conclusion":"failure"}'
R_PEND='{"name":"slow","status":"in_progress","conclusion":null}'
S_OK='{"context":"x","state":"success"}'
S_BAD='{"context":"y","state":"failure"}'
S_PEND='{"context":"z","state":"pending"}'
rpage() { printf '{"total_count":1,"check_runs":[%s]}\n' "$1"; }
spage() { printf '{"state":"success","statuses":[%s]}\n' "$1"; }
fixtures() { # filter, runs pages, status pages
  cpj "$1"; printf '%s\n' "$2" >"$CLD_DIR/runs.json"; printf '%s\n' "$3" >"$CLD_DIR/status.json"
}
DEFRUNS=$(rpage "$R_OK"); DEFSTAT=$(spage "$S_OK")
CIURL=https://github.com/acme/widget/pull/7

# pr: draft unless the level is merge, REST only.
GROW merge; cres
out=$("${CLD[@]}" plan "${PRFILES[@]}" 2>&1 </dev/null); rc=$?
CCS=$(printf '%s\n' "$out" | sed -n 's/^content sha256: //p')
[ "$rc" = 0 ] && [ "${#CCS}" = 64 ] && ok || bad "cloud plan with pr text: rc=$rc out=$out"
CPRARGS=(--expect-sha "$CS" --expect-content "$CCS" "${PRFILES[@]}")
printf '{"html_url":"%s"}\n' "$CIURL" >"$CLD_DIR/create.json"
out=$("${CLD[@]}" pr "${CPRARGS[@]}" 2>"$T/cl.err" </dev/null); rc=$?
[ "$rc" = 0 ] && [ "$out" = "$CIURL" ] && ok || bad "cloud pr at level merge: rc=$rc out=$out err=$(cat "$T/cl.err")"
for w in '[api] [--method] [POST] [repos/acme/widget/pulls]' '[-f] [title=feat: add widget]' '[-f] [head=feat/widget]' '[-f] [base=main]' '[-F] [draft=false]'; do
  grep -qF -- "$w" "$CLD_DIR/gh.log" && ok || bad "cloud pr (merge) gh call lacks $w: $(cat "$CLD_DIR/gh.log")"
done
grep -qF '[draft=true]' "$CLD_DIR/gh.log" && bad "cloud pr at level merge opened a draft" || ok
cmp -s "$CLD_DIR/gh.body" "$T/mbody" && ok || bad "cloud pr body differs from the planned body"
grep -qxF "PUSH push --no-follow-tags --recurse-submodules=no -- $CPROXY $CS:refs/heads/feat/widget" "$T/push.log" && ok || bad "cloud pr push argv: $(cat "$T/push.log")"
# Base and pushed branch come from the REST API, not from the agent-reachable loopback remote.
grep -qxF '[api] [repos/acme/widget/git/ref/heads/main] ' "$CLD_DIR/gh.log" && ok || bad "cloud pr did not read the default branch from GitHub: $(cat "$CLD_DIR/gh.log")"
grep -qxF '[api] [repos/acme/widget/git/ref/heads/feat/widget] ' "$CLD_DIR/gh.log" && ok || bad "cloud pr did not verify the pushed branch on GitHub: $(cat "$CLD_DIR/gh.log")"
apionly "cloud pr (merge)"
GROW pr; cres
out=$("${CLD[@]}" pr "${CPRARGS[@]}" 2>"$T/cl.err" </dev/null); rc=$?
[ "$rc" = 0 ] && [ "$out" = "$CIURL" ] && grep -qF '[-F] [draft=true]' "$CLD_DIR/gh.log" && ok || bad "cloud pr at level pr must be a draft: rc=$rc out=$out log=$(cat "$CLD_DIR/gh.log")"
apionly "cloud pr (pr)"
GROW push; cres
refused "cloud pr at level push" "too low" "${CLD[@]}" pr "${CPRARGS[@]}"
[ ! -s "$CLD_DIR/gh.log" ] && [ ! -e "$T/pushed" ] && ok || bad "cloud pr at level push reached gh or push"
GROW pr; cres; touch "$CLD_DIR/fail.create"
refused "cloud pr when gh fails" "gh could not create the pull request" "${CLD[@]}" pr "${CPRARGS[@]}"
for resp in '{"html_url":"http://github.com/acme/widget/pull/7"}' '{"number":7}' 'not json' '{"html_url":"https://github.com/a b"}' \
  '{"html_url":"https://github.com/evil/widget/pull/7"}' '{"html_url":"https://github.com/acme/widget-x/pull/7"}' \
  '{"html_url":"https://github.com/acme/widget/issues/7"}' '{"html_url":"https://github.com/acme/widget/pull/"}' \
  '{"html_url":"https://github.com/acme/widget/pull/7x"}' '{"html_url":"https://github.com/acme/widget/pull/7/files"}' \
  '{"html_url":"https://GITHUB.com/acme/widget/pull/7"}' '{"html_url":"https://github.com.evil.com/acme/widget/pull/7"}' \
  '{"html_url":"https://github.com/acme/widget/pull/7\n8"}' '{"html_url":"https://github.com/acme"}'; do
  cres; printf '%s\n' "$resp" >"$CLD_DIR/create.json"
  refused "cloud pr with response [$resp]" "unexpected pull request response" "${CLD[@]}" pr "${CPRARGS[@]}"
done
# The slug part of html_url compares case-insensitively (GitHub names are case-insensitive).
cres; printf '{"html_url":"https://github.com/ACME/Widget/pull/12"}\n' >"$CLD_DIR/create.json"
out=$("${CLD[@]}" pr "${CPRARGS[@]}" 2>&1 </dev/null); rc=$?
[ "$rc" = 0 ] && [ "$out" = "https://github.com/ACME/Widget/pull/12" ] && ok || bad "cloud pr with a differently cased slug in html_url: rc=$rc out=$out"
# M1: the default branch and the pushed branch are read from GitHub; any failure or mismatch refuses.
cres; printf '{"html_url":"%s"}\n' "$CIURL" >"$CLD_DIR/create.json"; touch "$CLD_DIR/fail.ref"
refused "cloud pr when the default branch ref call fails" "cannot read the default branch from GitHub" "${CLD[@]}" pr "${CPRARGS[@]}"
[ ! -e "$T/pushed" ] && ! grep -qF '[POST]' "$CLD_DIR/gh.log" && ok || bad "cloud pr pushed or created after a ref failure"
cres; printf '{"html_url":"%s"}\n' "$CIURL" >"$CLD_DIR/create.json"; touch "$CLD_DIR/fail.refbranch"
refused "cloud pr when the branch ref call fails" "cannot read the branch from GitHub" "${CLD[@]}" pr "${CPRARGS[@]}"
grep -qF '[POST]' "$CLD_DIR/gh.log" && bad "cloud pr created a PR after a branch ref failure" || ok
cres; printf '{"html_url":"%s"}\n' "$CIURL" >"$CLD_DIR/create.json"
printf '{"ref":"refs/heads/feat/widget","object":{"sha":"2222222222222222222222222222222222222222","type":"commit"}}\n' >"$CLD_DIR/refbranch.json"
refused "cloud pr when GitHub disagrees with the loopback remote" "branch on GitHub is not at --expect-sha" "${CLD[@]}" pr "${CPRARGS[@]}"
grep -qF '[POST]' "$CLD_DIR/gh.log" && bad "cloud pr created a PR though GitHub has another head" || ok
cres; printf '{"html_url":"%s"}\n' "$CIURL" >"$CLD_DIR/create.json"
refused "cloud pr with changed text" "changed since plan" "${CLD[@]}" pr --expect-sha "$CS" --expect-content "$ZERO" "${PRFILES[@]}"

# ci: verdict mapping from check runs and commit statuses, over several pages.
GROW merge
ccase() { # name, draft, runs pages, status pages, verdict, skipped, [flag]
  local n=$1 d=$2 want
  cres; fixtures ".draft=$d" "$3" "$4"
  out=$("${CLD[@]}" ci --pr 7 ${7:-} 2>"$T/cl.err" </dev/null); rc=$?
  want=$(printf 'verdict: %s\nskipped: %s\ndraft: %s\nurl: %s\nhead: %s' "$5" "$6" "$d" "$CIURL" "$CS")
  [ "$rc" = 0 ] && [ "$out" = "$want" ] && [ ! -s "$T/cl.err" ] && ok || bad "cloud ci $n: rc=$rc out=$out err=$(cat "$T/cl.err")"
  apionly "cloud ci $n"
}
ccase "passed" false "$DEFRUNS" "$DEFSTAT" passed -
ccase "passed with only a commit status" false "$(rpage "")" "$DEFSTAT" passed -
ccase "passed on a draft" true "$DEFRUNS" "$DEFSTAT" passed -
ccase "passed names the skipped check" false "$(rpage "$R_OK,$R_SKIP")" "$DEFSTAT" passed lint
ccase "failed check run" false "$(rpage "$R_OK,$R_FAIL")" "$DEFSTAT" failed -
ccase "failed commit status" false "$DEFRUNS" "$(spage "$S_OK,$S_BAD")" failed -
ccase "failed outranks pending" false "$(rpage "$R_PEND,$R_FAIL")" "$DEFSTAT" failed -
ccase "pending check run" false "$(rpage "$R_OK,$R_PEND")" "$DEFSTAT" pending -
ccase "pending commit status" false "$DEFRUNS" "$(spage "$S_PEND")" pending -
ccase "skipped-only" false "$(rpage "$R_SKIP")" "$(spage "")" skipped-only lint
ccase "none" false "$(rpage "")" "$(spage "")" none -
ccase "pagination: a failure on the second check-runs page" false "$(rpage "$R_OK")"$'\n'"$(rpage "$R_FAIL")" "$DEFSTAT" failed -
ccase "pagination: a pending check on the second status page" false "$DEFRUNS" "$(spage "$S_OK")"$'\n'"$(spage "$S_PEND")" pending -
ccase "pagination: both pages succeed" false "$(rpage "$R_OK")"$'\n'"$(rpage "$R_OK")" "$DEFSTAT"$'\n'"$DEFSTAT" passed -
ccase "after-ready: success plus skipped is pending" true "$(rpage "$R_OK,$R_SKIP")" "$DEFSTAT" pending lint --after-ready
ccase "after-ready: skipped only is pending" true "$(rpage "$R_SKIP")" "$(spage "")" pending lint --after-ready
ccase "after-ready: nothing yet is pending" true "$(rpage "")" "$(spage "")" pending - --after-ready
ccase "after-ready: failing stays failed" true "$(rpage "$R_FAIL")" "$DEFSTAT" failed - --after-ready
ccase "after-ready: success only stays passed" true "$DEFRUNS" "$DEFSTAT" passed - --after-ready
# The exact, read-only REST calls.
cres; fixtures . "$DEFRUNS" "$DEFSTAT"; "${CLD[@]}" ci --pr 7 >/dev/null 2>&1 </dev/null
want=$(printf '[api] [repos/acme/widget/pulls/7] \n[api] [--paginate] [repos/acme/widget/commits/%s/check-runs?per_page=100] \n[api] [--paginate] [repos/acme/widget/commits/%s/status?per_page=100] ' "$CS" "$CS")
[ "$(cat "$CLD_DIR/gh.log")" = "$want" ] && ok || bad "cloud ci gh calls: $(cat "$CLD_DIR/gh.log")"
# Refusals.
cirefuse() { # name, stderr substring
  local o err rc
  o=$("${CLD[@]}" ci --pr 7 2>"$T/cl.err" </dev/null); rc=$?; err=$(cat "$T/cl.err")
  [ "$rc" = 2 ] && [ -z "$o" ] && printf '%s' "$err" | grep -qF -- "$2" && ok || bad "cloud ci $1: rc=$rc out=$o err=$err"
  apionly "cloud ci $1"
}
cres; fixtures . "$DEFRUNS" "$DEFSTAT"; touch "$CLD_DIR/fail.pr"; cirefuse "gh error" "cannot read pull request"
cres; fixtures '.head.sha="0123456789ABCDEF0123456789ABCDEF01234567"' "$DEFRUNS" "$DEFSTAT"; cirefuse "uppercase head sha" "cannot read pull request"
cres; fixtures '.head.sha="abc"' "$DEFRUNS" "$DEFSTAT"; cirefuse "short head sha" "cannot read pull request"
cres; fixtures . 'not json' "$DEFSTAT"; cirefuse "invalid check-runs json" "cannot read pull request"
cres; fixtures . "$DEFRUNS" '{"statuses":"x"}'; cirefuse "bad statuses shape" "cannot read pull request"
cres; fixtures '.html_url="http://github.com/acme/widget/pull/7"' "$DEFRUNS" "$DEFSTAT"; cirefuse "non-https url" "unexpected"
cres; fixtures '.draft="no"' "$DEFRUNS" "$DEFSTAT"; cirefuse "draft not a boolean" "unexpected"
for lv in pr push commit; do
  if [ "$lv" = commit ]; then GROW commit '-'; else GROW "$lv"; fi
  cres; fixtures . "$DEFRUNS" "$DEFSTAT"
  refused "cloud ci at level $lv" "too low" "${CLD[@]}" ci --pr 7
  [ ! -s "$CLD_DIR/gh.log" ] && ok || bad "cloud ci at level $lv reached gh"
done
GROW merge

# merge: REST squash merge guarded by --expect-sha.
CMERGE=("${CLD[@]}" merge --pr 7 --expect-sha "$CS")
CMARK=("${CLD[@]}" merge --mark-ready-only --pr 7 --expect-sha "$CS")
cres; fixtures . "$DEFRUNS" "$DEFSTAT"
out=$("${CMERGE[@]}" 2>"$T/cl.err" </dev/null); rc=$?
[ "$rc" = 0 ] && [ "$out" = "7 $CS" ] && [ ! -s "$T/cl.err" ] && ok || bad "cloud merge: rc=$rc out=$out err=$(cat "$T/cl.err")"
grep -qxF "[api] [--method] [PUT] [repos/acme/widget/pulls/7/merge] [-f] [merge_method=squash] [-f] [sha=$CS] [-f] [commit_title=feat: add widget] [-f] [commit_message=] " "$CLD_DIR/gh.log" && ok || bad "cloud merge PUT argv: $(cat "$CLD_DIR/gh.log")"
want=$(printf '[api] [repos/acme/widget/git/ref/heads/main] \n[api] [repos/acme/widget/pulls/7] \n[api] [--paginate] [repos/acme/widget/commits/%s/check-runs?per_page=100] \n[api] [--paginate] [repos/acme/widget/commits/%s/status?per_page=100] \n[api] [--paginate] [repos/acme/widget/pulls/7/files?per_page=100] ' "$CS" "$CS")
[ "$(sed '$d' "$CLD_DIR/gh.log")" = "$want" ] && [ "$(wc -l <"$CLD_DIR/gh.log" | tr -d ' ')" = 6 ] && ok || bad "cloud merge made unexpected gh calls: $(cat "$CLD_DIR/gh.log")"
apionly "cloud merge"
cmr() { # name, stderr substring, fixture filter, [runs pages], [status pages]
  cres; fixtures "$3" "${4:-$DEFRUNS}" "${5:-$DEFSTAT}"
  refused "cloud merge $1" "$2" "${CMERGE[@]}"; noput "cloud merge $1"; apionly "cloud merge $1"
}
cres; fixtures . "$DEFRUNS" "$DEFSTAT"; printf 'gh: Head branch was modified. Review and try the merge again. (HTTP 409)\n' >"$CLD_DIR/merge.err"
refused "cloud merge 409" "pull request head no longer matches --expect-sha; GitHub refused the merge" "${CMERGE[@]}"; apionly "cloud merge 409"
cres; fixtures . "$DEFRUNS" "$DEFSTAT"; printf 'gh: Pull Request is not mergeable (HTTP 405)\n' >"$CLD_DIR/merge.err"
refused "cloud merge 405" "GitHub reports the pull request is not mergeable" "${CMERGE[@]}"
cres; fixtures . "$DEFRUNS" "$DEFSTAT"; printf 'gh: Server Error (HTTP 500)\n' >"$CLD_DIR/merge.err"
refused "cloud merge other failure" "gh could not merge the pull request" "${CMERGE[@]}"
for lv in off commit push pr; do
  case "$lv" in
    off) printf '' >"$REG"; want="not registered" ;;
    commit) GROW commit '-'; want="too low" ;;
    *) GROW "$lv"; want="too low" ;;
  esac
  cres; fixtures . "$DEFRUNS" "$DEFSTAT"
  refused "cloud merge at level $lv" "$want" "${CMERGE[@]}"
  [ ! -s "$CLD_DIR/gh.log" ] && ok || bad "cloud merge at level $lv reached gh"
done
GROW merge
cres; fixtures . "$DEFRUNS" "$DEFSTAT"
refused "cloud merge sha mismatch with HEAD" "does not match" "${CLD[@]}" merge --pr 7 --expect-sha 1111111111111111111111111111111111111111
[ ! -s "$CLD_DIR/gh.log" ] && ok || bad "cloud merge with a wrong --expect-sha reached gh"
cmr "pr head sha differs" "does not match --expect-sha" '.head.sha="2222222222222222222222222222222222222222"'
cmr "wrong head branch" "head branch differs" '.head.ref="feat/other"'
cmr "wrong base" "registered default" '.base.ref="develop"'
cmr "cross-repository" "cross-repository" '.head.repo.full_name="evil/widget"'
cmr "deleted fork head" "cross-repository" '.head.repo=null'
cmr "closed" "not open" '.state="closed"'
cmr "merged" "not open" '.state="closed" | .merged_at="2026-01-01T00:00:00Z"'
cmr "draft" "pull request is a draft" '.draft=true'
cmr "ci failing" "CI checks are failing" . "$(rpage "$R_FAIL")" "$DEFSTAT"
cmr "ci failing status" "CI checks are failing" . "$DEFRUNS" "$(spage "$S_BAD")"
cmr "ci pending" "still pending" . "$(rpage "$R_PEND")" "$DEFSTAT"
cmr "ci none" "no CI checks" . "$(rpage "")" "$(spage "")"
cmr "ci skipped-only" "every check was skipped or neutral" . "$(rpage "$R_SKIP")" "$(spage "")"
cmr "ci failure on the second page" "CI checks are failing" . "$(rpage "$R_OK")"$'\n'"$(rpage "$R_FAIL")" "$DEFSTAT"
cmr "null body has no headings" "PR body is missing the heading" '.body=null'
cmr "title not conventional" "Conventional" '.title="add widget"'
cres; fixtures . "$DEFRUNS" "$DEFSTAT"; touch "$CLD_DIR/fail.pr"
refused "cloud merge gh view error" "cannot read pull request" "${CMERGE[@]}"; noput "cloud merge gh view error"

# M1: the merge base and the file list come from the REST API. The local commits only touch a.txt, so the
# loopback remote and the local scan see nothing; GitHub's view of the pull request is what is checked.
cmf() { # name, stderr substring, files.json content (or fail), [file in CLD_DIR to write, its content]
  cres; fixtures . "$DEFRUNS" "$DEFSTAT"
  if [ "$3" = fail ]; then touch "$CLD_DIR/fail.files"; else printf '%s\n' "$3" >"$CLD_DIR/files.json"; fi
  [ -z "${4:-}" ] || printf '%s\n' "$5" >"$CLD_DIR/$4"
  refused "cloud merge $1" "$2" "${CMERGE[@]}"; noput "cloud merge $1"; apionly "cloud merge $1"
}
PFWHY="merge never accepts these changes"
for p in .github/workflows/x.yml .claude/hooks/x.sh .claude/settings.json CLAUDE.md sub/CLAUDE.md CLAUDE.local.md .mcp.json CODEOWNERS; do
  cmf "files list names $p" "CI policy file changed in pull request 7: $p; $PFWHY" "[{\"filename\":\"a.txt\"},{\"filename\":\"$p\",\"status\":\"modified\"}]"
done
cmf "rename away from a policy file" "CI policy file changed in pull request 7: .claude/settings.json; $PFWHY" '[{"filename":"moved.json","previous_filename":".claude/settings.json","status":"renamed"}]'
cmf "policy file on the second page" "CI policy file changed in pull request 7: .github/workflows/x.yml; $PFWHY" "$(printf '[{"filename":"a.txt"}]\n[{"filename":".github/workflows/x.yml"}]')"
GROW merge main conventional ci
cmf "policy file even with a ci row" "CI policy file changed in pull request 7: .github/workflows/x.yml; $PFWHY" '[{"filename":".github/workflows/x.yml"}]'
GROW merge
cmf "files list call fails" "cannot list the files of pull request 7" fail
for fj in 'not json' '' '{"filename":"a.txt"}' '[{"filename":7}]' '[{"name":"a.txt"}]' '[{"filename":"a.txt","previous_filename":3}]' '["a.txt"]'; do
  cmf "files list shape [$fj]" "unexpected pull request file list" "$fj"
done
cmf "files list at the GitHub cap" "lists 3000 files" "$(jq -nc '[range(3000) | {filename: "f\(.).txt"}]')"
cres; fixtures . "$DEFRUNS" "$DEFSTAT"; jq -nc '[range(2999) | {filename: "f\(.).txt"}]' >"$CLD_DIR/files.json"
out=$("${CMERGE[@]}" 2>&1 </dev/null); rc=$?
[ "$rc" = 0 ] && [ "$out" = "7 $CS" ] && ok || bad "cloud merge with 2999 files must pass: rc=$rc out=$out"
cres; fixtures . "$DEFRUNS" "$DEFSTAT"; printf '[]\n' >"$CLD_DIR/files.json"
passes "cloud merge with an empty files list" "${CMERGE[@]}"
cres; fixtures . "$DEFRUNS" "$DEFSTAT"; printf '[{"filename":"claude/settings.json"},{"filename":"CLAUDE.md.bak"},{"filename":".github/ISSUE_TEMPLATE/x.md"}]\n' >"$CLD_DIR/files.json"
passes "cloud merge with lookalike paths in the files list" "${CMERGE[@]}"
# The default branch ref: any failure or odd answer refuses before the pull request is read.
cres; fixtures . "$DEFRUNS" "$DEFSTAT"; touch "$CLD_DIR/fail.ref"
refused "cloud merge when the ref call fails" "cannot read the default branch from GitHub" "${CMERGE[@]}"; noput "cloud merge ref failure"
grep -qF 'pulls/7' "$CLD_DIR/gh.log" && bad "cloud merge read the pull request after a ref failure" || ok
MAINSHA=$(git rev-parse main)
UPMAIN=$(printf '%s' "$MAINSHA" | tr 'a-f' 'A-F')
for rj in '{"ref":"refs/heads/other","object":{"sha":"'"$MAINSHA"'","type":"commit"}}' \
  '{"ref":"refs/heads/main","object":{"sha":"'"$MAINSHA"'","type":"tag"}}' \
  '{"ref":"refs/heads/main","object":{"sha":"'"$UPMAIN"'","type":"commit"}}' \
  '{"ref":"refs/heads/main","object":{"sha":"abc","type":"commit"}}' \
  '[{"ref":"refs/heads/main","object":{"sha":"'"$MAINSHA"'","type":"commit"}}]' \
  '{"ref":"refs/heads/main","object":null}' 'not json'; do
  cmf "ref answer [$rj]" "cannot read the default branch from GitHub" '[]' ref.json "$rj"
done
cmf "ref at a commit missing locally" "default branch on the remote is newer than local history" '[]' ref.json \
  '{"ref":"refs/heads/main","object":{"sha":"3333333333333333333333333333333333333333","type":"commit"}}'
# Moving the local remote-tracking ref cannot shift the base: GitHub's main is used.
git update-ref refs/remotes/origin/main HEAD
cres; fixtures . "$DEFRUNS" "$DEFSTAT"
passes "cloud merge ignores a moved local origin/main" "${CMERGE[@]}"
git update-ref -d refs/remotes/origin/main

# L4: GitHub owner/repo names are case-insensitive; two rows that match that way are ambiguous.
printf 'github:ACME/Widget\t-\tmerge\tmain\tconventional\t-\n' >"$REG"
"${CLD[@]}" status | grep -x 'level: merge' >/dev/null && ok || bad "cloud row with a differently cased slug must match"
for u in https://github.com/Acme/WIDGET.git http://local_proxy@127.0.0.1:41234/git/ACME/widget; do
  git remote set-url origin "$u"
  "${CLD[@]}" status | grep -x 'level: merge' >/dev/null && ok || bad "cloud origin with a differently cased slug must match: $u"
done
git remote set-url origin "$CPROXY"
printf 'github:acme/widget\t-\tmerge\tmain\tconventional\t-\ngithub:ACME/widget\t-\tpush\tmain\tconventional\t-\n' >"$REG"
cres
refused "ambiguous github rows (case)" "more than one github: registry row" "${CLD[@]}" status
refused "ambiguous github rows block merge" "more than one github: registry row" "${CMERGE[@]}"
[ ! -s "$CLD_DIR/gh.log" ] && [ ! -e "$T/pushed" ] && ok || bad "ambiguous rows reached gh or push"
printf 'github:acme/widget\t-\tmerge\tmain\tconventional\t-\ngithub:acme/widget\t-\tmerge\tmain\tconventional\t-\n' >"$REG"
refused "ambiguous github rows (exact duplicate)" "more than one github: registry row" "${CLD[@]}" status
printf 'github:acme/widget\t-\tmerge\tmain\tconventional\t-\ngithub:acme/widget2\t-\tpush\tmain\tconventional\t-\n%s\thttps://github.com/acme/widget.git\tpush\tmain\tconventional\t-\n' "$CKEY" >"$REG"
"${CLD[@]}" status | grep -x 'level: merge' >/dev/null && ok || bad "a different repo row and a local row are not ambiguous"
GROW merge

# L3: the push goes to the verified URL; a failing push never prints the URL's userinfo.
git remote set-url origin "$LEAKURL"
cres; touch "$T/push.fail"
out=$("${CLD[@]}" pr "${CPRARGS[@]}" 2>&1 </dev/null); rc=$?
[ "$rc" != 0 ] && printf '%s' "$out" | grep -qF '://***@localhost:8080/git/acme/widget.git' && ok || bad "failed push output: rc=$rc out=${out//$FAKE_PW/<masked>}"
printf '%s' "$out" | grep -qF "$FAKE_PW" && bad "failed push printed the URL userinfo" || ok
grep -qF '[POST]' "$CLD_DIR/gh.log" && bad "cloud pr created a PR after a failed push" || ok
git remote set-url origin "$CPROXY"

# L2: gh runs with the passwd home and its gh config dir, whatever the caller exports.
cres; fixtures . "$DEFRUNS" "$DEFSTAT"
HOME=/nonexistent-home GH_CONFIG_DIR=/nonexistent-gh "${CLD[@]}" ci --pr 7 >/dev/null 2>&1 </dev/null
GHENV=$(cat "$CLD_DIR/gh.env" 2>/dev/null)
case "$GHENV" in
  /nonexistent*|*'|/nonexistent'*|'|'*|*'|') bad "gh environment was not pinned: $GHENV" ;;
  *) [ "${GHENV#*|}" = "${GHENV%%|*}/.config/gh" ] && [ -d "${GHENV%%|*}" ] && ok || bad "gh environment: $GHENV" ;;
esac
# mark-ready needs GraphQL, which the cloud blocks.
CMARKWHY="cannot mark ready in cloud (GraphQL blocked); click Ready for review on GitHub, then run ci --pr 7 --after-ready --wait 480"
cres; fixtures '.draft=true' "$DEFRUNS" "$DEFSTAT"
refused "cloud mark-ready-only on a draft" "$CMARKWHY" "${CMARK[@]}"; noput "cloud mark-ready-only"; apionly "cloud mark-ready-only"
cres; fixtures '.draft=false' "$DEFRUNS" "$DEFSTAT"
refused "cloud mark-ready-only on a non-draft" "applies to drafts only" "${CMARK[@]}"; apionly "cloud mark-ready-only non-draft"

# enable and disable stay local: they need a terminal, and never touch github: rows.
GROW merge; cp "$REG" "$T/reg.cloud"
for sub in "enable commit" "disable"; do
  err=$(printf 'widget\n' | env CLAUDE_CODE_REMOTE=true "$CL0" $sub 2>&1 >/dev/null); rc=$?
  [ "$rc" = 2 ] && printf '%s' "$err" | grep -qF "own terminal" && ok || bad "cloud $sub without a terminal: rc=$rc err=$err"
done
cmp -s "$REG" "$T/reg.cloud" && ok || bad "refused cloud enable/disable changed the registry"
out=$(printf 'widget\n' | "${CLD[@]}" enable commit 2>&1); rc=$?
[ "$rc" = 0 ] && ok || bad "enable commit with CLAUDE_CODE_REMOTE set: rc=$rc out=$out"
grep -qxF "$(cat "$T/reg.cloud")" "$REG" && ok || bad "enable dropped the github row: $(cat "$REG")"
[ "$(awk -F'\t' -v k="$CKEY" '$1 == k {print $3}' "$REG")" = commit ] && ok || bad "enable did not write the local row: $(cat "$REG")"
"${CLD[@]}" status | grep -x 'level: merge' >/dev/null && ok || bad "cloud status after enable must still read the github row"
"${LOC[@]}" status | grep -x 'level: commit' >/dev/null && ok || bad "local status after enable must read the local row"
out=$("${CLD[@]}" disable 2>&1); rc=$?
[ "$rc" = 0 ] && grep -qxF "$(cat "$T/reg.cloud")" "$REG" && ! grep -qF "$CKEY" "$REG" && ok || bad "disable must drop only the local row: rc=$rc out=$out reg=$(cat "$REG")"
"${CLD[@]}" status | grep -x 'level: merge' >/dev/null && ok || bad "cloud status after disable must still read the github row"
cd "$T/m" || exit 1
[ -z "$(ls -A "$T/tmp")" ] && ok || bad "private temp copies left behind after merge cases: $(ls "$T/tmp")"
# --- per-repository GitHub account (column 7 of the registry row) ---
# Stub gh and git live in $T/stubacct and are driven by files in $AD. gh logs argv to gh.log and the GH_TOKEN
# it was given (or <unset>) to gh.env, one line per call. git logs the argv of push and ls-remote to git.log,
# records the environment of each call in git.env, and runs the real `git credential fill` with that very
# environment for three hosts. Pushes and ls-remote are served from a local bare repository. No network.
AD="$T/acct"; mkdir -p "$AD" "$T/stubacct" "$T/c9"
export AD_DIR="$AD" AD_REAL_GIT="$REAL_GIT"
printf 'AD_DIR=%q\nAD_REAL_GIT=%q\n' "$AD" "$REAL_GIT" >"$T/stubacct/stub.env"
A="$T/c9/git-publish.sh"; mk_copy "$A" "$T/stubacct:"
ATOK="ghp_""FAKEACCOUNTTOKEN0123456789"
cat >"$T/stubacct/gh" <<'E'
#!/bin/bash
. "${0%/*}/stub.env"
D="$AD_DIR"
for a in "$@"; do printf '[%s] ' "$a"; done >>"$D/gh.log"; echo >>"$D/gh.log"
printf '%s\n' "${GH_TOKEN:-<unset>}" >>"$D/gh.env"
pwd -P >>"$D/gh.cwd"
printf '%s|%s\n' "${DBUS_SESSION_BUS_ADDRESS:-<unset>}" "${XDG_RUNTIME_DIR:-<unset>}" >>"$D/gh.bus"
# Like gh, run git in the working directory: a filter configured for a repository there would run now.
[ -f README.md ] && "$AD_REAL_GIT" hash-object README.md >/dev/null 2>&1
case "$1 $2" in
  "auth token")
    if [ "$3" = --help ]; then
      if [ -e "$D/help.nouser" ]; then echo "Usage: gh auth token [flags]"; else echo "Usage: gh auth token [flags]  --hostname string  --user string"; fi
      exit 0
    fi
    [ -e "$D/tok.fail" ] && { echo "no account" >&2; exit 1; }
    cat "$D/tok.out" ;;
  "api user") [ -e "$D/user.fail" ] && { echo "bad credentials" >&2; exit 1; }; cat "$D/user.out" ;;
  "api repos/"*) [ -e "$D/perm.fail" ] && { echo "not found" >&2; exit 1; }; cat "$D/perm.out" ;;
  "pr create") [ -e "$D/create.fail" ] && exit 1 ;;
  "pr view") cat "$D/pr.json" ;;
  "pr ready"|"pr merge") : ;;
  *) exit 1 ;;
esac
exit 0
E
cat >"$T/stubacct/git" <<'E'
#!/bin/bash
. "${0%/*}/stub.env"
D="$AD_DIR"
probe() { # $1 command name
  { echo "== $1"; env | grep -E '^(SSL_CERT_FILE|SSL_CERT_DIR|CURL_CA_BUNDLE|GH_TOKEN|GITHUB_TOKEN|GP_TOKEN|GIT_CONFIG_COUNT|GIT_CONFIG_KEY_1[0-3]|GIT_CONFIG_VALUE_1[0-3]|SSH_ASKPASS|GIT_ASKPASS|GIT_TRACE[A-Z0-9_]*|BASH_ENV|BASH_FUNC_[^=]*|DEBUG|SSLKEYLOGFILE|DYLD_[A-Z_]*|LD_[A-Z_]*|HTTPS_PROXY|https_proxy|HTTP_PROXY|http_proxy|NO_PROXY|DBUS_SESSION_BUS_ADDRESS|XDG_RUNTIME_DIR)='; } >>"$D/git.env"
  for h in github.com example.com github.com.evil.test; do
    printf 'protocol=https\nhost=%s\n\n' "$h" | "$AD_REAL_GIT" credential fill >"$D/cred.$1.$h" 2>&1
  done
}
case "$1" in
  push)
    echo "$*" >>"$D/git.log"
    [ -e "$D/push.fail" ] && { echo "fatal: unable to access $*" >&2; exit 128; }
    probe push
    exec "$AD_REAL_GIT" push --no-follow-tags -- "$(cat "$D/bare")" "${@: -1}" ;;
  ls-remote)
    echo "$*" >>"$D/git.log"
    probe ls-remote
    if [ "$2" = --symref ]; then printf 'ref: refs/heads/main\tHEAD\n'; exit 0; fi
    exec "$AD_REAL_GIT" ls-remote -- "$(cat "$D/bare")" "$4" ;;
esac
exec "$AD_REAL_GIT" "$@"
E
chmod +x "$T/stubacct/gh" "$T/stubacct/git"

areset() { # stub state back to a healthy account; logs and probes cleared
  rm -f "$AD"/gh.log "$AD"/gh.env "$AD"/gh.cwd "$AD"/gh.bus "$AD"/git.log "$AD"/git.env "$AD"/cred.* "$AD"/*.fail "$AD"/help.nouser
  : >"$AD/gh.log"; : >"$AD/gh.env"; : >"$AD/gh.cwd"; : >"$AD/gh.bus"; : >"$AD/git.log"; : >"$AD/git.env"
  printf '%s\n' "$ATOK" >"$AD/tok.out"; printf 'acctuser\n' >"$AD/user.out"; printf 'true\n' >"$AD/perm.out"
}
arun() { AOUT=$("$@" 2>&1 </dev/null); ARC=$?; }
noleak() { # name, secrets...: none may appear in the script output, gh.log or git.log
  local n=$1 s f; shift
  for s in "$@"; do
    [ -n "$s" ] || continue
    if printf '%s' "$AOUT" | grep -qF -- "$s"; then bad "$n: secret in the output"; else ok; fi
    for f in gh.log git.log; do
      if grep -qF -- "$s" "$AD/$f"; then bad "$n: secret in $f"; else ok; fi
    done
  done
}
afail() { # name, stderr substring, cmd...: exit 2 with the message, no leak, no git network call
  local n=$1 want=$2; shift 2
  arun "$@"
  if [ "$ARC" = 2 ] && printf '%s' "$AOUT" | grep -qF -- "$want"; then ok; else bad "$n: rc=$ARC out=$AOUT"; fi
  noleak "$n" "$ATOK" "$(head -n 1 "$AD/tok.out")"
  [ ! -s "$AD/git.log" ] && ok || bad "$n: git reached the network after the failure: $(cat "$AD/git.log")"
}
myrow() { awk -F'\t' -v k="$AKEY" '$1 == k' "$REG"; }
rawrow() { { printf '%s' "$AKEY"; for f in "$@"; do printf '\t%s' "$f"; done; printf '\n'; } >"$REG"; }
nbranch() { branch "$1"; commit "f-${1//\//-}.txt" x "feat: $1"; AS=$(sha); }
gitenv_all() { # name, pattern: every recorded git call has an env line matching the pattern
  local n=$1 p=$2 calls hits
  calls=$(grep -c '^== ' "$AD/git.env"); hits=$(grep -c -- "$p" "$AD/git.env")
  [ "$calls" -gt 0 ] && [ "$calls" = "$hits" ] && ok || bad "$n: $hits of $calls git calls match $p: $(cat "$AD/git.env")"
}
credcheck() { # name, command (push|ls-remote): the helper answers only for github.com
  local n=$1 c=$2 h
  grep -qxF 'username=x-access-token' "$AD/cred.$c.github.com" && grep -qxF "password=$ATOK" "$AD/cred.$c.github.com" && ok || bad "$n: github.com credential: $(sed 's/password=.*/password=<hidden>/' "$AD/cred.$c.github.com")"
  for h in example.com github.com.evil.test; do
    if grep -q '^password=' "$AD/cred.$c.$h" || grep -qF -- "$ATOK" "$AD/cred.$c.$h"; then bad "$n: credential leaked to $h"; else ok; fi
  done
}

git init -q -b main "$T/a"; cd "$T/a" || exit 1
git config user.email t@example.invalid; git config user.name t; git config commit.gpgsign false
commit README.md hello "chore: init"
git clone -q --bare "$T/a" "$T/a-remote.git"; printf '%s\n' "$T/a-remote.git" >"$AD/bare"
AURL=https://github.com/o/r.git
git remote add origin "$AURL"; git update-ref refs/remotes/origin/main HEAD
AKEY=$(cd "$(git rev-parse --git-common-dir)" && pwd -P)
rm -f "$REG"; areset

# registry parsing: a login is honored only on a non-commit https://github.com/ row; anything else is unregistered
stcase() { # name, expected account line, expected level line, row fields...
  local n=$1 ea=$2 el=$3 out; shift 3
  rawrow "$@"; out=$("$A" status 2>&1)
  printf '%s\n' "$out" | grep -qxF "account: $ea" && printf '%s\n' "$out" | grep -qxF "level: $el" && ok || bad "status $n: $out"
}
L39=$(printf 'a%.0s' $(seq 1 39)); L40=${L39}a
stcase "login in column 7" acctuser push "$AURL" push main conventional - acctuser
stcase "login on a pr row" acctuser pr "$AURL" pr main conventional ci acctuser
stcase "login of 39 characters" "$L39" push "$AURL" push main conventional - "$L39"
stcase "dash in column 7" active push "$AURL" push main conventional - -
stcase "empty column 7" active push "$AURL" push main conventional - ""
stcase "six columns" active push "$AURL" push main conventional -
stcase "five columns" active push "$AURL" push main conventional
for bad_login in -lead under_score "a;b" 'a$b' "$L40" 'a/b' 'é'; do
  stcase "invalid login [$bad_login] is unregistered" - off "$AURL" push main conventional - "$bad_login"
done
stcase "eighth column is unregistered" - off "$AURL" push main conventional - acctuser extra
stcase "eighth column '-' is unregistered" - off "$AURL" push main conventional - acctuser -
stcase "login on a commit row is unregistered" - off - commit - conventional - acctuser
stcase "commit row without a login stays registered" active commit - commit - conventional -
stcase "login with an ssh URL is unregistered" - off git@github.com:o/r.git push main conventional - acctuser
stcase "login with a non-github https URL is unregistered" - off https://example.com/o/r.git push main conventional - acctuser
stcase "login with a lookalike https host is unregistered" - off https://github.com.evil.test/o/r.git push main conventional - acctuser
stcase "ssh row without a login stays registered" active push git@github.com:o/r.git push main conventional -

# cloud rows never carry an account: a login makes the row unregistered, `-` or empty stays registered
cd "$T/cl" || exit 1
cloudst() { # name, expected account line, expected level line, column 7 value
  local n=$1 ea=$2 el=$3 out
  printf 'github:acme/widget\t-\tmerge\tmain\tconventional\t-\t%s\n' "$4" >"$REG"; out=$("${CLD[@]}" status 2>&1)
  printf '%s\n' "$out" | grep -qxF "account: $ea" && printf '%s\n' "$out" | grep -qxF "level: $el" && ok || bad "cloud status $n: $out"
}
cloudst "login on a cloud row" - off acctuser
cloudst "dash on a cloud row" active merge -
cloudst "empty column on a cloud row" active merge ""
cd "$T/a" || exit 1

# an old reader (six variables) puts "ci-column<TAB>login" into its last variable, so its c validation fails:
# the row is unregistered for it (fail closed) instead of silently dropping the account
grep -qF 'case "$c" in ""|-|ci) ;; *) return 1 ;; esac' "$SRC" && ok || bad "the c validation line the old-reader simulation mirrors is gone"
old_reader() { # row: 0 when the old six-variable reader would accept the row's column 6
  local k u l d s c
  IFS=$'\t' read -r k u l d s c <<<"$1"
  case "$c" in ""|-|ci) return 0 ;; *) return 1 ;; esac
}
old_reader "$(printf 'k\t%s\tpush\tmain\tconventional\t-' "$AURL")" && ok || bad "old reader must still accept a six-column row"
old_reader "$(printf 'k\t%s\tpush\tmain\tconventional\tci\tacctuser' "$AURL")" && bad "old reader accepted a seven-column row (ci) with a login" || ok
old_reader "$(printf 'k\t%s\tpush\tmain\tconventional\t-\tacctuser' "$AURL")" && bad "old reader accepted a seven-column row (-) with a login" || ok

# enable --account: gh call order, token only through env, 7 columns written, confirmation line
areset
out=$(printf 'r\n' | GH_TOKEN=other "$A" enable push --account acctuser 2>&1); rc=$?; AOUT=$out
[ "$rc" = 0 ] && printf '%s' "$out" | grep -qxF 'Account    : acctuser' && ok || bad "enable --account: rc=$rc out=$out"
[ "$(myrow | awk -F'\t' '{print NF " " $7 " " $3 " " $2}')" = "7 acctuser push $AURL" ] && ok || bad "registry row with the account: $(cat "$REG")"
[ "$(file_mode "$REG")" = 600 ] && ok || bad "registry mode after enable --account"
"$A" status | grep -qxF 'account: acctuser' && ok || bad "status after enable --account"
want="[auth] [token] [--help]
[auth] [token] [--hostname] [github.com] [--user] [acctuser]
[api] [user] [--jq] [.login]
[api] [repos/o/r] [--jq] [.permissions.push]"
[ "$(sed 's/ $//' "$AD/gh.log")" = "$want" ] && ok || bad "enable gh calls (exact argv, in order): $(cat "$AD/gh.log")"
[ "$(sed -n 1,2p "$AD/gh.env")" = "$(printf '<unset>\n<unset>')" ] && ok || bad "the first two gh calls must have no GH_TOKEN (caller had one): $(cat "$AD/gh.env")"
[ "$(tail -n +3 "$AD/gh.env" | sort -u)" = "$ATOK" ] && [ "$(wc -l <"$AD/gh.env" | tr -d ' ')" = 4 ] && ok || bad "later gh calls must carry the token in GH_TOKEN"
noleak "enable --account" "$ATOK"
grep -qx 'ls-remote --symref -- https://github.com/o/r.git HEAD' "$AD/git.log" && ok || bad "enable should ask the remote for HEAD: $(cat "$AD/git.log")"
gitenv_all "enable git env GP_TOKEN" "^GP_TOKEN=$ATOK\$"
credcheck "enable" ls-remote
# a level pr row is accepted too, and re-enabling without the flag writes six columns and clears the account
areset
out=$(printf 'r\n' | "$A" enable pr --account AcctUser 2>&1)
[ "$(myrow | awk -F'\t' '{print NF " " $3 " " $7}')" = "7 pr AcctUser" ] && ok || bad "enable pr --account: $out $(cat "$REG")"
areset
out=$(printf 'r\n' | "$A" enable push 2>&1); rc=$?
[ "$rc" = 0 ] && ! printf '%s' "$out" | grep -qF 'Account' && ok || bad "enable without the flag must not print an Account line: rc=$rc out=$out"
[ "$(myrow | awk -F'\t' '{print NF}')" = 6 ] && "$A" status | grep -qxF 'account: active' && ok || bad "re-enable without --account: $(cat "$REG")"
[ ! -s "$AD/gh.log" ] && ! grep -q 'GP_TOKEN' "$AD/git.env" && ok || bad "enable without an account made gh or token calls: $(cat "$AD/gh.log")"

# enable refusals leave the registry untouched; the SSH refusal comes before any gh call
areset; cp "$REG" "$AD/reg.before"
refused "enable --account with a bad login" "--account must be a GitHub login" "$A" enable push --account 'bad_login'
refused "enable --account with an empty value" "needs a value" "$A" enable push --account ''
refused "enable --account with an option-like value" "--account must be a GitHub login" "$A" enable push --account '--style'
refused "enable --account at level commit" "--account does not apply to level commit" "$A" enable commit --account acctuser
refused "enable duplicate --account" "duplicate --account" "$A" enable push --account acctuser --account other
refused "enable --account missing value" "needs a value" "$A" enable push --account
git remote set-url origin git@github.com:o/r.git
refused "enable --account with an ssh URL" "account requires an https://github.com/ push URL" "$A" enable push --account acctuser
[ ! -s "$AD/gh.log" ] && [ ! -s "$AD/git.log" ] && ok || bad "gh or git was called before the ssh refusal: $(cat "$AD/gh.log" "$AD/git.log")"
git remote set-url origin https://example.com/o/r.git
refused "enable --account with a non-github https URL" "account requires an https://github.com/ push URL" "$A" enable push --account acctuser
[ ! -s "$AD/gh.log" ] && ok || bad "gh was called before the non-github refusal: $(cat "$AD/gh.log")"
git remote set-url origin "$AURL"
touch "$AD/perm.fail"
arun "$A" enable push --account acctuser
[ "$ARC" = 2 ] && printf '%s' "$AOUT" | grep -qF 'cannot read the permissions of o/r (account acctuser)' && ok || bad "permissions read failure: rc=$ARC out=$AOUT"
noleak "permissions read failure" "$ATOK"
areset; printf 'false\n' >"$AD/perm.out"
arun "$A" enable push --account acctuser
[ "$ARC" = 2 ] && printf '%s' "$AOUT" | grep -qF 'account acctuser has no push access to o/r' && ok || bad "no push access: rc=$ARC out=$AOUT"
noleak "no push access" "$ATOK"
[ ! -s "$AD/git.log" ] && ok || bad "git reached the network after a refused permission check: $(cat "$AD/git.log")"
areset; printf 'true\nextra\n' >"$AD/perm.out"
arun "$A" enable push --account acctuser
[ "$ARC" = 2 ] && printf '%s' "$AOUT" | grep -qF 'has no push access' && ok || bad "permission output other than exactly true must refuse: rc=$ARC out=$AOUT"
cmp -s "$REG" "$AD/reg.before" && ok || bad "a refused enable changed the registry: $(cat "$REG")"
# the same auth failures refuse enable
areset; touch "$AD/tok.fail"; afail "enable, account not logged in" "account acctuser is not logged in to github.com; run gh auth login" "$A" enable push --account acctuser
areset; touch "$AD/help.nouser"; afail "enable, old gh" "gh >= 2.40 needed for per-repo account" "$A" enable push --account acctuser
cmp -s "$REG" "$AD/reg.before" && ok || bad "an enable that failed on auth changed the registry"

# token resolution failures on push: exit 2, exact message, no leak, no git network call, and gh stops at the failing step
rawrow "$AURL" push main conventional - acctuser
nbranch feat/auth; AUTHS=$AS
areset; touch "$AD/help.nouser"
afail "push, gh too old" "gh >= 2.40 needed for per-repo account" "$A" push --expect-sha "$AUTHS"
[ "$(wc -l <"$AD/gh.log" | tr -d ' ')" = 1 ] && ok || bad "old gh: only the --help probe may run: $(cat "$AD/gh.log")"
areset; touch "$AD/tok.fail"
afail "push, not logged in" "account acctuser is not logged in to github.com; run gh auth login" "$A" push --expect-sha "$AUTHS"
[ "$(wc -l <"$AD/gh.log" | tr -d ' ')" = 2 ] && ok || bad "not logged in: stops after the token call: $(cat "$AD/gh.log")"
areset; : >"$AD/tok.out"
afail "push, empty token" "account acctuser is not logged in to github.com" "$A" push --expect-sha "$AUTHS"
areset; printf 'not a token!\n' >"$AD/tok.out"
afail "push, garbage token" "gh returned an unusable token for acctuser" "$A" push --expect-sha "$AUTHS"
[ "$(wc -l <"$AD/gh.log" | tr -d ' ')" = 2 ] && ok || bad "garbage token must not be sent to gh api: $(cat "$AD/gh.log")"
areset; { printf 'ghp_'; head -c 300 /dev/zero | tr '\0' a; printf '\n'; } >"$AD/tok.out"
afail "push, over-long token" "gh returned an unusable token for acctuser" "$A" push --expect-sha "$AUTHS"
areset; printf 'ghp_FIRSTLINE0123\nghp_SECONDLINE456\n' >"$AD/tok.out"
afail "push, token with a newline" "gh returned an unusable token for acctuser" "$A" push --expect-sha "$AUTHS"
noleak "token with a newline" "ghp_SECONDLINE456"
areset; touch "$AD/user.fail"
afail "push, token rejected" "token for acctuser was rejected; re-login acctuser" "$A" push --expect-sha "$AUTHS"
areset; : >"$AD/user.out"
afail "push, empty login from api user" "token for acctuser was rejected" "$A" push --expect-sha "$AUTHS"
areset; printf 'someoneelse\n' >"$AD/user.out"
afail "push, token of another account" "gh token belongs to another account than acctuser" "$A" push --expect-sha "$AUTHS"
[ "$(wc -l <"$AD/gh.log" | tr -d ' ')" = 3 ] && ok || bad "mismatch: gh stops after api user: $(cat "$AD/gh.log")"
rawrow "$AURL" pr main conventional - acctuser
areset; printf 'someoneelse\n' >"$AD/user.out"
afail "pr, token of another account" "gh token belongs to another account than acctuser" "$A" pr --expect-sha "$AUTHS" --expect-content "$ZERO" "${PRFILES[@]}"
rawrow "$AURL" merge main conventional - acctuser
areset; touch "$AD/tok.fail"
afail "ci, not logged in" "is not logged in to github.com" "$A" ci --pr 7
areset; touch "$AD/tok.fail"
afail "merge, not logged in" "is not logged in to github.com" "$A" merge --pr 7 --expect-sha "$AUTHS"
rawrow "$AURL" push main conventional - acctuser

# push in account mode: succeeds into the bare repo; token via env only; case-insensitive login match
areset; printf 'ACCTuser\n' >"$AD/user.out"
arun env GH_TOKEN=other GITHUB_TOKEN=other2 GH_ENTERPRISE_TOKEN=other3 SSL_CERT_FILE=/nonexistent/ca.pem SSL_CERT_DIR=/nonexistent CURL_CA_BUNDLE=/nonexistent/ca.pem "$A" push --expect-sha "$AUTHS"
[ "$ARC" = 0 ] && ok || bad "account push: rc=$ARC out=$AOUT"
[ "$(git -C "$T/a-remote.git" rev-parse refs/heads/feat/auth)" = "$AUTHS" ] && ok || bad "account push did not reach the bare remote"
want="[auth] [token] [--help]
[auth] [token] [--hostname] [github.com] [--user] [acctuser]
[api] [user] [--jq] [.login]"
[ "$(sed 's/ $//' "$AD/gh.log")" = "$want" ] && ok || bad "push gh calls: $(cat "$AD/gh.log")"
[ "$(sed -n 1,2p "$AD/gh.env")" = "$(printf '<unset>\n<unset>')" ] && ok || bad "first two gh calls must have no GH_TOKEN: $(cat "$AD/gh.env")"
[ "$(tail -n +3 "$AD/gh.env")" = "$ATOK" ] && ok || bad "api user must carry the resolved token, not the caller's"
grep -qxF "push --no-follow-tags --recurse-submodules=no -- $AURL $AUTHS:refs/heads/feat/auth" "$AD/git.log" && ok || bad "push argv is not the unchanged one: $(cat "$AD/git.log")"
grep -qE '(^| )-c( |$)' "$AD/git.log" && bad "git -c was used: $(cat "$AD/git.log")" || ok
grep -qE '^ls-remote -- ' "$AD/git.log" && ok || bad "ls-remote argv changed: $(cat "$AD/git.log")"
[ "$(grep -c '^== ' "$AD/git.env")" -ge 2 ] && ok || bad "expected at least one ls-remote and one push: $(cat "$AD/git.env")"
gitenv_all "git GP_TOKEN" "^GP_TOKEN=$ATOK\$"
gitenv_all "git config count" '^GIT_CONFIG_COUNT=14$'
gitenv_all "forced empty core.askPass key 10" '^GIT_CONFIG_KEY_10=core.askPass$'
gitenv_all "forced empty core.askPass value 10" '^GIT_CONFIG_VALUE_10=$'
gitenv_all "unscoped helper reset key 11" '^GIT_CONFIG_KEY_11=credential.helper$'
gitenv_all "unscoped helper reset value 11" '^GIT_CONFIG_VALUE_11=$'
gitenv_all "git helper key 12" '^GIT_CONFIG_KEY_12=credential.https://github.com.helper$'
gitenv_all "git helper key 13" '^GIT_CONFIG_KEY_13=credential.https://github.com.helper$'
gitenv_all "git helper reset value 12" '^GIT_CONFIG_VALUE_12=$'
gitenv_all "git helper value 13" '^GIT_CONFIG_VALUE_13=!f(){'
if grep -qE '^(GH_TOKEN|GITHUB_TOKEN|SSL_CERT_FILE|SSL_CERT_DIR|CURL_CA_BUNDLE)=' "$AD/git.env"; then bad "caller token or CA variables reached git: $(grep -E '^(GH_TOKEN|GITHUB_TOKEN|SSL_CERT_FILE|SSL_CERT_DIR|CURL_CA_BUNDLE)=' "$AD/git.env")"; else ok; fi
grep -qF -- 'other' "$AD/gh.env" && bad "the caller's GH_TOKEN reached gh in account mode" || ok
credcheck "push" push
credcheck "ls-remote" ls-remote
noleak "account push" "$ATOK"

# push failure in account mode names the account, never the token
nbranch feat/pushfail; areset; touch "$AD/push.fail"
arun "$A" push --expect-sha "$AS"
[ "$ARC" != 0 ] && printf '%s' "$AOUT" | grep -qF 'git-publish: push failed (account acctuser)' && ok || bad "push failure message: rc=$ARC out=$AOUT"
noleak "account push failure" "$ATOK"
rawrow "$AURL" push main conventional -; areset; touch "$AD/push.fail"
arun "$A" push --expect-sha "$AS"
[ "$ARC" != 0 ] && ! printf '%s' "$AOUT" | grep -qF '(account' && ok || bad "push failure without an account must not mention one: rc=$ARC out=$AOUT"

# pr in account mode: token reaches pr create; failure message carries the account
rawrow "$AURL" pr main conventional - acctuser
nbranch feat/pr1; areset
out=$("$A" plan "${PRFILES[@]}" 2>&1) || bad "plan in account mode: $out"
ACS=$(printf '%s\n' "$out" | sed -n 's/^content sha256: //p')
[ ! -s "$AD/gh.log" ] && [ ! -s "$AD/git.log" ] && ok || bad "plan must stay offline: $(cat "$AD/gh.log" "$AD/git.log")"
arun "$A" pr --expect-sha "$AS" --expect-content "$ACS" "${PRFILES[@]}"
[ "$ARC" = 0 ] && ok || bad "account pr: rc=$ARC out=$AOUT"
[ "$(sed -n 2p "$AD/gh.log")" = "[auth] [token] [--hostname] [github.com] [--user] [acctuser] " ] && ok || bad "pr gh call 2: $(cat "$AD/gh.log")"
sed -n 4p "$AD/gh.log" | grep -qF '[pr] [create] [--draft] [--repo] [o/r] [--base] [main] [--head] [feat/pr1] [--title] [feat: add widget] [--body-file] [' && ok || bad "pr create argv: $(cat "$AD/gh.log")"
[ "$(wc -l <"$AD/gh.log" | tr -d ' ')" = 4 ] && [ "$(sed -n 1,2p "$AD/gh.env" | sort -u)" = '<unset>' ] && [ "$(sed -n 3,4p "$AD/gh.env" | sort -u)" = "$ATOK" ] && ok || bad "pr gh env: $(cat "$AD/gh.env")"
noleak "account pr" "$ATOK"
nbranch feat/pr2; areset; touch "$AD/create.fail"
out=$("$A" plan "${PRFILES[@]}" 2>&1); ACS=$(printf '%s\n' "$out" | sed -n 's/^content sha256: //p')
arun "$A" pr --expect-sha "$AS" --expect-content "$ACS" "${PRFILES[@]}"
[ "$ARC" = 2 ] && printf '%s' "$AOUT" | grep -qF 'gh could not create the pull request (account acctuser)' && ok || bad "account pr failure message: rc=$ARC out=$AOUT"
noleak "account pr failure" "$ATOK"

# ci in account mode: the token reaches gh pr view
rawrow "$AURL" merge main conventional - acctuser
areset
jq -n --arg u "https://github.com/o/r/pull/7" '{isDraft:false,url:$u,statusCheckRollup:[],headRefOid:"0123456789abcdef0123456789abcdef01234567"}' >"$AD/pr.json"
arun "$A" ci --pr 7
[ "$ARC" = 0 ] && ok || bad "account ci: rc=$ARC out=$AOUT"
sed -n 4p "$AD/gh.log" | grep -qF '[pr] [view] [7] [--repo] [o/r]' && [ "$(sed -n 4p "$AD/gh.env")" = "$ATOK" ] && ok || bad "ci pr view call: $(cat "$AD/gh.log") / $(cat "$AD/gh.env")"
noleak "account ci" "$ATOK"

# without an account (six and five columns): no extra gh call, no token, caller GH_TOKEN passes through, git env unchanged
for cols in 6 5; do
  if [ "$cols" = 6 ]; then rawrow "$AURL" pr main conventional -; else rawrow "$AURL" pr main conventional; fi
  nbranch "feat/plain$cols"; areset
  out=$("$A" plan "${PRFILES[@]}" 2>&1); ACS=$(printf '%s\n' "$out" | sed -n 's/^content sha256: //p')
  arun env GH_TOKEN=other "$A" pr --expect-sha "$AS" --expect-content "$ACS" "${PRFILES[@]}"
  [ "$ARC" = 0 ] && ok || bad "pr with $cols columns: rc=$ARC out=$AOUT"
  [ "$(wc -l <"$AD/gh.log" | tr -d ' ')" = 1 ] && sed -n 1p "$AD/gh.log" | grep -qF '[pr] [create] [--draft] [--repo] [o/r]' && ok || bad "$cols columns: extra gh calls: $(cat "$AD/gh.log")"
  [ "$(cat "$AD/gh.env")" = other ] && ok || bad "$cols columns: caller GH_TOKEN must pass through: $(cat "$AD/gh.env")"
  if grep -qE '^(GP_TOKEN|GIT_CONFIG_KEY_1[1-3])=' "$AD/git.env"; then bad "$cols columns: account credential config was set: $(cat "$AD/git.env")"; else ok; fi
  gitenv_all "$cols columns: config count" '^GIT_CONFIG_COUNT=11$'
  gitenv_all "$cols columns: forced empty core.askPass" '^GIT_CONFIG_KEY_10=core.askPass$'
  grep -qE '^== push' "$AD/git.env" && ok || bad "$cols columns: no push recorded"
  [ "$(git -C "$T/a-remote.git" rev-parse "refs/heads/feat/plain$cols")" = "$AS" ] && ok || bad "$cols columns: push did not reach the remote"
done
rawrow "$AURL" push main conventional -
nbranch feat/plain3; areset
arun "$A" push --expect-sha "$AS"
[ "$ARC" = 0 ] && [ ! -s "$AD/gh.log" ] && ok || bad "push without an account must make no gh call: rc=$ARC gh=$(cat "$AD/gh.log")"

# merge and merge --mark-ready-only in account mode: the token reaches pr view, pr ready and pr merge
rawrow "$AURL" merge main conventional - acctuser
nbranch feat/amerge
amergej() { # isDraft
  jq -n --arg s "$AS" --arg b "$(cat "$T/mbody")" --argjson d "$1" '{state:"OPEN",isDraft:$d,isCrossRepository:false,headRefName:"feat/amerge",headRefOid:$s,baseRefName:"main",title:"feat: add widget",body:$b,statusCheckRollup:[{__typename:"CheckRun",name:"ci",status:"COMPLETED",conclusion:"SUCCESS"}]}' >"$AD/pr.json"
}
AUTH3="[auth] [token] [--help]
[auth] [token] [--hostname] [github.com] [--user] [acctuser]
[api] [user] [--jq] [.login]"
AVIEW="[pr] [view] [7] [--repo] [o/r] [--json] [state,isDraft,isCrossRepository,headRefName,headRefOid,baseRefName,title,body,statusCheckRollup]"
areset; amergej true
arun "$A" merge --mark-ready-only --pr 7 --expect-sha "$AS"
[ "$ARC" = 0 ] && printf '%s\n' "$AOUT" | grep -qxF "marked ready: 7 $AS" && ok || bad "account merge --mark-ready-only: rc=$ARC out=$AOUT"
[ "$(sed 's/ $//' "$AD/gh.log")" = "$(printf '%s\n%s\n%s' "$AUTH3" "$AVIEW" "[pr] [ready] [7] [--repo] [o/r]")" ] && ok || bad "mark-ready gh calls: $(cat "$AD/gh.log")"
[ "$(sed -n 1,2p "$AD/gh.env" | sort -u)" = '<unset>' ] && [ "$(sed -n 3,5p "$AD/gh.env" | sort -u)" = "$ATOK" ] && [ "$(wc -l <"$AD/gh.env" | tr -d ' ')" = 5 ] && ok || bad "mark-ready gh env (pr ready must carry the token)"
noleak "account merge --mark-ready-only" "$ATOK"
areset; amergej false
arun "$A" merge --pr 7 --expect-sha "$AS"
[ "$ARC" = 0 ] && printf '%s\n' "$AOUT" | grep -qxF "7 $AS" && ok || bad "account merge: rc=$ARC out=$AOUT"
[ "$(sed 's/ $//' "$AD/gh.log")" = "$(printf '%s\n%s\n%s' "$AUTH3" "$AVIEW" "[pr] [merge] [7] [--repo] [o/r] [--squash] [--match-head-commit] [$AS] [--subject] [feat: add widget] [--body] []")" ] && ok || bad "merge gh calls: $(cat "$AD/gh.log")"
[ "$(sed -n 1,2p "$AD/gh.env" | sort -u)" = '<unset>' ] && [ "$(sed -n 3,5p "$AD/gh.env" | sort -u)" = "$ATOK" ] && [ "$(wc -l <"$AD/gh.env" | tr -d ' ')" = 5 ] && ok || bad "merge gh env (pr merge must carry the token)"
noleak "account merge" "$ATOK"

# enable refused on a token of another account or a rejected token leaves the registry byte-identical
cp "$REG" "$AD/reg.before"
areset; printf 'someoneelse\n' >"$AD/user.out"
afail "enable, token of another account" "gh token belongs to another account than acctuser" "$A" enable push --account acctuser
cmp -s "$REG" "$AD/reg.before" && ok || bad "enable with another account's token changed the registry"
areset; touch "$AD/user.fail"
afail "enable, token rejected" "token for acctuser was rejected; re-login acctuser" "$A" enable push --account acctuser
cmp -s "$REG" "$AD/reg.before" && ok || bad "enable with a rejected token changed the registry"

# a raw row whose line ends in a tab after column 7 (an empty eighth column) is unregistered
printf '%s\t%s\tpush\tmain\tconventional\t-\tacctuser\t\n' "$AKEY" "$AURL" >"$REG"
out=$("$A" status 2>&1); printf '%s\n' "$out" | grep -qxF 'level: off' && ok || bad "trailing tab after column 7: $out"
printf '%s\t%s\tpush\tmain\tconventional\t-\t\n' "$AKEY" "$AURL" >"$REG"
out=$("$A" status 2>&1); printf '%s\n' "$out" | grep -qxF 'level: push' && ok || bad "a six-column row with a trailing tab stays registered: $out"

# caller git config with its own helpers: for github.com only the account token answers
printf '[credential]\n\thelper = "!f() { echo username=u; echo password=WRONG; }; f"\n[credential "https://github.com"]\n\thelper =\n\thelper = "!f() { echo username=ghuser; echo password=WRONG_GH; }; f"\n' >"$AD/global.cfg"
rawrow "$AURL" push main conventional - acctuser
nbranch feat/aglobal; areset
arun env GIT_CONFIG_GLOBAL="$AD/global.cfg" "$A" push --expect-sha "$AS"
[ "$ARC" = 0 ] && ok || bad "account push with caller helpers: rc=$ARC out=$AOUT"
[ "$(grep '^password=' "$AD/cred.push.github.com")" = "password=$ATOK" ] && ! grep -q 'WRONG' "$AD/cred.push.github.com" && ok || bad "github.com credential with caller helpers: $(sed 's/password=ghp_.*/password=<token>/' "$AD/cred.push.github.com")"
grep -q 'password=' "$AD/cred.push.example.com" && bad "account mode: a caller helper answered for another host: $(cat "$AD/cred.push.example.com")" || ok
# control: without an account the caller's generic helper does answer for other hosts, so the config was in effect
rawrow "$AURL" push main conventional -
nbranch feat/aglobal-plain; areset
arun env GIT_CONFIG_GLOBAL="$AD/global.cfg" "$A" push --expect-sha "$AS"
[ "$ARC" = 0 ] && grep -qx 'password=WRONG' "$AD/cred.push.example.com" && ok || bad "control: the caller config was not in effect for other hosts: rc=$ARC $(cat "$AD/cred.push.example.com")"
# the unscoped reset: a global credential.helper never runs where GP_TOKEN is set, for any host
printf '#!/bin/sh\n: >"%s/sentinel.helper"\n' "$AD" >"$AD/helper.sh"; chmod +x "$AD/helper.sh"
printf '[credential]\n\thelper = %s\n' "$AD/helper.sh" >"$AD/helper.cfg"
rawrow "$AURL" push main conventional - acctuser
nbranch feat/ahelper; areset; rm -f "$AD"/sentinel.*
arun env GIT_CONFIG_GLOBAL="$AD/helper.cfg" "$A" push --expect-sha "$AS"
[ "$ARC" = 0 ] && ok || bad "account push with a global helper: rc=$ARC out=$AOUT"
[ ! -e "$AD/sentinel.helper" ] && ok || bad "a global credential helper ran in account mode"
rawrow "$AURL" push main conventional -
nbranch feat/ahelper-plain; areset; rm -f "$AD"/sentinel.*
arun env GIT_CONFIG_GLOBAL="$AD/helper.cfg" "$A" push --expect-sha "$AS"
[ -e "$AD/sentinel.helper" ] && ok || bad "control: the global helper did not run without an account; the helper test proves nothing"
rm -f "$AD"/sentinel.*

# --- clean environment: exported functions, BASH_ENV, askpass, tracing and debug variables never take effect ---
printf ': >"%s/sentinel.bashenv"\n' "$AD" >"$AD/bashenv.sh"
printf '#!/bin/sh\n: >"%s/sentinel.askpass"\necho x\n' "$AD" >"$AD/askpass.sh"; chmod +x "$AD/askpass.sh"
nosentinel() { # name
  if ls "$AD"/sentinel.* >/dev/null 2>&1; then bad "$1: injected code ran: $(cd "$AD" && ls sentinel.*)"; else ok; fi
}
hijack_run() { # how (path|bash), cmd args...: runs with exported gh, git, test and echo functions plus BASH_ENV
  local how=$1; shift
  (
    for f in gh git test echo; do eval "$f() { : >'$AD/sentinel.fn-$f'; }"; done
    export -f gh git test echo
    if [ "$how" = path ]; then BASH_ENV="$AD/bashenv.sh" "$@"; else bash "$@"; fi
  ) </dev/null >"$AD/hijack.out" 2>&1
}
for kind in acct plain; do
  if [ "$kind" = acct ]; then rawrow "$AURL" push main conventional - acctuser; else rawrow "$AURL" push main conventional -; fi
  for how in path bash; do
    nbranch "feat/fn-$kind-$how"; areset; rm -f "$AD"/sentinel.*
    hijack_run "$how" "$A" push --expect-sha "$AS"; rc=$?
    [ "$rc" = 0 ] && [ "$(git -C "$T/a-remote.git" rev-parse "refs/heads/feat/fn-$kind-$how")" = "$AS" ] && ok || bad "push with injected functions ($kind, $how): rc=$rc $(cat "$AD/hijack.out")"
    nosentinel "exported functions/BASH_ENV ($kind, $how)"
    grep -qE '^(BASH_FUNC_|BASH_ENV=)' "$AD/git.env" && bad "function text or BASH_ENV reached git ($kind, $how)" || ok
    if [ "$kind" = acct ]; then credcheck "credential helper with injected functions ($how)" push; fi
  done
done
# BASH_ENV is not run for the status command either, and a hand-set marker with a dirty environment is refused
rm -f "$AD"/sentinel.*
BASH_ENV="$AD/bashenv.sh" "$A" status >/dev/null 2>&1; nosentinel "BASH_ENV on status"
refused "hand-set clean marker with an extra variable" "environment is not clean" env GIT_PUBLISH_CLEAN_ENV=1 SOME_VAR=1 "$A" status
refused "hand-set clean marker with BASH_ENV" "environment is not clean" env GIT_PUBLISH_CLEAN_ENV=1 BASH_ENV="$AD/bashenv.sh" "$A" status
out=$(env -i GIT_PUBLISH_CLEAN_ENV=1 "BASH_FUNC_gh%%=() { : >'$AD/sentinel.fn-marker'; }" "$A" status 2>&1 </dev/null); rc=$?
[ "$rc" = 2 ] && printf '%s' "$out" | grep -qF 'environment is not clean' && ok || bad "hand-set clean marker with an exported function only: rc=$rc out=$out"
out=$(env -i GIT_PUBLISH_CLEAN_ENV=1 BASH_ENV="$AD/bashenv.sh" "$A" status 2>&1 </dev/null); rc=$?
[ "$rc" = 2 ] && printf '%s' "$out" | grep -qF 'environment is not clean' && ok || bad "hand-set clean marker with BASH_ENV only: rc=$rc out=$out"
out=$(env -i GIT_PUBLISH_CLEAN_ENV=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 "$A" status 2>&1 </dev/null); rc=$?
[ "$rc" = 0 ] && printf '%s\n' "$out" | grep -qxF 'level: push' && ok || bad "control: a marked run with only allowlisted variables must work: rc=$rc out=$out"
nosentinel "hand-set marker cases"

# askpass: an agent-set SSH_ASKPASS/GIT_ASKPASS never runs (empty core.askPass), and in account mode a proxy URL
# with a user name is dropped. The stub git's credential fill for example.com has no helper, so git would ask.
rm -f "$AD"/sentinel.*
printf 'protocol=https\nhost=example.com\n\n' | SSH_ASKPASS="$AD/askpass.sh" git credential fill >/dev/null 2>&1
[ -e "$AD/sentinel.askpass" ] && ok || bad "control: git did not run SSH_ASKPASS with terminal prompts disabled; the askpass test proves nothing"
for kind in acct plain; do
  if [ "$kind" = acct ]; then rawrow "$AURL" push main conventional - acctuser; else rawrow "$AURL" push main conventional -; fi
  nbranch "feat/askpass-$kind"; areset; rm -f "$AD"/sentinel.*
  arun env SSH_ASKPASS="$AD/askpass.sh" GIT_ASKPASS="$AD/askpass.sh" DISPLAY=:0 HTTPS_PROXY=http://user@127.0.0.1:9 https_proxy=http://user@127.0.0.1:9 NO_PROXY='*' "$A" push --expect-sha "$AS"
  [ "$ARC" = 0 ] && ok || bad "push with askpass variables ($kind): rc=$ARC out=$AOUT"
  nosentinel "askpass ($kind)"
  grep -qE '^(SSH_ASKPASS|GIT_ASKPASS)=' "$AD/git.env" && bad "askpass variables reached git ($kind)" || ok
  if [ "$kind" = acct ]; then
    grep -qE '^(HTTPS_PROXY|https_proxy)=' "$AD/git.env" && bad "a proxy URL with a user name reached git in account mode" || ok
    grep -qx 'NO_PROXY=\*' "$AD/git.env" && ok || bad "NO_PROXY should still pass through"
  else
    grep -qx 'HTTPS_PROXY=http://user@127.0.0.1:9' "$AD/git.env" && ok || bad "proxy variables must still pass through without an account"
  fi
done

# tracing and debug variables are dropped: no trace file, nothing in git's environment
rawrow "$AURL" push main conventional - acctuser
nbranch feat/trace; areset
arun env GIT_TRACE2_ENV_VARS=GP_TOKEN GIT_TRACE2_EVENT="$AD/trace.event" GIT_TRACE2_PERF="$AD/trace.perf" GIT_TRACE2="$AD/trace.2" \
  GIT_TRACE="$AD/trace.t" GIT_TRACE_CURL="$AD/trace.curl" GIT_CURL_VERBOSE=1 GIT_REDACT_COOKIES=x GH_DEBUG=api DEBUG=1 \
  SSLKEYLOGFILE="$AD/trace.keys" "$A" push --expect-sha "$AS"
[ "$ARC" = 0 ] && ok || bad "push with trace variables: rc=$ARC out=$AOUT"
if ls "$AD"/trace.* >/dev/null 2>&1; then bad "a trace file was written: $(cd "$AD" && ls trace.*)"; else ok; fi
grep -qE '^(GIT_TRACE[A-Z0-9_]*|DEBUG|SSLKEYLOGFILE)=' "$AD/git.env" && bad "trace or debug variables reached git: $(grep -E '^(GIT_TRACE|DEBUG|SSLKEY)' "$AD/git.env")" || ok
noleak "trace variables" "$ATOK"

# the local backend drops caller CA overrides even without an account
rawrow "$AURL" push main conventional -
nbranch feat/plainca; areset
arun env SSL_CERT_FILE=/nonexistent/ca.pem SSL_CERT_DIR=/nonexistent CURL_CA_BUNDLE=/nonexistent/ca.pem "$A" push --expect-sha "$AS"
[ "$ARC" = 0 ] && ! grep -qE '^(SSL_CERT_FILE|SSL_CERT_DIR|CURL_CA_BUNDLE)=' "$AD/git.env" && ok || bad "CA variables must be dropped on the local backend: rc=$ARC $(grep -E '^(SSL|CURL)' "$AD/git.env")"

# repo-local filter.* and submodule.*.update are refused only with an account, before any gh or git network call;
# other submodule keys stay allowed, and rows without an account accept all of them as before. filter.lfs: always LFS.
nbranch feat/cfgcheck
cfgcase() { # want (ok|refused), kind (acct|plain), key, value
  local want=$1 kind=$2 k=$3 v=$4 out rc
  if [ "$kind" = acct ]; then rawrow "$AURL" push main conventional - acctuser; else rawrow "$AURL" push main conventional -; fi
  git config "$k" "$v"; areset
  if [ "$want" = refused ]; then
    out=$("$A" push --expect-sha "$AS" 2>&1 </dev/null); rc=$?
  else
    out=$("$A" plan 2>&1 </dev/null); rc=$?
  fi
  git config --unset "$k"
  if [ "$want" = ok ]; then
    [ "$rc" = 0 ] && ok || bad "$k must be accepted ($kind): rc=$rc out=$out"
  else
    [ "$rc" = 2 ] && printf '%s' "$out" | grep -qF "repository config section '${k%%.*}' has a setting that is not allowed with a per-repository account" && ok || bad "$k must be refused ($kind): rc=$rc out=$out"
    [ ! -s "$AD/gh.log" ] && [ ! -s "$AD/git.log" ] && ok || bad "$k: gh or git network call before the refusal: $(cat "$AD/gh.log" "$AD/git.log")"
  fi
}
for kv in filter.x.clean=cat filter.x.smudge=cat filter.x.process=cat filter.x.required=true 'submodule.sub.update=!true'; do
  cfgcase refused acct "${kv%%=*}" "${kv#*=}"
  cfgcase ok plain "${kv%%=*}" "${kv#*=}"
done
for kv in submodule.sub.url=https://example.invalid/s.git submodule.sub.active=true submodule.sub.branch=main submodule.recurse=true; do
  cfgcase ok acct "${kv%%=*}" "${kv#*=}"
  cfgcase ok plain "${kv%%=*}" "${kv#*=}"
done
for kind in acct plain; do
  if [ "$kind" = acct ]; then rawrow "$AURL" push main conventional - acctuser; else rawrow "$AURL" push main conventional -; fi
  git config filter.lfs.clean "git-lfs clean -- %f"
  refused "filter.lfs keeps its LFS message ($kind)" "Git LFS repositories are not supported on this route" "$A" plan
  git config --unset filter.lfs.clean
done

# the Linux keyring needs the session bus. Only the standard layout is accepted: XDG_RUNTIME_DIR exactly
# <base>/<uid> (base /run/user), and DBUS_SESSION_BUS_ADDRESS exactly unix:path=<that dir>/bus[,guid=<hex>].
# Valid values reach every gh and git call without an account, and only the two `gh auth token` calls with one.
# /run/user does not exist on macOS, so a copy with the base moved into $AD (the only patched line) covers acceptance.
A2="$T/c10/git-publish.sh"; mkdir -p "$T/c10"; mk_copy "$A2.tmp" "$T/stubacct:"
sed -e "s|^XDG_RUNTIME_BASE=/run/user\$|XDG_RUNTIME_BASE=\"$AD/runbase\"|" "$A2.tmp" >"$A2" && rm -f "$A2.tmp" && chmod +x "$A2"
[ "$(grep -c "^XDG_RUNTIME_BASE=\"$AD/runbase\"\$" "$A2")" = 1 ] || patch_fatal "XDG_RUNTIME_BASE line was not rewritten"
XDGOK="$AD/runbase/$(id -u)"; XDGWW="$AD/xdg-ww"; mkdir -p "$XDGOK" "$XDGWW"; chmod 700 "$XDGOK"; chmod 777 "$XDGWW"
BUSOK="unix:path=$XDGOK/bus"
for kind in plain acct; do
  if [ "$kind" = acct ]; then rawrow "$AURL" pr main conventional - acctuser; else rawrow "$AURL" pr main conventional -; fi
  nbranch "feat/dbus-$kind"
  out=$("$A2" plan "${PRFILES[@]}" 2>&1); ACS=$(printf '%s\n' "$out" | sed -n 's/^content sha256: //p'); areset
  arun env DBUS_SESSION_BUS_ADDRESS="$BUSOK" XDG_RUNTIME_DIR="$XDGOK" "$A2" pr --expect-sha "$AS" --expect-content "$ACS" "${PRFILES[@]}"
  [ "$ARC" = 0 ] && ok || bad "pr with session bus variables ($kind): rc=$ARC out=$AOUT"
  if [ "$kind" = plain ]; then
    gitenv_all "DBUS_SESSION_BUS_ADDRESS forwarded to git (plain)" "^DBUS_SESSION_BUS_ADDRESS=$BUSOK\$"
    gitenv_all "XDG_RUNTIME_DIR forwarded to git (plain)" "^XDG_RUNTIME_DIR=$XDGOK\$"
    [ "$(sort -u "$AD/gh.bus")" = "$BUSOK|$XDGOK" ] && ok || bad "gh without an account must see the session bus: $(cat "$AD/gh.bus")"
  else
    grep -qE '^(DBUS_SESSION_BUS_ADDRESS|XDG_RUNTIME_DIR)=' "$AD/git.env" && bad "session bus variables reached git in account mode" || ok
    [ "$(sed -n 1,2p "$AD/gh.bus" | sort -u)" = "$BUSOK|$XDGOK" ] && ok || bad "the gh auth token calls must keep the session bus: $(cat "$AD/gh.bus")"
    [ "$(tail -n +3 "$AD/gh.bus" | sort -u)" = '<unset>|<unset>' ] && [ "$(wc -l <"$AD/gh.bus" | tr -d ' ')" = 4 ] && ok || bad "gh_run must not see the session bus in account mode: $(cat "$AD/gh.bus")"
  fi
done
# anything else is dropped (not refused), without an account too
rawrow "$AURL" push main conventional -
buscase() { # name, bus (kept|dropped), runtime dir (kept|dropped), script copy, bus value, runtime dir value
  local n=$1 wb=$2 wx=$3 cp=$4 bus=$5 xdg=$6
  nbranch feat/badbus; areset
  arun env DBUS_SESSION_BUS_ADDRESS="$bus" XDG_RUNTIME_DIR="$xdg" "$cp" push --expect-sha "$AS"
  [ "$ARC" = 0 ] && ok || bad "$n: rc=$ARC out=$AOUT"
  if [ "$wb" = kept ]; then grep -qxF "DBUS_SESSION_BUS_ADDRESS=$bus" "$AD/git.env" && ok || bad "$n: bus address must be kept"
  else grep -q '^DBUS_SESSION_BUS_ADDRESS=' "$AD/git.env" && bad "$n: bus address must be dropped: $(grep '^DBUS' "$AD/git.env")" || ok; fi
  if [ "$wx" = kept ]; then grep -qxF "XDG_RUNTIME_DIR=$xdg" "$AD/git.env" && ok || bad "$n: runtime dir must be kept"
  else grep -q '^XDG_RUNTIME_DIR=' "$AD/git.env" && bad "$n: runtime dir must be dropped: $(grep '^XDG' "$AD/git.env")" || ok; fi
  git push -q "$T/a-remote.git" --delete feat/badbus 2>/dev/null
}
NL='
'
buscase "standard layout with a guid" kept kept "$A2" "$BUSOK,guid=0123abcdef" "$XDGOK"
buscase "abstract address" dropped kept "$A2" "unix:abstract=$XDGOK/bus" "$XDGOK"
buscase "non-standard socket path" dropped kept "$A2" "unix:path=$AD/other/bus" "$XDGOK"
buscase "unixexec transport" dropped kept "$A2" "unixexec:path=/bin/sh" "$XDGOK"
buscase "tcp transport" dropped kept "$A2" "tcp:host=localhost,port=1" "$XDGOK"
buscase "chained address" dropped kept "$A2" "$BUSOK;unixexec:path=/bin/sh" "$XDGOK"
buscase "uppercase guid" dropped kept "$A2" "$BUSOK,guid=ABC" "$XDGOK"
buscase "empty guid" dropped kept "$A2" "$BUSOK,guid=" "$XDGOK"
buscase "newline after the address" dropped kept "$A2" "$BUSOK${NL}x" "$XDGOK"
buscase "newline inside the guid" dropped kept "$A2" "$BUSOK,guid=ab${NL}cd" "$XDGOK"
buscase "runtime dir not <base>/<uid>" dropped dropped "$A2" "unix:path=$XDGWW/bus" "$XDGWW"
buscase "runtime dir with a trailing slash" dropped dropped "$A2" "$BUSOK" "$XDGOK/"
buscase "runtime dir with a newline" dropped dropped "$A2" "$BUSOK" "$XDGOK${NL}"
buscase "relative runtime dir" dropped dropped "$A2" "$BUSOK" "relative/run"
buscase "bus without a runtime dir" dropped dropped "$A2" "$BUSOK" ""
chmod 770 "$XDGOK"
buscase "group-writable runtime dir" dropped dropped "$A2" "$BUSOK" "$XDGOK"
chmod 700 "$XDGOK"; mv "$XDGOK" "$XDGOK.real"; ln -s "$XDGOK.real" "$XDGOK"
buscase "symlinked runtime dir" dropped dropped "$A2" "$BUSOK" "$XDGOK"
rm -f "$XDGOK"; mv "$XDGOK.real" "$XDGOK"
# the production base is /run/user; on a system without it (macOS) both variables are always dropped
if [ ! -d "/run/user/$(id -u)" ]; then
  buscase "production copy without /run/user" dropped dropped "$A" "unix:path=/run/user/$(id -u)/bus" "/run/user/$(id -u)"
fi

# a global insteadOf plus an identity pushInsteadOf would redirect the preflight ls-remote: refused before any network call
printf '[url "https://evil.invalid/"]\n\tinsteadOf = https://github.com/\n[url "https://github.com/"]\n\tpushInsteadOf = https://github.com/\n' >"$AD/rewrite.cfg"
rawrow "$AURL" push main conventional - acctuser
nbranch feat/rewrite; areset
arun env GIT_CONFIG_GLOBAL="$AD/rewrite.cfg" "$A" push --expect-sha "$AS"
[ "$ARC" = 2 ] && printf '%s' "$AOUT" | grep -qF 'would rewrite the push URL again' && ok || bad "insteadOf redirecting the preflight: rc=$ARC out=$AOUT"
[ ! -s "$AD/git.log" ] && [ ! -s "$AD/gh.log" ] && ok || bad "a network call happened before the rewrite refusal: $(cat "$AD/git.log" "$AD/gh.log")"
# the same rewrite plus a global credential helper: the helper never runs, and enable refuses before any network call
{ cat "$AD/rewrite.cfg"; printf '[credential]\n\thelper = %s\n' "$AD/helper.sh"; } >"$AD/rewrite-helper.cfg"
areset; rm -f "$AD"/sentinel.*
arun env GIT_CONFIG_GLOBAL="$AD/rewrite-helper.cfg" "$A" push --expect-sha "$AS"
[ "$ARC" = 2 ] && printf '%s' "$AOUT" | grep -qF 'would rewrite the push URL again' && ok || bad "rewrite plus helper on push: rc=$ARC out=$AOUT"
cp "$REG" "$AD/reg.before"; areset
arun env GIT_CONFIG_GLOBAL="$AD/rewrite-helper.cfg" "$A" enable push --account acctuser
[ "$ARC" = 2 ] && printf '%s' "$AOUT" | grep -qF 'would rewrite the push URL again' && ok || bad "enable must refuse the rewrite: rc=$ARC out=$AOUT"
[ ! -s "$AD/git.log" ] && [ ! -s "$AD/gh.log" ] && cmp -s "$REG" "$AD/reg.before" && ok || bad "enable reached the network or changed the registry before the rewrite refusal"
[ ! -e "$AD/sentinel.helper" ] && ok || bad "the global credential helper ran during the rewrite cases"

# a relative TMPDIR is refused: in account mode gh runs from /, so the body file path must be absolute
rawrow "$AURL" pr main conventional - acctuser
refused "relative TMPDIR" "TMPDIR must be an absolute path" env TMPDIR=relative-tmp "$A" plan "${PRFILES[@]}"
[ ! -e "$T/a/relative-tmp" ] && ok || bad "a relative TMPDIR was created"

# gh never runs in the repository in account mode, so a repository filter cannot see GH_TOKEN
printf '#!/bin/sh\n: >"%s/sentinel.filter"\ncat\n' "$AD" >"$AD/filter.sh"; chmod +x "$AD/filter.sh"
printf '[filter "sent"]\n\tclean = %s\n' "$AD/filter.sh" >"$AD/filter.cfg"
printf '* filter=sent\n' >"$T/a/.git/info/attributes"
rm -f "$AD"/sentinel.*
(cd "$T/a" && GIT_CONFIG_GLOBAL="$AD/filter.cfg" "$T/stubacct/gh" control) >/dev/null 2>&1
[ -e "$AD/sentinel.filter" ] && ok || bad "control: the stub gh did not run the filter from the repository; the filter tests prove nothing"
rm -f "$AD"/sentinel.*
cwd_root() { # name: every gh call ran from /
  [ -s "$AD/gh.cwd" ] && [ "$(sort -u "$AD/gh.cwd")" = / ] && ok || bad "$1: gh ran outside /: $(sort -u "$AD/gh.cwd")"
}
# ci reads no repository config, so a filter configured in the repository itself reaches this point
rawrow "$AURL" merge main conventional - acctuser; areset
jq -n --arg u "https://github.com/o/r/pull/7" '{isDraft:false,url:$u,statusCheckRollup:[],headRefOid:"0123456789abcdef0123456789abcdef01234567"}' >"$AD/pr.json"
git config filter.sent.clean "$AD/filter.sh"
arun "$A" ci --pr 7
git config --remove-section filter.sent
[ "$ARC" = 0 ] && ok || bad "account ci with a repository filter: rc=$ARC out=$AOUT"
nosentinel "repository filter during account ci"; cwd_root "account ci"
# pr and merge refuse the repository filter, and a filter from the global config still never runs under gh
rawrow "$AURL" pr main conventional - acctuser
nbranch feat/filterpr; areset
out=$(GIT_CONFIG_GLOBAL="$AD/filter.cfg" "$A" plan "${PRFILES[@]}" 2>&1); ACS=$(printf '%s\n' "$out" | sed -n 's/^content sha256: //p')
git config filter.sent.clean "$AD/filter.sh"
arun "$A" pr --expect-sha "$AS" --expect-content "$ACS" "${PRFILES[@]}"
git config --remove-section filter.sent
[ "$ARC" = 2 ] && printf '%s' "$AOUT" | grep -qF "section 'filter'" && [ ! -s "$AD/gh.log" ] && ok || bad "account pr with a repository filter: rc=$ARC out=$AOUT"
areset
arun env GIT_CONFIG_GLOBAL="$AD/filter.cfg" "$A" pr --expect-sha "$AS" --expect-content "$ACS" "${PRFILES[@]}"
[ "$ARC" = 0 ] && ok || bad "account pr with a global filter: rc=$ARC out=$AOUT"
nosentinel "global filter during account pr"; cwd_root "account pr"
grep -qF "[--body-file] [$T/tmp/" "$AD/gh.log" && ok || bad "pr --body-file must be an absolute path: $(cat "$AD/gh.log")"
rawrow "$AURL" merge main conventional - acctuser
nbranch feat/amerge2; areset
jq -n --arg s "$AS" --arg b "$(cat "$T/mbody")" '{state:"OPEN",isDraft:false,isCrossRepository:false,headRefName:"feat/amerge2",headRefOid:$s,baseRefName:"main",title:"feat: add widget",body:$b,statusCheckRollup:[{__typename:"CheckRun",name:"ci",status:"COMPLETED",conclusion:"SUCCESS"}]}' >"$AD/pr.json"
git config filter.sent.clean "$AD/filter.sh"
arun "$A" merge --pr 7 --expect-sha "$AS"
git config --remove-section filter.sent
[ "$ARC" = 2 ] && printf '%s' "$AOUT" | grep -qF "section 'filter'" && [ ! -s "$AD/gh.log" ] && ok || bad "account merge with a repository filter: rc=$ARC out=$AOUT"
areset
arun env GIT_CONFIG_GLOBAL="$AD/filter.cfg" "$A" merge --pr 7 --expect-sha "$AS"
[ "$ARC" = 0 ] && ok || bad "account merge with a global filter: rc=$ARC out=$AOUT"
nosentinel "global filter during account merge"; cwd_root "account merge"
rm -f "$T/a/.git/info/attributes"
# without an account gh still runs in the repository, as before
rawrow "$AURL" push main conventional -; nbranch feat/plaincwd; areset
rawrow "$AURL" pr main conventional -
out=$("$A" plan "${PRFILES[@]}" 2>&1); ACS=$(printf '%s\n' "$out" | sed -n 's/^content sha256: //p')
arun "$A" pr --expect-sha "$AS" --expect-content "$ACS" "${PRFILES[@]}"
[ "$ARC" = 0 ] && [ "$(sort -u "$AD/gh.cwd")" = "$(cd "$T/a" && pwd -P)" ] && ok || bad "gh without an account should run in the repository: rc=$ARC cwd=$(cat "$AD/gh.cwd")"

# only a script read from a file re-runs itself; a cwd file named bash is never run
mkdir -p "$AD/selfdir"
printf '#!/bin/sh\n: >"%s/sentinel.selfbash"\n' "$AD" >"$AD/selfdir/bash"; chmod +x "$AD/selfdir/bash"
rm -f "$AD"/sentinel.*
out=$(cd "$AD/selfdir" && bash -s status <"$A" 2>&1); rc=$?
[ "$rc" = 2 ] && printf '%s' "$out" | grep -qF 'run the script by its path' && ok || bad "bash < script: rc=$rc out=$out"
out=$(cd "$AD/selfdir" && bash -c "$(cat "$A")" bash status 2>&1); rc=$?
[ "$rc" = 2 ] && printf '%s' "$out" | grep -qF 'run the script by its path' && ok || bad "bash -c script: rc=$rc out=$out"
nosentinel "cwd file named bash"
out=$(cd "$T/c9" && bash git-publish.sh status 2>&1); rc=$?
[ "$rc" = 0 ] && printf '%s\n' "$out" | grep -qx 'backend: local' && ok || bad "bash with a relative script path must still work: rc=$rc out=$out"
[ -z "$(ls -A "$T/tmp")" ] && ok || bad "private temp copies left behind after the account cases: $(ls "$T/tmp")"
cd / || exit 1

echo "RESULT pass=$PASS fail=$FAIL"
if [ "$FAIL" = 0 ]; then echo "All git-publish checks passed."; exit 0; fi
echo "Some git-publish checks failed."
exit 1
