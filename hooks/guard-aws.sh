#!/usr/bin/env bash
# Global PreToolUse guard for Bash (main session AND subagents): default-deny grammar for every `aws` invocation plus
# tripwires for common ways around it. Exit code 2 blocks the call and returns stderr to Claude. Requires jq.
# A small shell lexer splits the text on real operators (; & | && || ( ) newline, $( ), backticks, <( ), >( )),
# skips comments, redirections and quoted heredoc bodies, and flags expansions, escapes, globs and braces per word.
# It fails closed: a command word built from an expansion, substitution, escape, glob or brace is denied for every
# command, and an aws command may not contain unquoted { } # * ? [ ~ $ or \ at all.
# The grammar: --profile claude-agent exactly once, a denied-flag list, a secret/auth operation denylist, then an
# allowlist (read-only describe/list calls, ec2 mutations only with --dry-run). Anything else is denied.
# Tripwires are string checks on a normalized copy and remain bypassable by a determined author (for example SDK
# code in a script file). Defense in depth, NOT a sandbox: the claude-agent credentials must still be scoped in IAM.
set -f
export LC_ALL=C
AWS_AGENT_PROFILE='claude-agent'
command -v jq >/dev/null 2>&1 || { echo "BLOCKED by guard-aws: jq is required" >&2; exit 2; }
INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty') || { echo "BLOCKED by guard-aws: could not parse its JSON input" >&2; exit 2; }
[ -z "$CMD" ] && exit 0

deny() {
  echo "BLOCKED by guard-aws: $1. Do not retry or work around this. Report it to the orchestrator; the user must approve or run it manually." >&2
  exit 2
}
deny_list() {
  echo "BLOCKED by guard-aws: aws $1 $2 is not on the aws-engineer allowlist; return it to the user to run as \`! <cmd>\`." >&2
  exit 2
}
safe_word() { if [[ $1 =~ ^[a-z0-9-]*$ ]]; then printf '%s' "$1"; else printf '<arg>'; fi; }

