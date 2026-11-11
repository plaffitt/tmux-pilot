#!/usr/bin/env bash
# Drive a user's existing tmux pane: read it, type into it, collect output.
# Read-only subcommands: list, state, tail, result. Writing ones: send, paste.
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
usage:
  pane.sh list
  pane.sh open   [window|%pane] [below|above|left|right]
  pane.sh state  <%pane>
  pane.sh tail   <%pane> [lines]
  pane.sh send   <%pane> <prompt-regex> <command>
  pane.sh paste  <%pane> <prompt-regex> <script-file>
  pane.sh result <%pane> <id> [timeout-seconds]
  pane.sh claim   <%pane>
  pane.sh release <%pane>
  pane.sh interrupt <%pane>
  pane.sh handover <%pane>
  pane.sh takeback <%pane>
  pane.sh enter   <%pane> <prompt-regex>
  pane.sh leave   <%pane> <prompt-regex>
EOF
  exit 64
}

die() { echo "pane.sh: $*" >&2; exit 1; }

check_id() {
  [[ $1 =~ ^%[0-9]+$ ]] || die "target must be a pane ID such as %3, not '$1'"
  tmux display-message -p -t "$1" '#{pane_id}' >/dev/null 2>&1 || die "pane $1 does not exist"
}

last_line() {
  tmux capture-pane -p -J -t "$1" -S -50 | { grep -v '^[[:space:]]*$' || true; } | tail -n 1
}

# Refuse to type unless the pane is alive, not in copy mode, and idle at the expected prompt.
check_ready() {
  local pane=$1 expect=$2 mode dead last
  check_id "$pane"
  read -r mode dead < <(tmux display-message -p -t "$pane" '#{pane_in_mode} #{pane_dead}')
  [[ $dead == 0 ]] || die "pane $pane is dead"
  [[ $mode == 0 ]] || die "pane $pane is in copy mode (the user is scrolling): ask them to leave it"
  last=$(last_line "$pane")
  [[ $last =~ $expect ]] || die "last line of $pane does not match /$expect/: '$last'"
}

# Refuse to type into a local bash that enter did not start: the commands would land in the user's
# own history. A remote shell behind ssh shows up as ssh here, so this only guards local panes.
require_child() {
  [[ $(tmux display-message -p -t "$1" '#{pane_current_command}') != bash ]] && return 0
  [[ -n $(tmux show -pqv -t "$1" @claude_child) ]] && return 0
  die "pane $1 runs the user's own bash: run 'pane.sh enter $1 <prompt-regex>' first, so your commands stay out of their history"
}

# Drop trailing blank lines (the unused bottom of the screen).
trim() { awk 'NF { while (n > 0) { print ""; n-- } print; next } { n++ }'; }

new_id() { printf '%s%05d' "$(date +%s)" "$RANDOM"; }

# Look of a claimed pane: a tinted background and a banner in its top border. Dark orange while
# Claude works in the pane, very dark grey while it holds the pane but does nothing in it, dark purple
# while it waits for the user to act in it (handover): a key to press, an answer to type.
BUSY_STYLE='bg=#170c00'
IDLE_STYLE='bg=#1a1a1a'
WAIT_STYLE='bg=#1c1026'
# It sits inside a #{?cond,yes,no} format: a bare comma would end the branch, but a nested
# #{?...} is fine since tmux skips over braces.
CLAIM_BANNER='#{?@claude_wait,#[bold fg=#b07cd8] Claude pilote ce pane (c’est à vous) ,#{?@claude_busy,#[bold fg=#d2691e] Claude pilote ce pane (travail en cours) ,#[bold fg=#5a5a5a] Claude pilote ce pane }}#[default]'

# @claude_busy holds a token while Claude works in the pane: cmd-<id> while a sent command runs,
# act-<id> after any other action. Each watcher only clears its own token.
# When does Claude stop working in the pane? Installed as a plugin, its Stop hook tells exactly: Claude's
# turn is over (hook stop below), and the pane turns grey then; until then Claude may come back to it
# at any time, so it stays orange. The SessionStart hook flags the session in a global tmux option.
# Without the hooks (the skill alone), the pane turns grey BUSY_LINGER seconds after the last action;
# with them, HOOKED_LINGER is only a safety net, for a turn that ends without its Stop hook.
BUSY_LINGER=5
HOOKED_LINGER=120
SESSION=${CLAUDE_CODE_SESSION_ID:-}
hooked() { [[ -n $SESSION && -n $(tmux show -gqv "@claude_hooked_$SESSION" 2>/dev/null) ]]; }
linger() { if hooked; then echo "$HOOKED_LINGER"; else echo "$BUSY_LINGER"; fi; }

