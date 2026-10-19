#!/usr/bin/env bash
# Isolated regression checks: no APT, systemd, or live config changes.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
# NORMALIZE is redirected to a temp stub below, so source a variant whose
# readonly line leaves it assignable.
source <(sed '$d' caddy/update-caddy-debian.sh | sed 's/^readonly NORMALIZE=/NORMALIZE=/')
apt-get(){ echo 'simulated APT output'; }
apt-cache(){ printf 'caddy:\n  Candidate: 2.11.7\n'; }
target=$(candidate_version)
[[ "$target" == v2.11.7 ]]
echo 'PASS: APT output does not contaminate candidate version'

# die must invoke rollback after a service mutation, including explicit errors.
set +e
result=$( (SERVICE_TOUCHED=true; rollback_runtime(){ echo "rollback:$1"; exit "$1"; }; die test) 2>/dev/null )
rc=$?
set -e
[[ "$rc" == 1 && "$result" == 'rollback:1' ]]
echo 'PASS: explicit failure invokes runtime rollback'

# Failed downloads must never touch the service.
curl(){ return 22; }
systemctl(){ echo 'UNEXPECTED SERVICE MUTATION'; return 99; }
ARCH=amd64
set +e
result=$( (download_and_verify v2.11.7) 2>&1 )
rc=$?
set -e
[[ "$rc" != 0 && "$result" != *'UNEXPECTED SERVICE MUTATION'* ]]
echo 'PASS: unavailable custom release leaves service alone'

# normalize_state must delegate to the shared component with --caddy.
tmp="$(mktemp -d)"
NORMALIZE="$tmp/normalize.sh"
printf '%s\n' '#!/bin/bash' 'echo "normalize $*" >> '"$tmp"'/calls' > "$NORMALIZE"
chmod +x "$NORMALIZE"
# log/die are already available from the sourced script; suppress log stdout.
log(){ :; }
normalize_state
grep -q 'normalize --caddy' "$tmp/calls" || { echo 'FAIL: normalize_state did not invoke --caddy'; exit 1; }
echo 'PASS: normalize_state invokes the shared normalizer with --caddy'

# A missing normalization component must abort (no-update path cannot silently exit 0).
rm -f "$NORMALIZE"
set +e
( normalize_state ) >/dev/null 2>&1
rc=$?
set -e
[[ "$rc" != 0 ]] || { echo 'FAIL: missing normalizer did not abort'; exit 1; }
echo 'PASS: missing normalization component aborts'
rm -rf "$tmp"

# The no-upgrade branch must reach normalize_state before exit (spec section 5.1).
awk '/already up to date/{f=1} f&&/normalize_state/{print;exit} f&&/exit 0/{exit}' \
  caddy/update-caddy-debian.sh | grep -q normalize_state \
  || { echo 'FAIL: no-update path missing normalize_state'; exit 1; }
echo 'PASS: already-current path normalizes before exiting'

# upgrade() reconciles managed state BEFORE its single conditional restart,
# so one restart applies both the new binary and any corrected drop-in.
awk '/^upgrade\(\)\{/{f=1} f&&/normalize_state/{print "OK";exit} f&&/systemctl restart caddy/{exit}' \
  caddy/update-caddy-debian.sh | grep -q OK \
  || { echo 'FAIL: upgrade does not normalize before restarting'; exit 1; }
echo 'PASS: upgrade normalizes before the single restart'

# preflight re-asserts the APT protection mechanisms (diversion + symlink)
# before any mutation, which is what makes plain `apt upgrade` non-invalidating.
awk '/^preflight\(\)\{/,/^\}/' caddy/update-caddy-debian.sh | grep -q 'dpkg-divert --list' \
  || { echo 'FAIL: preflight does not verify the diversion'; exit 1; }
awk '/^preflight\(\)\{/,/^\}/' caddy/update-caddy-debian.sh | grep -q 'readlink -f /usr/bin/caddy' \
  || { echo 'FAIL: preflight does not verify the custom-binary symlink'; exit 1; }
echo 'PASS: preflight verifies APT protection before mutating'

# No apt-mark hold or pinning is executed anywhere in the update flow
# (comments may explain why they are deliberately absent).
grep -Ev '^[[:space:]]*#' caddy/update-caddy-debian.sh | grep -Eq 'apt-mark|apt_preferences|etc/apt/preferences' \
  && { echo 'FAIL: unexpected apt hold/pinning found'; exit 1; }
echo 'PASS: minimum-sufficient APT protection (divert only, no hold/pinning)'
