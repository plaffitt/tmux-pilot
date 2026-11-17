#!/usr/bin/env bash
# Drive a user's existing tmux pane: read it, type into it, collect output.
# Read-only subcommands: list, state, tail, result, wait. Writing ones: send, paste.
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
  pane.sh wait   <%pane> <id> [--match <regex>] [--quiet <seconds>]
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
  alive "$1" || die "pane $1 does not exist"
}

# tmux 3.4 prints nothing but exits 0 for a pane that does not exist: compare the ID it prints.
alive() { [[ $(tmux display-message -p -t "$1" '#{pane_id}' 2>/dev/null) == "$1" ]]; }

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
# while it waits for the user to act in it (handover): a key to press, an answer to type. Grey with an
# orange "(command running)" label when Claude's turn is over but a command it sent still runs.
BUSY_STYLE='bg=#170c00'
IDLE_STYLE='bg=#1a1a1a'
WAIT_STYLE='bg=#1c1026'
# It sits inside a #{?cond,yes,no} format: a bare comma would end the branch, but a nested
# #{?...} is fine since tmux skips over braces.
# The labels come from pane options set at claim time, in the language of Claude Code (en or fr), so
# each pane shows its own; their values may hold commas, since tmux only parses the format around them.
CLAIM_BANNER='#{?@claude_wait,#[bold fg=#b07cd8] #{@claude_label_wait} ,#{?@claude_running,#[bold fg=#d2691e] #{@claude_label_running} ,#{?@claude_busy,#[bold fg=#d2691e] #{@claude_label_busy} ,#[bold fg=#5a5a5a] #{@claude_label} }}}#[default]'

# shellcheck source=lang.sh
source "$(cd "$(dirname "$0")" && pwd)/lang.sh"

# Border labels (holding, working, waiting for the user, command running) in Claude Code's language:
# from the translation of messages/en.sh when there is one, in English otherwise. A missing translation
# is not an error: the border stays English, and Claude is told where to write the translation. A
# label the translation lacks stays English too, since en.sh is read first.
set_labels() {
  local file held busy wait running
  file=$(messages_file) || echo "pane.sh: no translation yet for Claude Code's language: translate $MESSAGES_EN into $file (see SKILL.md, Language), then run claim again; the border is in English until then"
  IFS=$'\t' read -r held busy wait running < <(
    # shellcheck source=messages/en.sh
    source "$MESSAGES_EN"
    [[ ! -r $file ]] || source "$file"
    printf '%s\t%s\t%s\t%s\n' "$M_BORDER" "$M_BORDER_BUSY" "$M_BORDER_WAIT" "$M_BORDER_RUNNING"
  )
  tmux set -p -t "$1" @claude_label "$held"
  tmux set -p -t "$1" @claude_label_busy "$busy"
  tmux set -p -t "$1" @claude_label_wait "$wait"
  tmux set -p -t "$1" @claude_label_running "$running"
}

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
  tmux set -p -u -t "$1" @claude_running
  [[ -n $(tmux show -pqv -t "$1" @claude) ]] || return 0
  [[ -z $(tmux show -pqv -t "$1" @claude_wait) ]] || return 0
  tmux set -p -t "$1" window-style "$3"
  tmux set -p -t "$1" window-active-style "$3"
}'

# Orange: Claude's turn runs and it touches the pane, so the "(command running)" label is over.
paint_busy() {
  tmux set -p -u -t "$1" @claude_running
  paint "$1" "$BUSY_STYLE"
}

# While the pane is handed over, Claude's reads keep it purple: the user is the one to act.
set_busy() {
  tmux set -p -t "$1" @claude_busy "$2"
  [[ -n $(tmux show -pqv -t "$1" @claude_wait) ]] || paint_busy "$1"
}

