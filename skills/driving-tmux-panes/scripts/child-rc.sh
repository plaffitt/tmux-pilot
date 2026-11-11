# Startup file of the child bash that `pane.sh enter` starts in a local pane
# (`bash --rcfile child-rc.sh`): the user's usual setup, a history file of its own, then the
# prompt hook that lets Claude drive the shell. Leaving the child bash (exit) drops all of it.

[[ -f ~/.bashrc ]] && source ~/.bashrc

# Commands Claude types here stay out of the user's history. Bash loads the history file after
# its startup files, so setting it here is enough.
HISTFILE=~/.bash_history_claude

# During the onboarding tour, onboarding.sh marks the pane with the directory of the `onboarding`
# command and the file of its texts: tmux pane options, so nothing shows in the pane.
if [[ -n ${TMUX_PANE:-} ]]; then
  __claude_dir=$(tmux show -pqv -t "$TMUX_PANE" @claude_onboard_dir 2>/dev/null)
  if [[ -n $__claude_dir ]]; then
    PATH=$__claude_dir:$PATH
    export CLAUDE_ONBOARD_MESSAGES
    CLAUDE_ONBOARD_MESSAGES=$(tmux show -pqv -t "$TMUX_PANE" @claude_onboard_messages)
  fi
  unset __claude_dir
fi

source "$(dirname "${BASH_SOURCE[0]}")/claude-hook.sh"
