# Language of the texts shown in a pane (border labels, guided tour), sourced by pane.sh and
# onboarding.sh. The code only holds English, in messages/en.sh. The language is that of Claude Code's
# `language` setting; for anything but English, Claude translates en.sh once into the user's data
# directory, where these functions find it.

MESSAGES_EN=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/messages/en.sh
TRANSLATIONS_DIR=${XDG_DATA_HOME:-$HOME/.local/share}/tmux-pilot

# Claude Code's language setting, a free text such as "Français" or "日本語", from the project's local
# settings, the project's settings, then the user's; empty when none is set. Read with sed: settings
# files are plain JSON, and no jq is needed.
claude_language() {
  local f v=
  for f in .claude/settings.local.json .claude/settings.json ~/.claude/settings.json; do
    [[ -r $f ]] || continue
    v=$(sed -n 's/.*"language"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f" | head -n 1)
    [[ -n $v ]] && break
  done
  printf '%s\n' "$v"
}

is_english() {
  local re='^[[:space:]]*(en([-_].*)?|english.*)?[[:space:]]*$'
  shopt -s nocasematch
  [[ $1 =~ $re ]]
  local st=$?
  shopt -u nocasematch
  return $st
}

# Where the translation for a language lives: its name lowercased, anything but letters and digits as _.
translation_file() {
  printf '%s/%s.sh\n' "$TRANSLATIONS_DIR" "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c '[:alnum:]' '_')"
}

# The messages file for Claude Code's language: en.sh for English or no setting, else its translation.
# Prints the path; fails when the translation does not exist yet, after printing where it belongs.
messages_file() {
  local lang file
  lang=$(claude_language)
  if is_english "$lang"; then
    echo "$MESSAGES_EN"
    return 0
  fi
  file=$(translation_file "$lang")
  echo "$file"
  [[ -r $file ]]
}
