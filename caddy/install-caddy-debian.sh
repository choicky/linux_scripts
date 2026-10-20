#!/usr/bin/env bash
# Compatibility entry point. This installer supports Debian and Ubuntu APT
# distributions, so its canonical name is install-caddy-apt.sh. This wrapper
# only forwards to it; there is no second implementation to keep in sync.
set -Eeuo pipefail
exec bash "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/install-caddy-apt.sh" "$@"