# End a handover: back to orange if Claude is still working in the pane, grey otherwise.
takeback_pane() {
  [[ -n $(tmux show -pqv -t "$1" @claude_wait) ]] || return 0
  tmux set -p -u -t "$1" @claude_wait
  [[ -n $(tmux show -pqv -t "$1" @claude) ]] || return 0
  if [[ -n $(tmux show -pqv -t "$1" @claude_busy) ]]; then paint_busy "$1"; else paint "$1" "$IDLE_STYLE"; fi
}

# Show the warning until the turn ends (or the linger runs out). Leaves a running command's token
# alone unless forced, but brings orange back if the Stop hook greyed the pane meanwhile. Only a
# claimed pane changes colour: reading a pane the user did not hand over leaves it as it is.
touch_busy() {
  local pane=$1 force=${2:-} token
  [[ -n $(tmux show -pqv -t "$pane" @claude) ]] || return 0
  tmux set -p -u -t "$pane" @claude_turn_over
  if [[ -z $force && $(tmux show -pqv -t "$pane" @claude_busy) == cmd-* ]]; then
    [[ -n $(tmux show -pqv -t "$pane" @claude_wait) ]] || paint_busy "$pane"
    return 0
  fi
  token=act-$(new_id)
  set_busy "$pane" "$token"
  setsid bash -c "$UNBUSY"'
    sleep "$4"
    unbusy "$1" "$2" "$3"
  ' _ "$pane" "$token" "$IDLE_STYLE" "$(linger)" </dev/null >/dev/null 2>&1 &
}

