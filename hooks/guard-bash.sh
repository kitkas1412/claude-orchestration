#!/usr/bin/env bash
# Global PreToolUse guard for Bash (main session AND subagents).
# Exit code 2 blocks the call and returns stderr to Claude.
# Defense in depth, NOT a sandbox. Requires jq. Matching is case-insensitive.
set -f
INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
[ -z "$CMD" ] && exit 0

deny() {
  echo "BLOCKED by guard-bash: $1. Do not retry or work around this. Report it to the orchestrator; the user must approve or run it manually." >&2
  exit 2
}
has() { printf '%s' "$CMD" | grep -Eiq -- "$1"; }
S='(^|[[:space:];&|(])'          # start of a command
G='([^;&|]*[[:space:]])?'        # optional args between command and subcommand

# --- privilege / system ---
has "${S}(sudo|su|doas)([[:space:]]|$)"                    && deny "privilege escalation"
has "${S}(mkfs[.a-z0-9]*|shutdown|reboot|halt)([[:space:]]|$)" && deny "system command"
has "${S}dd[[:space:]]+[^;&|]*of="                         && deny "dd write"
has "(curl|wget)[^;&|]*\|[[:space:]]*(sudo[[:space:]]+)?(sh|bash|zsh|python[0-9.]*|node|ruby|perl)([[:space:]]|$)" \
                                                           && deny "piping a download into a shell"
has "chmod[[:space:]]+-R[[:space:]]+(0?777|a\+rwx)"        && deny "chmod -R 777"

# --- git history / working tree destruction, remote writes ---
has "${S}git[[:space:]]+${G}push([[:space:]]|$)"                       && deny "git push"
has "${S}git[[:space:]]+${G}reset[[:space:]]+${G}--hard"               && deny "git reset --hard"
has "${S}git[[:space:]]+${G}clean[[:space:]]+${G}-[a-zA-Z]*[fdx]"      && deny "git clean"
has "${S}git[[:space:]]+${G}checkout[[:space:]]+(--[[:space:]]|\.([[:space:]]|$))" && deny "git checkout discarding changes"
has "${S}git[[:space:]]+${G}restore[[:space:]]" && ! has "--staged"    && deny "git restore of working tree"
printf '%s' "$CMD" | grep -Eq -- "${S}git[[:space:]]+${G}branch[[:space:]]+${G}-D([[:space:]]|$)" && deny "git branch -D"
has "${S}git[[:space:]]+${G}stash[[:space:]]+(drop|clear)"             && deny "git stash drop/clear"
has "${S}git[[:space:]]+${G}(filter-branch|filter-repo|reflog[[:space:]]+expire|gc[[:space:]]+--prune)" && deny "history rewriting"
has "(^|[[:space:]])--no-verify([[:space:]]|$)"                        && deny "--no-verify"

# --- publish / deploy / infrastructure mutation ---
has "${S}(npm|pnpm|yarn|bun)[[:space:]]+${G}publish"                   && deny "package publish"
has "${S}(twine[[:space:]]+upload|cargo[[:space:]]+${G}publish|gem[[:space:]]+push|docker[[:space:]]+${G}push|podman[[:space:]]+${G}push)" && deny "publish/push artifact"
has "${S}kubectl[[:space:]]+${G}(apply|delete|replace|patch|scale|rollout|create|edit|drain|cordon|taint)([[:space:]]|$)" && deny "kubectl mutation"
has "${S}helm[[:space:]]+${G}(install|upgrade|uninstall|rollback|delete)([[:space:]]|$)" && deny "helm mutation"
has "${S}(terraform|tofu)[[:space:]]+${G}(apply|destroy|import|taint|untaint|state)([[:space:]]|$)" && deny "terraform mutation"
has "${S}pulumi[[:space:]]+${G}(up|destroy|refresh)([[:space:]]|$)"   && deny "pulumi mutation"
has "${S}(vercel|netlify|fly|flyctl|firebase|serverless|sls|cdk|wrangler|heroku|gcloud|az|aws)[[:space:]]+${G}(deploy|publish|destroy|delete|terminate)([[:space:]]|$)" && deny "cloud deploy/delete"
has "${S}vercel[[:space:]]+${G}--prod"                                 && deny "production deploy"
has "${S}aws[[:space:]]+s3[[:space:]]+(rm|rb)([[:space:]]|$)"          && deny "aws s3 delete"
has "${S}gh[[:space:]]+${G}(release[[:space:]]+(create|delete)|pr[[:space:]]+merge|repo[[:space:]]+delete)" && deny "gh remote-mutating command"

