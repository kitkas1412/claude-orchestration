#!/usr/bin/env bash
# Claude Code on the web: environment setup script for claude-orchestration.
# EXPERIMENTAL. Paste this whole file into the environment dialog (claude.ai/code, "Setup script").
# Use it together with the project export (install.sh --project): whether Claude Code in the cloud
# loads hooks from /root/.claude is unverified, so the repo-level export is the dependable part.
#
# What it does (as root, before Claude Code starts, result cached in the environment snapshot):
#   1. clones REPO_URL into SRC_DIR and checks out the exact commit REF (detached);
#   2. runs install.sh --no-backup --no-apple-design with HOME=TARGET_HOME (user-level install);
#   3. rebuilds the git-publish registry in TARGET_HOME/.claude from GRANTS below.
#
# HOW TO FILL REF: set REF to the full 40-hex commit SHA of claude-orchestration you reviewed
#   (git rev-parse HEAD in your checkout, after it is pushed). While REF is the placeholder the script
#   installs nothing, registers nothing, prints a WARNING and exits 0.
#
# HOW TO FILL GRANTS: one grant per line, whitespace-separated:
#       owner/repo level [default_branch] [style] [ci]
#   level: commit | push | pr | merge        style: conventional (default) | project
#   ci: "ci" lets the route change CI files; "-" (default) refuses them.
#   default_branch: if omitted, it is read anonymously with git ls-remote (public repos only); if that
#   fails the grant is skipped with a WARNING. At level commit an omitted branch is stored as "-".
#   Use "-" as a placeholder when you need to give style or ci without a branch (commit level only).
#   Blank lines and lines starting with # are ignored. Invalid lines are skipped with a WARNING.
#
# SECURITY: publish levels come ONLY from the GRANTS text below, which lives in your environment
#   configuration, outside any repository. The script never reads grants from a repo, env vars or
#   the network.
#   Publish levels in the cloud are a workflow guardrail, NOT a security boundary: the agent runs as the
#   same OS user that owns the registry and the hooks, so a prompt-injected agent could bypass them.
#   Grant `merge` only for repositories protected on GitHub (branch protection / rulesets with required
#   status checks, and required reviews where possible) or for low-stakes repositories. Prefer `pr`
#   otherwise.
#
# FAIL CLOSED: at the start of every run, before any check, clone or install, an existing registry is
#   replaced by an empty one. Any later failure therefore leaves zero grants. If the registry path is a
#   symlink or not a regular file, it is left untouched and no grants are registered.
#
# HOW TO REVOKE: delete the lines from GRANTS and save. The environment snapshot is rebuilt and the
#   registry is regenerated without them. Running sessions keep the old file until they end.

REPO_URL=https://github.com/kitkas1412/claude-orchestration.git
REF=REPLACE_WITH_COMMIT_SHA
TARGET_HOME=/root
SRC_DIR=/opt/claude-orchestration
GH_BASE=https://github.com

GRANTS=$(cat <<'EOF'
# owner/repo level [default_branch] [style] [ci]
# example-owner/example-repo pr main conventional
EOF
)

SLUG_RE='^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9._-]+$'
SAFE_BRANCH_RE='^[A-Za-z0-9][A-Za-z0-9._/-]*$'

warn() { echo "WARNING: $*"; }

re_match() { printf '%s\n' "$1" | LC_ALL=C grep -Eq -- "$2"; }

# Anonymous default-branch lookup; prints the branch name or nothing.
lookup_default_branch() {
  local url="$GH_BASE/$1" out
  if command -v timeout >/dev/null 2>&1; then
    out=$(GIT_TERMINAL_PROMPT=0 timeout 20 git ls-remote --symref "$url" HEAD 2>/dev/null) || return 1
  else
    out=$(GIT_TERMINAL_PROMPT=0 git ls-remote --symref "$url" HEAD 2>/dev/null) || return 1
  fi
  printf '%s\n' "$out" | awk '$1 == "ref:" && $3 == "HEAD" {sub("^refs/heads/", "", $2); print $2; exit}'
}

install_orchestration() {
  if [ -d "$SRC_DIR/.git" ]; then
    git -C "$SRC_DIR" remote set-url origin "$REPO_URL" >/dev/null 2>&1 || return 1
    git -C "$SRC_DIR" fetch -q --tags origin '+refs/heads/*:refs/remotes/origin/*' >/dev/null 2>&1 || return 1
  else
    mkdir -p "$SRC_DIR" >/dev/null 2>&1 || return 1
    git clone -q "$REPO_URL" "$SRC_DIR" >/dev/null 2>&1 || return 1
  fi
  git -C "$SRC_DIR" -c advice.detachedHead=false checkout -q --detach "$REF" >/dev/null 2>&1 || return 1
  [ "$(git -C "$SRC_DIR" rev-parse HEAD 2>/dev/null)" = "$REF" ] || return 1
  bash "$SRC_DIR/install.sh" --no-backup --no-apple-design </dev/null >/dev/null 2>&1 || return 1
  [ -f "$TARGET_HOME/.claude/hooks/git-publish.sh" ] || return 1
}

