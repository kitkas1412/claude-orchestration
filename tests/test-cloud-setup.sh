#!/usr/bin/env bash
# Tests cloud/setup.sh offline, in temp dirs only. Never touches the real ~/.claude, /root or /opt.
# Usage: bash tests/test-cloud-setup.sh
#
# The script under test is copied and sed-patched: REPO_URL points at a local repo made from the
# current working tree (so uncommitted changes are tested), REF is that repo's commit, TARGET_HOME and
# SRC_DIR are temp dirs, GH_BASE points at local file:// repos (default-branch lookup without network),
# and the GRANTS body is replaced with test grants.
# git-publish.sh resolves its home from the passwd database, not $HOME, so the final check runs a
# copy whose REGISTRY= line is patched (same technique as tests/test-git-publish.sh).
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/cloud/setup.sh"
pass=0
fail=0
ok() { pass=$((pass + 1)); echo "ok    $1"; }
bad() { fail=$((fail + 1)); echo "FAIL  $1"; }
check() { # $1 description, rest: command
  local d=$1
  shift
  if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi
}

T=$(mktemp -d "${TMPDIR:-/tmp}/test-cloud-setup.XXXXXX") || { echo "FATAL: mktemp failed"; exit 2; }
cleanup() {
  case "$T" in
    */test-cloud-setup.*) [ -d "$T" ] && rm -rf -- "$T" ;;
  esac
}
trap cleanup EXIT
fatal() { echo "FATAL: $1"; exit 2; }

export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_TERMINAL_PROMPT=0
GIT="git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false"
TAB=$(printf '\t')

for tool in git jq awk sed tar; do command -v "$tool" >/dev/null || fatal "missing tool: $tool"; done
[ -f "$SRC" ] || fatal "cloud/setup.sh not found"
bash -n "$SRC" || fatal "cloud/setup.sh has a syntax error"

# --- fixtures ---
# Origin: a copy of the working tree (tracked + untracked, not ignored) as one commit.
mkdir "$T/work" "$T/gh" || fatal "mkdir"
(cd "$ROOT" && git ls-files -co --exclude-standard | while IFS= read -r f; do [ -f "$f" ] && printf '%s\n' "$f"; done) >"$T/files.txt"
(cd "$ROOT" && tar -cf - -T "$T/files.txt") | tar -xf - -C "$T/work" || fatal "copy working tree"
(cd "$T/work" && git init -q -b main . && git add -A && $GIT commit -q -m "test snapshot") || fatal "origin commit"
git clone -q --bare "$T/work" "$T/origin.git" || fatal "bare clone"
REF=$(git -C "$T/work" rev-parse HEAD) || fatal "rev-parse"

# Local stand-in for github.com so the default-branch lookup works offline: HEAD -> trunk.
mkdir "$T/lk" && (cd "$T/lk" && git init -q -b trunk . && echo x >f && git add f && $GIT commit -q -m x) || fatal "lookup fixture"
mkdir -p "$T/gh/lookup-owner" && git clone -q --bare "$T/lk" "$T/gh/lookup-owner/lookup-repo" || fatal "lookup bare clone"

GRANTS_TEXT='# comment line
good-owner/good-repo pr main conventional ci

other-owner/other.repo merge release/1.0 project
commit-owner/commit-repo commit
lookup-owner/lookup-repo push
bad_owner/repo pr main
owner/repo2 admin main
owner/repo3 pr -bad
owner/repo4 pr ../x
missing-owner/missing-repo pr
dup-owner/dup-repo pr main
dup-owner/dup-repo merge main'

# mk_script <dest> <repo_url> <ref> <target_home> <src_dir> <gh_base>
mk_script() {
  local dest=$1
  sed -e "s|^REPO_URL=.*|REPO_URL=$2|" -e "s|^REF=.*|REF=$3|" -e "s|^TARGET_HOME=.*|TARGET_HOME=$4|" \
    -e "s|^SRC_DIR=.*|SRC_DIR=$5|" -e "s|^GH_BASE=.*|GH_BASE=$6|" "$SRC" |
    G="$GRANTS_TEXT" awk '
      /^GRANTS=\$\(cat <<.EOF.$/ { print; print ENVIRON["G"]; skip = 1; next }
      skip && /^EOF$/ { skip = 0 }
      !skip { print }' >"$dest" || fatal "patch failed"
  [ "$(grep -c '^REPO_URL=' "$dest")" = 1 ] && grep -qxF "REF=$3" "$dest" && grep -qxF "TARGET_HOME=$4" "$dest" \
    && grep -qxF "SRC_DIR=$5" "$dest" && grep -qxF "GH_BASE=$6" "$dest" && grep -qxF "$(printf '%s\n' "$GRANTS_TEXT" | head -n 1)" "$dest" \
    || fatal "patched copy is missing expected lines"
  bash -n "$dest" || fatal "patched copy has a syntax error"
}

mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null; }

