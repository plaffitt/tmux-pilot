# tmux-pilot

A Claude Code plugin that lets Claude drive your tmux panes, with you watching: an ssh session to a server, a NAS, a jump host, a console or a REPL that only your terminal can reach.

Claude claims a pane, types in it, reads what comes back, and gives the pane back as it was. The pane always tells you who is in charge:

| Pane | Border | Meaning |
|---|---|---|
| dark orange | Claude is driving this pane (working) | Claude's turn runs and it works in this pane: do not type there |
| very dark grey | Claude is driving this pane | Claude holds it but does nothing in it |
| very dark grey | Claude is driving this pane (command running), in orange | Claude's turn is over, but a command it sent still runs there |
| dark purple | Claude is driving this pane (your turn) | Claude waits for you: a key to press, a password to type |

The texts follow Claude Code's `language` setting. The plugin only ships English: for another language, Claude translates them once, on first use, and keeps the translation in `~/.local/share/tmux-pilot/`.

## What it does

- **Your history stays yours.** Claude types in a child bash with its own history file, `~/.bash_history_claude`. Even the line that starts it is erased from your history.
- **No markers on screen.** The child's prompt starts with `[claude <exit status>]`: Claude knows a command is over, and how it ended, as soon as the next prompt shows up. You only see the commands and their output, and your pane title is never touched.
- **Works behind ssh.** On a remote host the prompt hook is pasted into the child bash, readable and commented.
- **Notified when a command ends.** Claude starts a background `wait` on a long command and goes on with its turn, or ends it: it is told the moment the command ends, with its exit status and last lines, instead of polling the pane. The pane does not stay orange meanwhile.
- **Pattern watch.** For a command that never ends, such as `kubectl logs -f`, Claude is woken when a line matches a pattern it chose, at most once a minute. It is also told when the command waits for a password or an answer, when the output goes quiet, or when the ssh connection drops.
- **Safe typing.** Claude only types when the pane sits idle at the expected prompt, never while you scroll, never `clear`, and never a password.
- **Clean exit.** When Claude leaves, or when you type `exit` in its child bash yourself, the pane gets its colours, border and shell back. When the Claude session ends, its panes are given back too.
- **Guided tour.** The first time, Claude offers a short tour in a new pane, in your language, at your pace.

## How it is built

- `skills/driving-tmux-panes/`: the skill, with `scripts/pane.sh`, the only way Claude touches a pane.
- `hooks/hooks.json`: Claude Code hooks. `Stop` turns Claude's panes grey when its turn ends (a command still running there shows "(command running)"), `SessionEnd` gives them back, `SessionStart` flags the session. Without them, as a bare skill, a pane turns grey 5 s after Claude's last action.

Requires tmux (tested with 3.4) and bash 5.0 or later.

## Install

```
/plugin marketplace add plaffitt/tmux-pilot
/plugin install tmux-pilot@tmux-pilot
```

## License

MIT