# --- normalization (same steps as guard-bash): drop line continuations and $IFS ---
BSNL=$'\\\n'
N=${CMD//"$BSNL"/ }
N=$(printf '%s' "$N" | sed -E 's/\$(\{IFS\}|IFS)(\$[0-9])?/ /g')

ASSIGN_RE='^[A-Za-z_][A-Za-z0-9_]*(\[[^]]*\])?\+?='
AWSW='(^|[^[:alnum:]_.-])aws(2|v2)?([^[:alnum:]_-]|$)'

# --- lexer ---
# Per word: WV value (quotes removed), WR raw text, WF flags, WSG segment, WB/WE source offsets in N.
# Flags: D expansion or substitution, A ANSI-C $'..', B ${..}, E unquoted backslash, G unquoted * ? [,
#        C unquoted { or }, H unquoted # inside a word, T unquoted ~, Q quoted part, R redirection target or fd.
# SEGF per segment: '#' when a comment ends it. SUBST=1 when any substitution was seen; ARRAY=1 for name=( .
lex() {
  local s=$1 len=${#1} i=0 c nx mode=o cur='' raw='' fl='' have=0 wb=0 seg=0 redir='' sp=0 j body rest
  local -a STT=() STC=() STR=() STF=() STW=() STS=() STM=() STO=()
  WV=(); WR=(); WF=(); WSG=(); WB=(); WE=(); SEGF=(''); NSEG=1; SUBST=0; ARRAY=0
  HDD=(); HDQ=(); HDS=(); HB=()
  st() { if [ "$have" = 0 ]; then have=1; wb=$i; fi; }
  pushw() {
    if [ "$have" = 1 ]; then
      if [ -n "$redir" ]; then
        fl+=R
        if [ "$redir" = H ]; then
          HDD+=("$cur"); HDS+=("$seg"); case "$fl" in *[QE]*) HDQ+=(1) ;; *) HDQ+=(0) ;; esac
        fi
        redir=''
      fi
      WV+=("$cur"); WR+=("$raw"); WF+=("$fl"); WSG+=("$seg"); WB+=("$wb"); WE+=("$i")
    fi
    cur=''; raw=''; fl=''; have=0
  }
  newseg() { pushw; redir=''; NSEG=$((NSEG+1)); seg=$((NSEG-1)); SEGF[seg]=''; }
  subst_open() { # $1: type P (from outside), Q (from double quotes), B/C (backtick from outside/double quotes)
    st; SUBST=1
    STT[sp]=$1; STC[sp]=$cur; STR[sp]=$raw; STF[sp]=$fl; STW[sp]=$wb; STS[sp]=$seg; STM[sp]=$mode; STO[sp]=$i; sp=$((sp+1))
    cur=''; raw=''; fl=''; have=0; mode=o; redir=''
    NSEG=$((NSEG+1)); seg=$((NSEG-1)); SEGF[seg]=''
  }
  subst_close() {
    pushw; sp=$((sp-1))
    cur=${STC[sp]}; raw="${STR[sp]}\$(${s:STO[sp]+1:i-STO[sp]-1})"; fl="${STF[sp]}D"; wb=${STW[sp]}; seg=${STS[sp]}; mode=${STM[sp]}; have=1
  }
  backtick() { if [ "$sp" -gt 0 ] && { [ "${STT[sp-1]}" = B ] || [ "${STT[sp-1]}" = C ]; }; then subst_close; elif [ "$mode" = d ]; then subst_open C; else subst_open B; fi; }
  redirop() { # s[i] is < or >; consume the operator and mark the next word as its target
    nx=${s:i+1:1}
    if [ "$c" = '<' ]; then
      if [ "$nx" = '<' ]; then
        case "${s:i+2:1}" in
          '<') i=$((i+2)); redir=R ;;
          '-') i=$((i+2)); redir=H ;;
          *) i=$((i+1)); redir=H ;;
        esac
        return 0
      fi
      case "$nx" in '&'|'>') i=$((i+1)) ;; esac
    else
      case "$nx" in '>'|'|'|'&') i=$((i+1)) ;; esac
    fi
    redir=R
  }
  heredocs() { # s[i] is the newline after a line with << operators: skip quoted bodies and plain unquoted bodies,
    # but lex the body as code when it feeds a shell or holds a live substitution
    local k d text pre w hc
    [ "${#HDD[@]}" -gt 0 ] || return 0
    for ((k=0; k<${#HDD[@]}; k++)); do
      d=${HDD[k]}; text=$'\n'"${s:i+1}"$'\n'
      pre=${text%%$'\n'"$d"$'\n'*}
      hc=''
      for ((w=0; w<${#WV[@]}; w++)); do
        [ "${WSG[w]}" = "${HDS[k]}" ] || continue
        case "${WF[w]}" in *R*) continue ;; esac
        [[ ${WV[w]} =~ $ASSIGN_RE ]] && continue
        hc=${WV[w]##*/}; break
      done
      case "$hc" in bash|sh|zsh|dash|ksh|fish|source|.|eval) break ;; esac
      if [ "${HDQ[k]}" = 0 ]; then
        case "$pre" in *'$('*|*'`'*) break ;; esac
      fi
      # a quoted body read by cat, tee, git (commit -F -) or git-publish.sh is inert data for the text tripwires
      if [ "${HDQ[k]}" = 1 ]; then
        case "$hc" in cat|tee|git|git-publish.sh)
          if [ "${#pre}" -eq "${#text}" ]; then HB+=("$((i+1)) $len"); else HB+=("$((i+1)) $((i+${#pre}))"); fi ;;
        esac
      fi
      if [ "${#pre}" -eq "${#text}" ]; then i=$len; break; fi
      i=$((i + ${#pre} + ${#d} + 1))
    done
    HDD=(); HDQ=(); HDS=()
  }
  while [ "$i" -lt "$len" ]; do
    c=${s:i:1}
    if [ "$mode" = d ]; then
      case "$c" in
        '"') mode=o; raw+=$c ;;
        '\') nx=${s:i+1:1}
             case "$nx" in
               '$'|'`'|'"'|'\') cur+=$nx; raw+=$c$nx; i=$((i+1)) ;;
               *) cur+=$c; raw+=$c ;;
             esac ;;
        '$') nx=${s:i+1:1}
             case "$nx" in
               '(') i=$((i+1)); subst_open Q ;;
               '{') fl+=DB; cur+=$c; raw+=$c ;;
               [A-Za-z_0-9@*#?\$!-]) fl+=D; cur+=$c; raw+=$c ;;
               *) cur+=$c; raw+=$c ;;
             esac ;;
        '`') backtick ;;
        '<'|'>') if [ "${s:i+1:1}" = '(' ]; then i=$((i+1)); subst_open Q; else cur+=$c; raw+=$c; fi ;;
        *) cur+=$c; raw+=$c ;;
      esac
    else
      case "$c" in
        ' '|$'\t') pushw ;;
        $'\n') newseg; heredocs ;;
        ';') newseg ;;
        '|') if [ "${s:i+1:1}" = '|' ]; then i=$((i+1)); newseg; else newseg; SEGF[seg]+='|'; fi ;;
        '&') if [ "${s:i+1:1}" = '>' ]; then pushw; i=$((i+1)); c='>'; redirop; else newseg; fi ;;
        '(') case "$cur" in *=) [ "$have" = 1 ] && ARRAY=1 ;; esac
             newseg; STT[sp]=p; sp=$((sp+1)) ;;
        ')') if [ "$sp" -gt 0 ] && { [ "${STT[sp-1]}" = P ] || [ "${STT[sp-1]}" = Q ]; }; then subst_close
             else
               if [ "$sp" -gt 0 ] && [ "${STT[sp-1]}" = p ]; then sp=$((sp-1)); fi
               newseg
             fi ;;
        '<'|'>') if [ "${s:i+1:1}" = '(' ]; then i=$((i+1)); subst_open P
                 else
                   if [ "$have" = 1 ] && [ -z "$fl" ] && [[ $cur =~ ^[0-9]+$ ]]; then fl=R; fi
                   pushw; redirop
                 fi ;;
        "'") st; rest=${s:i+1}; body=${rest%%\'*}; cur+=$body; raw+="'$body'"; fl+=Q; i=$((i+${#body}+1)) ;;
        '"') st; fl+=Q; mode=d; raw+=$c ;;
        '\') st; nx=${s:i+1:1}; cur+=$nx; raw+=$c$nx; fl+=E; i=$((i+1)) ;;
        '$') nx=${s:i+1:1}
             case "$nx" in
               '(') i=$((i+1)); subst_open P ;;
               "'") st; fl+=DA; j=$((i+2))
                    while [ "$j" -lt "$len" ]; do
                      case "${s:j:1}" in '\') j=$((j+2)) ;; "'") break ;; *) j=$((j+1)) ;; esac
                    done
                    body=${s:i+2:j-i-2}; cur+=$body; raw+="\$'$body'"; i=$j ;;
               '"') st; fl+=DQ; mode=d; raw+='$"'; i=$((i+1)) ;;
               '{') st; fl+=DB; cur+='${'; raw+='${'; i=$((i+1)) ;;
               [A-Za-z_]) st; fl+=D; cur+=$c; raw+=$c ;;
               [0-9@*#?\$!-]) st; fl+=D; cur+=$c$nx; raw+=$c$nx; i=$((i+1)) ;;
               *) st; cur+=$c; raw+=$c ;;
             esac ;;
        '`') backtick ;;
        '#') if [ "$have" = 0 ]; then
               SEGF[seg]+='#'; rest=${s:i}; body=${rest%%$'\n'*}; i=$((i+${#body}-1))
             else cur+=$c; raw+=$c; fl+=H; fi ;;
        '*'|'?'|'[') st; cur+=$c; raw+=$c; fl+=G ;;
        '{'|'}') st; cur+=$c; raw+=$c; fl+=C ;;
        '~') st; cur+=$c; raw+=$c; fl+=T ;;
        *) st; cur+=$c; raw+=$c ;;
      esac
    fi
    i=$((i+1))
  done
  pushw
}
lex "$N"
NW=${#WV[@]}
SEGW=()
for ((k=0; k<NW; k++)); do SEGW[WSG[k]]+="$k "; done

# TOKS/TF/TK: one segment's words without redirection targets (values, flags, word index).
seg_toks() {
  TOKS=(); TF=(); TK=(); TR=()
  local k
  for k in ${SEGW[$1]:-}; do
    case "${WF[k]}" in *R*) continue ;; esac
    TOKS+=("${WV[k]}"); TF+=("${WF[k]}"); TK+=("$k"); TR+=("${WR[k]}")
  done
}
# FI = index of the command word after leading assignments and shell keywords.
first_cmd() {
  FI=0; HAD_ASSIGN=0
  local cnt=${#TOKS[@]} t
  while [ "$FI" -lt "$cnt" ]; do
    t=${TOKS[FI]}
    if [[ $t =~ $ASSIGN_RE ]]; then HAD_ASSIGN=1; FI=$((FI+1)); continue; fi
    case "$t" in
      if|then|else|elif|do|while|until|'!'|'{'|'}') FI=$((FI+1)) ;;
      time) FI=$((FI+1)); [ "${TOKS[FI]:-}" = -p ] && FI=$((FI+1)) ;;
      coproc) FI=$((FI+1)); [ "${TOKS[FI+1]:-}" = '{' ] && FI=$((FI+2)) ;;
      function) FI=$((FI+2)) ;;
      *) break ;;
    esac
  done
  return 0
}
lower() { case "$1" in *[A-Z]*) printf '%s' "$1" | tr '[:upper:]' '[:lower:]' ;; *) printf '%s' "$1" ;; esac; }
isaws() { local b=${1##*/}; b=${b%%@*}; case "$b" in [Aa][Ww][Ss]|[Aa][Ww][Ss]2|[Aa][Ww][Ss][Vv]2) return 0 ;; esac; return 1; }
# A glob word whose last path part could expand to aws.
glob_aws() { local b; b=$(lower "${1##*/}"); [[ aws == $b || aws2 == $b || awsv2 == $b ]]; }

# --- commit messages: plain -m/--message text of `git commit` is prose, so the tripwires skip it ---
STRIP=()
for ((sgi=0; sgi<NSEG; sgi++)); do
  seg_toks "$sgi"; first_cmd
  cnt=${#TOKS[@]}
  [ "$FI" -lt "$cnt" ] && [ "${TOKS[FI]##*/}" = git ] && [ "${TF[FI]}" = '' ] || continue
  j=$((FI+1))
  while [ "$j" -lt "$cnt" ]; do
    case "${TOKS[j]}" in -C|-c|--git-dir|--work-tree|--namespace) j=$((j+2)) ;; -*) j=$((j+1)) ;; *) break ;; esac
  done
  [ "${TOKS[j]:-}" = commit ] || continue
  for ((j=j+1; j<cnt; j++)); do
    m=-1
    case "${TOKS[j]}" in
      -m|--message|-[a-zA-Z]*m) m=$((j+1)) ;;
      --message=*|-m?*) m=$j ;;
    esac
    [ "$m" -ge 0 ] && [ "$m" -lt "$cnt" ] || continue
    k=${TK[m]}
    case "${WF[k]}" in *[DABE]*) continue ;; esac
    span=${N:WB[k]:WE[k]-WB[k]}
    case "$span" in *'$'*|*'`'*|*'<('*|*'>('*) continue ;; esac
    STRIP[k]=1
  done
