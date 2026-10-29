# Sourced by NON-INTERACTIVE bash only (via BASH_ENV). Interactive shells never
# read this file, so a human running `git push` still gets the normal prompt.
#
# Why it exists: when an agent runs `bash -c '... git push ...'`, git opens
# /dev/tty directly to prompt for credentials. The agent's TUI owns that
# terminal in raw mode and swallows the keystrokes, so git blocks on read()
# forever, with the prompt invisible (it bypasses stdout/stderr). It looks
# exactly like resource contention. Failing fast makes it a real error message
# the agent can see and report.
export GIT_TERMINAL_PROMPT=0
