#!/bin/bash
# Single validated route for pushing a branch, opening a draft PR and squash-merging it
# in projects the user registered. Agents may run `status`, `plan`, `push`, `pr`, `merge` and `ci`,
# each bounded by the registered level (commit < push < pr < merge). Only `enable` and
# `disable` need a real terminal (require_tty is defense in depth).
# Exit code 2 = refused. Targets bash 3.2
# (macOS) and Linux. Repo files cannot relax the local checks, but CI results come from repo-authored
# workflows, so a green check is only as trustworthy as those files; hence the CI file policy below.
set -u
umask 077

die() {
  printf 'git-publish: REFUSED: %s\n' "$*" >&2
  exit 2
}

# --- environment hardening ---
PATH=/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin
export PATH
unset IFS CDPATH
LOCAL_GIT_VARS=$(git rev-parse --local-env-vars 2>/dev/null) || die "cannot list git environment variables"
for v in $LOCAL_GIT_VARS GIT_SSH GIT_SSH_COMMAND GIT_EXEC_PATH GH_REPO GH_HOST \
  GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM GIT_EXTERNAL_DIFF GIT_PROXY_COMMAND GIT_TEMPLATE_DIR \
  GIT_TRACE GIT_TRACE_CURL GIT_TRACE_PACKET GIT_TRACE_SETUP GIT_TRACE2 GIT_TRACE2_EVENT GIT_CURL_VERBOSE GH_DEBUG \
  GIT_ASKPASS GIT_SSL_NO_VERIFY GIT_SSL_CAINFO GIT_SSL_CAPATH GIT_SSL_CERT GIT_SSL_KEY GIT_ALLOW_PROTOCOL \
  XDG_CONFIG_HOME GH_CONFIG_DIR; do
  unset "$v"
done
# Repo config and hooks are writable by whoever edited the repo, so anything able to
# execute code during a publish is forced off here (git >= 2.31; verified in preflight).
# This also skips the project's own pre-push hooks on this route.
GIT_NO_REPLACE_OBJECTS=1
GIT_PAGER=cat
# Agents run this without a terminal: a missing credential must fail, not hang.
GIT_TERMINAL_PROMPT=0
GH_PROMPT_DISABLED=1
GIT_SSH_COMMAND='ssh -oBatchMode=yes'
# A promisor remote would otherwise fetch from a repo-configured URL in the middle of a scan.
GIT_NO_LAZY_FETCH=1
# Grafts and a forged commit-graph can rewrite parents and so hide commits from the scan.
GIT_GRAFT_FILE=/dev/null
export GIT_NO_REPLACE_OBJECTS GIT_PAGER GIT_TERMINAL_PROMPT GH_PROMPT_DISABLED GIT_SSH_COMMAND GIT_NO_LAZY_FETCH GIT_GRAFT_FILE
i=0
for kv in core.hooksPath=/dev/null core.fsmonitor=false core.commitGraph=false advice.graftFileDeprecated=false log.showSignature=false push.gpgSign=false diff.orderFile=/dev/null diff.suppressBlankEmpty=false diff.interHunkContext=0 protocol.ext.allow=never; do
  export "GIT_CONFIG_KEY_$i=${kv%%=*}" "GIT_CONFIG_VALUE_$i=${kv#*=}"
  i=$((i + 1))
done
GIT_CONFIG_COUNT=$i
export GIT_CONFIG_COUNT

