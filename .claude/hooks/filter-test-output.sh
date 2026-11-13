#!/usr/bin/env bash
# PreToolUse hook for Bash: rewrites allowlisted test/build/lint commands so long output is
# filtered before Claude sees it, and the original exit code is preserved.
# Two modes of this one script; neither ever executes a command string:
#   hook mode   (no args): reads the hook JSON on stdin, prints updatedInput JSON or {}.
#               The rewrite is ( set -o pipefail; CMD 2>&1 | 'SELF' --filter ), so CMD still runs
#               in the Bash tool's own shell (aliases and functions kept) and its status is kept.
#   filter mode (--filter): reads output on stdin, logs it, prints a filtered view, exits 0.
# Fails OPEN: any problem in hook mode prints {} and exits 0 (never blocks, never auto-approves).
# Full logs are kept in ${TMPDIR:-/tmp} (filter-test-output.*) so the agent can Read them;
# this user's logs older than 1 day are deleted on the next run.
set -u

usage() { echo "usage: filter-test-output.sh            (PreToolUse hook, JSON on stdin)" >&2
          echo "       filter-test-output.sh --filter   (filters stdin; takes no command)" >&2; exit 2; }

if [ $# -gt 0 ]; then
  [ "$1" = "--filter" ] && [ $# -eq 1 ] || usage

  CAP_KB=51200       # stored log cap (50 MB); later output is drained and discarded
  HEAD_N=20; TAIL_N=60; SHORT_N=200; HIT_CAP=150; MAX_LEN=2000
  DIR="${TMPDIR:-/tmp}"
  case $DIR in /*) ;; *) DIR=/tmp ;; esac   # never pass "-..." or a relative path to find
  [ -d "$DIR" ] || exec cat                  # never lose output
  find "$DIR" -maxdepth 1 -type f -name 'filter-test-output.*' -user "$(id -u)" -mmin +1440 \
    -delete 2>/dev/null
  LOG=$(mktemp "$DIR/filter-test-output.XXXXXX" 2>/dev/null) || exec cat   # never lose output
  chmod 600 "$LOG" 2>/dev/null

  # Prints LOG (TOTAL lines) in full if short, else head, failure lines with context, and tail.
  # Memory-bounded: streams the file; holds only 2 lines of context. Long lines are truncated.
  render() {
    local total=$1
    if [ "$total" -le "$SHORT_N" ]; then
      if LC_ALL=C awk -v m="$MAX_LEN" 'length($0) > m { f = 1; exit } END { exit f }' "$LOG"; then
        cat "$LOG"
      else
        LC_ALL=C awk -v m="$MAX_LEN" '{ if (length($0) > m) $0 = substr($0, 1, m) \
          "... [filter-test-output: line truncated, " length($0) " chars]"; print }' "$LOG"
      fi
      return
    fi
    LC_ALL=C awk -v total="$total" -v head_n="$HEAD_N" -v tail_n="$TAIL_N" -v cap="$HIT_CAP" \
      -v m="$MAX_LEN" -v ctx=2 '
      function out(s) {
        if (length(s) > m) s = substr(s, 1, m) "... [filter-test-output: line truncated, " length(s) " chars]"
        print s
      }
      function emit(i, s) {
        if (n >= cap) { if (!capped) print "[filter-test-output] ... failure lines capped at " cap; capped = 1; return }
        if (last && i != last + 1) print "--"
        out(s); n++; last = i
      }
      BEGIN { lo = head_n + 1; hi = total - tail_n }
      NR <= head_n {
        out($0)
        if (NR == head_n) print "[filter-test-output] ... output truncated; failure-related lines follow ..."
        next
      }
      NR <= hi {
        if (!capped) {
          if (/FAIL|ERROR|Error:|error:|error TS[0-9]+|  error  |Traceback|panic:|panicked at|not ok|AssertionError|[0-9]+ failing|✗|✕|^E /) {
            for (j = NR - ctx; j < NR; j++) if (j >= lo && j > last) emit(j, ring[j % (ctx + 1)])
            emit(NR, $0); after = ctx
          } else if (after > 0) { emit(NR, $0); after-- }
        }
        ring[NR % (ctx + 1)] = $0
        next
      }
      NR == hi + 1 { print "[filter-test-output] ... last " tail_n " lines ..." }
      { out($0) }' "$LOG"
  }
  count() { LC_ALL=C awk 'END { print NR }' "$LOG"; }

  PID=""
  on_signal() {
    trap '' HUP INT TERM
    if [ -n "$PID" ]; then kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null; fi
    local total; total=$(count)
    render "$total"
    echo "[filter-test-output] interrupted after $total lines; full log: $LOG"
    exit "$1"
  }
  trap 'on_signal 129' HUP
  trap 'on_signal 130' INT
  trap 'on_signal 143' TERM

  # Capture in the background and wait, so a signal interrupts the wait and the trap runs.
  # cat writes each read at once, so the log is current when interrupted. ulimit -f caps the log;
  # with SIGXFSZ ignored, cat stops with EFBIG and the rest of stdin is drained below.
  # Any capture failure also drains, so the producer never gets SIGPIPE (exit 141).
  exec 3<&0
  ( ulimit -f "$CAP_KB"; trap '' XFSZ; exec cat ) <&3 >"$LOG" 2>/dev/null &
  PID=$!
  wait "$PID"
  CAP_RC=$?
  CAPPED=0
  [ "$(wc -c <"$LOG" | tr -d ' ')" -ge $((CAP_KB * 1024)) ] && CAPPED=1
  if [ "$CAP_RC" -ne 0 ] || [ "$CAPPED" = 1 ]; then
    cat <&3 >/dev/null 2>&1 &
    PID=$!
    wait "$PID"
  fi
  if [ "$CAPPED" = 1 ]; then
    if [ "$CAP_KB" -ge 1024 ]; then SIZE="$((CAP_KB / 1024)) MB"; else SIZE="$CAP_KB KB"; fi
    printf '\n[filter-test-output] log capped at %s; later output was discarded\n' "$SIZE" >>"$LOG"
  fi
  trap '' HUP INT TERM   # done reading: a late signal must not render twice or count a deleted LOG
  PID=""
  exec 3<&-
  TOTAL=$(count)
  render "$TOTAL"
  if [ "$TOTAL" -le "$SHORT_N" ]; then
    rm -f "$LOG"   # short output is shown in full; nothing to read back
  else
    echo "[filter-test-output] $TOTAL lines total; full log: $LOG"
  fi
  exit 0
fi

# --- hook mode ---
none() { echo '{}'; exit 0; }
[ "${CLAUDE_FILTER_OUTPUT:-1}" = "0" ] && none
command -v jq >/dev/null 2>&1 || none
SELF_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd -P) || none
[ -n "$SELF_DIR" ] || none
SELF="$SELF_DIR/$(basename "$0")"
[ -f "$SELF" ] && [ -x "$SELF" ] || none
INPUT=$(cat) || none
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null) || none
[ -z "$CMD" ] && none
# Background calls are read back incrementally; leave them unfiltered.
BG=$(printf '%s' "$INPUT" | jq -r '.tool_input.run_in_background == true' 2>/dev/null) || none
[ "$BG" = "false" ] || none

# Whole command must match: an allowlisted command plus optional args made only of safe characters
# (no quotes, ( ) ; & | < > ` $ # backslash, control characters or newlines). A rewritten command
# starts with "(" and so never matches again.
LC_ALL=C
ARGS='( [A-Za-z0-9_./:=@%+, -]*)?'
NAME='[A-Za-z0-9_-]+'
RE="^(npm test|npm run (test|build|lint)(:[A-Za-z0-9_:-]*)?|pnpm (test|run test|run build|run lint)|yarn (test|build|lint)|npx (jest|vitest)|pytest|python -m pytest|python3 -m pytest|go (test|build|vet)|cargo (test|build|clippy)|make (test|build|lint|check)|bash tests/$NAME\.sh|python3 tests/$NAME\.py)$ARGS\$"
[[ "$CMD" =~ $RE ]] || none

# CMD is inserted verbatim: the allowlist above admits no shell metacharacters, so it cannot
# break out of the pipeline. SELF is single-quoted with jq @sh. Valid in both bash and zsh.
printf '%s' "$INPUT" | jq -c --arg self "$SELF" --arg cmd "$CMD" '
  {hookSpecificOutput: {hookEventName: "PreToolUse",
    updatedInput: (.tool_input + {command:
      ("( set -o pipefail; " + $cmd + " 2>&1 | " + ($self | @sh) + " --filter )")})}}' 2>/dev/null || none
exit 0
