# Texts Claude shows in a pane, sourced as bash: the 4 border labels (M_BORDER*: holding, working,
# waiting for the user, a command still running while Claude's turn is over), and one M_<STEP> per
# `onboarding <step>` call of the guided tour, where Claude speaks in the first person to the user.
# The code only holds English. To translate (see SKILL.md, Language): write the same variables, with
# translated values, to the file pane.sh names; keep the names, no tab in a border label, and since the
# tour values go through printf, write %% for a literal % and keep the %s of M_RC (the exit status).
# A label missing from a translation shows in English.
M_BORDER='Claude is driving this pane'
M_BORDER_BUSY='Claude is driving this pane (working)'
M_BORDER_WAIT='Claude is driving this pane (your turn)'
M_BORDER_RUNNING='Claude is driving this pane (command running)'
M_PRESS_ENTER='Press Enter to continue'
M_HELLO='Hi! Here is a short tour of how I drive your tmux panes. I took control of this pane: its border says "Claude is driving this pane". The [claude 0] prefix of the prompt marks a child bash I started, with a history file of its own, ~/.bash_history_claude: nothing I type here reaches your own history.'
M_COLORS='While I read or type in a pane, it turns dark orange and its border adds (working). Do not type in it then: your keys would mix with mine and I could misread the output. When I wait for you to act, like right now, the pane turns purple and the border says (your turn): then it is your turn to type. After Enter, I run `sleep 3`: watch the pane stay orange.'
M_PAUSE='As soon as you press Enter, I stop touching the terminal for 10 s. 5 s after my last action, you will see the pane turn grey: I no longer touch it, but I keep control of it.'
M_STATUS='The number in [claude 0] is the exit status of the last command: that is where I read it, even if your own prompt does not show it. After Enter, I run `false`, which fails: watch the prefix turn into [claude 1].'
M_RC='I read the exit status of `false`: %s.'
M_SCRIPT='I paste longer scripts as a whole, and sh runs them. After Enter, I paste a short multi-line loop.'
M_STOP='I can stop a command that runs too long with Ctrl-C. After Enter, I start `sleep 60` and stop it 3 s later.'
M_BYE='Tour done! After Enter, I leave my child bash and give the pane back to you: it gets its usual look back. If you type `exit` in my child bash yourself, you get the pane back the same way.'