resolve_home() {
  local user h=""
  case "$(uname -s)" in
    Darwin) user=$(id -un) && h=$(dscl . -read "/Users/$user" NFSHomeDirectory 2>/dev/null | sed -n 's/^NFSHomeDirectory: //p') ;;
    *) h=$(getent passwd "$(id -u)" 2>/dev/null | awk -F: 'NR==1 {print $6}') ;;
  esac
  case "$h" in
    /*) [ -d "$h" ] || die "home directory from the passwd database does not exist" ;;
    *) die "cannot resolve home directory from the passwd database" ;;
  esac
  printf '%s\n' "$h"
}

RESOLVED_HOME=$(resolve_home) || exit 2
REGISTRY="$RESOLVED_HOME/.claude/git-publish.registry"
# gh and git read their user config from the passwd home, never from a caller-chosen HOME.
# HTTPS_PROXY and SSL_CERT_* stay: the cloud session's egress proxy may need them.
HOME=$RESOLVED_HOME
GH_CONFIG_DIR="$RESOLVED_HOME/.config/gh"
export HOME GH_CONFIG_DIR

require_tty() {
  [ -t 0 ] && [ -t 1 ] && (: </dev/tty) 2>/dev/null || die "this command must be run by the user in their own terminal"
}

# Claude Code on the web blocks GraphQL, so pr, merge and ci use the REST API there. The cloud backend
# honors only `github:<owner>/<repo>` registry rows, so setting the variable elsewhere finds no row.
BACKEND=local
if [ "${CLAUDE_CODE_REMOTE:-}" = true ]; then
  BACKEND=cloud-rest
fi

# --- patterns ---
CONVENTIONAL_RE='^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)(\([^()[:space:]]+\))?!?: [^[:space:]].*$'
SAFE_BRANCH_RE='^[A-Za-z0-9][A-Za-z0-9._/-]*$'
CONVENTIONAL_BRANCH_RE='^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)/[a-z0-9]+(-[a-z0-9]+)*$'
# Matched case-insensitively. Report locations only; matched text must never be printed.
SECRET_RE='-----BEGIN ([A-Z0-9]+ )*PRIVATE KEY( BLOCK)?-----'
SECRET_RE="$SECRET_RE|(^|[^[:alnum:]])(AKIA|ASIA)[0-9A-Z]{16}"
SECRET_RE="$SECRET_RE|(^|[^[:alnum:]_])gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{22,}"
SECRET_RE="$SECRET_RE|(^|[^[:alnum:]])xox[abeoprs]-[A-Za-z0-9-]{10,}"
SECRET_RE="$SECRET_RE|(^|[^[:alnum:]_-])sk-[A-Za-z0-9_-]{32,}|(^|[^[:alnum:]_-])sk-ant-[A-Za-z0-9_-]{20,}"
SECRET_RE="$SECRET_RE|(^|[^[:alnum:]])(sk|rk)_live_[A-Za-z0-9]{16,}"
SECRET_RE="$SECRET_RE|(^|[^[:alnum:]_-])AIza[0-9A-Za-z_-]{35}|(^|[^[:alnum:]_-])glpat-[A-Za-z0-9_-]{20,}|(^|[^[:alnum:]_])npm_[A-Za-z0-9]{36}"
SECRET_RE="$SECRET_RE|eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"
SECRET_RE="$SECRET_RE|https?://[^/[:space:]:@]+:[^/[:space:]@]+@"
SECRET_RE="$SECRET_RE|(password|passwd|pwd|secret|api[_-]?key|access[_-]?token|auth[_-]?token|private[_-]?key)[\"']?[[:space:]]*[:=][[:space:]]*[\"'][^\"'[:space:]\$<{][^\"'[:space:]]{15,}[\"']"
# Unquoted value of 8+ characters. Letters and underscores alone read as an identifier (ordinary code),
# so one other character is required; grep -E has no lookahead, so its position is enumerated.
UQ_ALPHA='[[:alpha:]_]'
UQ_ANY="[^\"'[:space:](){}<>\$,;&|/.]"
UQ_OTHER="[^[:alpha:]_\"'[:space:](){}<>\$,;&|/.]"
UQ_VALUE="[^[:alpha:]_\"'[:space:]\$<{(%#/.,;&|]$UQ_ANY{7,}|$UQ_ALPHA{8,}$UQ_OTHER$UQ_ANY*"
for k in 0 1 2 3 4 5 6; do
  UQ_VALUE="$UQ_VALUE|$UQ_ALPHA{$((k + 1))}$UQ_OTHER$UQ_ANY{$((6 - k)),}"
done
SECRET_RE="$SECRET_RE|(password|passwd|pwd|secret|api[_-]?key|access[_-]?token|auth[_-]?token|private[_-]?key)[[:space:]]*=[[:space:]]*($UQ_VALUE)([[:space:];,&|]|\$)"

matches() { printf '%s\n' "$1" | LC_ALL=C grep -Eq -- "$2"; }
# Only grep's "no match" counts as clean; a grep error must end in a refusal at the caller.
is_secret() { printf '%s\n' "$1" | LC_ALL=C grep -aEiq -- "$SECRET_RE"; [ "$?" -ne 1 ]; }
lower() { printf '%s' "$1" | LC_ALL=C tr '[:upper:]' '[:lower:]'; }
# Display only: drops C0 controls, then UTF-8 C1 controls and bidirectional overrides.
sanitize() {
  LC_ALL=C tr -d '\000-\010\013-\037\177' | LC_ALL=C sed -e $'s/\xC2[\x80-\x9F]//g' -e $'s/\xE2\x80[\x8E\x8F\xAA-\xAE]//g' -e $'s/\xE2\x81[\xA6-\xA9]//g'
}

REFUSALS=0
refuse() {
  printf 'git-publish: REFUSED: %s\n' "$*" >&2
  REFUSALS=$((REFUSALS + 1))
}
stop_if_refused() { [ "$REFUSALS" -eq 0 ] || exit 2; }

# --- arguments ---
OPT_EXPECT=""
OPT_CONTENT=""
OPT_TITLE=""
OPT_BODY=""
OPT_STYLE=""
OPT_PR=""
OPT_ALLOW_CI=0
OPT_MARK_READY=0
OPT_AFTER_READY=0
parse_opts() {
  local allowed="$1" flag
  shift
  while [ $# -gt 0 ]; do
    flag=$1
    case " $allowed " in
      *" $flag "*) ;;
      *) die "unknown or disallowed argument; allowed here: ${allowed:-none}" ;;
    esac
    if [ "$flag" = --allow-ci-changes ]; then
      [ "$OPT_ALLOW_CI" = 0 ] || die "duplicate $flag"
      OPT_ALLOW_CI=1
      shift
      continue
    fi
    if [ "$flag" = --after-ready ]; then
      [ "$OPT_AFTER_READY" = 0 ] || die "duplicate $flag"
      OPT_AFTER_READY=1
      shift
      continue
    fi
    if [ "$flag" = --mark-ready-only ]; then
      [ "$OPT_MARK_READY" = 0 ] || die "duplicate $flag"
      OPT_MARK_READY=1
      shift
      continue
    fi
    [ $# -ge 2 ] && [ -n "$2" ] || die "$flag needs a value"
    case "$flag" in
      --expect-sha) [ -z "$OPT_EXPECT" ] || die "duplicate $flag"; OPT_EXPECT=$2 ;;
      --expect-content) [ -z "$OPT_CONTENT" ] || die "duplicate $flag"; OPT_CONTENT=$2 ;;
      --title-file) [ -z "$OPT_TITLE" ] || die "duplicate $flag"; OPT_TITLE=$2 ;;
      --body-file) [ -z "$OPT_BODY" ] || die "duplicate $flag"; OPT_BODY=$2 ;;
      --style) [ -z "$OPT_STYLE" ] || die "duplicate $flag"; OPT_STYLE=$2 ;;
      --pr) [ -z "$OPT_PR" ] || die "duplicate $flag"; OPT_PR=$2 ;;
      *) die "unknown or disallowed argument; allowed here: ${allowed:-none}" ;;
    esac
    shift 2
  done
}
require_expect_sha() {
  matches "$OPT_EXPECT" '^[0-9a-f]{40}$' || die "--expect-sha must be a full 40-hex commit SHA"
}
require_pr_number() {
  case "$OPT_PR" in
    ""|0*|*[!0123456789]*) die "--pr must be a positive integer" ;;
  esac
  [ "${#OPT_PR}" -le 10 ] || die "--pr must be a positive integer"
}

# --- registry: TSV of git-common-dir realpath, push URL, level, default branch, style, CI changes ---
# The CI changes column is `ci` or `-`; a row without it (five columns) means not allowed.
# Cloud rows (cloud-rest backend only) are `github:<owner>/<repo>`, `-`, level, default branch, style, CI changes;
# the local backend never honors them, and enable/disable never write them.
R_KEY=""
R_URL=""
R_LEVEL=off
R_DEFAULT=""
R_STYLE=""
R_CI=-

repo_key() {
  local common
  common=$(git rev-parse --git-common-dir 2>/dev/null) || return 1
  (cd -- "$common" 2>/dev/null && pwd -P)
}

registry_lookup() {
  local k u l d s c
  [ "$BACKEND" = local ] || { cloud_registry_lookup; return; }
  R_KEY=$(repo_key) || return 1
  [ -n "$R_KEY" ] && [ -f "$REGISTRY" ] && [ ! -L "$REGISTRY" ] || return 1
  while IFS=$'\t' read -r k u l d s c || [ -n "$k" ]; do
    case "$k" in github:*) continue ;; esac
    [ "$k" = "$R_KEY" ] || continue
    case "$l" in commit|push|pr|merge) ;; *) return 1 ;; esac
    case "$s" in conventional|project) ;; *) return 1 ;; esac
    case "$c" in ""|-|ci) ;; *) return 1 ;; esac
    if [ "$l" = commit ]; then
      [ "$u" = - ] && [ "$d" = - ] || return 1
    else
      [ -n "$u" ] && [ "$u" != - ] && matches "$d" "$SAFE_BRANCH_RE" || return 1
    fi
    R_URL=$u R_LEVEL=$l R_DEFAULT=$d R_STYLE=$s R_CI=${c:--}
    return 0
  done <"$REGISTRY"
  return 1
}

# Cloud rows are keyed by the slug derived from origin. R_URL is the live origin push URL, so
# check_remote_identity still refuses a push URL that changed after the lookup.
# GitHub owner and repository names are case-insensitive, so the key is too; two matching rows are ambiguous.
cloud_registry_lookup() {
  local k u l d s c want found=0 row=""
  cloud_origin || return 1
  R_KEY="github:$REPO_SLUG"
  want=$(lower "$R_KEY")
  [ -f "$REGISTRY" ] && [ ! -L "$REGISTRY" ] || return 1
  while IFS=$'\t' read -r k u l d s c || [ -n "$k" ]; do
    [ "$(lower "$k")" = "$want" ] || continue
    found=$((found + 1))
    [ "$found" -eq 1 ] || die "more than one github: registry row matches this repository; the user must remove the duplicate"
    row=$k$'\t'$u$'\t'$l$'\t'$d$'\t'$s$'\t'$c
  done <"$REGISTRY"
  [ "$found" -eq 1 ] || return 1
  IFS=$'\t' read -r k u l d s c <<<"$row"
  matches "${k#github:}" '^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$' || return 1
  [ "$u" = - ] || return 1
  case "$l" in commit|push|pr|merge) ;; *) return 1 ;; esac
  case "$s" in conventional|project) ;; *) return 1 ;; esac
  case "$c" in ""|-|ci) ;; *) return 1 ;; esac
  if [ "$l" != commit ] || [ "$d" != - ]; then
    matches "$d" "$SAFE_BRANCH_RE" || return 1
  fi
  R_URL=$CLOUD_URL R_LEVEL=$l R_DEFAULT=$d R_STYLE=$s R_CI=${c:--}
  return 0
}

# Copy every row except this repository's to stdout.
registry_other_rows() {
  local line
  [ -f "$REGISTRY" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$R_KEY"$'\t'*) ;;
      *) printf '%s\n' "$line" ;;
    esac
  done <"$REGISTRY"
}

# Atomically replace the registry with stdin, mode 600.
registry_write() {
  local dir tmp
  [ ! -L "$REGISTRY" ] || die "registry is a symlink"
  dir=${REGISTRY%/*}
  mkdir -p -- "$dir" || die "cannot create registry directory"
  tmp=$(mktemp "$REGISTRY.XXXXXX") || die "cannot create temporary registry file"
  if ! cat >"$tmp" || ! chmod 600 "$tmp" || ! mv -f "$tmp" "$REGISTRY"; then
    rm -f -- "$tmp"
    die "cannot write registry"
  fi
}

level_rank() {
  case "$1" in
    commit) echo 1 ;;
    push) echo 2 ;;
    pr) echo 3 ;;
    merge) echo 4 ;;
    *) echo 0 ;;
  esac
}

# --- URL helpers: never print the URL from a refusal ---
url_refusal() {
  local u=$1
  matches "$u" '[[:cntrl:]]' && { echo "origin push URL contains control characters"; return 0; }
  matches "$u" '^[A-Za-z0-9+.-]+::' && { echo "origin push URL uses a remote helper transport"; return 0; }
  if printf '%s\n' "$u" | LC_ALL=C grep -Eiq -- '^https?://[^/]*@|^[a-z0-9+.-]+://[^/@]*:[^/@]*@' || is_secret "$u"; then
    echo "origin push URL embeds credentials; remove them first"
    return 0
  fi
  return 1
}

REPO_SLUG=""
parse_github() {
  local rest
  case "$1" in
    git@github.com:*) rest=${1#git@github.com:} ;;
    ssh://git@github.com/*) rest=${1#ssh://git@github.com/} ;;
    https://github.com/*) rest=${1#https://github.com/} ;;
    *) return 1 ;;
  esac
  rest=${rest%/}
  rest=${rest%.git}
  matches "$rest" '^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$' || return 1
  case "$rest" in */.|*/..) return 1 ;; esac
  REPO_SLUG=$rest
}