paint() {
  tmux set -p -t "$1" window-style "$2"
  tmux set -p -t "$1" window-active-style "$2"
}

# Shared by the background watchers: drop token $2 from pane $1 if it is still there, then grey the pane.
UNBUSY='unbusy() {
  [[ $(tmux show -pqv -t "$1" @claude_busy 2>/dev/null) == "$2" ]] || return 0
  tmux set -p -u -t "$1" @claude_busy
  [[ -n $(tmux show -pqv -t "$1" @claude) ]] || return 0
  [[ -z $(tmux show -pqv -t "$1" @claude_wait) ]] || return 0
  tmux set -p -t "$1" window-style "$3"
  tmux set -p -t "$1" window-active-style "$3"
}'

# While the pane is handed over, Claude's reads keep it purple: the user is the one to act.
set_busy() {
  tmux set -p -t "$1" @claude_busy "$2"
  [[ -n $(tmux show -pqv -t "$1" @claude_wait) ]] || paint "$1" "$BUSY_STYLE"
}

# End a handover: back to orange if Claude is still working in the pane, grey otherwise.
takeback_pane() {
  [[ -n $(tmux show -pqv -t "$1" @claude_wait) ]] || return 0
  tmux set -p -u -t "$1" @claude_wait
  [[ -n $(tmux show -pqv -t "$1" @claude) ]] || return 0
  if [[ -n $(tmux show -pqv -t "$1" @claude_busy) ]]; then paint "$1" "$BUSY_STYLE"; else paint "$1" "$IDLE_STYLE"; fi
}

# Show the warning until the turn ends (or the linger runs out). Leaves a running command's token
# alone unless forced. Only a claimed pane changes colour: reading a pane the user did not hand over
# leaves it as it is.
touch_busy() {
  local pane=$1 force=${2:-} token
  [[ -n $(tmux show -pqv -t "$pane" @claude) ]] || return 0
  tmux set -p -u -t "$pane" @claude_turn_over
  [[ -n $force || $(tmux show -pqv -t "$pane" @claude_busy) != cmd-* ]] || return 0
  token=act-$(new_id)
  set_busy "$pane" "$token"
  setsid bash -c "$UNBUSY"'
    sleep "$4"
    unbusy "$1" "$2" "$3"
  ' _ "$pane" "$token" "$IDLE_STYLE" "$(linger)" </dev/null >/dev/null 2>&1 &
}

# Show the warning while command <id> runs, then until the turn ends (or the linger runs out): once a
# [claude <rc>] prompt shows up below line <start>, or, without a start line, once the END marker does.
# The watcher stops as soon as the token changes (newer action, interrupt, release) or the pane is gone.
mark_busy() {
  local pane=$1 id=$2 start=${3:-} skip=${4:-} height=${5:-}
  [[ -n $(tmux show -pqv -t "$pane" @claude) ]] || return 0
  tmux set -p -u -t "$pane" @claude_turn_over
  set_busy "$pane" "cmd-$id"
  setsid bash -c "$UNBUSY"'
    pane=$1 id=$2 start=$5 skip=$6 script=$7 height=$8
    done_yet() {
      if [[ -n $start ]]; then
        bash "$script" _done "$pane" "$start" "$skip" "$height" >/dev/null
      else
        tmux capture-pane -p -J -t "$pane" -S - | grep -Eq "END_$id rc=[0-9]"
      fi
    }
    while [[ $(tmux show -pqv -t "$pane" @claude_busy 2>/dev/null) == "cmd-$id" ]]; do
      if done_yet; then
        tmux set -p -t "$pane" @claude_busy "act-$id"
        # Claude turn already over (the command outlived it): grey at once.
        [[ -n $(tmux show -pqv -t "$pane" @claude_turn_over) ]] || sleep "$4"
        unbusy "$pane" "act-$id" "$3"
        break
      fi
      # Reading a few lines after the command is cheap; grepping the whole scrollback is not.
      if [[ -n $start ]]; then sleep 0.25; else sleep 1; fi
    done
  ' _ "$pane" "$id" "$IDLE_STYLE" "$(linger)" "$start" "$skip" "$here/pane.sh" "$height" </dev/null >/dev/null 2>&1 &
}

