#!/usr/bin/env bash
# Guided tour of pane.sh: opens a new pane next to the user's and drives it like any other pane.
# Each explanation is a short `onboarding <step>` command typed in the pane: it prints the text of the
# step and waits for the user to press Enter, so the user sets the pace. Real commands run between
# the steps. Each step is logged on stdout so Claude can relay it.
# usage: onboarding.sh [lang|messages-file] [target] [below|above|left|right]
#   lang: a file name in onboarding-messages/ (en, fr); messages-file: a translation of en.sh.
#   target: a window or pane to open a new pane next to (default: the active pane of the current
#   session), on the given side (default: below); or a pane ID such as %3 with no side, to run the
#   tour in that existing pane, which must sit idle at its prompt.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
pane() { bash "$here/pane.sh" "$@"; }
log() { printf '[%s] %s\n' "$(date +%T)" "$*"; }

lang=${1:-en}
if [[ -f $lang ]]; then messages=$(realpath "$lang"); else messages=$here/onboarding-messages/$lang.sh; fi
[[ -r $messages ]] || { echo "onboarding: no messages for '$lang' (translate $here/onboarding-messages/en.sh)" >&2; exit 1; }

# A regex matching the final character of the pane's last non-blank line (the prompt sign).
prompt_re() {
  local line sign
  line=$(tmux capture-pane -p -J -t "$1" | { grep -v '^[[:space:]]*$' || true; } | tail -n 1)
  line=${line%"${line##*[![:space:]]}"}
  sign=${line: -1}
  [[ -n $sign ]] || { echo "onboarding: no prompt in $1" >&2; exit 1; }
  printf '%s ?$' "$(printf '%s' "$sign" | sed 's/[]\/$*.^[]/\\&/g')"
}

# Wait for command <id> to end, however long the user takes to press Enter; its exit status goes to $rc.
wait_result() {
  local out st start=$SECONDS
  while :; do
    set +e
    out=$(pane result "$P" "$1" 5 2>/dev/null)
    st=$?
    set -e
    if ((st == 0)); then rc=${out##*rc=}; return 0; fi
    ((st == 124)) || { echo "onboarding: result failed ($st)" >&2; exit 1; }
    ((SECONDS - start < ${ONBOARDING_IDLE_MAX:-1800})) || { echo "onboarding: nobody pressed Enter, stopping" >&2; exit 1; }
  done
}
run() { wait_result "$(pane send "$P" "$RE" "$1" | sed 's/^id=//')"; }
step() {
  log "step $*: waiting for Enter"
  run "onboarding $*"
  ((rc == 0)) || { echo "onboarding: step $1 failed with status $rc in $P" >&2; exit 1; }
}

target=${2:-$(tmux display-message -p '#{window_id}')}
if [[ $target =~ ^%[0-9]+$ && -z ${3:-} ]]; then
  P=$target
  log "running the tour in the existing pane $P"
else
  # Always bash, whatever the user's shell: enter needs it.
  case ${3:-below} in
    below) side=(-v) ;; above) side=(-v -b) ;; right) side=(-h) ;; left) side=(-h -b) ;;
    *) echo "onboarding: side must be below, above, left or right" >&2; exit 64 ;;
  esac
  P=$(tmux split-window -d "${side[@]}" -t "$target" -P -F '#{pane_id}' bash)
  log "opened $P ${3:-below} $target"
  sleep 1
fi
# child-rc.sh reads these when enter starts the child bash: it puts the `onboarding` command in PATH
# after the user's ~/.bashrc, whatever the bashrc does to PATH. Nothing to type for either.
tmux set -p -t "$P" @claude_onboard_dir "$here/onboarding-bin"
tmux set -p -t "$P" @claude_onboard_messages "$messages"
# On the way out, drop the onboarding marks. If the tour stops half-way (an error, or nobody pressed
# Enter for 30 min), stop the step that waits and leave the child bash: the user gets the pane back.
cleanup() {
  local st=$?
  tmux set -p -u -t "$P" @claude_onboard_dir 2>/dev/null
  tmux set -p -u -t "$P" @claude_onboard_messages 2>/dev/null
  if ((st != 0)) && [[ -n $(tmux show -pqv -t "$P" @claude_child 2>/dev/null) ]]; then
    pane interrupt "$P" >/dev/null 2>&1 || true
    sleep 1
    # Not through leave: it checks the prompt, which may be what went wrong. The child is still there
    # (@claude_child is set), so exit 0 goes to it; its watcher then releases the pane.
    tmux send-keys -t "$P" C-u
    tmux send-keys -t "$P" -l 'exit 0'
    tmux send-keys -t "$P" Enter
    for ((i = 0; i < 20; i++)); do
      [[ -z $(tmux show -pqv -t "$P" @claude_child 2>/dev/null) ]] && break
      sleep 0.25
    done
    pane release "$P" >/dev/null 2>&1 || true
    log "tour stopped: $P given back to the user"
  fi
}
trap cleanup EXIT
# Killed (cancelled by the user, say): exit through cleanup, so the pane is given back.
trap 'exit 143' TERM INT HUP

pane claim "$P" >/dev/null
pane enter "$P" "$(prompt_re "$P")" >/dev/null
RE=$(prompt_re "$P")
log "claimed $P and entered a child bash: [claude 0] prompt, history in ~/.bash_history_claude"

step hello
step colors
run 'sleep 3'
log "ran sleep 3 (pane orange)"

step pause
sleep 10
log "idled 10 s (pane grey after 5 s)"

step status
run 'false'
false_rc=$rc
step rc "$false_rc"
log "read exit status $false_rc"

step script
script=$(mktemp)
printf 'for i in 1 2 3; do\n  date +%%T\n  sleep 1\ndone\n' >"$script"
wait_result "$(pane paste "$P" "$RE" "$script" | sed 's/^id=//')"
rm -f "$script"
log "pasted a multi-line loop"

step stop
id=$(pane send "$P" "$RE" 'sleep 60' | sed 's/^id=//')
sleep 3
pane interrupt "$P" >/dev/null
wait_result "$id"
log "interrupted sleep 60 (rc=$rc)"

step bye
pane leave "$P" "$RE" >/dev/null
log "left the child bash and released $P: original look restored"
