# Texts of the onboarding tour, sourced as bash: one M_<STEP> per `onboarding <step>` call.
# Claude speaks in the first person and addresses the user directly.
# To translate: copy this file, translate the values, keep the variable names.
# Values go through printf: write %% for a literal %, and keep the %s of M_RC (the exit status).
M_PRESS_ENTER='Press Enter to continue'
M_HELLO='Hi! Here is a short tour of how I drive your tmux panes. I took control of this pane: its border says "Claude pilote ce pane". The [claude 0] prefix of the prompt marks a child bash I started, with a history file of its own, ~/.bash_history_claude: nothing I type here reaches your own history.'
M_COLORS='While I read or type in a pane, it turns dark orange and its border adds (travail en cours). Do not type in it then: your keys would mix with mine and I could misread the output. When I wait for you to act, like right now, the pane turns purple and the border says (c’est à vous): then it is your turn to type. After Enter, I run `sleep 3`: watch the pane stay orange.'
M_PAUSE='As soon as you press Enter, I stop touching the terminal for 10 s. 5 s after my last action, you will see the pane turn grey: I no longer touch it, but I keep control of it.'
M_STATUS='The number in [claude 0] is the exit status of the last command: that is where I read it, even if your own prompt does not show it. After Enter, I run `false`, which fails: watch the prefix turn into [claude 1].'
M_RC='I read the exit status of `false`: %s.'
M_SCRIPT='I paste longer scripts as a whole, and sh runs them. After Enter, I paste a short multi-line loop.'
M_STOP='I can stop a command that runs too long with Ctrl-C. After Enter, I start `sleep 60` and stop it 3 s later.'
M_BYE='Tour done! After Enter, I leave my child bash and give the pane back to you: it gets its usual look back. If you type `exit` in my child bash yourself, you get the pane back the same way.'