done
# Spans to blank in the text copy: stripped commit messages (replaced by "") and inert heredoc bodies.
SPANS=()
for ((k=0; k<NW; k++)); do [ "${STRIP[k]:-}" = 1 ] && SPANS+=("${WB[k]} ${WE[k]} m"); done
for sp_ in "${HB[@]}"; do SPANS+=("$sp_ h"); done
NC=''; pos=0
if [ "${#SPANS[@]}" -gt 0 ]; then
  while read -r b_ e_ t_; do
    [ "$b_" -ge "$pos" ] || continue
    NC+=${N:pos:b_-pos}; [ "$t_" = m ] && NC+='""'; pos=$e_
  done < <(printf '%s\n' "${SPANS[@]}" | sort -n -k1,1)
fi
NC+=${N:pos}
NS=$(printf '%s' "$NC" | tr -d "\"'\\\\")
n()  { printf '%s' "$NC" | grep -Eiq -- "$1"; }
ns() { printf '%s' "$NS" | grep -Eiq -- "$1"; }

CS='(^|[[:space:];&|(`])'
CMDPOS='(^[[:space:]]*|[;&|(`][[:space:]]*)'
P='([^[:space:];&|"'"'"'`()]*/)?'
END='([[:space:];&|)`"'"'"'<>]|$)'
Q='["'"'"']'
G='([^;&|]*[[:space:]])?'
SHELLS='(bash|sh|zsh|dash|ksh)'
INTERP='(python[0-9.]*|node|ruby|perl|deno|bun)'

