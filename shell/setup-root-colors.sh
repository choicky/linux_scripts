#!/usr/bin/env bash
# Configure a colored interactive Bash prompt and common colored aliases for root.
set -Eeuo pipefail

readonly BASHRC="/root/.bashrc"
readonly BEGIN_MARKER="# >>> linux_scripts root colors >>>"
readonly END_MARKER="# <<< linux_scripts root colors <<<"

[[ ${EUID} -eq 0 ]] || { printf 'ERROR: Run this script as root.\n' >&2; exit 1; }
touch "${BASHRC}"

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

# Replace a previous block from this script, if present, so reruns stay idempotent.
awk -v begin="${BEGIN_MARKER}" -v end="${END_MARKER}" '
  $0 == begin { skip=1; next }
  $0 == end   { skip=0; next }
  !skip       { print }
' "${BASHRC}" >"$tmp"

cat >>"$tmp" <<'EOF'

# >>> linux_scripts root colors >>>
# Red root user, green hostname, blue working directory.
PS1='\[\033[01;31m\]\u\[\033[00m\]@\[\033[01;32m\]\h\[\033[00m\]:\[\033[01;34m\]\w\[\033[00m\]\$ '

# Colored command output.
if command -v dircolors >/dev/null 2>&1; then
    eval "$(dircolors -b)"
    alias ls='ls --color=auto'
    alias ll='ls -alF --color=auto'
    alias la='ls -A --color=auto'
    alias l='ls -CF --color=auto'
fi

alias grep='grep --color=auto'
alias fgrep='fgrep --color=auto'
alias egrep='egrep --color=auto'
# <<< linux_scripts root colors <<<
EOF

cat "$tmp" >"${BASHRC}"
chmod 0644 "${BASHRC}"

printf 'Root Bash colors configured in %s.\n' "${BASHRC}"
printf 'Run: source /root/.bashrc\n'