# Cloud backend only: the session's loopback git proxy, http(s)://[userinfo@]host[:port]/git/<owner>/<repo>[.git].
# The URL may embed userinfo, so it is never printed; only the slug is.
parse_cloud_proxy() {
  local rest
  printf '%s\n' "$1" | LC_ALL=C grep -Eq -- '^https?://([^/@?#[:space:]]+@)?(127\.0\.0\.1|localhost|\[::1\])(:[0-9]{1,5})?/git/[^/?#[:space:]]+/[^/?#[:space:]]+$' || return 1
  rest=${1#*://}
  rest=${rest#*/git/}
  rest=${rest%.git}
  matches "$rest" '^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$' || return 1
  case "$rest" in */.|*/..) return 1 ;; esac
  REPO_SLUG=$rest
}

# Cloud backend only: exactly one origin push URL, in a github.com form or the loopback proxy form.
CLOUD_URL=""
cloud_origin() {
  local urls
  urls=$(git remote get-url --push --all origin 2>/dev/null) || return 1
  [ -n "$urls" ] && [ "$(printf '%s\n' "$urls" | wc -l)" -eq 1 ] || return 1
  matches "$urls" '[[:cntrl:]]' && return 1
  parse_github "$urls" || parse_cloud_proxy "$urls" || return 1
  CLOUD_URL=$urls
}

# Sets REPO_SLUG for pr, merge and ci. The cloud slug was derived from origin by the registry lookup.
resolve_slug() {
  if [ "$BACKEND" = cloud-rest ]; then
    [ -n "$REPO_SLUG" ] && [ "$R_KEY" = "github:$REPO_SLUG" ]
  else
    parse_github "$R_URL"
  fi
}

# Output is empty when the branch does not exist on the remote; non-zero on network failure.
remote_branch_sha() {
  local ref="refs/heads/$1" out
  out=$(git ls-remote -- "$R_URL" "$ref" 2>/dev/null) || return 1
  printf '%s\n' "$out" | awk -v ref="$ref" '$2 == ref {print $1; exit}'
}

# Cloud backend only: the loopback proxy is reachable by the agent, so branch tips that the checks rely on
# come from the GitHub REST API instead. Prints the 40-hex commit SHA; non-zero on any failure or odd shape.
cloud_ref_sha() {
  local out
  command -v gh >/dev/null 2>&1 || die "gh is not installed"
  command -v jq >/dev/null 2>&1 || die "jq is not installed"
  out=$(gh api "repos/$REPO_SLUG/git/ref/heads/$1" 2>/dev/null) || return 1
  out=$(printf '%s' "$out" | jq -er --arg r "refs/heads/$1" \
    'select(type == "object" and .ref == $r and (.object | type) == "object" and .object.type == "commit") | .object.sha | strings' 2>/dev/null) || return 1
  matches "$out" '^[0-9a-f]{40}$' || return 1
  printf '%s\n' "$out"
}

# --- preflight ---
BRANCH=""
HEAD_SHA=""
BASE_SHA=""

check_branch_name() {
  local b=$1
  matches "$b" "$SAFE_BRANCH_RE" || die "branch name is outside the safe character set"
  case "$b" in
    *..*|*//*|*/|*.|*.lock|*.lock/*|*/.*) die "branch name is outside the safe character set" ;;
  esac
  [ "${#b}" -le 200 ] || die "branch name is too long"
  case "$(lower "$b")" in
    main|master|develop|trunk|production|release/*) die "publishing protected branch '$b' is not allowed" ;;
  esac
  [ "$(lower "$b")" != "$(lower "$R_DEFAULT")" ] || die "publishing the registered default branch is not allowed"
}

# Repo-local config that could redirect the push or run code during it.
# Prints the section name only: a full key can embed a URL with a token.
check_repo_config() {
  local cfg scope key lk
  cfg=$(git config --list --includes --name-only --show-scope 2>/dev/null) || die "cannot read repository config"
  while IFS=$'\t' read -r scope key; do
    case "$scope" in local|worktree) ;; *) continue ;; esac
    lk=$(lower "$key")
    case "$lk" in
      http.postbuffer|http.lowspeedlimit|http.lowspeedtime|http.version|http.maxrequests) continue ;;
      filter.lfs.*|lfs.*) die "Git LFS repositories are not supported on this route" ;;
      core.sshcommand|core.gitproxy|core.askpass|core.alternaterefscommand|credential.*|http.*|url.*|protocol.*|extensions.partialclone|remote.origin.mirror|remote.*.promisor|remote.*.partialclonefilter|remote.*.uploadpack|remote.*.receivepack|remote.*.vcs|remote.*.proxy)
        die "repository config section '${lk%%.*}' has a setting that is not allowed on this route; remove it first" ;;
    esac
  done <<<"$cfg"
}

check_remote_identity() {
  local urls
  # --all because every configured pushurl receives the push, not just the first.
  urls=$(git remote get-url --push --all origin 2>/dev/null) || die "remote origin has no push URL"
  [ "$urls" = "$R_URL" ] || die "origin push URL differs from the registered URL"
  check_repo_config
}

check_lfs() {
  local rc
  git grep -q -F 'filter=lfs' "$HEAD_SHA" -- ':(glob)**/.gitattributes' 2>/dev/null
  rc=$?
  [ "$rc" -ne 0 ] && [ "$rc" -ne 1 ] && die "cannot read .gitattributes from HEAD"
  [ "$rc" -eq 1 ] || die "Git LFS repositories are not supported on this route"
}

# Local refs can be moved to hide commits from the checks, so online runs anchor the base to the remote.
compute_base() {
  local mode=$1 tip="" remote
  if [ "$mode" = online ]; then
    if [ "$BACKEND" = cloud-rest ]; then
      remote=$(cloud_ref_sha "$R_DEFAULT") || die "cannot read the default branch from GitHub"
    else
      remote=$(remote_branch_sha "$R_DEFAULT") || die "cannot read the default branch from the registered remote"
    fi
    if [ -n "$remote" ]; then
      git cat-file -e "$remote^{commit}" 2>/dev/null || die "default branch on the remote is newer than local history; fetch it first"
      tip=$remote
    fi
  fi
  [ -n "$tip" ] || tip=$(git rev-parse --quiet --verify "refs/remotes/origin/$R_DEFAULT^{commit}" 2>/dev/null)
  [ -n "$tip" ] || tip=$(git rev-parse --quiet --verify "refs/heads/$R_DEFAULT^{commit}" 2>/dev/null)
  [ -n "$tip" ] || die "registered default branch not found locally; fetch it first"
  BASE_SHA=$(git merge-base "$tip" "$HEAD_SHA" 2>/dev/null) || die "no merge-base with the registered default branch"
  [ -n "$BASE_SHA" ] || die "no merge-base with the registered default branch"
}

require_level() {
  local need=$1
  git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository"
  [ "$(git config --get core.hooksPath)" = /dev/null ] || die "git is too old to disable repository hooks (need 2.31 or newer)"
  registry_lookup || die "repository is not registered; the user must run enable in their terminal"
  [ "$(level_rank "$R_LEVEL")" -ge "$(level_rank "$need")" ] || die "registered level '$R_LEVEL' is too low; '$need' is required"
}

# Fatal checks stop at the first failure because later checks depend on them.
preflight() {
  local need=$1 mode=$2 expect=$3 ref
  require_level "$need"
  # Shallow boundaries cut history the same way grafts do, so the scan could miss commits.
  [ "$(git rev-parse --is-shallow-repository 2>/dev/null)" = false ] || die "shallow repositories are not supported on this route; fetch the full history first"

  ref=$(git symbolic-ref --quiet HEAD 2>/dev/null) || die "detached HEAD"
  case "$ref" in
    refs/heads/*) BRANCH=${ref#refs/heads/} ;;
    *) die "HEAD is not a local branch" ;;
  esac
  check_branch_name "$BRANCH"
  if [ "$R_STYLE" = conventional ] && ! matches "$BRANCH" "$CONVENTIONAL_BRANCH_RE"; then
    die "branch name must be <type>/<kebab-summary>"
  fi

  HEAD_SHA=$(git rev-parse --quiet --verify "HEAD^{commit}" 2>/dev/null) || die "cannot resolve HEAD"
  if [ -n "$expect" ] && [ "$expect" != "$HEAD_SHA" ]; then
    die "HEAD does not match --expect-sha"
  fi

  check_remote_identity
  check_lfs
  compute_base "$mode"
  [ "$(git rev-list --count "$BASE_SHA..$HEAD_SHA")" -gt 0 ] || die "no commits to publish since the merge-base"
}

safe_diff() {
  git diff --no-ext-diff --no-textconv --no-color --no-renames --no-relative --text --submodule=short \
    --unified=0 --inter-hunk-context=0 --src-prefix=a/ --dst-prefix=b/ "$@"
}

# Reduce a unified diff to added lines (mode=content) or file:line of the wanted lines (mode=map).
# Hunk sizes are tracked so an added line that looks like a +++ header cannot change the file name.
# A hunk that does not add up means the scan lost its place, so it exits non-zero and the caller refuses.
added_lines() {
  LC_ALL=C awk -v mode="$1" -v want="${2:-}" '
    BEGIN { n = split(want, w, " "); for (i = 1; i <= n; i++) wanted[w[i]] = 1 }
    function emit() {
      seen++
      if (mode == "content") print substr($0, 2)
      else if (seen in wanted) print path ":" line
    }
    /^diff --git / && (old != 0 || new != 0) { exit 1 }
    old > 0 || new > 0 {
      c = substr($0, 1, 1)
      if (c == "-") { old-- }
      else if (c == "+") { emit(); new--; line++ }
      else if (c == " " || c == "") { old--; new--; line++ }
      next
    }
    /^@@ / {
      split($0, f, " ")
      a = split(substr(f[2], 2), o, ","); old = (a > 1) ? o[2] + 0 : 1
      b = split(substr(f[3], 2), p, ","); new = (b > 1) ? p[2] + 0 : 1
      line = p[1] + 0
      next
    }
    /^\+\+\+ / {
      path = substr($0, 5)
      sub(/\t$/, "", path)
      gsub(/"/, "", path)
      sub(/^b\//, "", path)
    }
    END { if (old != 0 || new != 0) exit 1 }
  '
}

is_forbidden_name() {
  case "$(lower "${1##*/}")" in
    .env.example|.env.sample|.env.template|.env.dist) return 1 ;;
    .env*|*.pem|*.key|*.p12|*.pfx|*.jks|*.keystore|*.kdbx|*.tfvars|*.tfstate|*.tfstate.backup) return 0 ;;
    id_rsa*|id_dsa*|id_ecdsa*|id_ed25519*) return 0 ;;
    .npmrc|.netrc|.pypirc|.git-credentials|.htpasswd|credentials|credentials.json|secrets.json) return 0 ;;
  esac
  return 1
}

