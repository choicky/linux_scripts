#!/usr/bin/env bash
# Isolated regression checks: no APT, systemd, or live config changes.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
# NORMALIZE is redirected to a temp stub below, so source a variant whose
# readonly line leaves it assignable.
source <(sed '$d' caddy/update-caddy-debian.sh \
  | sed -e 's/^readonly NORMALIZE=/NORMALIZE=/' -e 's/^readonly OS_RELEASE=/OS_RELEASE=/')
apt-get(){ echo 'simulated APT output'; }
# apt-cache policy output for a healthy official repository, including the
# version table the origin assertion reads.
apt-cache(){
  printf 'caddy:\n  Installed: (none)\n  Candidate: 2.11.7\n  Version table:\n     2.11.7 500\n        500 https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version/main amd64 Packages\n'
}
target=$(candidate_version)
[[ "$target" == v2.11.7 ]]
echo 'PASS: APT output does not contaminate candidate version'

# The candidate must come from the official Caddy repository. Ubuntu publishes
# its own distro build of caddy, so a version that merely parses is not enough.
apt-cache(){
  printf 'caddy:\n  Installed: (none)\n  Candidate: 2.6.2-14\n  Version table:\n     2.6.2-14 500\n        500 http://archive.ubuntu.com/ubuntu resolute/universe amd64 Packages\n'
}
set +e
result=$( (caddy_repo_candidate) 2>&1 )
rc=$?
set -e
[[ "$rc" != 0 ]] || { echo 'FAIL: distribution caddy build was accepted'; exit 1; }
[[ "$result" == *'not the official Caddy repository'* ]] \
  || { echo "FAIL: unclear origin rejection message: $result"; exit 1; }
echo 'PASS: distribution-owned caddy candidate is rejected'

# The origin must bind to the candidate's own version entry. Ubuntu lists a
# distribution build in the same table as the official repository, so a parser
# that keeps its first match attributes the official origin to the wrong
# version and lets a downgrade through.
apt-cache(){
  printf 'caddy:\n  Installed: 2.11.7\n  Candidate: 2.6.2-14ubuntu1\n  Version table:\n     2.11.7 500\n        500 https://dl.cloudsmith.io/public/caddy/stable/deb/deb stable/main amd64 Packages\n *** 2.6.2-14ubuntu1 500\n        500 http://archive.ubuntu.com/ubuntu resolute/universe amd64 Packages\n    100 /var/lib/dpkg/status\n'
}
set +e
result=$( (caddy_repo_candidate) 2>&1 )
rc=$?
set -e
[[ "$rc" != 0 ]] || { echo "FAIL: universe candidate accepted via an older cloudsmith entry: $result"; exit 1; }
[[ "$result" == *"comes from 'http://archive.ubuntu.com/ubuntu"* ]] \
  || { echo "FAIL: wrong origin attributed to the candidate: $result"; exit 1; }
echo 'PASS: origin binds to the candidate entry, not the first table line'

# Reverse ordering, the *** installed marker and the dpkg status entry must all
# still resolve the official origin for the candidate.
apt-cache(){
  printf 'caddy:\n  Installed: 2.11.7\n  Candidate: 2.11.7\n  Version table:\n     2.6.2-14ubuntu1 500\n        500 http://archive.ubuntu.com/ubuntu resolute/universe amd64 Packages\n *** 2.11.7 500\n        500 https://dl.cloudsmith.io/public/caddy/stable/deb/deb stable/main amd64 Packages\n    100 /var/lib/dpkg/status\n'
}
set +e
result=$( (caddy_repo_candidate) 2>&1 )
rc=$?
set -e
[[ "$rc" == 0 && "$result" == '2.11.7' ]] \
  || { echo "FAIL: official candidate rejected: $result"; exit 1; }
echo 'PASS: installed *** candidate keeps the official origin'

