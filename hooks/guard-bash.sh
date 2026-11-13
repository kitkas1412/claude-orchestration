#!/usr/bin/env bash
# Global PreToolUse guard for Bash (main session AND subagents).
# Exit code 2 blocks the call and returns stderr to Claude.
# Defense in depth, NOT a sandbox. Requires jq. Matching is case-insensitive.
set -f
command -v jq >/dev/null 2>&1 || { echo "BLOCKED: jq is required by guard-bash" >&2; exit 2; }
INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty') || { echo "BLOCKED: guard-bash could not parse its JSON input" >&2; exit 2; }
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

# --- publish route: remote writes, git aliases, registry, git-publish.sh enable/disable (user terminal only) ---
# Catches common command forms from careless or injected agents; not a boundary against deliberate code execution.
# These rules run on a normalized copy of the command (N):
#  1. Plain -m/-am/--message text of git commit/tag is dropped, so prose may mention these commands.
#     Never when the message could expand ($, backtick, backslash) or end the segment.
#  2. Line continuations and $IFS become spaces.
#  3. After a launcher (bash -c, eval, python -c, a pipe or here-string into a shell, ...) quotes stop hiding a command.
#  4. Quotes and backslashes in the word at command position are removed.
#  5. gh -R/--repo flags are dropped, and quotes around git/gh/git-publish subcommand words are removed.
CS='(^|[[:space:];&|(`])'                 # a word that can start a command
CMDPOS='(^[[:space:]]*|[;&|(`][[:space:]]*)'  # strictly at command position
P='([^[:space:];&|"'"'"'`()]*/)?'         # optional directory prefix
END='([[:space:];&|)`"'"'"'<>]|$)'        # end of a command word
Q='["'"'"']'
WORD='[[:alnum:]_.-]+'