# Show the warning while command <id> runs, then until the turn ends (or the linger runs out): once a
# [claude <rc>] prompt shows up below the command, or the END marker does (internal _end subcommand,
# which also records the end in @claude_done). The watcher stops as soon as the token changes (newer
# action, interrupt, release) or the pane is gone.
mark_busy() {
  local pane=$1 id=$2
  [[ -n $(tmux show -pqv -t "$pane" @claude) ]] || return 0
  tmux set -p -u -t "$pane" @claude_turn_over
  set_busy "$pane" "cmd-$id"
  setsid bash -c "$UNBUSY"'
    pane=$1 id=$2 script=$5
    while [[ $(tmux show -pqv -t "$pane" @claude_busy 2>/dev/null) == "cmd-$id" ]]; do
      if bash "$script" _end "$pane" "$id" >/dev/null 2>&1; then
        tmux set -p -t "$pane" @claude_busy "act-$id"
        tmux set -p -u -t "$pane" @claude_running
        # Claude turn already over (the command outlived it): grey at once.
        [[ -n $(tmux show -pqv -t "$pane" @claude_turn_over) ]] || sleep "$4"
        unbusy "$pane" "act-$id" "$3"
        break
      fi
      sleep 0.25
    done
  ' _ "$pane" "$id" "$IDLE_STYLE" "$(linger)" "$here/pane.sh" </dev/null >/dev/null 2>&1 &
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

# The end of command <id> is recorded once, by whoever spots it first (the busy watcher, wait or
# result), in @claude_done "<id> <rc> <epoch>"; the others read it there. Only while @claude_cmd still
# names that command: a newer send clears it.
record_done() {
  [[ $(tmux show -pqv -t "$1" @claude_cmd) == "$2 "* ]] || return 0
  [[ $(tmux show -pqv -t "$1" @claude_done) == "$2 "* ]] && return 0
  tmux set -p -t "$1" @claude_done "$2 $3 $(date +%s)"
}

# Exit status of command <id> (mode, start, skip and height as in @claude_cmd) once it is over,
# recording its end; fails before. In markers mode it looks for END_<id> rc=<n> in the last 50 lines,
# or in the range of capture-pane -S given as 7th argument ("-" for the whole scrollback).
cmd_end() {
  local pane=$1 id=$2 mode=$3 start=${4:-} skip=${5:-} height=${6:-} range=${7:--50} did drc rc
  read -r did drc _ <<<"$(tmux show -pqv -t "$pane" @claude_done)" || true
  if [[ $did == "$id" ]]; then
    echo "$drc"
    return 0
  fi
  if [[ $mode == markers ]]; then
    # rc=[0-9] never matches the typed command line, which reads rc=$?.
    rc=$(tmux capture-pane -p -J -t "$pane" -S "$range" | grep -oE "END_$id rc=[0-9]+" | tail -n 1 | sed 's/.*rc=//') || true
    [[ -n $rc ]] || return 1
  else
    rc=$(cmd_done "$pane" "$start" "$skip" "$height") || return 1
  fi
  record_done "$pane" "$id" "$rc"
  echo "$rc"
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
  tmux set -p -u -t "$1" @claude_label
  tmux set -p -u -t "$1" @claude_label_busy
  tmux set -p -u -t "$1" @claude_label_wait
  tmux set -p -u -t "$1" @claude_label_running
  tmux set -p -u -t "$1" @claude_running
  tmux set -p -u -t "$1" @claude_done
  tmux set -p -u -t "$1" @claude_match_last
  tmux set -p -u -t "$1" @claude_match_pos
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
      # Claude's turn is over: all its panes turn grey. Where a command it sent still runs, the
      # cmd-* token stays, so its watcher still spots the end, and the border says "(command
      # running)" until then.
      for pane in $(session_panes "$sid"); do
        tmux set -p -t "$pane" @claude_turn_over 1
        token=$(tmux show -pqv -t "$pane" @claude_busy)
        if [[ $token == cmd-* ]]; then
          tmux set -p -t "$pane" @claude_running 1
          # The command may have ended in between: its watcher then cleared the token.
          [[ $(tmux show -pqv -t "$pane" @claude_busy) == cmd-* ]] || tmux set -p -u -t "$pane" @claude_running
        else
          clear_busy "$pane"
        fi
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

# A new command starts: forget the end and the matches of the previous one.
new_command() {
  tmux set -p -u -t "$1" @claude_done
  tmux set -p -u -t "$1" @claude_match_last
  tmux set -p -u -t "$1" @claude_match_pos
}

# The line Claude runs to be told when the command ends.
wait_hint() {
  printf 'wait: bash %q wait %s %s   # run with run_in_background\n' "$here/pane.sh" "$1" "$2"
}

# wait: sleep until the first event on command <id>, for Claude to run with run_in_background; it
# tells Claude what happened in its first output line, and how in its exit code: 0 ended (the exit
# status is in the text), 10 matched, 11 input?, 12 quiet, 3 gone, 4 superseded, 5 lost. It exits
# quietly when the process that started it is gone. No time limit: Claude stops it or it ends.
INPUT_RE='password|\[sudo\]|\(yes/no|\[y/N\]|passphrase'
INPUT_STILL=5
MATCH_THROTTLE=60
MATCH_MAX=20
REMOTE_RE='^(ssh|mosh|mosh-client|autossh|telnet)$'
LOCAL_RE='^(bash|zsh|fish|sh|dash|ksh)$'

wait_report_end() {
  local pane=$1 id=$2 did rc ep dur
  read -r did rc ep <<<"$(tmux show -pqv -t "$pane" @claude_done)" || true
  if [[ ${did:-} != "$id" ]]; then rc=$3 ep=$(date +%s); fi
  dur=$((ep - ${id%?????}))
  ((dur >= 0)) || dur=0
  printf 'ended pane=%s id=%s rc=%s duration=%dm%02ds\n' "$pane" "$id" "$rc" $((dur / 60)) $((dur % 60))
  # The bottom of the screen, not the lines after the command: right even when the scrollback is full.
  tmux capture-pane -p -J -t "$pane" -S -100 | { grep -v '^[[:space:]]*$' || true; } | tail -n 20
}

# Physical row <r> (absolute index) as it stands, for the history size <hs> just read.
wait_row() { tmux capture-pane -p -t "$pane" -S $(($1 - hs)) -E $(($1 - hs)) 2>/dev/null; }

# The complete lines (above the cursor) that showed up since the last call, in NEWL. Lines keep their
# absolute index until the scrollback fills up; then tmux drops the oldest tenth at once, and indexes
# shift. So <seen>, the last row read, is trusted only while that row still holds <seen_row>, the text
# it had (the first time: the command line). Otherwise the new lines are those after the last non-blank
# line read (<seen_text>), or after the command line. Uses the variables of run_wait.
wait_scan() {
  local last=$((hs + cy - 1)) from k i anchor row all=()
  NEWL=()
  if ((seen >= 0 && seen <= last)); then
    row=$(wait_row "$seen")
    if [[ -z $first_scan ]]; then
      [[ $row == "$seen_row" ]] || seen=-1
    elif [[ $mode == markers ]]; then
      [[ $(wait_row $((seen + 1))) == *"$id"* ]] || seen=-1
    else
      [[ $(wait_row $((seen + 2 - ${height:-1}))) =~ $PROMPT_TAG ]] || seen=-1
    fi
  else
    seen=-1
  fi
  if ((seen >= 0)); then
    ((last > seen)) || return 0
    from=$((seen + 1))
    ((from > last - 400)) || from=$((last - 400))
    mapfile -t NEWL < <(tmux capture-pane -p -J -t "$pane" -S $((from - hs)) -E $((cy - 1)))
  else
    mapfile -t all < <(tmux capture-pane -p -J -t "$pane" -S -200 -E $((cy - 1)))
    k=-1
    if [[ -n $seen_text ]]; then
      for ((i = ${#all[@]} - 1; i >= 0; i--)); do
        if [[ ${all[i]} == "$seen_text" ]]; then k=$i; break; fi
      done
    else
      if [[ $mode == markers ]]; then anchor="START_$id\$"; else anchor=$PROMPT_TAG; fi
      for ((i = ${#all[@]} - 1; i >= 0; i--)); do
        if [[ ${all[i]} =~ $anchor ]]; then k=$i; break; fi
      done
      skip_left=0
    fi
    NEWL=("${all[@]:k+1}")
  fi
  seen=$last seen_row=$(wait_row "$last") first_scan=
  # The first lines after the command are its own echo.
  if ((skip_left > 0)); then
    k=$((skip_left < ${#NEWL[@]} ? skip_left : ${#NEWL[@]}))
    NEWL=("${NEWL[@]:k}")
    skip_left=$((skip_left - k))
  fi
  for ((i = ${#NEWL[@]} - 1; i >= 0; i--)); do
    if [[ ${NEWL[i]} =~ [^[:space:]] ]]; then seen_text=${NEWL[i]}; break; fi
  done
}

run_wait() {
  local pane=$1 id=$2 re=$3 quiet=$4 parent=$PPID
  local cid mode start skip height rc now mid mt pos l cur in=
  local seen=-1 seen_row= seen_text= first_scan=1 skip_left=0 last_fire=0 matches=() NEWL=()
  local hs limit cy cx bytes curcmd snap=() sig prev_sig= sig_since=$SECONDS remote= local_polls=0
  alive "$pane" || { echo "gone pane=$pane id=$id"; exit 3; }
  read -r cid mode start skip height <<<"$(tmux show -pqv -t "$pane" @claude_cmd)" || true
  [[ ${cid:-} == "$id" ]] || { echo "superseded pane=$pane id=$id"; exit 4; }
  start=${start:-} skip=${skip:-1} height=${height:-}
  # A wait re-armed after a match goes on from there (@claude_match_pos: row, its text, last non-blank
  # line read), and keeps its throttle.
  read -r mid mt <<<"$(tmux show -pqv -t "$pane" @claude_match_last)" || true
  if [[ ${mid:-} == "$id" ]]; then
    last_fire=$mt
    pos=$(tmux show -pqv -t "$pane" @claude_match_pos)
    seen=${pos%%$'\t'*} pos=${pos#*$'\t'}
    seen_row=${pos%%$'\t'*} seen_text=${pos#*$'\t'}
    [[ $seen =~ ^[0-9]+$ ]] || seen=-1
    first_scan=
  elif [[ -n $start ]]; then
    seen=$((start - 1)) skip_left=$skip
  fi
  while :; do
    kill -0 "$parent" 2>/dev/null || exit 0
    alive "$pane" || { echo "gone pane=$pane id=$id"; exit 3; }
    if rc=$(cmd_end "$pane" "$id" "$mode" "$start" "$skip" "$height"); then
      wait_report_end "$pane" "$id" "$rc"
      exit 0
    fi
    if [[ $(tmux show -pqv -t "$pane" @claude_cmd 2>/dev/null) != "$id "* ]]; then
      alive "$pane" || { echo "gone pane=$pane id=$id"; exit 3; }
      echo "superseded pane=$pane id=$id"
      exit 4
    fi
    read -r hs limit cy cx bytes curcmd < <(tmux display-message -p -t "$pane" \
      '#{history_size} #{history_limit} #{cursor_y} #{cursor_x} #{history_bytes} #{pane_current_command}') \
      || { echo "gone pane=$pane id=$id"; exit 3; }
    # The connection dropped: the pane went from ssh (or the like) back to a local shell, with no prompt
    # of the command. A few polls in a row, so a command that merely ends is seen as ended first.
    if [[ $curcmd =~ $REMOTE_RE ]]; then
      remote=1 local_polls=0
    elif [[ -n $remote && $curcmd =~ $LOCAL_RE ]]; then
      if ((++local_polls >= 3)); then
        echo "lost pane=$pane id=$id"
        tmux capture-pane -p -J -t "$pane" -S -100 | { grep -v '^[[:space:]]*$' || true; } | tail -n 5
        exit 5
      fi
    fi
    if [[ -n $re ]]; then
      wait_scan
      for l in "${NEWL[@]}"; do
        if [[ $l =~ $re ]]; then matches+=("$l"); fi
      done
      now=$(date +%s)
      if ((${#matches[@]} > 0 && now - last_fire >= MATCH_THROTTLE)); then
        tmux set -p -t "$pane" @claude_match_last "$id $now"
        tmux set -p -t "$pane" @claude_match_pos "$seen"$'\t'"$seen_row"$'\t'"$seen_text"
        echo "matched pane=$pane id=$id"
        if ((${#matches[@]} > MATCH_MAX)); then matches=("${matches[@]: -MATCH_MAX}"); fi
        printf '%s\n' "${matches[@]}"
        exit 10
      fi
    fi
    # The cursor line and the one above: new output, or a line redrawn in place, changes them.
    mapfile -t snap < <(tmux capture-pane -p -t "$pane" -S $((cy - 1)) -E "$cy" 2>/dev/null)
    sig="$hs $cy $cx $bytes ${snap[*]}"
    if [[ $sig != "$prev_sig" ]]; then prev_sig=$sig sig_since=$SECONDS; fi
    cur=
    ((${#snap[@]} == 0)) || cur=${snap[${#snap[@]} - 1]}
    shopt -s nocasematch
    if [[ $cur =~ $INPUT_RE ]]; then in=1; else in=; fi
    shopt -u nocasematch
    if [[ -n $in ]] && ((SECONDS - sig_since >= INPUT_STILL)); then
      echo "input? pane=$pane id=$id"
      printf '%s\n' "$cur"
      exit 11
    fi
    if [[ -n $quiet ]] && ((SECONDS - sig_since >= quiet)); then
      echo "quiet pane=$pane id=$id"
      exit 12
    fi
    sleep 0.5
  done
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
    new_command "$1"
    tmux send-keys -t "$1" C-u
    start=$(abs_line "$1")
    if [[ -n $(tmux show -pqv -t "$1" @claude_child) ]]; then
      # Child bash from enter: type the bare command; the next [claude <rc>] prompt reports its end.
      height=$(prompt_height "$1")
      tmux set -p -t "$1" @claude_cmd "$id child $start 1 $height"
      tmux send-keys -t "$1" -l "$3"
      tmux send-keys -t "$1" Enter
    else
      # No hook (REPL, zsh, console): wrap the command in markers. printf builds START_<id> so the
      # typed line never contains it; rc=$? is expanded by the remote shell.
      tmux set -p -t "$1" @claude_cmd "$id markers $start 1"
      tmux send-keys -t "$1" -l "printf '%s_%s\n' START $id; $3; echo \"END_$id rc=\$?\""
      tmux send-keys -t "$1" Enter
    fi
    mark_busy "$1" "$id"
    echo "id=$id"
    wait_hint "$1" "$id"
    ;;
  paste)
    [[ $# -eq 3 ]] || usage
    [[ -r $3 ]] || die "cannot read $3"
    check_ready "$1" "$2"
    require_child "$1"
    takeback_pane "$1"
    id=$(new_id)
    grep -qx "SCRIPT_$id" "$3" && die "script contains the heredoc delimiter"
    new_command "$1"
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
      start=$(abs_line "$1") skip=$(wc -l <"$wrapper")
      tmux set -p -t "$1" @claude_cmd "$id markers $start $skip"
    fi
    tmux load-buffer -b "pane-$id" "$wrapper"
    rm -f "$wrapper"
    tmux send-keys -t "$1" C-u
    tmux paste-buffer -d -b "pane-$id" -t "$1"
    mark_busy "$1" "$id"
    echo "id=$id"
    wait_hint "$1" "$id"
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
      until rc=$(cmd_end "$1" "$2" markers "" "" "" -); do
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
    # Recorded already by the busy watcher or wait: no need to look again.
    until rc=$(cmd_end "$1" "$2" "$mode" "$start" "$skip" "$height"); do
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
    # Internal, for busy watchers started by an earlier version: the exit status of the command typed
    # at line <start>, once over.
    [[ $# -eq 4 ]] || usage
    cmd_done "$@"
    ;;
  _end)
    # Internal, for the busy watcher: the exit status of command <id>, once over, recorded in @claude_done.
    [[ $# -eq 2 ]] || usage
    read -r cid mode start skip height <<<"$(tmux show -pqv -t "$1" @claude_cmd)" || true
    [[ ${cid:-} == "$2" ]] || exit 1
    cmd_end "$1" "$2" "$mode" "${start:-}" "${skip:-}" "${height:-}"
    ;;
  wait)
    [[ $# -ge 2 ]] || usage
    pane=$1 id=$2 re= quiet=
    shift 2
    while (($# > 0)); do
      case $1 in
        --match) [[ $# -ge 2 && -n $2 ]] || usage; re=$2; shift 2 ;;
        --quiet) [[ $# -ge 2 && $2 =~ ^[1-9][0-9]*$ ]] || usage; quiet=$2; shift 2 ;;
        *) usage ;;
      esac
    done
    [[ $pane =~ ^%[0-9]+$ ]] || die "target must be a pane ID such as %3, not '$pane'"
    [[ $id =~ ^[0-9]{6,}$ ]] || die "bad id '$id'"
    if [[ -n $re ]]; then
      st=0
      [[ '' =~ $re ]] || st=$?
      ((st != 2)) || die "bad regex '$re'"
    fi
    run_wait "$pane" "$id" "$re" "$quiet"
    ;;
  claim)
    # The border speaks the user's language: Claude Code's language setting.
    [[ $# -eq 1 ]] || usage
    check_id "$1"
    set_labels "$1"
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
    # In markers mode Ctrl-C drops the END echo with the rest of the line: record the end here.
    read -r cid mode _ <<<"$(tmux show -pqv -t "$1" @claude_cmd)" || true
    if [[ ${mode:-} == markers ]]; then
      sleep 1
      cmd_end "$1" "$cid" markers >/dev/null || record_done "$1" "$cid" 130
    fi
    touch_busy "$1" force
    echo "sent Ctrl-C to $1"
    ;;
  handover)
    # Claude waits for the user to act in the pane (a key to press, an answer to type): purple,
    # "your turn". Ends with takeback, or as soon as Claude types in the pane again.
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