REGNAME=git-publish.registry
H1="$T/home1"
mkdir -p "$H1"
mk_script "$T/s1.sh" "$T/origin.git" "$REF" "$H1" "$T/src1" "file://$T/gh"
REG="$H1/.claude/$REGNAME"

# --- run 1 ---
(HOME="$T/untouched" bash "$T/s1.sh") >"$T/out1.txt" 2>&1
rc=$?
[ "$rc" = 0 ] && ok "run 1 exits 0" || bad "run 1 exits 0 (rc=$rc)"
check "git-publish.sh installed under TARGET_HOME" test -f "$H1/.claude/hooks/git-publish.sh"
check "settings.json installed under TARGET_HOME" test -f "$H1/.claude/settings.json"
check "SRC_DIR is a checkout at REF" test "$(git -C "$T/src1" rev-parse HEAD)" = "$REF"
check "HOME of the caller was not used" test ! -e "$T/untouched"
check "registry exists, regular, not a symlink" test -f "$REG" -a ! -L "$REG"
[ "$(mode_of "$REG")" = 600 ] && ok "registry mode is 600" || bad "registry mode is 600 (got $(mode_of "$REG"))"

EXPECTED="github:good-owner/good-repo${TAB}-${TAB}pr${TAB}main${TAB}conventional${TAB}ci
github:other-owner/other.repo${TAB}-${TAB}merge${TAB}release/1.0${TAB}project${TAB}-
github:commit-owner/commit-repo${TAB}-${TAB}commit${TAB}-${TAB}conventional${TAB}-
github:lookup-owner/lookup-repo${TAB}-${TAB}push${TAB}trunk${TAB}conventional${TAB}-
github:dup-owner/dup-repo${TAB}-${TAB}pr${TAB}main${TAB}conventional${TAB}-"
printf '%s\n' "$EXPECTED" >"$T/expected.txt"
if cmp -s "$T/expected.txt" "$REG"; then ok "registry holds exactly the valid rows in tab format (with trailing newline)"; else
  bad "registry holds exactly the valid rows"; diff "$T/expected.txt" "$REG" | sed 's/^/      /' | head -20
fi
[ "$(grep -c '^registered ' "$T/out1.txt")" = 5 ] && ok "5 'registered' lines printed" || bad "5 'registered' lines printed"
[ "$(grep -c '^WARNING' "$T/out1.txt")" = 6 ] && ok "6 WARNING lines (one per skipped grant)" || { bad "6 WARNING lines"; sed 's/^/      /' "$T/out1.txt"; }
check "warning for invalid slug" grep -q '^WARNING: invalid repository slug' "$T/out1.txt"
check "warning for invalid level" grep -q '^WARNING: invalid level for owner/repo2' "$T/out1.txt"
check "warning for unsafe branch" grep -q '^WARNING: unsafe branch name for owner/repo3' "$T/out1.txt"
check "warning for unsafe branch (dot-dot)" grep -q '^WARNING: unsafe branch name for owner/repo4' "$T/out1.txt"
check "warning for failed default-branch lookup (offline stand-in has no such repo)" grep -q '^WARNING: cannot determine default branch of missing-owner/missing-repo' "$T/out1.txt"
check "warning for duplicate grant" grep -q '^WARNING: duplicate grant for dup-owner/dup-repo' "$T/out1.txt"
! grep -q 'owner/repo[234]' "$REG" && ok "no row for invalid grants" || bad "no row for invalid grants"
! grep -qiE 'token|ghp_|password' "$T/out1.txt" && ok "output has no secret-looking text" || bad "output has no secret-looking text"

# --- run 2: idempotent ---
cp "$REG" "$T/reg.run1"
(bash "$T/s1.sh") >"$T/out2.txt" 2>&1
rc=$?
[ "$rc" = 0 ] && ok "run 2 exits 0 (existing SRC_DIR is fetched)" || bad "run 2 exits 0 (rc=$rc)"
cmp -s "$T/reg.run1" "$REG" && ok "run 2 registry is byte-identical" || bad "run 2 registry is byte-identical"
[ "$(mode_of "$REG")" = 600 ] && ok "run 2 registry mode still 600" || bad "run 2 registry mode still 600"
[ -z "$(ls -A "$H1/.claude" | grep -F "$REGNAME.")" ] && ok "no temp registry files left behind" || bad "no temp registry files left behind"