# A lone leading grep or rg only reads text, so it may mention assignments, IaC verbs and credential tools.
PLAIN_SEARCH=0
case "$CMD" in
  *[\;\&\|\<\>\`\$\(\)$'\n']*) ;;
  *) printf '%s' "$CMD" | grep -Eq '^[[:space:]]*(grep|rg)[[:space:]]' && PLAIN_SEARCH=1 ;;
esac

# Obfuscation markers from the lexer: $'..', ${..}, $( ), backticks, <( ), an unquoted brace, an array assignment.
HID1='(^|/)\.[^/]*[][$*?{}\\`]'
HID2='(^|/)\[[^]/]*\.'
HID3='\.[Aa][][*?]'
MARK=0
[ "$SUBST" = 1 ] || [ "$ARRAY" = 1 ] && MARK=1
for ((k=0; k<NW; k++)); do
  case "${WF[k]}" in
    *[AB]*) MARK=1 ;;
    *C*) case "${WV[k]}" in '{}'|'{'|'}') ;; *) MARK=1 ;; esac ;;
  esac
  # glob or expansion inside a hidden path component (~/.a?s, $HOME/.a${x}ws, [.]aws)
  case "${WF[k]}" in
    *[DGCE]*) [[ ${WR[k]} =~ $HID1 || ${WR[k]} =~ $HID2 || ${WR[k]} =~ $HID3 ]] \
                && deny "glob, escape or expansion in a hidden path (credential directories are off limits)" ;;
  esac
done
n "${CS}eval([[:space:]]|$)" && MARK=1

# --- bypass tripwires (every agent) ---
if [ "$PLAIN_SEARCH" = 0 ] && [ "$MARK" = 1 ] && ns "$AWSW"; then
  deny "aws together with an expansion, substitution, brace, eval or array (write the literal aws command)"
fi
LAUNCH="${CS}(${P}(bash|sh|zsh|dash|ksh|python[0-9.]*|perl|ruby|node)[[:space:]]+(-[^[:space:]]+[[:space:]]+)*-[a-zA-Z]*[ce][a-zA-Z]*([[:space:]]|${Q})|eval[[:space:]])"
FEED="\\|&?[[:space:]]*${P}${SHELLS}${END}|${CS}${P}${SHELLS}([[:space:]]+-[^[:space:]]+)*[[:space:]]*<<"
SRC="${CMDPOS}(source|\\.)[[:space:]]"
if n "${LAUNCH}|${FEED}|${SRC}"; then
  ns "$AWSW" && deny "aws combined with a shell launcher (bash -c, eval, source, a pipe or heredoc into a shell)"
  n "\\\$'|\\\$\\{|\\\$\\(|\`|<\\(|>\\(" && deny "shell launcher with an expansion or substitution"
fi
n "${CS}alias[[:space:]]+[^=;&|]*=[[:space:]]*${Q}?${P}aws"  && deny "alias to aws"
n "${CS}hash[[:space:]]+-[a-z]*p" && ns "$AWSW"               && deny "hash -p mapping to aws"
ns "(^|[^A-Za-z0-9_])[A-Za-z_][A-Za-z0-9_]*=([^[:space:];&|]*/)?aws(2|v2)?([[:space:];&|)]|$)" && ns '\$' \
  && deny "aws through a variable"