# --- destructive database operations ---
# Plain text searches may mention SQL keywords, unless a database client is also on the line.
TEXT_SEARCH=0
if printf '%s' "$CMD" | grep -Eiq '^[[:space:]]*(grep|rg|ag|git[[:space:]]+(grep|log))[[:space:]]' \
  && ! printf '%s' "$CMD" | grep -Eiq '(psql|mysql|mariadb|sqlite3|mongosh|sqlcmd|prisma)'; then
  TEXT_SEARCH=1
fi
[ "$TEXT_SEARCH" = 0 ] && has "(drop|truncate)[[:space:]]+(table|database|schema|index)" && deny "destructive SQL"
[ "$TEXT_SEARCH" = 0 ] && has "delete[[:space:]]+from[[:space:]]+[^;]*(;|$)" && ! has "where" && deny "DELETE without WHERE"
has "${S}(dropdb|dropuser)([[:space:]]|$)"                             && deny "dropdb"
has "(db:(drop|reset|schema:load|setup)|migrate:(fresh|reset|refresh)|migrate[[:space:]]+reset|--force-reset|--accept-data-loss|flushall|flushdb)" && deny "database reset"

# --- secrets via shell ---
CLEAN=$(printf '%s' "$CMD" | sed -E 's/\.env\.(example|sample|template|dist)//g')
printf '%s' "$CLEAN" | grep -Eiq "(^|[[:space:]/=\"'])(\.env(\.[A-Za-z0-9_-]+)?|id_rsa[^[:space:]]*|id_ed25519[^[:space:]]*|[^[:space:]/]*\.pem|\.npmrc|\.netrc|\.pypirc)(\$|[[:space:]\"';&|)])" && deny "secret-bearing file"
has "(\.ssh/|\.aws/|\.gnupg/|\.kube/config|\.docker/config\.json|\.config/gh/)" && deny "credential directory"
has "${S}(printenv|env)([[:space:]]*$|[[:space:]]*[|;&])"              && deny "environment dump"

# --- recursive rm: only known build/cache directories ---
SAFE_RM='^(node_modules|dist|build|out|\.next|\.nuxt|\.turbo|\.cache|\.parcel-cache|target|__pycache__|\.pytest_cache|\.mypy_cache|\.ruff_cache|coverage|\.venv|venv|\.gradle|\.dart_tool|DerivedData|Pods)$'
while IFS= read -r seg; do
  seg="${seg#"${seg%%[![:space:]]*}"}"
  case "$seg" in rm|rm[[:space:]]*) ;; *) continue ;; esac
  rec=0
  for tok in $seg; do
    case "$tok" in
      --recursive) rec=1 ;;
      --*) ;;
      -*[rR]*) rec=1 ;;
    esac
  done
  [ "$rec" = 1 ] || continue
  for tok in $seg; do
    [ "$tok" = rm ] && continue
    case "$tok" in -*) continue ;; esac
    case "$tok" in
      /*|~*|\$*|..*|.|*'*'*|*'?'*) deny "recursive rm on risky path '$tok'" ;;
    esac
    t=${tok%/}; t=${t#./}; base=${t##*/}
    printf '%s' "$base" | grep -Eq "$SAFE_RM" || deny "recursive rm outside known build/cache directories: $tok"
  done
done <<< "$(printf '%s' "$CMD" | tr ';&|' '\n\n\n')"

exit 0