NM='[^;&|"'"'"'`$\\]'
COMMIT_HEAD="(^|[;&|(][[:space:]]*)(${P}git([[:space:]]+${NM}*)?[[:space:]]+(commit|tag)([[:space:]]+${NM}*)?)"
FLAG='[[:space:]]+(-m|-am|--message)[= ]*'
MSG_DQ='"[^"`$\\;&|]*"'
MSG_SQ="'"'[^'"'"'`$\\;&|]*'"'"
N=$(printf '%s' "$CMD" | sed -E -e ':a' -e "s#${COMMIT_HEAD}${FLAG}${MSG_DQ}#\1\2#" -e 'ta' -e "s#${COMMIT_HEAD}${FLAG}${MSG_SQ}#\1\2#" -e 'ta')
BSNL=$'\\\n'
N=${N//"$BSNL"/ }
N=$(printf '%s' "$N" | sed -E 's/\$(\{IFS\}|IFS)(\$[0-9])?/ /g')
LAUNCH="${CS}(${P}(bash|sh|zsh|dash|ksh|python[0-9.]*|perl|ruby|node)[[:space:]]+(-[^[:space:]]+[[:space:]]+)*-[a-zA-Z]*[ce][a-zA-Z]*([[:space:]]|${Q})|eval[[:space:]])"
SHELLS='(bash|sh|zsh|dash|ksh)'
FEED="\\|&?[[:space:]]*${P}${SHELLS}${END}|${CS}${P}${SHELLS}([[:space:]]+-[^[:space:]]+)*[[:space:]]*<<<"
# Taken before quotes become spaces below, so a word split by quotes stays one word here.
NS=$(printf '%s' "$N" | tr -d "\"'\\\\")
if printf '%s' "$N" | grep -Eiq -- "${LAUNCH}|${FEED}"; then
  N=$(printf '%s' "$N" | sed -E -e ':a' -e "s#([[:alnum:]_])${Q}+([[:alnum:]_])#\1\2#" -e 'ta' | tr "\"'" '  ')
fi
GIT_OPTS='([[:space:]]+-[^[:space:]]+([[:space:]]+[^-[:space:]"'"'"'][^[:space:]]*)?)*'
CW='[[:alnum:]_./~+-]*'
PWORD='[[:alnum:]_.-]*'
GH_REPO='[[:space:]]+(-R[=[:space:]]*|--repo[=[:space:]]+)[^[:space:];&|]+'
N=$(printf '%s' "$N" | sed -E -e ':a' \
  -e "s#(${CMDPOS}${CW})${Q}(${CW})${Q}#\1\3#" -e 'ta' \
  -e "s#(${CMDPOS}${CW})\\\\(${CW})#\1\3#" -e 'ta' \
  -e "s#((^|[[:space:];&|(\`]|/)gh([[:space:]]+[^;&|]*)?)${GH_REPO}#\1#" -e 'ta' \
  -e "s#((^|[[:space:];&|(\`]|/)git${GIT_OPTS}[[:space:]]+${PWORD})${Q}(${PWORD})${Q}#\1\5#" -e 'ta' \
  -e "s#((^|[[:space:];&|(\`]|/)gh([[:space:]]+[^-[:space:]\"'][^[:space:]\"']*)?[[:space:]]+)${Q}(${WORD})${Q}#\1\4#" -e 'ta' \
  -e "s#((^|[[:space:]/])git-publish(\.sh)?${Q}?[[:space:]]+(-[^[:space:]]+[[:space:]]+)*)${Q}(${WORD})${Q}#\1\5#" -e 'ta')
n() { printf '%s' "$N" | grep -Eiq -- "$1"; }
GN=$(printf '%s' "$N" | sed -E -e ':a' -e 's#((^|[[:space:];&|(`]|/)git)[[:space:]]+(-C|-c|--git-dir|--work-tree|--namespace)[[:space:]]+[^[:space:]]+#\1#' -e 'ta')

n "${CS}${P}git[[:space:]]+${G}push${END}"                                && deny "git push"
n "${CS}${P}git[[:space:]]+${G}(-c[[:space:]]*|--config-env[=[:space:]]+)${Q}?alias\." && deny "git alias injection"
n "${CS}(export[[:space:]]+)?GIT_CONFIG_(COUNT|PARAMETERS|GLOBAL|KEY_[0-9]+|VALUE_[0-9]+)="    && deny "git config through the environment"
n "${CS}${P}git(-|[[:space:]]+${G})(send-pack|http-push)${END}"           && deny "git remote write"
n "${CS}${P}git-push${END}"                                               && deny "git push"
n "${CS}${P}git(-|[[:space:]]+${G})credential[[:space:]]+${G}${Q}?fill${END}"  && deny "git credential fill"
n "${CS}${P}git(-|[[:space:]]+${G})credential-[[:alnum:]_-]+[[:space:]]+${G}${Q}?get${END}" && deny "git credential helper"
n "${CS}${P}gh[[:space:]]+${G}auth[[:space:]]+git-credential${END}"       && deny "gh auth git-credential"
n "${CS}${P}security[[:space:]]+${G}find-internet-password${END}"         && deny "keychain password lookup"
n "${CS}${P}gh[[:space:]]+${G}auth[[:space:]]+token${END}"                && deny "gh auth token"
n "${CS}${P}gh[[:space:]]+${G}auth[[:space:]]+status[^;&|]*[[:space:]](--show-token|-[a-zA-Z]*t)([=[:space:];&|)]|$)" && deny "gh auth status --show-token"
n "${CS}${P}gh[[:space:]]+${G}(release[[:space:]]+(create|delete|upload|edit)|pr[[:space:]]+(merge|create|new|ready|edit)|repo[[:space:]]+(delete|create|sync)|alias[[:space:]]+(set|import|delete)|workflow[[:space:]]+run|secret[[:space:]]+set|ext(ension)?s?[[:space:]]+install)" && deny "gh remote-mutating command"
# Subcommand or command word hidden in a variable or substitution.
printf '%s' "$GN" | grep -Eiq -- "${CS}${P}git([[:space:]]+-[^[:space:]]+)*[[:space:]]+${Q}?[\$\`]" && deny "git subcommand from a variable"
VARCMD="${CMDPOS}${Q}?\\\$\\{?[A-Za-z_][A-Za-z0-9_]*\\}?${Q}?[[:space:]]"
n "${VARCMD}+${G}(push|send-pack|http-push)${END}"                        && deny "push through a command variable"
n "${CS}[A-Za-z_][A-Za-z0-9_]*=${Q}?${P}(git|gh)${Q}?([[:space:];&]|$)" && n "$VARCMD" && deny "git or gh through a command variable"

# git-publish.sh: agents may run status, plan, push, pr, merge and ci; the registry and enable/disable are user terminal only
# Checked with every quote and backslash removed, so a split word cannot hide the file name or subcommand.
ns() { printf '%s' "$NS" | grep -Eiq -- "$1"; }
ns "git-publish\.reg|\.claude/g[^[:space:]/]*[*?[{]|\.claude/[^[:space:]/]*[*?[{][^[:space:]/]*registry" && deny "git-publish registry"
# A lone leading grep or rg only reads text, so it may search for these words.
PLAIN_SEARCH=0
case "$CMD" in
  *[\;\&\|\<\>\`\$\(\)$'\n']*) ;;
  *) printf '%s' "$CMD" | grep -Eq '^[[:space:]]*(grep|rg)[[:space:]]' && PLAIN_SEARCH=1 ;;
esac
[ "$PLAIN_SEARCH" = 0 ] && ns "(git-publish(\.sh)?|git-p[^[:space:]/]*[*?[][^[:space:]/]*)[[:space:]]+(-[^[:space:]]*[[:space:]]+)*(enable|disable)${END}" && deny "git-publish.sh enable/disable (user terminal only)"
ns "${CS}[A-Za-z_][A-Za-z0-9_]*=[^[:space:];&|]*git-publish" && ns "[[:space:]](enable|disable)([[:space:]]|$)" && deny "git-publish.sh through a variable"
printf '%s' "$NS" | grep -Ei -- 'git-publish' | grep -Eiq -- "${CMDPOS}${P}(script|expect|unbuffer|socat)([[:space:]]|$)|import[[:space:]]+pty|pty\.(spawn|fork|openpty)" && deny "terminal emulation around git-publish.sh"

# Protected config: writing is denied here; reading stays governed by the rules below.
HOMEP='(~|\$HOME|\$\{HOME\}|/(Users|home)/[^/[:space:]"'"'"']+|/root)'
PCFG="${HOMEP}/(\.claude/(hooks|agents|skills|settings[^/[:space:]]*\.json|CLAUDE\.md|git-publish\.reg|g[^[:space:]/]*[*?[{]|[^[:space:]/]*[*?[{][^[:space:]/]*registry)|\.gitconfig|\.config/git/config)"
PROOT="${HOMEP}/\.claude/?([[:space:])\`]|$)"
WRITER="(^|[[:space:](\`])(mv|rm|unlink|tee|truncate|touch|chmod|chown|chflags|sed[[:space:]]+([^;&|]*[[:space:]])?(-[a-zA-Z]*i[^[:space:]]*|--in-place[^[:space:]]*)|perl[[:space:]]+([^;&|]*[[:space:]])?-[a-zA-Z]*i[a-zA-Z]*)([[:space:]]|$)"
COPIER="(^|[[:space:](\`])(cp|install|ln|rsync|ditto)[[:space:]]"
# A project's .claude/hooks and .claude/settings*.json at any prefix (none, ./, ../x/, absolute).
# In cloud sessions these project hooks are the only guards. Reads stay allowed; writes are denied.
PNAME='\.claude/(hooks|rules|agents|settings[^/[:space:]]*\.json|[^[:space:]/]*[*?[{][^[:space:]/]*)'
PEND='([/[:space:])`]|$)'
PREND='([[:space:])`]|$)'
PB='(^|[[:space:]=>(`]|/)'
PROJ="${PB}(${PNAME}${PEND}|\.claude(/\.?)?${PREND})"
PROJ_DEST="${PB}(${PNAME}(/[^[:space:]]*)?|\.claude(/\.?)?)[)\`]*[[:space:]]*$|[[:space:]](-t|--target-directory)[=[:space:]]*([^[:space:]]*/)?(${PNAME}${PEND}|\.claude(/\.?)?${PREND})"
# ">|" is split at "|" below, so check it on the whole command.
ns ">\|[[:space:]]*(${PCFG}|([^[:space:]]*/)?${PNAME}${PEND})" && deny "write to protected configuration"
CWD_P=""
while IFS= read -r seg; do
  seg_has() { printf '%s' "$seg" | grep -Eiq -- "$1"; }
  # Protected-path checks see the segment without quotes or doubled slashes, and with
  # bare file names resolved against an earlier cd into the home directory tree.
  pseg=$(printf '%s' "$seg" | tr -d "\"'" | sed -E 's#/+#/#g')
  # The rewrite below also prefixes command words, so writer and copier detection uses this copy.
  cmdseg=$pseg
  if printf '%s' "$pseg" | grep -Eq '^[[:space:](`]*(cd|pushd)([[:space:]]|$)'; then
    target=$(printf '%s' "$pseg" | sed -E -e 's/^[[:space:](`]*(cd|pushd)([[:space:]]+-[^[:space:]]+)*[[:space:]]*//' -e 's/[[:space:])`].*$//' -e 's#/$##')
    PREV_P=$CWD_P
    CWD_P=""
    if [ -z "$target" ]; then
      CWD_P='~'
    elif printf '%s' "$target" | grep -Eiq -- "^${HOMEP}(/|$)"; then
      CWD_P=$target
    elif printf '%s' "$target" | grep -Eiq -- '(^|/)\.claude(/|$)'; then
      CWD_P=$target
    elif [ -n "$PREV_P" ] && printf '%s' "$target" | grep -Eq '^[^/~$-]' && ! printf '%s' "$target" | grep -Eq '(^|/)\.\.(/|$)'; then
      CWD_P="$PREV_P/${target#./}"
    fi
  elif [ -n "$CWD_P" ]; then
    trimmed=${pseg#"${pseg%%[![:space:]]*}"}
    first=${trimmed%%[[:space:]]*}
    rest=$(printf '%s' "${trimmed#"$first"}" | sed -E -e 's#(^|[[:space:]>])\./#\1#g' -e "s#(^|[[:space:]>])([^/~\$[:space:]>-][^[:space:]>]*)#\1${CWD_P}/\2#g")
    pseg="$first$rest"
  fi
  # Case-sensitive on this segment: -S/--staged unstages only; -s is --source and -W/--worktree writes files.
  restore_staged_only() {
    printf '%s' "$cmdseg" | grep -Eq -- '(^|[[:space:]])(--staged|-[a-rt-zA-Z]*S[a-rt-zA-Z]*)([[:space:]=]|$)' \
      && ! printf '%s' "$cmdseg" | grep -Eq -- '(^|[[:space:]])(--worktree|-[a-zA-Z]*W[a-zA-Z]*)([[:space:]=]|$)'
  }
  pseg_has() { printf '%s' "$pseg" | grep -Eiq -- "$1"; }
  cmdseg_has() { printf '%s' "$cmdseg" | grep -Eiq -- "$1"; }
  pseg_has ">[[:space:]]*[^[:space:]]*\.git/(config|info/grafts)([[:space:])\`]|$)" && deny "write to repository git config"
  pseg_has ">[[:space:]]*${PCFG}"                                         && deny "write to protected configuration"
  if pseg_has "$PCFG|$PROOT"; then
    cmdseg_has "$WRITER"                                                  && deny "write to protected configuration"
    if cmdseg_has "$COPIER"; then
      pseg_has "${PCFG}[^[:space:]]*[)\`]*[[:space:]]*$|[[:space:]](-t|--target-directory)[=[:space:]]*${PCFG}" && deny "write to protected configuration"
    fi
  fi
  pseg_has ">[[:space:]]*([^[:space:]]*/)?${PNAME}${PEND}"               && deny "write to project .claude hooks or settings"
  if pseg_has "$PROJ"; then
    cmdseg_has "$WRITER"                                                  && deny "write to project .claude hooks or settings"
    cmdseg_has "$COPIER" && pseg_has "$PROJ_DEST"                         && deny "write to project .claude hooks or settings"
    # git checkout/restore and patch rewrite the named files in place.
    # "git restore --staged" without --worktree/-W only unstages, so it is allowed here.
    if cmdseg_has "${CS}${P}(git[[:space:]]+${G}(checkout|restore)|patch)([[:space:]]|$)"; then
      if cmdseg_has "${CS}${P}git[[:space:]]+${G}restore([[:space:]]|$)" \
         && ! cmdseg_has "${CS}${P}(git[[:space:]]+${G}checkout|patch)([[:space:]]|$)" \
         && restore_staged_only; then
        :
      else
        deny "write to project .claude hooks or settings"
      fi
    fi
  fi
  # Download, extract and unzip destinations (an option names the target directory or file).
  PDEST="[=[:space:]]*([^[:space:]]*/)?(${PNAME}${PEND}|\\.claude(/\\.?)?${PREND})"
  # Any git restore segment other than a staged-only one rewrites the working tree.
  if cmdseg_has "${CS}${P}git[[:space:]]+${G}restore([[:space:]]|$)"; then
    restore_staged_only || deny "git restore of working tree"
  fi
  # curl -o/--output are case-sensitive: -O (remote-name) writes to the cwd, which is not protected.
  # Match the flag case-insensitively with the path, then require a lowercase o in the flag itself.
  cmdseg_has "${CS}${P}curl[[:space:]]"  && printf '%s' "$pseg" | grep -Eio -- "(^|[[:space:]])(-[a-z]*o|--output(-dir)?)${PDEST}" \
    | grep -Eq -- '^[[:space:]]*(-[a-zA-Z]*o|--output(-dir)?)' && deny "download into project .claude hooks or settings"
  cmdseg_has "${CS}${P}wget[[:space:]]"  && pseg_has "(^|[[:space:]])(-[a-z]*o|--output-document|-P|--directory-prefix)${PDEST}" && deny "download into project .claude hooks or settings"
  cmdseg_has "${CS}${P}unzip[[:space:]]" && pseg_has "(^|[[:space:]])-d${PDEST}"                             && deny "unzip into project .claude hooks or settings"
  if cmdseg_has "${CS}${P}tar[[:space:]]" && pseg_has "(^|[[:space:]])(-[a-z]*x[a-z]*|--extract|--get)([[:space:]]|$)|tar[[:space:]]+[a-z]*x"; then
    pseg_has "(^|[[:space:]])(-[a-z]*C|--directory)${PDEST}" && deny "extract into project .claude hooks or settings"
  fi
  nq=$(printf '%s' "$seg" | tr -d "\"'")
  nq_has() { printf '%s' "$nq" | grep -Eiq -- "$1"; }
  if nq_has "${CS}${P}git[[:space:]]+${G}config[[:space:]]"; then
    READS='(^|[[:space:]])(--(get|get-all|get-regexp|get-urlmatch|list)|-l)([[:space:]]|$)'
    if nq_has "config[[:space:]]+${G}alias\."; then
      nq_has "$READS" || deny "git alias configuration"
    fi
    if nq_has "config[[:space:]]+${G}--(global|system)[[:space:]]+${G}(core\.(sshcommand|gitproxy|askpass)|credential\.|http\.|url\.|include(if)?\.)[^[:space:]]*[[:space:]]+[^[:space:]]"; then
      nq_has "$READS" || deny "global git configuration that redirects a push"
    fi
    if nq_has "config[[:space:]]+${G}(--file|-f)[=[:space:]]*${PCFG}"; then
      nq_has "$READS" || deny "write to protected configuration"
    fi
  fi
  if seg_has "${CS}${P}gh[[:space:]]+${G}api([[:space:]]|$)"; then
    printf '%s' "$seg" | grep -Eq -- "(^|[[:space:]])(-[a-zA-Z]*[fF]|--field|--raw-field|--input)([[:space:]=]|$)|(^|[[:space:]])-[fF][^[:space:]-]" && deny "gh api with request body"
    while IFS= read -r method; do
      [ -z "$method" ] && continue
      value=$(printf '%s' "$method" | sed -E 's/^[[:space:]]*(-[a-zA-Z]*X|--method)[=[:space:]]*//' | tr -d "\"'")
      printf '%s' "$value" | grep -Eiq '^get$' || deny "gh api with non-GET method"
    done <<< "$(printf '%s' "$seg" | grep -Eo -- "(^|[[:space:]])(-[a-zA-Z]*X|--method)[=[:space:]]*[^[:space:]]*")"
  fi
done <<< "$(printf '%s' "$N" | tr ';&|' '\n\n\n')"

# --- git history / working tree destruction, remote writes ---
has "${S}git[[:space:]]+${G}reset[[:space:]]+${G}--hard"               && deny "git reset --hard"
has "${S}git[[:space:]]+${G}clean[[:space:]]+${G}-[a-zA-Z]*[fdx]"      && deny "git clean"
has "${S}git[[:space:]]+${G}checkout[[:space:]]+(--[[:space:]]|\.([[:space:]]|$))" && deny "git checkout discarding changes"
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
printf '%s' "$CLEAN" | grep -Eiq "(^|[[:space:]/=\"'])(\.env(\.[A-Za-z0-9_-]+)?|id_rsa[^[:space:]]*|id_ed25519[^[:space:]]*|[^[:space:]/]*\.pem|\.npmrc|\.netrc|\.pypirc|\.git-credentials)(\$|[[:space:]\"';&|)])" && deny "secret-bearing file"
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