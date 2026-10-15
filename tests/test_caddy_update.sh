#!/usr/bin/env bash
# Isolated regression checks: no APT, systemd, or live config changes.
set -Eeuo pipefail
cd "$(dirname "$0")/.."
source <(sed '$d' caddy/update-caddy-debian.sh)
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