ns "(^|[[:space:]])-m[[:space:]]*awscli([[:space:]]|$)"      && deny "python -m awscli"
ns "${CS}(pipx|uvx|uv[[:space:]]+tool[[:space:]]+run|pipx[[:space:]]+run)[[:space:]]+${G}awscli"  && deny "awscli through pipx/uvx"
ns "amazon/aws-cli"                                          && deny "aws-cli container image"
if [ "$PLAIN_SEARCH" = 0 ]; then
  ns "(^|[^[:alnum:]_-])\\.aws([^[:alnum:]_-]|\$)"           && deny "AWS credential directory path"
else
  ns "/\\.aws([^[:alnum:]_-]|\$)"                            && deny "AWS credential directory path"
fi
# Interpreter with inline code (or heredoc, here-string, pipe) that talks to an AWS SDK.
INL="${CS}${P}(${INTERP}[[:space:]]+(-[^[:space:]]+[[:space:]]+)*(-[a-zA-Z]*[cepE][a-zA-Z]*|--eval|--print)([[:space:]]|${Q})|deno[[:space:]]+eval[[:space:]])"
INFEED="\\|&?[[:space:]]*${P}${INTERP}${END}|${CS}${P}${INTERP}([[:space:]]+-[^[:space:]]+)*[[:space:]]*(-[[:space:]]*)?<<"
if n "${INL}|${INFEED}" && printf '%s' "$CMD" | grep -Eiq 'boto3|botocore|aiobotocore|aws-sdk|@aws-sdk|Aws::|aws_sdk|awssdk'; then
  deny "inline interpreter code that uses an AWS SDK"
fi
if [ "$PLAIN_SEARCH" = 0 ]; then
  ns "(^|[[:space:]])--aws-sigv4|X-Amz-Security-Token|AWS4-HMAC" && deny "manual AWS request signing"
  VER='(@[^[:space:];&|]*)?'
  ns "${CS}${P}((cdk|aws-cdk|cdktf)${VER}[[:space:]]+${G}(deploy|destroy|bootstrap|import|watch|rollback)|sam[[:space:]]+${G}(deploy|delete|sync|publish)|(sls|serverless)${VER}[[:space:]]+${G}(deploy|remove|rollback)|eb[[:space:]]+${G}(deploy|create|terminate|setenv|scale)|amplify[[:space:]]+${G}(push|publish|delete)|copilot[[:space:]]+${G}(deploy|delete)|(chalice|zappa)[[:space:]]+${G}(deploy|delete|undeploy)|sst[[:space:]]+${G}(deploy|remove))${END}" \
                                                             && deny "infrastructure-as-code mutation"
fi