# --- revocation: fewer grants => rows disappear ---
GRANTS_SAVE=$GRANTS_TEXT
GRANTS_TEXT='good-owner/good-repo pr main'
mk_script "$T/s1b.sh" "$T/origin.git" "$REF" "$H1" "$T/src1" "file://$T/gh"
(bash "$T/s1b.sh") >"$T/out2b.txt" 2>&1
[ "$(cat "$REG")" = "github:good-owner/good-repo${TAB}-${TAB}pr${TAB}main${TAB}conventional${TAB}-" ] \
  && ok "removing grants removes their rows" || bad "removing grants removes their rows"
GRANTS_TEXT=$GRANTS_SAVE

# --- revocation first: a failed rerun leaves an empty registry ---
empty_reg() { [ -f "$REG" ] && [ ! -L "$REG" ] && [ ! -s "$REG" ] && [ "$(mode_of "$REG")" = 600 ]; }
restore_reg() { (bash "$T/s1.sh") >/dev/null 2>&1; [ -s "$REG" ]; }

restore_reg || fatal "could not populate registry before revocation tests"
mk_script "$T/s_ph.sh" "$T/origin.git" "REPLACE_WITH_COMMIT_SHA" "$H1" "$T/src1" "file://$T/gh"
(bash "$T/s_ph.sh") >"$T/out_ph.txt" 2>&1
rc=$?
[ "$rc" = 0 ] && grep -q '^WARNING: REF is still the placeholder' "$T/out_ph.txt" && empty_reg \
  && ok "placeholder REF rerun: exit 0, registry exists and is empty" || bad "placeholder REF rerun: registry empty"

restore_reg || fatal "could not repopulate registry"
mk_script "$T/s_mal.sh" "$T/origin.git" "main" "$H1" "$T/src1" "file://$T/gh"
(bash "$T/s_mal.sh") >"$T/out_mal.txt" 2>&1
rc=$?
[ "$rc" = 0 ] && grep -q '^WARNING: REF is not a 40-hex' "$T/out_mal.txt" && empty_reg \
  && ok "malformed REF rerun: exit 0, registry empty" || bad "malformed REF rerun: registry empty"

restore_reg || fatal "could not repopulate registry"
mk_script "$T/s_url.sh" "$T/does-not-exist.git" "$REF" "$H1" "$T/src1-url" "file://$T/gh"
(bash "$T/s_url.sh") >"$T/out_url.txt" 2>&1
rc=$?
[ "$rc" = 0 ] && grep -q '^WARNING: could not install' "$T/out_url.txt" && empty_reg \
  && ok "bad REPO_URL rerun: exit 0, registry empty" || bad "bad REPO_URL rerun: registry empty"

# --- revocation fallback: emptying fails => registry removed; removal fails too => REVOKE FAILED ---
# Simulated with PATH shims (test only): a mktemp that fails for registry temp files, and optionally an rm
# that fails for the registry itself. Everything else is passed through to the real tools.
REAL_MKTEMP=$(command -v mktemp)
REAL_RM=$(command -v rm)
mkdir "$T/shim-mk" "$T/shim-both"
for d in shim-mk shim-both; do
  printf '#!/bin/sh\ncase "$*" in *%s.*) exit 1 ;; esac\nexec "%s" "$@"\n' "$REGNAME" "$REAL_MKTEMP" >"$T/$d/mktemp"
  chmod +x "$T/$d/mktemp"
done
printf '#!/bin/sh\nfor a in "$@"; do case "$a" in *%s) exit 1 ;; esac; done\nexec "%s" "$@"\n' "$REGNAME" "$REAL_RM" >"$T/shim-both/rm"
chmod +x "$T/shim-both/rm"

restore_reg || fatal "could not repopulate registry"
mk_script "$T/s_fb.sh" "$T/origin.git" "REPLACE_WITH_COMMIT_SHA" "$H1" "$T/src1" "file://$T/gh"
(PATH="$T/shim-mk:$PATH" bash "$T/s_fb.sh") >"$T/out_fb.txt" 2>&1
rc=$?
[ "$rc" = 0 ] && [ ! -e "$REG" ] && [ ! -L "$REG" ] && grep -q '^WARNING: could not empty the existing registry; removed it' "$T/out_fb.txt" \
  && ok "empty-write fails: registry removed, exit 0" || { bad "empty-write fails: registry removed, exit 0 (rc=$rc)"; sed 's/^/      /' "$T/out_fb.txt"; }