# A candidate whose version entry carries no repository line is ambiguous and
# must be refused instead of guessed.
apt-cache(){
  printf 'caddy:\n  Installed: (none)\n  Candidate: 2.11.7\n  Version table:\n     2.11.7 500\n'
}
set +e
result=$( (caddy_repo_candidate) 2>&1 )
rc=$?
set -e
[[ "$rc" != 0 && "$result" == *'no repository origin'* ]] \
  || { echo "FAIL: origin-less candidate accepted or misdescribed: $result"; exit 1; }
echo 'PASS: candidate without any repository origin is refused'
apt-cache(){
  printf 'caddy:\n  Installed: (none)\n  Candidate: 2.11.7\n  Version table:\n     2.11.7 500\n        500 https://dl.cloudsmith.io/public/caddy/stable/deb/deb stable/main amd64 Packages\n'
}

# Supported-distribution matrix, asserted against the same fixtures as the
# installer so the two APT entry points cannot drift apart.
os_tmp="$(mktemp -d)"
os_release_case(){ # $1 = os-release contents; prints the label or fails
  printf '%s' "$1" > "$os_tmp/os-release"
  ( OS_RELEASE="$os_tmp/os-release"; require_supported_os; printf '%s' "$DISTRO_LABEL" )
}
os_reject_case(){ # $1 = contents, $2 = expected phrase
  printf '%s' "$1" > "$os_tmp/os-release"
  set +e
  local err rc
  err=$( (OS_RELEASE="$os_tmp/os-release"; require_supported_os) 2>&1 )
  rc=$?
  set -e
  [[ "$rc" == 1 ]] || { echo "FAIL: expected rejection, accepted: $1"; exit 1; }
  [[ "$err" == *"$2"* ]] || { echo "FAIL: wrong diagnostic: $err"; exit 1; }
}
for accepted in 'ID=debian
VERSION_ID="12"|Debian 12' \
                'ID=debian
VERSION_ID="13"|Debian 13' \
                'ID=ubuntu
VERSION_ID="24.04"|Ubuntu 24.04 LTS' \
                'ID=ubuntu
VERSION_ID="26.04"|Ubuntu 26.04 LTS'; do
  content=${accepted%|*}; want=${accepted##*|}
  [[ "$(os_release_case "$content")" == "$want" ]] \
    || { echo "FAIL: $content did not report $want"; exit 1; }
done
echo 'PASS: Debian 12/13 and Ubuntu 24.04/26.04 are accepted'

os_reject_case 'ID=ubuntu
VERSION_ID="22.04"
' "Ubuntu '22.04' is not supported"
os_reject_case 'ID=debian
VERSION_ID="11"
' "Debian '11' is not supported"
os_reject_case 'ID=linuxmint
ID_LIKE="ubuntu debian"
VERSION_ID="22.1"
' "Distribution 'linuxmint' is not supported"
os_reject_case 'NAME="Whatever"
VERSION_ID="12"
' 'has no ID field'
os_reject_case '' 'non-empty regular file'
[[ "$( (OS_RELEASE="$os_tmp/absent"; require_supported_os) 2>&1 )" == *'Cannot read a non-empty regular file'* ]] \
  || { echo 'FAIL: missing os-release was not reported safely'; exit 1; }
echo 'PASS: unsupported, unknown and malformed distributions are rejected'
rm -rf "$os_tmp"

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

# The compatibility entry point must behave exactly like the canonical one and
# must not carry a second implementation.
set +e
canonical_out=$(bash caddy/install-caddy-apt.sh --check-os 2>&1); canonical_rc=$?
wrapper_out=$(bash caddy/install-caddy-debian.sh --check-os 2>&1); wrapper_rc=$?
set -e
[[ "$canonical_rc" == "$wrapper_rc" && "$canonical_out" == "$wrapper_out" ]] \
  || { echo "FAIL: wrapper disagrees with canonical installer ($canonical_rc/$wrapper_rc)"; exit 1; }
grep -Eq 'apt-get|dpkg-divert|preflight\(\)' caddy/install-caddy-debian.sh \
  && { echo 'FAIL: compatibility wrapper contains installer logic'; exit 1; }
echo "PASS: install-caddy-debian.sh forwards to install-caddy-apt.sh (host: ${canonical_out:-rejected, rc $canonical_rc})"