clear_busy() { tmux set -p -u -t "$1" @claude_busy 2>/dev/null || true; }

# enter starts a child bash with its own history file and the prompt hook of claude-hook.sh.
# Bash records the whole line before running it, so `history -d -1` (bash >= 5.0) deletes that very
# line before the child even starts: the user's history keeps no trace of it, whatever HISTCONTROL
# says, even if the pane is closed while the child runs.
# In a local pane the child reads child-rc.sh, which sets all of it up from 1 short typed line. Behind
# ssh that file does not exist, so the child starts with its history file set, then gets the hook pasted.
here=$(cd "$(dirname "$0")" && pwd)
REMOTE_CHILD_SHELL='history -d -1; HISTFILE=~/.bash_history_claude bash'

# The startup file as the user reads it in the pane: ~/ rather than their home path.
local_child_shell() {
  local rc=$here/child-rc.sh
  if [[ $rc == "$HOME"/* ]]; then rc="~/$(printf '%q' "${rc#"$HOME"/}")"; else rc=$(printf '%q' "$rc"); fi
  echo "history -d -1; bash --rcfile $rc"
}

# split-window flags for a side of the target pane.
split_side() {
  case $1 in
    below) echo -v ;;
    above) echo -v -b ;;
    right) echo -h ;;
    left) echo -h -b ;;
    *) die "side must be below, above, left or right, not '$1'" ;;
  esac
}

# A pane runs on this machine when its foreground program is a local shell, not ssh or the like.
is_local() { [[ $(tmux display-message -p -t "$1" '#{pane_current_command}') =~ ^(bash|zsh|fish|sh|dash|ksh)$ ]]; }

# Absolute index of the cursor line, counted from the oldest line of the scrollback.
abs_line() { tmux display-message -p -t "$1" '#{e|+:#{history_size},#{cursor_y}}'; }

# The prefix the hook puts at the start of each prompt of the child bash.
# Bracket expressions rather than \[ \]: grep -E and awk -v read them the same way.
PROMPT_TAG='[[]claude [0-9]+[]] '

# Physical lines <from> to <to>, absolute indexes; a 4th argument joins the wrapped ones (-J).
lines() {
  local hs
  hs=$(tmux display-message -p -t "$1" '#{history_size}')
  tmux capture-pane -p ${4:+-J} -t "$1" -S $(($2 - hs)) -E $(($3 - hs))
}

# Height of the prompt the cursor sits on: from the last line holding the tag to the cursor. The pane
# is idle at its prompt here, and the tag can follow output that had no final newline.
prompt_height() {
  local cur
  cur=$(abs_line "$1")
  lines "$1" $((cur - 9)) "$cur" \
    | awk -v tag="$PROMPT_TAG" '$0 ~ tag { last = NR } END { print last ? NR - last + 1 : 1 }'
}

# The command typed at line <start> is over once its prompt is back: the tag stands on the line where a
# prompt of <height> lines ending at the cursor starts. Text that merely contains the tag, with other
# lines below it, does not count. Prints the exit status read in the tag; fails before.
prompt_row() { echo $(($(abs_line "$1") - $2 + 1)); }
cmd_done() {
  local row
  row=$(prompt_row "$1" "$4")
  ((row > $2)) || return 1
  lines "$1" "$row" "$row" | grep -oE "$PROMPT_TAG" | tail -n 1 | grep -oE '[0-9]+'
}

# Output of the command typed at line <start>: the lines between the command (its <skip> echoed lines
# dropped) and the new prompt, plus what precedes the tag on the prompt line when the output has no
# final newline.
cmd_output() {
  local row prefix
  row=$(prompt_row "$1" "$4")
  ((row - 1 < $2)) || lines "$1" "$2" $((row - 1)) J | tail -n +$(($3 + 1))
  prefix=$(lines "$1" "$row" "$row" | awk -v tag="$PROMPT_TAG" '{ p = 0; while (match(substr($0, p + 1), tag)) p += RSTART; print substr($0, 1, p - 1) }')
  [[ -z $prefix ]] || printf '%s\n' "$prefix"
}

# Has a prompt of the child bash shown up below absolute line <start>? A [claude <rc>] prompt left
# on screen by an earlier child does not count.
child_prompt() { (($(abs_line "$1") > $2)) && lines "$1" $(($2 + 1)) "$(abs_line "$1")" | grep -qE "$PROMPT_TAG"; }

# Wait up to 10 s for the pane's last line to match the prompt regex.
wait_prompt() {
  local i
  for ((i = 0; i < 20; i++)); do
    [[ $(last_line "$1") =~ $2 ]] && return 0
    sleep 0.5
  done
  die "no prompt matching /$2/ in $1 after 10 s"
}

# Window options a claim changes; their window-local values are saved before the first claim.
WINDOW_OPTS=(pane-border-status pane-border-format)

# Give back their own border options to windows that no longer hold a claimed pane,
# including those whose claimed pane was closed by the user without a release.
restore_unclaimed_windows() {
  local win opt prev
  for win in $(tmux list-windows -a -F '#{window_id}'); do
    [[ -n $(tmux show -wqv -t "$win" @claude_saved) ]] || continue
    tmux list-panes -t "$win" -F '#{@claude}' | grep -qx 1 && continue
    for opt in "${WINDOW_OPTS[@]}"; do
      prev=$(tmux show -wqv -t "$win" "@claude_prev_$opt")
      if [[ -n $prev ]]; then tmux set -w -t "$win" "$opt" "$prev"; else tmux set -w -u -t "$win" "$opt"; fi
      tmux set -w -u -t "$win" "@claude_prev_$opt"
    done
    tmux set -w -u -t "$win" @claude_saved
  done
}

# Give the pane back as it was: its own colours and border, no claim left.
release_pane() {
  tmux set -p -u -t "$1" @claude
  tmux set -p -u -t "$1" @claude_wait
  clear_busy "$1"
  tmux set -p -u -t "$1" window-style
  tmux set -p -u -t "$1" window-active-style
  restore_unclaimed_windows
  # Last: leave waits for @claude_child to go, so everything above is done by then.
  tmux set -p -u -t "$1" @claude_cmd
  tmux set -p -u -t "$1" @claude_exited
  tmux set -p -u -t "$1" @claude_session
  tmux set -p -u -t "$1" @claude_turn_over
  tmux set -p -u -t "$1" @claude_child
}

# The panes this session claimed.
session_panes() {
  [[ -n $1 ]] || return 0
  tmux list-panes -a -F '#{pane_id} #{@claude} #{@claude_session}' 2>/dev/null | awk -v s="$1" '$2 == 1 && $3 == s { print $1 }'
}

# Plugin hooks, fed the hook input (JSON) on stdin; they must never fail nor block Claude Code.
run_hook() {
  local sid pane token
  sid=$(tr -d '\n' | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  [[ -n $sid ]] || return 0
  tmux list-sessions >/dev/null 2>&1 || return 0
  case $1 in
    session-start)
      tmux set -g "@claude_hooked_$sid" 1
      ;;
    stop)
      # Claude's turn is over: its panes turn grey, except where a command it sent still runs (that
      # one turns grey as soon as the command ends).
      for pane in $(session_panes "$sid"); do
        tmux set -p -t "$pane" @claude_turn_over 1
        token=$(tmux show -pqv -t "$pane" @claude_busy)
        [[ $token == cmd-* ]] && continue
        clear_busy "$pane"
        [[ -n $(tmux show -pqv -t "$pane" @claude_wait) ]] || paint "$pane" "$IDLE_STYLE"
      done
      ;;
    session-end)
      # The session goes away (exit, /clear): give its panes back. A child bash idle at its prompt is
      # left with exit 0, its watcher then releases the pane; anything else is released as it is.
      for pane in $(session_panes "$sid"); do
        if [[ -n $(tmux show -pqv -t "$pane" @claude_child) && $(tmux show -pqv -t "$pane" @claude_busy) != cmd-* ]]; then
          tmux send-keys -t "$pane" C-u
          tmux send-keys -t "$pane" -l 'exit 0'
          tmux send-keys -t "$pane" Enter
        else
          release_pane "$pane"
        fi
      done
      tmux set -gu "@claude_hooked_$sid"
      ;;
  esac
}

# Watch the child bash of enter and give the pane back once it exits, whether Claude (leave) or the
# user typed exit. In a local pane the hook flags the exit in @claude_exited. Behind ssh it cannot
# reach tmux, but bash prints "exit" when an interactive shell ends: an "exit" line after the last
# [claude <rc>] prompt, while no command of Claude runs, means the child is gone.
# Stops if the pane disappears.
watch_child() {
  setsid bash -c '
    pane=$1 script=$2 tag=$3
    gone() {
      [[ -n $(tmux show -pqv -t "$pane" @claude_exited) ]] && return 0
      [[ $(tmux show -pqv -t "$pane" @claude_busy) != cmd-* ]] || return 1
      tmux capture-pane -p -J -t "$pane" -S -40 \
        | awk -v tag="$tag" "\$0 ~ tag { e = 0; next } \$0 == \"exit\" { e = 1 } END { exit !e }"
    }
    while tmux display-message -p -t "$pane" "#{pane_id}" >/dev/null 2>&1; do
      [[ -n $(tmux show -pqv -t "$pane" @claude_child) ]] || exit 0
      gone && exec bash "$script" release "$pane"
      sleep 0.5
    done
    bash "$script" list >/dev/null
  ' _ "$1" "$here/pane.sh" "$PROMPT_TAG" </dev/null >/dev/null 2>&1 &
}

cmd=${1:-}
[[ -n $cmd ]] || usage
shift

case $cmd in
  list)
    restore_unclaimed_windows
    tmux list-panes -a -F '#{pane_id} #{session_name}:#{window_index}.#{pane_index} #{pane_current_command} #{pane_title}'
    ;;
  open)
    # A new pane next to the user's, without taking the focus; default: below, in the current window.
    [[ $# -le 2 ]] || usage
    flags=$(split_side "${2:-below}") || exit 1
    tmux split-window -d $flags ${1:+-t "$1"} -P -F '#{pane_id}'
    ;;
  state)
    [[ $# -eq 1 ]] || usage
    check_id "$1"
    touch_busy "$1"
    tmux display-message -p -t "$1" 'command=#{pane_current_command} in_mode=#{pane_in_mode} dead=#{pane_dead}'
    tmux capture-pane -p -J -t "$1" -S - | trim | tail -n 5
    ;;
  tail)
    [[ $# -ge 1 && $# -le 2 ]] || usage
    check_id "$1"
    touch_busy "$1"
    tmux capture-pane -p -J -t "$1" -S - | trim | tail -n "${2:-20}"
    ;;
  send)
    [[ $# -eq 3 ]] || usage
    check_ready "$1" "$2"
    require_child "$1"
    takeback_pane "$1"
    id=$(new_id)
    tmux send-keys -t "$1" C-u
    if [[ -n $(tmux show -pqv -t "$1" @claude_child) ]]; then
      # Child bash from enter: type the bare command; the next [claude <rc>] prompt reports its end.
      start=$(abs_line "$1") height=$(prompt_height "$1")
      tmux set -p -t "$1" @claude_cmd "$id child $start 1 $height"
      tmux send-keys -t "$1" -l "$3"
      tmux send-keys -t "$1" Enter
      mark_busy "$1" "$id" "$start" 1 "$height"
    else
      # No hook (REPL, zsh, console): wrap the command in markers. printf builds START_<id> so the
      # typed line never contains it; rc=$? is expanded by the remote shell.
      tmux set -p -t "$1" @claude_cmd "$id markers"
      tmux send-keys -t "$1" -l "printf '%s_%s\n' START $id; $3; echo \"END_$id rc=\$?\""
      tmux send-keys -t "$1" Enter
      mark_busy "$1" "$id"
    fi
    echo "id=$id"
    ;;
  paste)
    [[ $# -eq 3 ]] || usage
    [[ -r $3 ]] || die "cannot read $3"
    check_ready "$1" "$2"
    require_child "$1"
    takeback_pane "$1"
    id=$(new_id)
    grep -qx "SCRIPT_$id" "$3" && die "script contains the heredoc delimiter"
    wrapper=$(mktemp)
    if [[ -n $(tmux show -pqv -t "$1" @claude_child) ]]; then
      {
        printf "sh <<'SCRIPT_%s'\n" "$id"
        cat "$3"
        [[ -z $(tail -c 1 "$3") ]] || echo
        printf 'SCRIPT_%s\n' "$id"
      } >"$wrapper"
      # result skips the echoed script: 1 screen line per wrapper line once wrapped lines are joined.
      start=$(abs_line "$1") skip=$(wc -l <"$wrapper") height=$(prompt_height "$1")
      tmux set -p -t "$1" @claude_cmd "$id child $start $skip $height"
    else
      # The heredoc and the END echo share the first line, so the shell parses all of it before running.
      {
        printf "sh <<'SCRIPT_%s'; echo \"END_%s rc=\$?\"\n" "$id" "$id"
        printf "printf '%%s_%%s\\\\n' START %s\n" "$id"
        cat "$3"
        [[ -z $(tail -c 1 "$3") ]] || echo
        printf 'SCRIPT_%s\n' "$id"
      } >"$wrapper"
      tmux set -p -t "$1" @claude_cmd "$id markers"
      start= skip= height=
    fi
    tmux load-buffer -b "pane-$id" "$wrapper"
    rm -f "$wrapper"
    tmux send-keys -t "$1" C-u
    tmux paste-buffer -d -b "pane-$id" -t "$1"
    mark_busy "$1" "$id" "$start" "$skip" "$height"
    echo "id=$id"
    ;;
  result)
    [[ $# -ge 2 && $# -le 3 ]] || usage
    check_id "$1"
    [[ $2 =~ ^[0-9]+$ ]] || die "bad id '$2'"
    read -r cid mode start skip height < <(tmux show -pqv -t "$1" @claude_cmd) || true
    [[ ${cid:-} == "$2" ]] || die "id $2 is not the last command sent to $1"
    deadline=$((SECONDS + ${3:-30}))
    timeout_out() {
      echo "TIMEOUT: command $2 still running; last lines of $1:" >&2
      tmux capture-pane -p -J -t "$1" -S - | trim | tail -n 15 >&2
      exit 124
    }
    if [[ $mode == markers ]]; then
      # rc=[0-9] never matches the typed command line, which reads rc=$?.
      until tmux capture-pane -p -J -t "$1" -S - | grep -Eq "END_$2 rc=[0-9]"; do
        ((SECONDS < deadline)) || timeout_out "$@"
        sleep 0.5
      done
      touch_busy "$1"
      # START is matched at end of line: pasted scripts can leave continuation prompts before it.
      tmux capture-pane -p -J -t "$1" -S - \
        | awk -v s="START_$2\$" -v e="END_$2 rc=[0-9]" '$0 ~ e {print; exit} f {print} $0 ~ s {f=1}'
      exit 0
    fi
    # The command is over once a [claude <rc>] prompt shows up below it.
    until rc=$(cmd_done "$1" "$start" "$skip" "$height"); do
      ((SECONDS < deadline)) || timeout_out "$@"
      sleep 0.25
    done
    touch_busy "$1"
    read -r hs limit < <(tmux display-message -p -t "$1" '#{history_size} #{history_limit}')
    ((hs < limit)) || echo "pane.sh: scrollback of $1 is full, the start of the output may be cut or shifted" >&2
    cmd_output "$1" "$start" "$skip" "$height"
    echo "rc=$rc"
    ;;
  hook)
    # Called by the plugin's hooks (hooks/hooks.json): session-start, stop or session-end.
    [[ $# -eq 1 ]] || usage
    run_hook "$1" || true
    exit 0
    ;;
  _done)
    # Internal, for the busy watcher: the exit status of the command typed at line <start>, once over.
    [[ $# -eq 4 ]] || usage
    cmd_done "$@"
    ;;
  claim)
    [[ $# -eq 1 ]] || usage
    check_id "$1"
    restore_unclaimed_windows
    win=$(tmux display-message -p -t "$1" '#{window_id}')
    if [[ -z $(tmux show -wqv -t "$win" @claude_saved) ]]; then
      for opt in "${WINDOW_OPTS[@]}"; do
        # -w without -g reads only the window's own value: empty means it inherits the global one.
        tmux set -w -t "$win" "@claude_prev_$opt" "$(tmux show -wqv -t "$win" "$opt")"
      done
      tmux set -w -t "$win" @claude_saved 1
    fi
    default_format=$(tmux show -gwv pane-border-format)
    tmux set -p -t "$1" @claude 1
    [[ -z $SESSION ]] || tmux set -p -t "$1" @claude_session "$SESSION"
    paint "$1" "$IDLE_STYLE"
    tmux set -w -t "$win" pane-border-status top
    tmux set -w -t "$win" pane-border-format "#{?@claude,$CLAIM_BANNER,$default_format}"
    echo "claimed $1"
    ;;
  release)
    [[ $# -eq 1 ]] || usage
    check_id "$1"
    release_pane "$1"
    echo "released $1"
    ;;
  interrupt)
    # Ctrl-C to the foreground program, for example to detach a follow command; never while the user scrolls.
    [[ $# -eq 1 ]] || usage
    check_id "$1"
    [[ $(tmux display-message -p -t "$1" '#{pane_in_mode}') == 0 ]] || die "pane $1 is in copy mode (the user is scrolling): ask them to leave it"
    takeback_pane "$1"
    tmux send-keys -t "$1" C-c
    touch_busy "$1" force
    echo "sent Ctrl-C to $1"
    ;;
  handover)
    # Claude waits for the user to act in the pane (a key to press, an answer to type): purple,
    # "c'est à vous". Ends with takeback, or as soon as Claude types in the pane again.
    [[ $# -eq 1 ]] || usage
    check_id "$1"
    [[ -n $(tmux show -pqv -t "$1" @claude) ]] || die "pane $1 is not claimed"
    tmux set -p -t "$1" @claude_wait 1
    paint "$1" "$WAIT_STYLE"
    echo "handed $1 over to the user"
    ;;
  takeback)
    [[ $# -eq 1 ]] || usage
    check_id "$1"
    takeback_pane "$1"
    echo "took $1 back"
    ;;
  enter)
    [[ $# -eq 2 ]] || usage
    check_ready "$1" "$2"
    takeback_pane "$1"
    touch_busy "$1"
    tmux set -p -u -t "$1" @claude_exited
    start=$(abs_line "$1")
    tmux send-keys -t "$1" C-u
    if is_local "$1"; then
      tmux send-keys -t "$1" -l "$(local_child_shell)"
      tmux send-keys -t "$1" Enter
    else
      tmux send-keys -t "$1" -l "$REMOTE_CHILD_SHELL"
      tmux send-keys -t "$1" Enter
      sleep 1
      wait_prompt "$1" "$2"
      # Without its comments and blank lines, each of which would draw a prompt of its own.
      {
        echo '# Prompt hook from the driving-tmux-panes skill: a [claude <exit status>] prefix on the prompt'
        grep -Ev '^[[:space:]]*(#|$)' "$here/claude-hook.sh"
      } | tmux load-buffer -b "hook-$$" -
      tmux paste-buffer -d -b "hook-$$" -t "$1"
    fi
    for ((i = 0; i < 20; i++)); do
      child_prompt "$1" "$start" && break
      sleep 0.5
    done
    child_prompt "$1" "$start" || die "no [claude <rc>] prompt in $1 after 10 s: check it with state"
    tmux set -p -t "$1" @claude_child 1
    watch_child "$1"
    touch_busy "$1"
    echo "entered a child bash in $1: check its prompt with state"
    ;;
  leave)
    [[ $# -eq 2 ]] || usage
    check_ready "$1" "$2"
    takeback_pane "$1"
    # Only exit a shell that enter started: anything else may be the user's own shell.
    [[ -n $(tmux show -pqv -t "$1" @claude_child) ]] \
      || die "no child bash started by enter in $1: refusing to exit what may be the user's own shell"
    tmux send-keys -t "$1" C-u
    # exit 0: the user's shell gets a clean status back, whatever the last command returned.
    tmux send-keys -t "$1" -l 'exit 0'
    tmux send-keys -t "$1" Enter
    # The watcher started by enter releases the pane once the child is gone; do it here if it did not.
    for ((i = 0; i < 20; i++)); do
      [[ -z $(tmux show -pqv -t "$1" @claude_child) ]] && break
      sleep 0.25
    done
    [[ -z $(tmux show -pqv -t "$1" @claude_child) ]] || release_pane "$1"
    echo "left the child bash in $1 and released the pane"
    ;;
  *)
    usage
    ;;
esac