# CI/policy files: workflows and CODEOWNERS decide what a green merge means; Claude Code config
# (.claude/, CLAUDE.md, CLAUDE.local.md, .mcp.json) decides what agents run and may do in this repository.
is_ci_path() {
  case "$(lower "$1")" in
    .github/workflows|.github/workflows/*|.github/actions|.github/actions/*|codeowners|.github/codeowners|docs/codeowners) return 0 ;;
    .claude|.claude/*|*/.claude|*/.claude/*) return 0 ;;
    claude.md|*/claude.md|claude.local.md|*/claude.local.md|.mcp.json|*/.mcp.json) return 0 ;;
  esac
  return 1
}

# Why a CI policy file change is refused on this run; empty means allowed. Set by run_standards.
CI_REFUSAL=""
# Workflows and CODEOWNERS decide what a green merge means, so deletions count too.
check_ci_files() {
  local from=$1 to=$2 where=$3 names f
  [ -n "$CI_REFUSAL" ] || return 0
  names=$(git diff --no-ext-diff --no-textconv --no-renames --no-relative --name-only -z "$from" "$to" | LC_ALL=C tr '\0' '\n'; exit "${PIPESTATUS[0]}") \
    || die "cannot list files of $where"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if is_ci_path "$f"; then
      refuse "CI policy file changed in $where: $(printf '%s' "$f" | sanitize); $CI_REFUSAL"
    fi
  done <<<"$names"
}

# Every commit is scanned on its own, so content added and later removed is still refused.
# All git failures refuse: a scan that did not run must never look like a clean one.
check_commit_diff() {
  local parent=$1 sha=$2 short=$3 names f hits locs loc
  names=$(git diff --no-ext-diff --no-textconv --no-renames --no-relative --name-only --diff-filter=d -z "$parent" "$sha" | LC_ALL=C tr '\0' '\n'; exit "${PIPESTATUS[0]}") \
    || die "cannot list files of commit $short"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if is_forbidden_name "$f"; then
      refuse "forbidden file in commit $short: $(printf '%s' "$f" | sanitize)"
    fi
  done <<<"$names"

  hits=$(
    safe_diff "$parent" "$sha" | added_lines content | LC_ALL=C grep -anEi -- "$SECRET_RE" | LC_ALL=C awk -F: '{print $1}' | tr '\n' ' '
    s=("${PIPESTATUS[@]}")
    [ "${s[0]}" -eq 0 ] && [ "${s[1]}" -eq 0 ] && [ "${s[2]}" -le 1 ]
  ) || die "cannot scan commit $short"
  [ -n "${hits// /}" ] || return 0
  locs=$(safe_diff "$parent" "$sha" | added_lines map "$hits"; exit "$((PIPESTATUS[0] | PIPESTATUS[1]))") || die "cannot scan commit $short"
  while IFS= read -r loc; do
    refuse "secret pattern at $(printf '%s' "$loc" | sanitize) (commit $short)"
  done <<<"$locs"
}

scan_commits() {
  local revs sha short info parents subj parent msg merge
  revs=$(git rev-list "$BASE_SHA..$HEAD_SHA") || die "cannot list commits"
  for sha in $revs; do
    short=${sha%"${sha#???????}"}
    info=$(git log -1 --no-color --format='%P%x09%s' "$sha") || die "cannot read commit $short"
    parents=${info%%$'\t'*}
    subj=${info#*$'\t'}
    merge=0
    case "$parents" in *' '*) merge=1 ;; esac
    case "$subj" in
      fixup!*|squash!*) refuse "commit $short: fixup!/squash! subject; rebase it away first" ;;
    esac
    # --no-merges semantics: merge subjects are generated by git and exempt from the format.
    if [ "$R_STYLE" = conventional ] && [ "$merge" = 0 ] \
      && ! matches "$subj" "$CONVENTIONAL_RE" && ! matches "$subj" '^Revert ".+"$'; then
      refuse "commit $short: subject is not Conventional Commits 1.0.0"
    fi
    msg=$(git log -1 --no-color --format=%B "$sha") || die "cannot read commit $short"
    if is_secret "$msg"; then
      refuse "commit $short: secret pattern in the commit message"
    fi
    parent=${parents%% *}
    if [ -z "$parent" ]; then
      parent=$(git hash-object -t tree /dev/null) || die "cannot compute the empty tree"
    fi
    check_commit_diff "$parent" "$sha" "$short"
    check_ci_files "$parent" "$sha" "commit $short"
  done
}

TITLE_PATH=""
BODY_PATH=""
TITLE_COPY=""
BODY_COPY=""
TITLE_VALUE=""
CONTENT_SHA=""
cleanup_copies() { rm -f "$TITLE_COPY" "$BODY_COPY" 2>/dev/null; }
trap cleanup_copies EXIT
trap 'exit 2' INT TERM