# --- the aws grammar ---
DENIED_FLAGS='cli-input-json cli-input-yaml endpoint-url debug no-verify-ssl ca-bundle no-sign-request no-dry-run'
# allowed_op SVC OP: 0 when on the allowlist; NEED_DRY=1 when it changes state.
allowed_op() {
  NEED_DRY=0
  case "$1 $2" in
    "sts get-caller-identity") ;;
    "ec2 describe-"*) ;;
    "ec2 run-instances"|"ec2 start-instances"|"ec2 stop-instances"|"ec2 reboot-instances"|"ec2 terminate-instances"|"ec2 create-tags"|"ec2 delete-tags"|\
    "ec2 create-security-group"|"ec2 delete-security-group"|"ec2 authorize-security-group-ingress"|"ec2 authorize-security-group-egress"|\
    "ec2 revoke-security-group-ingress"|"ec2 revoke-security-group-egress"|"ec2 modify-security-group-rules"|"ec2 modify-instance-attribute"|\
    "ec2 create-volume"|"ec2 attach-volume"|"ec2 detach-volume"|"ec2 delete-volume"|"ec2 create-snapshot"|"ec2 delete-snapshot"|"ec2 create-image"|\
    "ec2 allocate-address"|"ec2 associate-address"|"ec2 disassociate-address"|"ec2 release-address"|"ec2 create-launch-template"|\
    "ec2 monitor-instances"|"ec2 unmonitor-instances") NEED_DRY=1 ;;
    "s3 ls") ;;
    "s3api list-"*|"s3api head-bucket"|"s3api get-public-access-block") ;;
    "s3api get-bucket-location"|"s3api get-bucket-versioning"|"s3api get-bucket-encryption"|"s3api get-bucket-policy"|"s3api get-bucket-policy-status"|\
    "s3api get-bucket-acl"|"s3api get-bucket-tagging"|"s3api get-bucket-lifecycle-configuration"|"s3api get-bucket-cors"|"s3api get-bucket-logging"|\
    "s3api get-bucket-ownership-controls"|"s3api get-bucket-website"|"s3api get-bucket-notification-configuration"|"s3api get-bucket-replication") ;;
    *) return 1 ;;
  esac
  return 0
}
aws_segment() {
  local -a A=("${TOKS[@]:FI}")
  local n=${#A[@]} i tok name d v pcount=0 pval='' ok
  # --version and help need no profile; help only as aws help, aws <svc> help, aws <svc> <op> help (allowlisted)
  if [ "$n" -eq 2 ] && [ "${A[1]}" = "--version" ]; then return 0; fi
  if [ "$n" -ge 2 ] && [ "$n" -le 4 ] && [ "${A[n-1]}" = help ]; then
    case "$n" in
      2) return 0 ;;
      3) case "${A[1]}" in sts|ec2|s3|s3api) return 0 ;; esac ;;
      4) [ "${A[1]}" != s3 ] && allowed_op "${A[1]}" "${A[2]}" && return 0 ;;
    esac
  fi
  # b) profile exactly once; c) denied flags and file:// values
  for ((i=1; i<n; i++)); do
    tok=${A[i]}
    case "$tok" in
      --profile) pcount=$((pcount+1)); pval=${A[i+1]:-} ;;
      --profile=*) pcount=$((pcount+1)); pval=${tok#*=} ;;
    esac
  done
  [ "$pcount" = 1 ] && [ "$pval" = "$AWS_AGENT_PROFILE" ] || deny "aws needs exactly one --profile $AWS_AGENT_PROFILE"
  for ((i=1; i<n; i++)); do
    tok=${A[i]}
    case "$tok" in
      file://*|fileb://*|*=file://*|*=fileb://*) deny "aws argument reads a local file (file:// or fileb://)" ;;
      '$'*|-*'$'*) deny "aws argument built from a variable expansion" ;;
      --*) name=${tok#--}; name=${name%%=*}
           if [ -n "$name" ]; then
             for d in $DENIED_FLAGS; do
               case "$d" in "$name"*) deny "aws flag --$name is not allowed (--cli-input-*, --endpoint-url, --debug, TLS and signing overrides, abbreviations of these)" ;; esac
             done
             case "profile" in "$name"*) [ "$name" = profile ] || deny "abbreviated --profile flag" ;; esac
           fi ;;
    esac
  done
  # leading global flags, then service and operation
  i=1
  while [ "$i" -lt "$n" ]; do
    case "${A[i]}" in
      --profile) i=$((i+2)) ;;
      --profile=*) i=$((i+1)) ;;
      --region) v=${A[i+1]:-}; [[ $v =~ ^[a-z0-9-]+$ ]] || deny "aws --region needs a plain region name such as eu-west-1"; i=$((i+2)) ;;
      --region=*) v=${A[i]#*=}; [[ $v =~ ^[a-z0-9-]+$ ]] || deny "aws --region needs a plain region name such as eu-west-1"; i=$((i+1)) ;;
      --output) case "${A[i+1]:-}" in json|text|table|yaml|yaml-stream) ;; *) deny "aws --output must be json, text, table, yaml or yaml-stream" ;; esac; i=$((i+2)) ;;
      --output=*) case "${A[i]#*=}" in json|text|table|yaml|yaml-stream) ;; *) deny "aws --output must be json, text, table, yaml or yaml-stream" ;; esac; i=$((i+1)) ;;
      --no-cli-pager|--no-paginate|--color=*) i=$((i+1)) ;;
      --color) case "${A[i+1]:-}" in on|off|auto) i=$((i+2)) ;; *) i=$((i+1)) ;; esac ;;
      *) break ;;
    esac
  done
  SVC=${A[i]:-}; OP=${A[i+1]:-}
  case "$SVC" in -*|'') deny_list "$(safe_word "${SVC#-}")" "" ;; esac
  # d) secret and auth denylist, checked before the allowlist
  case "$SVC" in
    configure|sso|sso-oidc|login|logout) deny "aws $(safe_word "$SVC") handles credentials or sessions" ;;
    sts) [ "$OP" = get-caller-identity ] || deny "aws sts $(safe_word "$OP") can mint credentials" ;;
  esac
  case "$SVC $OP" in
    "ecr get-login"|"ecr get-login-password"|"eks get-token"|"codeartifact get-authorization-token"|"rds generate-db-auth-token"|"iam create-access-key") deny "aws $SVC $OP returns credentials" ;;
    "lambda get-function"*|"lambda list-functions"|"ecs describe-task-definition"|"cloudformation describe-stacks"|"cloudformation get-template") deny "aws $SVC $OP can expose environment variables or secrets" ;;
    "ssm get-parameter"*|"secretsmanager get-secret-value"|"secretsmanager batch-get-secret-value") deny "aws $SVC $OP returns secrets" ;;
    "s3 cp"|"s3 sync"|"s3 mv"|"s3 presign"|"s3 rm"|"s3 rb"|"s3api get-object"*|"s3api select-object-content") deny "aws $SVC $OP moves or reads object data" ;;
    "ec2 get-"*|"ec2 describe-launch-template-versions"|"ec2 describe-spot-fleet-requests"|"ec2 describe-spot-instance-requests"|"ec2 describe-vpn-connections"|"ec2 describe-verified-access-trust-providers") deny "aws $SVC $OP can expose secrets" ;;
  esac
  if [ "$SVC $OP" = "ec2 describe-instance-attribute" ]; then
    for tok in "${A[@]}"; do
      tok=${tok//[_-]/}
      case "$tok" in *[Uu][Ss][Ee][Rr][Dd][Aa][Tt][Aa]*) deny "aws ec2 describe-instance-attribute userdata can expose secrets" ;; esac
    done
  fi
  # e) allowlist (fail closed)
  allowed_op "$SVC" "$OP" || deny_list "$(safe_word "$SVC")" "$(safe_word "$OP")"
  if [ "$NEED_DRY" = 1 ]; then
    ok=0
    for ((i=1; i<n; i++)); do [ "${A[i]}" = "--dry-run" ] && ok=1; done
    [ "$ok" = 1 ] || deny "aws $SVC $OP changes state and is allowed only with --dry-run"
  fi
  return 0
}

