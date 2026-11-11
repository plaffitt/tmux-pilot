# Prompt hook of the child bash that `pane.sh enter` starts, so Claude can drive this shell cleanly.
# It prefixes the prompt with [claude <rc>], <rc> being the exit status of the last command: anyone
# looking at the pane knows who is typing, and pane.sh knows a command is over, and how it ended,
# as soon as the next prompt shows up. Leaving the child bash (exit) drops all of it, and pane.sh
# gives the pane back as it was.

# Save the exit status of the command, then hand it back so the user's own PROMPT_COMMAND sees it.
__claude_pre() {
  __claude_rc=$?
  return $__claude_rc
}

# Rebuild the prompt: strip the prefix the previous call added, then add the new one.
__claude_ps1() {
  [[ $PS1 == "[claude "* ]] && PS1=${PS1#*"] "}
  PS1="[claude $__claude_rc] $PS1"
}

# When this shell exits in a local pane, tell tmux at once; behind ssh, pane.sh spots the exit line.
__claude_exit() {
  [[ -n ${TMUX_PANE:-} ]] && tmux set -p -t "$TMUX_PANE" @claude_exited 1 2>/dev/null
  return 0
}
trap __claude_exit EXIT

# Run around the user's own PROMPT_COMMAND, so a prompt rebuilt at each display keeps the hook.
PROMPT_COMMAND="__claude_pre; ${PROMPT_COMMAND:+$PROMPT_COMMAND; }__claude_ps1"