# Walks the path one component at a time: only the first level may be a symlink, and only the
# system links /tmp, /var and /etc (macOS). Sets RESOLVED_PATH; returns 1 after recording a refusal.
RESOLVED_PATH=""
resolve_input_path() {
  local label=$1 file=$2 rest comp cur=""
  case "$file" in
    -*) refuse "$label file path must not start with a dash"; return 1 ;;
    *[[:cntrl:]]*) refuse "$label file path contains control characters"; return 1 ;;
  esac
  case "$file" in
    /*) rest=${file#/} ;;
    *) rest="$(pwd -P)/$file"; rest=${rest#/} ;;
  esac
  while [ -n "$rest" ]; do
    case "$rest" in
      */*) comp=${rest%%/*}; rest=${rest#*/} ;;
      *) comp=$rest; rest="" ;;
    esac
    case "$comp" in
      ""|.) continue ;;
      ..) cur=${cur%/*}; continue ;;
    esac
    if [ -L "$cur/$comp" ]; then
      [ -n "$rest" ] || { refuse "$label file must not be a symlink"; return 1; }
      if [ -z "$cur" ]; then
        case "$comp" in
          tmp|var|etc) cur=$(cd "/$comp" 2>/dev/null && pwd -P); continue ;;
        esac
      fi
      refuse "$label file has a symlinked parent directory"
      return 1
    fi
    cur="$cur/$comp"
  done
  [ -n "$cur" ] || { refuse "$label file path is not valid"; return 1; }
  RESOLVED_PATH=$cur
}

# Copies the file once; every later check and the PR itself use only that private copy.
# Sets COPIED_PATH; returns 1 after recording a refusal.
COPIED_PATH=""
copy_input_file() {
  local label=$1 file=$2 copy size
  resolve_input_path "$label" "$file" || return 1
  if is_forbidden_name "$RESOLVED_PATH"; then
    refuse "$label file has a forbidden name"
    return 1
  fi
  [ -f "$RESOLVED_PATH" ] && [ -r "$RESOLVED_PATH" ] || { refuse "$label file is not a readable regular file"; return 1; }
  copy=$(mktemp "${TMPDIR:-/tmp}/git-publish.XXXXXX") || die "cannot create a private temporary file"
  if [ "$label" = title ]; then TITLE_COPY=$copy; else BODY_COPY=$copy; fi
  head -c 65537 "$RESOLVED_PATH" >"$copy" || { refuse "$label file cannot be read"; return 1; }
  size=$(wc -c <"$copy") || { refuse "$label file cannot be read"; return 1; }
  [ "$((size))" -le 65536 ] || { refuse "$label file is larger than 64KB"; return 1; }
  COPIED_PATH=$copy
}

sha256_stdin() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum
  else
    return 1
  fi
}

# SHA-256 over the single title line, a newline, then the body bytes.
compute_content_sha() {
  CONTENT_SHA=$({ printf '%s\n' "$TITLE_VALUE"; cat -- "$BODY_COPY"; } | sha256_stdin | awk '{print $1}')
  matches "$CONTENT_SHA" '^[0-9a-f]{64}$' || die "cannot compute SHA-256; shasum or sha256sum is required"
}

report_text_secrets() {
  local label=$1 file=$2 n hits
  hits=$(
    LC_ALL=C grep -anEi -- "$SECRET_RE" "$file" | LC_ALL=C awk -F: '{print $1}'
    s=("${PIPESTATUS[@]}")
    [ "${s[0]}" -le 1 ] && [ "${s[1]}" -eq 0 ]
  ) || { refuse "cannot scan the $label text"; return 0; }
  [ -n "$hits" ] || return 0
  while IFS= read -r n; do
    refuse "secret pattern at $label:$n"
  done <<<"$hits"
}

# Shared by pr and merge. Reads TITLE_VALUE and its private copy TITLE_COPY.
check_title() {
  if [ -z "$TITLE_VALUE" ]; then
    refuse "PR title is empty"
  elif matches "$TITLE_VALUE" '[[:cntrl:]]' || [ "$(printf '%s\n' "$TITLE_VALUE" | wc -l)" -ne 1 ]; then
    refuse "PR title must be a single line without control characters"
  elif [ "${#TITLE_VALUE}" -gt 256 ]; then
    refuse "PR title is longer than 256 characters"
  elif [ "$R_STYLE" = conventional ] && ! matches "$TITLE_VALUE" "$CONVENTIONAL_RE"; then
    refuse "PR title is not Conventional Commits 1.0.0"
  fi
  case "$TITLE_VALUE" in
    fixup!*|squash!*) refuse "PR title must not be a fixup!/squash! subject" ;;
  esac
  report_text_secrets title "$TITLE_COPY"
}

# Shared by pr and merge. Reads the private copy BODY_COPY.
check_body_headings() {
  local heading
  [ "$R_STYLE" = conventional ] || return 0
  for heading in What Why 'How tested' Risks; do
    LC_ALL=C grep -aEq -- "^## $heading[[:space:]]*$" "$BODY_COPY" || refuse "PR body is missing the heading '## $heading'"
  done
}

check_pr_text() {
  local title_file=$1 body_file=$2
  if copy_input_file title "$title_file"; then
    TITLE_PATH=$RESOLVED_PATH
    TITLE_VALUE=$(cat -- "$TITLE_COPY")
    check_title
  fi
  if copy_input_file body "$body_file"; then
    BODY_PATH=$RESOLVED_PATH
    check_body_headings
    report_text_secrets body "$BODY_COPY"
  fi
}

# Pass "merge" from the merge command: it never accepts CI policy file changes, whatever the registry says.
run_standards() {
  if [ "${1:-}" = merge ]; then
    CI_REFUSAL="merge never accepts these changes"
  elif [ "$R_CI" = ci ]; then
    CI_REFUSAL=""
  else
    CI_REFUSAL="the user must allow these changes with enable --allow-ci-changes in their terminal"
  fi
  scan_commits
  check_ci_files "$BASE_SHA" "$HEAD_SHA" "the commit range"
}

abs_path() {
  local dir
  dir=$(cd -- "$(dirname -- "$1")" 2>/dev/null && pwd -P) || die "cannot resolve path"
  printf '%s/%s\n' "$dir" "$(basename -- "$1")"
}

# R_URL already went through insteadOf/pushInsteadOf (git remote get-url --push), and git applies them again to a
# URL given to push. A chain in global or system config (A to B, B to C) would send the push to an unchecked C.
# `git -c remote.X.url=... remote get-url` cannot test this (it only knows remotes from repository config), so
# refuse when any rewrite prefix still matches R_URL. The URL is never printed: it may carry userinfo.
check_no_second_rewrite() {
  local rec prefix
  while IFS= read -r -d '' rec; do
    prefix=${rec#*$'\n'}
    case "$R_URL" in "$prefix"*) die "a git url.*.insteadOf or pushInsteadOf rule would rewrite the push URL again; remove the chained rule" ;; esac
  done < <(git config -z --get-regexp '^url\..*\.(insteadof|pushinsteadof)$' 2>/dev/null)
  return 0
}

# Pushes to the verified URL itself, not to `origin`, so remote config is not read again after the checks.
# git may echo the URL; any userinfo in it is masked before the output reaches the caller (on stderr).
do_push() {
  local b=$BRANCH rc
  check_remote_identity
  check_no_second_rewrite
  [ "$(git rev-parse --quiet --verify "refs/heads/$b^{commit}")" = "$HEAD_SHA" ] || die "branch moved during preflight"
  git push --no-follow-tags --recurse-submodules=no -- "$R_URL" "$HEAD_SHA:refs/heads/$b" 2>&1 \
    | LC_ALL=C sed -e 's#://[^/@[:space:]]*@#://***@#g' >&2
  rc=${PIPESTATUS[0]}
  return "$rc"
}

# --- subcommands ---
cmd_status() {
  local ci=refused
  [ $# -eq 0 ] || die "status takes no arguments"
  if registry_lookup; then
    [ "$R_CI" = ci ] && ci=allowed
    printf 'level: %s\nstyle: %s\ndefault branch: %s\nci changes: %s\n' "$R_LEVEL" "$R_STYLE" "$R_DEFAULT" "$ci"
  else
    printf 'level: off\nstyle: -\ndefault branch: -\nci changes: refused\n'
  fi
  printf 'backend: %s\n' "$BACKEND"
}

cmd_plan() {
  local need=push script top cmd log_out stat_out hooks_dir
  parse_opts "--title-file --body-file" "$@"
  if [ -n "$OPT_TITLE" ] || [ -n "$OPT_BODY" ]; then
    [ -n "$OPT_TITLE" ] && [ -n "$OPT_BODY" ] || die "--title-file and --body-file must be given together"
    need=pr
  fi
  preflight "$need" offline ""
  if [ "$need" = pr ]; then
    resolve_slug || die "pull requests are supported on github.com only"
    check_pr_text "$OPT_TITLE" "$OPT_BODY"
  fi
  run_standards
  stop_if_refused
  [ "$need" = pr ] && compute_content_sha

  script=$(abs_path "${BASH_SOURCE[0]}")
  top=$(git rev-parse --show-toplevel) || die "cannot find the work tree"
  cmd="cd $(printf '%q' "$top") && $(printf '%q' "$script")"
  if [ "$need" = pr ]; then
    cmd="$cmd pr --expect-sha $HEAD_SHA --expect-content $CONTENT_SHA --title-file $(printf '%q' "$TITLE_PATH") --body-file $(printf '%q' "$BODY_PATH")"
  else
    cmd="$cmd push --expect-sha $HEAD_SHA"
  fi

  log_out=$(git log --no-color --format='  %h %s' "$BASE_SHA..$HEAD_SHA") || die "cannot list commits"
  stat_out=$(git diff --no-ext-diff --no-textconv --no-color --no-relative --stat "$BASE_SHA" "$HEAD_SHA") || die "cannot compute the diffstat"

  printf 'branch: %s\nhead: %s\n' "$BRANCH" "$HEAD_SHA"
  printf 'base: %s (merge-base with %s)\n' "$BASE_SHA" "$R_DEFAULT"
  printf 'commits:\n'
  printf '%s\n' "$log_out" | sanitize
  printf 'diffstat:\n'
  printf '%s\n' "$stat_out" | sanitize
  if [ "$need" = pr ]; then
    printf 'pr title: %s\n' "$(printf '%s' "$TITLE_VALUE" | sanitize)"
    printf 'pr body preview:\n'
    head -n 40 "$BODY_COPY" | sanitize | sed 's/^/  /'
    [ "$(wc -l <"$BODY_COPY")" -le 40 ] || printf '  [body continues; preview limited to 40 lines]\n'
    printf 'content sha256: %s\n' "$CONTENT_SHA"
  fi
  # GIT_CONFIG_COUNT=0 reads the repo's own hook path, not the /dev/null forced above.
  hooks_dir=$(GIT_CONFIG_COUNT=0 git rev-parse --git-path hooks 2>/dev/null)
  if [ -n "$hooks_dir" ] && [ -f "$hooks_dir/pre-push" ]; then
    printf 'warning: this repository has a pre-push hook; it will NOT run on this route\n'
  fi
  printf '\nNext command:\n  %s\n' "$cmd"
}

cmd_push() {
  parse_opts "--expect-sha" "$@"
  require_expect_sha
  preflight push online "$OPT_EXPECT"
  run_standards
  stop_if_refused
  do_push || exit $?
}

cmd_pr() {
  local remote
  parse_opts "--expect-sha --expect-content --title-file --body-file" "$@"
  require_expect_sha
  [ -n "$OPT_TITLE" ] && [ -n "$OPT_BODY" ] || die "--title-file and --body-file are required"
  matches "$OPT_CONTENT" '^[0-9a-f]{64}$' || die "--expect-content must be the 64-hex SHA-256 printed by plan"
  command -v gh >/dev/null 2>&1 || die "gh is not installed"
  preflight pr online "$OPT_EXPECT"
  resolve_slug || die "pull requests are supported on github.com only"
  check_pr_text "$OPT_TITLE" "$OPT_BODY"
  run_standards
  stop_if_refused
  compute_content_sha
  [ "$CONTENT_SHA" = "$OPT_CONTENT" ] || die "PR title or body changed since plan; run plan again"

  remote=$(remote_branch_sha "$BRANCH") || die "cannot read the branch from the registered remote"
  if [ "$remote" != "$HEAD_SHA" ]; then
    do_push || exit $?
    remote=$(remote_branch_sha "$BRANCH") || die "cannot read the branch from the registered remote"
    [ "$remote" = "$HEAD_SHA" ] || die "remote branch is not at --expect-sha after the push"
  fi
  if [ "$BACKEND" = cloud-rest ]; then
    # The loopback proxy answered above; GitHub itself must agree before the PR is opened.
    remote=$(cloud_ref_sha "$BRANCH") || die "cannot read the branch from GitHub"
    [ "$remote" = "$HEAD_SHA" ] || die "branch on GitHub is not at --expect-sha after the push"
    cloud_pr_create
    return
  fi
  gh pr create --draft --repo "$REPO_SLUG" --base "$R_DEFAULT" --head "$BRANCH" --title "$TITLE_VALUE" --body-file "$BODY_COPY"
}

# The response is read once; every merge check uses only this copy.
PR_JSON=""
PR_FIELDS=state,isDraft,isCrossRepository,headRefName,headRefOid,baseRefName,title,body,statusCheckRollup
PR_SHAPE='length == 1 and (.[0] | type == "object"
  and ([.state, .headRefName, .headRefOid, .baseRefName, .title, .body] | all(type == "string"))
  and (.isDraft | type) == "boolean" and (.isCrossRepository | type) == "boolean"
  and ((.statusCheckRollup | type) == "array" or .statusCheckRollup == null))'
# Anything not recognised counts as failing, so an unknown state can never allow a merge.
# Skipped and neutral runs prove nothing: they neither block a merge nor count as the required success.
PR_CI_DEFS='
  def verdict:
    if type != "object" then "failing"
    elif .__typename == "CheckRun" then
      if .status != "COMPLETED" then "pending"
      elif .conclusion == "SUCCESS" then "success"
      elif .conclusion == "SKIPPED" or .conclusion == "NEUTRAL" then "skipped"
      else "failing" end
    elif .__typename == "StatusContext" then
      if .state == "SUCCESS" then "success"
      elif .state == "PENDING" or .state == "EXPECTED" then "pending"
      else "failing" end
    else "failing" end;'
PR_CI_FILTER="$PR_CI_DEFS"'
  [(.statusCheckRollup // [])[] | verdict]
  | if length == 0 then "none"
    elif any(. == "failing") then "failed"
    elif any(. == "pending") then "pending"
    elif any(. == "success") then "passed"
    else "skipped-only" end'
# Commas and control characters are replaced so a check name cannot fake a list entry or an output line.
PR_CI_SKIPPED="$PR_CI_DEFS"'
  [(.statusCheckRollup // [])[] | select(verdict == "skipped") | (.name // "" | tostring | gsub("[[:cntrl:],]+"; " "))]
  | join(",")'
PR_CI_FIELDS=isDraft,statusCheckRollup,url,headRefOid
PR_CI_SHAPE='length == 1 and (.[0] | type == "object"
  and (.isDraft | type) == "boolean" and (.url | type) == "string" and (.headRefOid | type) == "string"
  and ((.statusCheckRollup | type) == "array" or .statusCheckRollup == null))'

# --- cloud-rest backend: REST equivalents of gh pr create/view/merge (GraphQL is blocked there) ---
# A merge-level repo cannot mark a draft ready in the cloud, so its pull requests open as ready.
cloud_pr_create() {
  local draft=true resp url rest num bad="gh returned an unexpected pull request response"
  [ "$R_LEVEL" = merge ] && draft=false
  command -v jq >/dev/null 2>&1 || die "jq is not installed"
  resp=$(gh api --method POST "repos/$REPO_SLUG/pulls" -f title="$TITLE_VALUE" -f head="$BRANCH" -f base="$R_DEFAULT" \
    -F draft="$draft" -F body=@"$BODY_COPY" 2>/dev/null) || die "gh could not create the pull request"
  url=$(printf '%s' "$resp" | jq -r '.html_url | strings' 2>/dev/null) || die "$bad"
  # Exactly https://github.com/<slug>/pull/<digits>; only the slug compares case-insensitively.
  case "$url" in
    https://github.com/*) ;;
    *) die "$bad" ;;
  esac
  rest=${url#https://github.com/}
  [ "$(lower "${rest:0:${#REPO_SLUG}}")" = "$(lower "$REPO_SLUG")" ] || die "$bad"
  rest=${rest:${#REPO_SLUG}}
  case "$rest" in
    /pull/*) num=${rest#/pull/} ;;
    *) die "$bad" ;;
  esac
  case "$num" in
    ""|*[!0123456789]*) die "$bad" ;;
  esac
  printf '%s\n' "$url"
}

# Merge only: the pull request's file list as GitHub reports it, so a lying loopback remote cannot hide a
# CI/policy file change. GitHub truncates the list at 3000 files; a list that may be cut is refused.
cloud_check_pr_files() {
  local out n f
  out=$(gh api --paginate "repos/$REPO_SLUG/pulls/$OPT_PR/files?per_page=100" 2>/dev/null) \
    || die "cannot list the files of pull request $OPT_PR with gh"
  out=$(printf '%s' "$out" | jq -sr '
    if length == 0 or any(.[]; type != "array") then error("shape") else add end
    | if any(.[]; type != "object" or (.filename | type) != "string"
        or ((.previous_filename // "") | type) != "string") then error("shape") else . end
    | (length | tostring), (.[] | .filename, (.previous_filename // empty))' 2>/dev/null) \
    || die "gh returned an unexpected pull request file list"
  n=${out%%$'\n'*}
  case "$n" in
    ""|*[!0123456789]*) die "gh returned an unexpected pull request file list" ;;
  esac
  [ "$n" -lt 3000 ] || die "pull request $OPT_PR lists $n files; GitHub truncates that list, so it cannot be checked"
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    if is_ci_path "$f"; then
      refuse "CI policy file changed in pull request $OPT_PR: $(printf '%s' "$f" | sanitize); merge never accepts these changes"
    fi
  done <<<"$(printf '%s\n' "$out" | sed 1d)"
  stop_if_refused
}

# Maps the REST pull request, its check runs and its commit statuses to the gh pr view --json shape,
# so PR_SHAPE, PR_CI_SHAPE and the verdict filters apply unchanged. Input: three slurped JSON values.
CLOUD_PR_MAP='if length != 3 then error("shape") else
  .[0] as $p | {
    state: (if $p.merged_at != null then "MERGED" else ($p.state | ascii_upcase) end),
    isDraft: $p.draft,
    isCrossRepository: (($p.head.repo.full_name | type) != "string" or $p.head.repo.full_name != $p.base.repo.full_name),
    headRefName: $p.head.ref, headRefOid: $p.head.sha, baseRefName: $p.base.ref,
    title: $p.title, body: ($p.body // ""), url: $p.html_url,
    statusCheckRollup: (.[1] + .[2])
  } end'
CLOUD_RUNS_MAP='[.[] | .check_runs[] | {__typename: "CheckRun", name: .name,
  status: (.status | ascii_upcase), conclusion: (.conclusion // "" | ascii_upcase)}]'
CLOUD_STATUSES_MAP='[.[] | .statuses[] | {__typename: "StatusContext", context: .context, state: (.state | ascii_upcase)}]'

# Prints the mapped pull request $1 as one JSON line; non-zero on any gh or jq failure.
cloud_pr_view() {
  local pr sha runs statuses
  pr=$(gh api "repos/$REPO_SLUG/pulls/$1" 2>/dev/null) || return 1
  sha=$(printf '%s' "$pr" | jq -r '.head.sha' 2>/dev/null) || return 1
  matches "$sha" '^[0-9a-f]{40}$' || return 1
  runs=$(gh api --paginate "repos/$REPO_SLUG/commits/$sha/check-runs?per_page=100" 2>/dev/null) || return 1
  runs=$(printf '%s' "$runs" | jq -sc "$CLOUD_RUNS_MAP" 2>/dev/null) || return 1
  statuses=$(gh api --paginate "repos/$REPO_SLUG/commits/$sha/status?per_page=100" 2>/dev/null) || return 1
  statuses=$(printf '%s' "$statuses" | jq -sc "$CLOUD_STATUSES_MAP" 2>/dev/null) || return 1
  printf '%s\n%s\n%s\n' "$pr" "$runs" "$statuses" | jq -sc "$CLOUD_PR_MAP" 2>/dev/null
}

# Same semantics as gh pr merge --squash --match-head-commit: GitHub refuses if the head moved.
cloud_pr_merge() {
  local err
  err=$(gh api --method PUT "repos/$REPO_SLUG/pulls/$OPT_PR/merge" -f merge_method=squash -f sha="$OPT_EXPECT" \
    -f commit_title="$TITLE_VALUE" -f commit_message= 2>&1 >/dev/null) && return 0
  case "$err" in
    *"(HTTP 409)"*) die "pull request head no longer matches --expect-sha; GitHub refused the merge" ;;
    *"(HTTP 405)"*) die "GitHub reports the pull request is not mergeable (branch protection, reviews or conflicts)" ;;
  esac
  die "gh could not merge the pull request"
}

pr_field() { printf '%s' "$PR_JSON" | jq -r ".$1" 2>/dev/null; }
pr_is() { printf '%s' "$PR_JSON" | jq -e --arg want "$2" ".$1 == \$want" >/dev/null 2>&1; }

# The one CI verdict used by merge and ci: passed, failed, pending, none or skipped-only.
CI_VERDICT=""
compute_ci_verdict() {
  CI_VERDICT=$(printf '%s' "$PR_JSON" | jq -r "$PR_CI_FILTER" 2>/dev/null) || die "cannot evaluate the CI checks"
  case "$CI_VERDICT" in
    passed|failed|pending|none|skipped-only) ;;
    *) die "cannot evaluate the CI checks" ;;
  esac
}

cmd_ci() {
  local bad="gh returned an unexpected pull request response" draft url skipped head
  parse_opts "--pr --after-ready" "$@"
  require_pr_number
  command -v gh >/dev/null 2>&1 || die "gh is not installed"
  command -v jq >/dev/null 2>&1 || die "jq is not installed"
  require_level merge
  resolve_slug || die "reading CI is supported on github.com only"

  if [ "$BACKEND" = cloud-rest ]; then
    PR_JSON=$(cloud_pr_view "$OPT_PR") || die "cannot read pull request $OPT_PR with gh"
  else
    PR_JSON=$(gh pr view "$OPT_PR" --repo "$REPO_SLUG" --json "$PR_CI_FIELDS" 2>/dev/null) || die "cannot read pull request $OPT_PR with gh"
  fi
  printf '%s' "$PR_JSON" | jq -se "$PR_CI_SHAPE" >/dev/null 2>&1 || die "$bad"
  compute_ci_verdict
  # Right after a draft is marked ready, skipped or missing checks may only not have restarted yet.
  if [ "$OPT_AFTER_READY" = 1 ]; then
    case "$CI_VERDICT" in
      skipped-only|none) CI_VERDICT=pending ;;
      passed) [ -z "$(printf '%s' "$PR_JSON" | jq -r "$PR_CI_SKIPPED" 2>/dev/null)" ] || CI_VERDICT=pending ;;
    esac
  fi
  skipped=$(printf '%s' "$PR_JSON" | jq -r "$PR_CI_SKIPPED" 2>/dev/null) || die "cannot evaluate the CI checks"
  skipped=$(printf '%s' "$skipped" | sanitize)
  draft=$(pr_field isDraft) || die "$bad"
  url=$(pr_field url) || die "$bad"
  case "$url" in
    https://*) ;;
    *) die "$bad" ;;
  esac
  case "$url" in
    *[[:space:][:cntrl:]]*) die "$bad" ;;
  esac
  head=$(pr_field headRefOid) || die "$bad"
  matches "$head" '^[0-9a-f]{40}$' || die "$bad"
  printf 'verdict: %s\nskipped: %s\ndraft: %s\nurl: %s\nhead: %s\n' "$CI_VERDICT" "${skipped:--}" "$draft" "$(printf '%s' "$url" | sanitize)" "$head"
}

cmd_merge() {
  local bad="gh returned an unexpected pull request response" cross draft
  parse_opts "--pr --expect-sha --mark-ready-only" "$@"
  require_expect_sha
  require_pr_number
  command -v gh >/dev/null 2>&1 || die "gh is not installed"
  command -v jq >/dev/null 2>&1 || die "jq is not installed"
  preflight merge online "$OPT_EXPECT"
  resolve_slug || die "merging is supported on github.com only"
  run_standards merge
  stop_if_refused

  if [ "$BACKEND" = cloud-rest ]; then
    PR_JSON=$(cloud_pr_view "$OPT_PR") || die "cannot read pull request $OPT_PR with gh"
  else
    PR_JSON=$(gh pr view "$OPT_PR" --repo "$REPO_SLUG" --json "$PR_FIELDS" 2>/dev/null) || die "cannot read pull request $OPT_PR with gh"
  fi
  printf '%s' "$PR_JSON" | jq -se "$PR_SHAPE" >/dev/null 2>&1 || die "$bad"
  if [ "$BACKEND" = cloud-rest ]; then
    cloud_check_pr_files
  fi

  pr_is state OPEN || die "pull request is not open"
  pr_is headRefName "$BRANCH" || die "pull request head branch differs from the current branch"
  pr_is headRefOid "$OPT_EXPECT" || die "pull request head does not match --expect-sha"
  pr_is baseRefName "$R_DEFAULT" || die "pull request base is not the registered default branch"
  cross=$(pr_field isCrossRepository) || die "$bad"
  [ "$cross" = false ] || die "cross-repository pull requests cannot be merged on this route"

  TITLE_COPY=$(mktemp "${TMPDIR:-/tmp}/git-publish.XXXXXX") || die "cannot create a private temporary file"
  BODY_COPY=$(mktemp "${TMPDIR:-/tmp}/git-publish.XXXXXX") || die "cannot create a private temporary file"
  pr_field title >"$TITLE_COPY" || die "$bad"
  pr_field body >"$BODY_COPY" || die "$bad"
  TITLE_VALUE=$(cat -- "$TITLE_COPY")
  check_title
  check_body_headings
  report_text_secrets body "$BODY_COPY"
  stop_if_refused

  # CI on a draft may not have run yet, so marking ready and merging are always separate, explicit runs.
  draft=$(pr_field isDraft) || die "$bad"
  if [ "$OPT_MARK_READY" = 1 ]; then
    [ "$draft" = true ] || die "pull request is not a draft; --mark-ready-only applies to drafts only"
  else
    [ "$draft" = false ] || die "pull request is a draft; run merge --mark-ready-only first, then merge again once CI has finished"
  fi

  compute_ci_verdict
  [ "$CI_VERDICT" != failed ] || die "CI checks are failing"

  if [ "$OPT_MARK_READY" = 1 ]; then
    [ "$BACKEND" = local ] || die "cannot mark ready in cloud (GraphQL blocked); click Ready for review on GitHub, then run ci --pr $OPT_PR --after-ready"
    gh pr ready "$OPT_PR" --repo "$REPO_SLUG" >/dev/null 2>&1 || die "gh could not mark the pull request ready"
    printf 'marked ready: %s %s\n' "$OPT_PR" "$OPT_EXPECT"
    return 0
  fi

  case "$CI_VERDICT" in
    none) die "pull request has no CI checks; at least one successful check is required" ;;
    skipped-only) die "pull request has no successful check: every check was skipped or neutral" ;;
    pending) die "CI checks are still pending" ;;
  esac
  if [ "$BACKEND" = cloud-rest ]; then
    cloud_pr_merge
    printf '%s %s\n' "$OPT_PR" "$OPT_EXPECT"
    return 0
  fi
  gh pr merge "$OPT_PR" --repo "$REPO_SLUG" --squash --match-head-commit "$OPT_EXPECT" --subject "$TITLE_VALUE" --body "" >/dev/null 2>&1 \
    || die "gh could not merge the pull request"
  printf '%s %s\n' "$OPT_PR" "$OPT_EXPECT"
}

cmd_enable() {
  local level urls reason default="" symref name answer origin top ci_col=- ci_word=refused
  require_tty
  # enable and disable manage only local rows, never `github:` rows.
  BACKEND=local
  [ $# -ge 1 ] || die "enable needs a level: commit, push, pr or merge"
  level=$1
  shift
  case "$level" in commit|push|pr|merge) ;; *) die "enable level must be commit, push, pr or merge" ;; esac
  parse_opts "--style --allow-ci-changes" "$@"
  [ -n "$OPT_STYLE" ] || OPT_STYLE=conventional
  case "$OPT_STYLE" in conventional|project) ;; *) die "--style must be conventional or project" ;; esac
  if [ "$OPT_ALLOW_CI" = 1 ]; then
    ci_col=ci
    ci_word=allowed
  fi

  R_KEY=$(repo_key) || die "not inside a git repository"
  case "$R_KEY" in
    *[[:cntrl:]]*) die "repository path contains control characters" ;;
  esac
  if [ "$level" = commit ]; then
    # Commit level never reaches a remote, so origin is optional and nothing about it is stored.
    origin=$(git remote get-url --push --all origin 2>/dev/null | head -n 1)
    urls=-
    default=-
    name=${origin%/}
    name=${name%.git}
    name=${name##*/}
    name=${name##*:}
    if [ -z "$name" ]; then
      top=$(git rev-parse --show-toplevel 2>/dev/null) || die "cannot find the work tree"
      name=${top##*/}
    fi
    # The name comes from an unvalidated origin here and is printed in the confirmation prompt.
    name=$(printf '%s' "$name" | sanitize | LC_ALL=C tr -d '\t\n')
  else
    check_repo_config
    urls=$(git remote get-url --push --all origin 2>/dev/null) || die "remote origin has no push URL"
    [ -n "$urls" ] && [ "$(printf '%s\n' "$urls" | wc -l)" -eq 1 ] || die "origin must have exactly one push URL"
    if reason=$(url_refusal "$urls"); then
      die "$reason"
    fi
    if [ "$level" = pr ] || [ "$level" = merge ]; then
      parse_github "$urls" || die "level $level supports github.com remotes only"
    fi

    # Ask the remote first: refs/remotes/origin/HEAD is a local ref anyone can repoint.
    symref=$(git ls-remote --symref -- "$urls" HEAD 2>/dev/null | awk '$1 == "ref:" && $3 == "HEAD" {print $2; exit}')
    [ -n "$symref" ] || symref=$(git symbolic-ref --quiet refs/remotes/origin/HEAD 2>/dev/null | sed 's#^refs/remotes/origin/#refs/heads/#')
    default=${symref#refs/heads/}
    [ -n "$default" ] && [ "$default" != "$symref" ] || die "cannot determine the default branch of origin; run git remote set-head origin --auto"
    matches "$default" "$SAFE_BRANCH_RE" || die "default branch name is outside the safe character set"

    name=${urls%/}
    name=${name%.git}
    name=${name##*/}
    name=${name##*:}
  fi
  [ -n "$name" ] || die "cannot derive the repository name"

  printf 'Repository : %s\nPush URL   : %s\nDefault    : %s\nLevel      : %s\nStyle      : %s\nCI changes : %s\n' \
    "$(printf '%s' "$R_KEY" | sanitize)" "$(printf '%s' "$urls" | sanitize)" "$default" "$level" "$OPT_STYLE" "$ci_word"
  printf "Type the repository name '%s' to confirm: " "$name"
  IFS= read -r answer || die "confirmation was not given"
  [ "$answer" = "$name" ] || die "confirmation did not match the repository name"

  {
    registry_other_rows
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$R_KEY" "$urls" "$level" "$default" "$OPT_STYLE" "$ci_col"
  } | registry_write
  [ "${PIPESTATUS[1]}" -eq 0 ] || exit 2
  printf 'git-publish: enabled level %s for %s\n' "$level" "$name"
}

cmd_disable() {
  require_tty
  BACKEND=local
  [ $# -eq 0 ] || die "disable takes no arguments"
  R_KEY=$(repo_key) || die "not inside a git repository"
  [ -n "$R_KEY" ] || die "not inside a git repository"
  if ! registry_lookup; then
    printf 'git-publish: repository was not registered\n'
    return 0
  fi
  registry_other_rows | registry_write
  [ "${PIPESTATUS[1]}" -eq 0 ] || exit 2
  printf 'git-publish: disabled\n'
}

[ $# -ge 1 ] || die "usage: git-publish.sh status|plan|push|pr|merge|ci [--pr <n> [--after-ready]]|enable|disable"
SUBCOMMAND=$1
shift
case "$SUBCOMMAND" in
  status) cmd_status "$@" ;;
  plan) cmd_plan "$@" ;;
  push) cmd_push "$@" ;;
  pr) cmd_pr "$@" ;;
  merge) cmd_merge "$@" ;;
  ci) cmd_ci "$@" ;;
  enable) cmd_enable "$@" ;;
  disable) cmd_disable "$@" ;;
  *) die "unknown subcommand; use status, plan, push, pr, merge, ci, enable or disable" ;;
esac