! grep -q 'REVOKE FAILED' "$T/out_fb.txt" && ok "empty-write fails: no REVOKE FAILED when removal works" || bad "empty-write fails: no REVOKE FAILED when removal works"

restore_reg || fatal "could not repopulate registry"
cp "$REG" "$T/reg.before"
(PATH="$T/shim-both:$PATH" bash "$T/s_fb.sh") >"$T/out_fb2.txt" 2>&1
rc=$?
[ "$rc" = 0 ] && grep -q "^WARNING: REVOKE FAILED: $REG could not be emptied or removed; old grants may still be active\$" "$T/out_fb2.txt" \
  && ok "empty-write and removal fail: REVOKE FAILED warning, exit 0" || { bad "empty-write and removal fail: REVOKE FAILED warning, exit 0 (rc=$rc)"; sed 's/^/      /' "$T/out_fb2.txt"; }
! grep -q 'github:' "$T/out_fb2.txt" && ok "REVOKE FAILED output does not print row contents" || bad "REVOKE FAILED output does not print row contents"
restore_reg || fatal "could not repopulate registry after fallback tests"

# --- case-insensitive duplicate slug ---
H5="$T/home5"
mkdir -p "$H5"
GRANTS_SAVE=$GRANTS_TEXT
GRANTS_TEXT='Case-Owner/Case-Repo pr main
case-owner/case-repo merge main'
mk_script "$T/s5.sh" "$T/origin.git" "$REF" "$H5" "$T/src5" "file://$T/gh"
(bash "$T/s5.sh") >"$T/out6.txt" 2>&1
[ "$(cat "$H5/.claude/$REGNAME")" = "github:Case-Owner/Case-Repo${TAB}-${TAB}pr${TAB}main${TAB}conventional${TAB}-" ] \
  && grep -q '^WARNING: duplicate grant for case-owner/case-repo' "$T/out6.txt" \
  && ok "case-only duplicate: second skipped with WARNING" || bad "case-only duplicate: second skipped with WARNING"

# --- glob characters are not expanded ---
H6="$T/home6"
mkdir -p "$H6" "$T/globcwd/glob-owner"
: >"$T/globcwd/glob-owner/evil"
GRANTS_TEXT='glob-owner/* pr main'
mk_script "$T/s6.sh" "$T/origin.git" "$REF" "$H6" "$T/src6" "file://$T/gh"
(cd "$T/globcwd" && bash "$T/s6.sh") >"$T/out7.txt" 2>&1
rc=$?
[ "$rc" = 0 ] && grep -q '^WARNING: invalid repository slug' "$T/out7.txt" && ! grep -q 'glob-owner' "$H6/.claude/$REGNAME" \
  && ok "glob in grant line is not expanded (literal slug rejected)" || bad "glob in grant line is not expanded"
GRANTS_TEXT=$GRANTS_SAVE

# --- symlink registry is refused ---
H2="$T/home2"
mkdir -p "$H2/.claude"
echo "precious" >"$T/victim.txt"
ln -s "$T/victim.txt" "$H2/.claude/$REGNAME"
mk_script "$T/s2.sh" "$T/origin.git" "$REF" "$H2" "$T/src2" "file://$T/gh"
(bash "$T/s2.sh") >"$T/out3.txt" 2>&1
rc=$?
[ "$rc" = 0 ] && ok "symlink registry: exits 0" || bad "symlink registry: exits 0 (rc=$rc)"
grep -q '^WARNING: registry path is a symlink' "$T/out3.txt" && ok "symlink registry: refused with WARNING" || bad "symlink registry: refused with WARNING"
[ "$(cat "$T/victim.txt")" = precious ] && ok "symlink target untouched" || bad "symlink target untouched"
[ -L "$H2/.claude/$REGNAME" ] && ok "symlink left in place" || bad "symlink left in place"
! grep -q '^registered ' "$T/out3.txt" && ok "symlink registry: no grants registered" || bad "symlink registry: no grants registered"

