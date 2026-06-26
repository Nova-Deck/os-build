#!/usr/bin/env bash
# zsh-wordsplit-guard — PreToolUse:Bash hook.
#
# Blocks the zsh word-split footgun: storing a command + its options in a shell
# variable and then expanding it UNQUOTED as a command, e.g.
#     SSH="ssh -o StrictHostKeyChecking=no"; $SSH host ...
# In bash, unquoted $SSH word-splits into separate args. In zsh (this user's
# shell) it does NOT — $SSH is treated as a single command name "ssh -o Str..."
# and fails with "no such file or directory". This catches it before it runs.
#
# Reads the hook JSON on stdin; exits 2 (block) with guidance when the pattern
# is found, 0 otherwise. Fails open (exit 0) if jq is unavailable.
set -euo pipefail

command -v jq >/dev/null 2>&1 || exit 0

cmd=$(jq -r '.tool_input.command // empty' 2>/dev/null) || exit 0
[ -n "$cmd" ] || exit 0

# 1. Variable names assigned a QUOTED value that contains whitespace — i.e. a
#    command plus its options (SSH="ssh -o X", CMD='docker run ...'). A value
#    with no internal space is an ordinary scalar and is not the footgun.
mapfile -t vars < <(
  printf '%s\n' "$cmd" \
    | grep -oE '(^|[[:space:];&|(])[A-Za-z_][A-Za-z0-9_]*=("[^"]*[[:space:]][^"]*"|'\''[^'\'']*[[:space:]][^'\'']*'\'')' \
    | grep -oE '[A-Za-z_][A-Za-z0-9_]*=' \
    | sed 's/=$//' \
    | sort -u
)
[ "${#vars[@]}" -gt 0 ] || exit 0

# 2. Flag if any such variable is later expanded UNQUOTED at a command position
#    (start of line, or after ; | & ( ), i.e. used AS the command itself.
#    Quoted uses ("$VAR") are intentional and not matched.
for v in "${vars[@]}"; do
  if printf '%s\n' "$cmd" \
      | grep -qE '(^|[;&|(])[[:space:]]*\$\{?'"$v"'\}?([[:space:]]|$)'; then
    cat >&2 <<EOF
BLOCKED — zsh word-split footgun: \$$v holds a command+options but is expanded
UNQUOTED as a command. In zsh (this shell) unquoted \$$v is NOT split on spaces,
so it runs as a single command name and fails ("no such file or directory").

Fix one of:
  * Inline the flags directly into the command, or
  * Use a bash array and expand it quoted:
      args=(ssh -o StrictHostKeyChecking=no); "\${args[@]}" host ...
EOF
    exit 2
  fi
done
exit 0