# --- per-segment checks ---
SHELLX='bash|sh|zsh|dash|ksh|fish|eval|source|\.'
CREDW='awscurl|aws-vault|granted|assume|aws-sso-util|saml2aws|gimme-aws-creds|s5cmd'
WRAP='env|command|exec|builtin|nohup|nice|timeout|gtimeout|stdbuf|xargs|watch|parallel|script|unbuffer|sudo|doas|caffeinate|arch|ionice|taskset|setsid|flock|sandbox-exec|chroot|nsenter|unshare|firejail|systemd-run|numactl|prlimit|chronic|rlwrap|strace|ltrace|dtruss|proxychains|proxychains4|torsocks'
RUNNER='npx|pnpm|pnpx|npm|yarn|bun|bunx|uvx|uv|pipx|poetry|pdm|hatch|rye|pipenv|conda|mamba|micromamba|pixi|mise|rtx|asdf|op|dotenv|dotenvx|direnv|dlx|nix|nix-shell|devbox|bundle|rbenv|pyenv|nodenv|volta|fnm|corepack|docker|podman|nerdctl'
# LINE_AWS: the text (inert heredocs and commit messages removed) mentions aws or AWS_*; then nothing dynamic passes.
LINE_AWS=0
ns "$AWSW" && LINE_AWS=1
printf '%s' "$NS" | grep -Eq '(^|[^A-Za-z0-9_])AWS_[A-Z0-9_]' && LINE_AWS=1
# Dynamic words tolerated only on lines without aws: an environment variable plus a literal path, the repo root, or
# (as a shell, source or . argument) a plain variable with an optional literal path.
DYN_CMD1='^"?\$\{?([A-Z_][A-Z0-9_]*)\}?/[A-Za-z0-9_./-]+"?$'
DYN_CMD2='^"?\$\(git rev-parse --show-toplevel\)/[A-Za-z0-9_./-]+"?$'
DYN_ARG='^"?\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?(/[A-Za-z0-9_./-]*)?"?$'
assigned() { [[ $NS =~ (^|[^A-Za-z0-9_])$1\+?= ]]; }
LINE_RUNS=0
for ((sgi=0; sgi<NSEG; sgi++)); do
  seg_toks "$sgi"; first_cmd
  cnt=${#TOKS[@]}
  # AWS_* assignments before the command word
  for ((j=0; j<FI; j++)); do
    [[ ${TOKS[j]} =~ ^AWS_[A-Za-z0-9_]*(\[|\+?=) ]] && deny "AWS_* environment assignment (profile, config and endpoint are fixed by the hook)"
  done
  [ "$FI" -lt "$cnt" ] || continue
  fw=${TOKS[FI]}; ff=${TF[FI]}
  case "$ff" in
    *[DABEGC]*) case "$fw" in '['|'[[') ;; *)
      dyn_ok=0
      if [ "$LINE_AWS" = 0 ] && ! isaws "$fw"; then
        case "$ff" in *[AEG]*) ;; *)
          if [[ ${TR[FI]} =~ $DYN_CMD1 ]]; then assigned "${BASH_REMATCH[1]}" || dyn_ok=1
          elif [[ ${TR[FI]} =~ $DYN_CMD2 ]]; then dyn_ok=1; fi ;;
        esac
      fi
      [ "$dyn_ok" = 1 ] || deny "command word built from an expansion, substitution, escape, glob or brace (write the literal command)" ;;
    esac ;;
  esac
  if isaws "$fw"; then
    case "$fw" in aws|aws2|awsv2) ;; *) deny "aws must be the bare lowercase command word (no path prefix)" ;; esac
    [ "$HAD_ASSIGN" = 1 ] && deny "aws must be the bare command word (no variable assignment before it)"
    case "${SEGF[sgi]}" in *'#'*) deny "comment inside an aws command" ;; esac
    for ((j=FI; j<cnt; j++)); do
      case "${TF[j]}" in *[DABEGCHT]*) deny "aws argument with unquoted { } # * ? [ ~ \$ or \\ (use literal IDs and single quotes)" ;; esac
    done
    LINE_RUNS=1
    aws_segment
    continue
  fi
  fb=$(lower "${fw##*/}"); fb=${fb%%@*}
  [[ $fb =~ ^($CREDW)$ ]] && deny "credential or cloud-session tool ($fb)"
  # A shell (or eval/source) that reads piped data or a substituted argument runs code this hook cannot see.
  if [[ $fb =~ ^($SHELLX)$ ]]; then
    LINE_RUNS=1
    case "${SEGF[sgi]}" in *'|'*) deny "pipe into a shell ($fb)" ;; esac
    hasc=0
    for ((j=FI+1; j<cnt; j++)); do case "${TOKS[j]}" in -*c*) hasc=1 ;; esac; done
    for ((j=FI+1; j<cnt; j++)); do
      case "${TF[j]}" in *[DABE]*)
        # a script path held in a plain variable (source "$HOME/.cargo/env", bash "$f") is allowed without -c or aws
        if [ "$fb" = eval ] || [ "$hasc" = 1 ] || [ "$LINE_AWS" = 1 ] || [[ ${TF[j]} == *[AE]* ]] || ! [[ ${TR[j]} =~ $DYN_ARG ]]; then
          deny "shell, eval or source with an expansion or substitution argument ($fb)"
        fi ;;
      esac
    done
  fi
  # AWS_* set through a builtin (export, declare, printf -v, read ...), or a builtin with a variable name built by expansion
  case "$fb" in
    export|declare|typeset|local|readonly|read|mapfile|readarray|printf)
      for ((j=FI+1; j<cnt; j++)); do
        t=${TOKS[j]}; r=${TR[j]}
        [ "$fb" = printf ] && { case "$t" in -v) t=${TOKS[j+1]:-}; r=${TR[j+1]:-} ;; -v?*) t=${t#-v}; r=${r#-v} ;; *) continue ;; esac; }
        [[ $t =~ ^AWS_ ]] && deny "AWS_* environment variable set through $fb"
        case "${r%%=*}" in *'$'*|*'\'*|*'{'*|*'`'*) deny "variable name built by expansion in $fb" ;; esac
      done ;;
  esac
  if [[ $fb =~ ^($WRAP|$RUNNER)$ ]]; then
    LINE_RUNS=1
    [ "$fb" = command ] && [[ ${TOKS[FI+1]:-} == -v || ${TOKS[FI+1]:-} == -V ]] && continue
    for ((j=FI+1; j<cnt; j++)); do
      t=${TOKS[j]}; f=${TF[j]}
      isaws "$t" && deny "aws behind a wrapper or runner ($fb)"
      [[ $(lower "$t") =~ $AWSW ]] && deny "aws inside an argument of a wrapper or runner ($fb)"
      b=$(lower "${t##*/}"); b=${b%%@*}
      if [[ $b =~ ^($SHELLX)$ ]]; then
        case "${SEGF[sgi]}" in *'|'*) deny "pipe into a shell behind a wrapper ($fb)" ;; esac
      fi
      case "$f" in *G*) glob_aws "$t" && deny "glob that can expand to aws behind a wrapper or runner ($fb)" ;; esac
      case "$f" in *[ABE]*) deny "escape or expansion behind a wrapper or runner ($fb)" ;; esac
      case "$f" in *C*) case "$t" in *,*|*..*) deny "brace expansion behind a wrapper or runner ($fb)" ;; esac ;; esac
      case "$f" in *D*) [[ $fb =~ ^($WRAP)$ ]] && deny "expansion behind a wrapper ($fb)" ;; esac
      [[ $b =~ ^($CREDW)$ ]] && deny "credential or cloud-session tool ($b)"
    done
    case "$fb" in
      docker|podman|nerdctl)
        hit=0
        for ((j=FI+1; j<cnt; j++)); do case "${TOKS[j]}" in run|exec|create) hit=1 ;; esac; done
        if [ "$hit" = 1 ]; then
          for ((j=FI+1; j<cnt; j++)); do
            v=''
            case "${TOKS[j]}" in
              -v|--volume|--mount) v=${TOKS[j+1]:-} ;;
              --volume=*|--mount=*) v=${TOKS[j]#*=} ;;
              -v?*) v=${TOKS[j]#-v} ;;
            esac
            [ -n "$v" ] || continue
            case "$v" in
              *'$HOME'*|*'${HOME}'*|'~'*|*/Users/*|/Users|/Users:*|*/home/*|/home|/home:*|/root*|/|/:*|*.[Aa][Ww][Ss]*|*=/:*|*=/,*|*=/)
                deny "container mount of the home directory, / or .aws" ;;
            esac
          done
        fi ;;
    esac
  elif [[ $fb =~ ^(ln|link|cp|mv|install|rsync|ditto)$ ]]; then
    for ((j=FI+1; j<cnt; j++)); do
      isaws "${TOKS[j]}" && deny "copy or link of the aws binary ($fb)"
      case "${TF[j]}" in *G*) glob_aws "${TOKS[j]}" && deny "copy or link of a glob that can match aws ($fb)" ;; esac
    done
  elif [ "$fb" = find ]; then
    hit=0
    for ((j=FI+1; j<cnt; j++)); do
      case "${TOKS[j]}" in -exec|-execdir|-ok|-okdir) hit=1 ;; esac
      if [ "$hit" = 1 ]; then
        isaws "${TOKS[j]}" && deny "aws behind find -exec"
        case "${TF[j]}" in *G*) glob_aws "${TOKS[j]}" && deny "glob that can expand to aws behind find -exec" ;; esac
        [ "${TOKS[j]}" = ';' ] || case "${TF[j]}" in *[DABE]*) deny "escape or expansion behind find -exec" ;; esac
      fi
    done
  fi
done
# AWS_* on a line that also runs aws, a wrapper or runner, a shell, eval or source
if [ "$LINE_RUNS" = 1 ] && printf '%s' "$NS" | grep -Eq '(^|[^A-Za-z0-9_])AWS_[A-Z0-9_]'; then
  deny "AWS_* on a line that runs aws, a runner, a wrapper or a shell"
fi

exit 0