# Prints one registry row per valid grant on stdout; reports on stdout via a fd 3 log.
build_rows() {
  local line slug lslug level branch style ci extra seen="" b
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    set -f
    # shellcheck disable=SC2086
    set -- $line
    set +f
    [ $# -gt 0 ] || continue
    slug=$1 level=${2:-} branch=${3:-} style=${4:-conventional} ci=${5:--} extra=${6:-}
    if [ -n "$extra" ]; then warn "grant for $slug has too many fields; skipped" >&3; continue; fi
    if ! re_match "$slug" "$SLUG_RE"; then warn "invalid repository slug; grant skipped" >&3; continue; fi
    case "$slug" in */.|*/..) warn "invalid repository slug; grant skipped" >&3; continue ;; esac
    case "$level" in commit|push|pr|merge) ;; *) warn "invalid level for $slug; grant skipped" >&3; continue ;; esac
    case "$style" in conventional|project) ;; *) warn "invalid style for $slug; grant skipped" >&3; continue ;; esac
    case "$ci" in ci|-) ;; *) warn "invalid ci value for $slug; grant skipped" >&3; continue ;; esac
    lslug=$(printf '%s' "$slug" | LC_ALL=C tr 'A-Z' 'a-z')
    case " $seen " in *" $lslug "*) warn "duplicate grant for $slug; skipped" >&3; continue ;; esac
    if [ -z "$branch" ]; then
      if [ "$level" = commit ]; then
        branch=-
      else
        b=$(lookup_default_branch "$slug") || b=""
        if [ -z "$b" ]; then warn "cannot determine default branch of $slug; grant skipped" >&3; continue; fi
        branch=$b
      fi
    fi
    if [ "$branch" = - ]; then
      if [ "$level" != commit ]; then warn "branch '-' is only valid at level commit ($slug); grant skipped" >&3; continue; fi
    elif ! re_match "$branch" "$SAFE_BRANCH_RE"; then
      warn "unsafe branch name for $slug; grant skipped" >&3; continue
    fi
    seen="$seen $lslug"
    printf 'github:%s\t-\t%s\t%s\t%s\t%s\n' "$slug" "$level" "$branch" "$style" "$ci"
    echo "registered $slug $level" >&3
  done <<EOF_GRANTS
$GRANTS
EOF_GRANTS
}

write_registry() {
  local dir="$TARGET_HOME/.claude" reg tmp
  reg="$dir/git-publish.registry"
  if [ -L "$reg" ]; then warn "registry path is a symlink; refusing to write it"; return 1; fi
  if [ -e "$reg" ] && [ ! -f "$reg" ]; then warn "registry path is not a regular file; refusing"; return 1; fi
  mkdir -p "$dir" || return 1
  tmp=$(mktemp "$reg.XXXXXX") || return 1
  if ! cat >"$tmp" || ! chmod 600 "$tmp" || ! mv -f "$tmp" "$reg"; then
    rm -f -- "$tmp"
    return 1
  fi
}

# Replaces an existing registry with an empty one (revocation first, fail closed).
# Returns 1 when the registry path is unsafe or cannot be emptied: the caller must then register nothing.
revoke_registry() {
  local reg="$TARGET_HOME/.claude/git-publish.registry"
  if [ -L "$reg" ]; then warn "registry path is a symlink; left untouched, no grants will be registered"; return 1; fi
  if [ -e "$reg" ] && [ ! -f "$reg" ]; then warn "registry path is not a regular file; left untouched, no grants will be registered"; return 1; fi
  [ -f "$reg" ] || return 0
  write_registry </dev/null && return 0
  # Emptying failed: fall back to removing the file (regular file only, re-checked right before).
  if [ -f "$reg" ] && [ ! -L "$reg" ] && rm -f -- "$reg" && [ ! -e "$reg" ] && [ ! -L "$reg" ]; then
    warn "could not empty the existing registry; removed it instead, no grants will be registered"
    return 1
  fi
  warn "REVOKE FAILED: $reg could not be emptied or removed; old grants may still be active"
  return 1
}

main() {
  local rows n can_register=1
  export HOME="$TARGET_HOME"
  revoke_registry || can_register=0
  case "$REF" in
    REPLACE_WITH_COMMIT_SHA)
      warn "REF is still the placeholder; nothing installed. Set REF to a 40-hex commit SHA."
      return 0 ;;
  esac
  if ! re_match "$REF" '^[0-9a-f]{40}$'; then
    warn "REF is not a 40-hex commit SHA; nothing installed."
    return 0
  fi
  if ! install_orchestration; then
    warn "could not install claude-orchestration at the pinned REF; no grants registered."
    return 0
  fi
  if [ "$can_register" != 1 ]; then
    warn "installed, but the registry was not touched; no grants registered."
    return 0
  fi
  rows=$(mktemp "${TMPDIR:-/tmp}/cloud-setup-rows.XXXXXX") || { warn "cannot create temporary file"; return 0; }
  exec 3>&1
  if ! build_rows >"$rows"; then
    warn "could not process grants; none registered."
    rm -f -- "$rows"
    return 0
  fi
  if ! write_registry <"$rows"; then
    warn "could not write the registry; no grants are active."
    rm -f -- "$rows"
    return 0
  fi
  n=$(wc -l <"$rows" | tr -d ' ')
  rm -f -- "$rows"
  echo "claude-orchestration installed at $REF; $n grant(s) registered."
  return 0
}

main || warn "setup failed unexpectedly; continuing."
exit 0