# --- REF placeholder ---
H3="$T/home3"
mkdir -p "$H3"
mk_script "$T/s3.sh" "$T/origin.git" "REPLACE_WITH_COMMIT_SHA" "$H3" "$T/src3" "file://$T/gh"
(bash "$T/s3.sh") >"$T/out4.txt" 2>&1
rc=$?
[ "$rc" = 0 ] && ok "placeholder REF: exits 0" || bad "placeholder REF: exits 0 (rc=$rc)"
grep -q '^WARNING: REF is still the placeholder' "$T/out4.txt" && ok "placeholder REF: WARNING" || bad "placeholder REF: WARNING"
[ ! -e "$H3/.claude" ] && [ ! -e "$T/src3" ] && ok "placeholder REF: nothing installed" || bad "placeholder REF: nothing installed"

# --- malformed REF (not 40 hex) ---
mk_script "$T/s3b.sh" "$T/origin.git" "main" "$H3" "$T/src3" "file://$T/gh"
(bash "$T/s3b.sh") >"$T/out4b.txt" 2>&1
rc=$?
[ "$rc" = 0 ] && grep -q '^WARNING: REF is not a 40-hex' "$T/out4b.txt" && [ ! -e "$H3/.claude" ] \
  && ok "malformed REF: WARNING, exit 0, nothing installed" || bad "malformed REF: WARNING, exit 0, nothing installed"

# --- bad REPO_URL ---
H4="$T/home4"
mkdir -p "$H4"
mk_script "$T/s4.sh" "$T/does-not-exist.git" "$REF" "$H4" "$T/src4" "file://$T/gh"
(bash "$T/s4.sh") >"$T/out5.txt" 2>&1
rc=$?
[ "$rc" = 0 ] && ok "bad REPO_URL: exits 0" || bad "bad REPO_URL: exits 0 (rc=$rc)"
grep -q '^WARNING: could not install' "$T/out5.txt" && ok "bad REPO_URL: WARNING" || bad "bad REPO_URL: WARNING"
[ ! -e "$H4/.claude/$REGNAME" ] && ok "bad REPO_URL: no registry written" || bad "bad REPO_URL: no registry written"

# --- installed git-publish.sh accepts the rows (cloud-rest backend) ---
PUB="$H1/.claude/hooks/git-publish.sh"
(cd "$T" && git init -q -b main repo-a && cd repo-a && git remote add origin https://github.com/good-owner/good-repo) || fatal "repo-a"
(cd "$T" && git init -q -b main repo-b && cd repo-b && git remote add origin https://github.com/commit-owner/commit-repo) || fatal "repo-b"
(cd "$T" && git init -q -b main repo-c && cd repo-c && git remote add origin https://github.com/not-granted/repo) || fatal "repo-c"
# resolve_home reads the passwd database, so run a copy whose REGISTRY= line points at the test file.
[ "$(grep -c '^REGISTRY=' "$PUB")" = 1 ] || fatal "expected exactly one REGISTRY= line in git-publish.sh"
sed -e "s|^REGISTRY=.*|REGISTRY=\"$REG\"|" "$PUB" >"$T/gp.sh" && chmod +x "$T/gp.sh" && bash -n "$T/gp.sh" || fatal "patch git-publish copy"
grep -qxF "REGISTRY=\"$REG\"" "$T/gp.sh" || fatal "REGISTRY line not rewritten"
# Revocation test above rewrote the registry; rerun run 1's script to restore the full set.
(bash "$T/s1.sh") >/dev/null 2>&1
st() { (cd "$T/$1" && CLAUDE_CODE_REMOTE=true bash "$T/gp.sh" status 2>&1); }
out=$(st repo-a)
printf '%s\n' "$out" | grep -qx 'level: pr' && printf '%s\n' "$out" | grep -qx 'default branch: main' \
  && printf '%s\n' "$out" | grep -qx 'ci changes: allowed' && printf '%s\n' "$out" | grep -qx 'backend: cloud-rest' \
  && ok "status: pr row accepted (level pr, ci allowed, backend cloud-rest)" || { bad "status: pr row accepted"; printf '%s\n' "$out" | sed 's/^/      /'; }
out=$(st repo-b)
printf '%s\n' "$out" | grep -qx 'level: commit' && printf '%s\n' "$out" | grep -qx 'backend: cloud-rest' \
  && ok "status: commit row with '-' branch accepted" || { bad "status: commit row accepted"; printf '%s\n' "$out" | sed 's/^/      /'; }
out=$(st repo-c)
printf '%s\n' "$out" | grep -qx 'level: off' && ok "status: ungranted repo is off" || bad "status: ungranted repo is off"

echo
echo "cloud setup tests: $pass passed, $fail failed"
[ "$fail" = 0 ]
