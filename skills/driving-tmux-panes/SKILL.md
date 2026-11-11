---
name: driving-tmux-panes
description: Use for any work in the user's tmux panes - opening or splitting a new pane, running commands in or reading output from an existing one (an ssh session to a server, NAS or VM, a jump host, a console, a REPL) - or when keys sent with tmux send-keys land in the wrong pane, output cannot be found in the scrollback, or quoting breaks on the way into the pane. Also when the user asks for an onboarding, demo or tour of driving tmux panes.
allowed-tools: Bash(bash ${CLAUDE_SKILL_DIR}/scripts/pane.sh list), Bash(bash ${CLAUDE_SKILL_DIR}/scripts/pane.sh state *), Bash(bash ${CLAUDE_SKILL_DIR}/scripts/pane.sh tail *), Bash(bash ${CLAUDE_SKILL_DIR}/scripts/pane.sh result *)
---

# Driving tmux panes

**First use for this user:** look in your persistent memory for a note that they already took the tmux pane onboarding. If there is none, do what they asked, then end your reply with 1 line, in their language, offering a short guided tour of how you drive their panes (see Onboarding below). Offer it only once: if they decline, save a memory saying so, so that you never offer it again.

## Overview

The pane belongs to the user: they are reading it while you work in it. Go through `pane.sh` for every action. It targets panes by stable ID, refuses to type unless the pane sits idle at the prompt you expect, never wipes the screen, and finds your output without printing anything extra in the pane.

Reading (`list`, `state`, `tail`, `result`) needs no approval. Typing (`send`, `paste`) asks the user every time, and the approval prompt shows the exact command that will land in their pane.

## When to use

- The user asks you to open or split a tmux pane: `pane.sh open [window|%pane] [below|above|left|right]` creates it next to theirs (default: below) without taking the focus and prints its `%ID`
- The user asks you to run something "in my ssh pane" or "on the NAS window"
- The target is only reachable through the user's terminal (ssh with 2FA, a jump host, a serial console)

Not for: commands your own shell tool can run directly (run them there), or full-screen programs such as editors and `htop` (read only, do not type into them).

## Ground rules

- Read-only commands first. Before anything that changes state, tell the user what it does; the approval prompt is not an explanation.
- Never type passwords, passphrases or 2FA codes. Use `sudo -n` so a missing credential fails at once instead of hanging on a prompt, then hand the command to the user.
- Never send `clear`, `reset` or `C-l`: they wipe the scrollback the user is reading.
- Read only the target pane. `tail` works on any pane: do not use it to look at others.
- Never call raw `tmux send-keys` or `paste-buffer` yourself: they skip the checks.

## Onboarding

When the user accepts, or asks for an onboarding, a demo or a tour, run `bash ${CLAUDE_SKILL_DIR}/scripts/onboarding.sh <lang> [target] [side]` with `run_in_background`, in the language the user speaks to you. To run the tour in an existing local bash pane, idle at its prompt, pass its `%ID` alone: if you just opened a pane for the user and it is still empty, use that one rather than opening another. Otherwise the script opens a new pane next to the target window or pane (default: the active pane), on the side the user asks for (`below`, `above`, `left`, `right`; default `below`). `<lang>` is `en` or `fr`, the files in `scripts/onboarding-messages/`. For any other language, copy `en.sh` to a temporary file, translate its values following the rules at its top, and pass that file's path instead.

The script drives the demo pane like any other pane: claim, enter, the orange and grey states, exit statuses, paste, interrupt, leave. Each explanation is a short `onboarding <step>` command typed in the pane (`hello`, `colors`, `pause`, `status`, `rc`, `script`, `stop`, `bye`): it prints the text of the step, then waits for the user to press Enter, so the user sets the pace. Tell the user in 1 or 2 lines which pane to look at and to press Enter there to move on, and that you will pick up where you left off afterwards. The script logs each step with a timestamp, for you only: do not relay them. When it ends, do not recap the tour, the user just watched it: say in 1 line that it is over (and that they can close the demo pane, if the script opened it), then resume the task you were on before the tour, or stop there if the tour was the whole request. The demo pane runs a fresh `bash`, so their own panes and history are untouched; they close it afterwards.

Once the tour has run, save a memory that the user already took the tmux pane onboarding, so you never offer it again; they can still ask for it. Reading a pane without claiming it is fine (`state`, `tail`): only a claimed pane changes colour.

## Workflow

Below, `pane.sh` stands for `bash ${CLAUDE_SKILL_DIR}/scripts/pane.sh`.

1. **Find the pane:** `pane.sh list` prints `%ID session:window.pane command title`. Use the `%ID` from then on: an index shifts as soon as the user opens or closes a pane, the ID does not. If 2 panes could match, ask.
2. **Look at it:** `pane.sh state %3` prints the command running in the pane, copy mode, dead flag and the last 5 lines. Note the idle prompt, for example `admin@nas:~$`.
3. **Mark the pane as yours:** `pane.sh claim %3` tints the pane's background and shows "Claude pilote ce pane" in its top border, so anyone looking at the screen knows who is typing. While you work in the pane, the pane turns dark orange and the border adds "(travail en cours)" to warn the user not to type there; a command sent with `send` or `paste` keeps it on until it ends. Installed as a plugin, its Stop hook turns the pane very dark grey when your turn ends: you may come back to the pane any time during a turn, so it stays orange until then. With the skill alone, the pane turns grey 5 s after your last action. Grey means you hold the pane but do nothing in it. When the session ends (exit, /clear), the SessionEnd hook gives its panes back. It only changes the local tmux, never the remote side.
   - In a bash pane (bash 5.0 or later), then run `pane.sh enter %3 '<prompt-regex>'`. In a local pane it types 1 line, `history -d -1; bash --rcfile <skill>/scripts/child-rc.sh`: the child loads the user's `~/.bashrc`, writes its history to `~/.bash_history_claude`, and sources `scripts/claude-hook.sh`, which prefixes the prompt with `[claude <exit status of the last command>]`, for example `[claude 0]`. Behind ssh that file does not exist on the remote host, so it types `history -d -1; HISTFILE=~/.bash_history_claude bash`, waits for the child's prompt, then pastes the hook without its comments. Either way your commands stay out of the user's shell and history, and `history -d -1` erases the launch line itself before the child starts, so nothing leaks even if the pane is closed while the child runs. Run `state` afterwards: the prompt must show `[claude 0]`, and `send` works as usual inside the child. In a pane running a local bash, `send` and `paste` refuse until `enter` has run, so your commands never reach the user's history.
   - Skip `enter` in a REPL, zsh, fish or a console; `claim` still applies.
4. **Send 1 command line:** `pane.sh send %3 'admin@nas:~\$ $' 'df -h /share'`
   - The 2nd argument is a regex the pane's last line must match.
   - It refuses if the pane is missing, dead, in copy mode (the user is scrolling), or not at that prompt.
   - It clears half-typed input with `C-u`, types the line, and prints `id=<id>`.
   - The command is 1 line, without a trailing `;` or `&`.
5. **Collect the result:** `pane.sh result %3 <id> 30` waits up to 30 s for the command to end, then prints its output and `rc=<exit status>`.
   - After `enter`, `send` types the bare command: `result` waits for the next `[claude <rc>]` prompt below the command, reads the exit status in it, and prints the output in between. The user sees only the command, its output and the prompt; the pane title is never touched.
   - Without `enter` (REPL, zsh, console), `send` wraps the command in `START_<id>` and `END_<id>` markers instead, and `result` ends with `END_<id> rc=<exit status>`.
   - Exit code 124 means time ran out: it prints the last lines instead. Call `result` again to keep waiting, or ask before interrupting.
   - Your tool call has its own time limit: keep each wait under it and call again rather than passing a large timeout.
6. **Multi-line scripts or tricky quoting:** write the script to a file with your file-writing tool, so the user sees its content, then run `pane.sh paste %3 'admin@nas' /path/to/script`, then `result`.
   - `paste` wraps the file in `sh <<'SCRIPT_<id>'` and runs it in the remote `sh`, so quotes, backslashes and `\0` arrive intact.
   - Never escape a script into `send`.
7. **Before the next send,** run `state` again if the user may have typed in the pane meanwhile.
8. **When you are done,** `pane.sh leave %3 '<prompt-regex>'` exits the child bash (it refuses if `enter` did not start one) and restores the pane and its window as they were. Without `enter`, `pane.sh release %3` does the restoring. If the user types `exit` in the child bash themselves, the pane is restored the same way: a watcher started by `enter` releases the pane once the child is gone (in a local pane the hook flags its exit; behind ssh the watcher spots the `exit` line bash prints after the last `[claude <rc>]` prompt). The user is back in their own shell, with its directory, variables and history untouched.

## Large or slow output

- A piped command (`cmd | tail`) shows nothing until it ends. That is not a hang: wait with `result`.
- Scrollback is capped by `history-limit` (`tmux show -gv history-limit`). For large output, redirect it to a file on the remote side, then read it in pages (`sed -n '1,200p' file`) with further `send` calls.

## Hand back to the user

Stop and ask the user to act in the pane when `state`, `tail` or a timed-out `result` shows:

- a password or sudo prompt (`password`, `[sudo]`);
- a host-key question (`(yes/no`);
- a 2FA prompt;
- a pager or editor that opened.

Run `pane.sh handover %3` when you ask: the pane turns dark purple and its border says "(c’est à vous)", so the user sees it is their turn to type. After they confirm, run `pane.sh takeback %3` (any `send`, `paste`, `interrupt`, `enter` or `leave` also takes the pane back), then `state` before the next send.

## Common mistakes

| Mistake | Fix |
|---|---|
| Targeting `session:window.pane` | `pane.sh` only accepts `%ID` |
| Loose prompt regex such as `.` | Match the user and host of the prompt |
| `clear` before each command | Markers already isolate the output |
| Escaping a script inside `send` | Write a file, then `paste` |
| Long `result` timeout that hits the tool's limit | Short waits, called again |
| Waiting on a password prompt | `sudo -n`, then hand back |
| Reading other panes "for context" | Only the target pane |
