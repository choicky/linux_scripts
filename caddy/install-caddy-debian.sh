#!/usr/bin/env bash
# Install Caddy Stable package support on Debian 12/13 and select the matching
# prebuilt custom binary from choicky/caddy-custom-build.
set -Eeuo pipefail

readonly CONFIG="/etc/caddy/caddy.jsonc"
readonly DROPIN_DIR="/etc/systemd/system/caddy.service.d"
readonly DROPIN_FILE="${DROPIN_DIR}/override.conf"
readonly CADDY_DEFAULT="/usr/bin/caddy.default"
readonly CADDY_CUSTOM="/usr/bin/caddy.custom"
readonly RELEASE_REPO="choicky/caddy-custom-build"
readonly MODULE_L4="github.com/mholt/caddy-l4"
readonly MODULE_CF_IP="github.com/WeidiDeng/caddy-cloudflare-ip"
NO_START=false

log(){ printf '\n==> %s\n' "$*"; }
die(){ printf '\nERROR: %s\n' "$*" >&2; exit 1; }
usage(){ printf 'Usage: %s [--no-start]\n' "$0"; }

parse_args(){ while (( $# )); do case "$1" in --no-start) NO_START=true;; -h|--help) usage; exit 0;; *) usage >&2; die "Unknown option: $1";; esac; shift; done; }

preflight(){
  [[ ${EUID} -eq 0 ]] || die "Run this script as root."
  . /etc/os-release
  [[ ${ID:-} == debian ]] || die "Only Debian is supported."
  case "${VERSION_ID:-}" in 12|13);; *) die "Only Debian 12 and Debian 13 are supported.";; esac
  getent passwd sing-box >/dev/null || die "User 'sing-box' does not exist. Install official sing-box first."
  getent group sing-box >/dev/null || die "Group 'sing-box' does not exist. Install official sing-box first."
  [[ ! -e /usr/local/bin/caddy ]] || die "Existing /usr/local/bin/caddy detected. Use migrate-caddy-debian.sh."
  case "$(dpkg --print-architecture)" in amd64) ARCH=amd64;; arm64) ARCH=arm64;; *) die "Unsupported architecture: $(dpkg --print-architecture). Only amd64 and arm64 are provided.";; esac
  log "Environment: Debian ${VERSION_ID}, architecture: ${ARCH}"
}

install_caddy(){
  log "Installing Caddy Stable from the official APT repository"

  # Never let the package post-install action start the vendor Caddyfile during
  # installation/upgrade. start_caddy() unmasks the service only after the
  # custom binary, drop-in and configuration have been prepared and validated.
  systemctl stop caddy >/dev/null 2>&1 || true
  systemctl mask caddy >/dev/null

  apt-get update
  apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gpg
  curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt -o /etc/apt/sources.list.d/caddy-stable.list
  chmod 0644 /usr/share/keyrings/caddy-stable-archive-keyring.gpg /etc/apt/sources.list.d/caddy-stable.list
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y -o Dpkg::Options::="--force-confold" caddy

  # A previous successful run may already have diverted the package binary and
  # selected /usr/bin/caddy.custom. In that state the package-managed binary is
  # /usr/bin/caddy.default; both fresh installs and retries are supported.
  systemctl stop caddy
  systemctl disable caddy >/dev/null 2>&1 || true
}

package_binary(){
  if [[ -x "$CADDY_DEFAULT" ]]; then printf '%s\n' "$CADDY_DEFAULT"; else printf '%s\n' /usr/bin/caddy; fi
}

download_custom_caddy(){
  local version asset tmpdir package_bin
  package_bin="$(package_binary)"
  version="$("$package_bin" version | awk '{print $1}')"
  [[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Cannot determine installed Caddy version."
  asset="caddy-linux-${ARCH}"
  tmpdir="$(mktemp -d)"
  trap 'rm -rf "$tmpdir"' RETURN
  log "Downloading custom Caddy ${version} for linux/${ARCH}"
  curl -fL --retry 3 -o "${tmpdir}/${asset}" "https://github.com/${RELEASE_REPO}/releases/download/${version}/${asset}"
  curl -fL --retry 3 -o "${tmpdir}/SHA256SUMS" "https://github.com/${RELEASE_REPO}/releases/download/${version}/SHA256SUMS"
  (cd "$tmpdir" && grep -E "[[:space:]]+${asset}$" SHA256SUMS | sha256sum -c -) || die "SHA256 verification failed for ${asset}."
  chmod 0755 "${tmpdir}/${asset}"
  [[ "$("${tmpdir}/${asset}" version | awk '{print $1}')" == "$version" ]] || die "Custom Caddy version does not match APT Caddy: ${version}."
  local modules
  modules="$("${tmpdir}/${asset}" list-modules --packages)"
  grep -Fq "$MODULE_L4" <<<"$modules" || die "Missing caddy-l4."
  grep -Fq "$MODULE_CF_IP" <<<"$modules" || die "Missing caddy-cloudflare-ip."
  grep -Fq 'caddy.adapters.jsonc github.com/caddyserver/caddy/v2' <<<"$modules" || die "Missing built-in JSONC adapter."
  install -m 0755 "${tmpdir}/${asset}" "$CADDY_CUSTOM"
  trap - RETURN; rm -rf "$tmpdir"
}

setup_custom_binary(){
  log "Registering stock and custom Caddy binaries"

  # Keep the package-managed binary behind a dpkg diversion. Do not combine
  # must have one unambiguous destination for the stock binary.
  local diversion
  diversion="$(dpkg-divert --listpackage /usr/bin/caddy 2>/dev/null || true)"
  if [[ -z "$diversion" ]]; then
    dpkg-divert --add --rename --divert "$CADDY_DEFAULT" /usr/bin/caddy
  elif ! dpkg-divert --list /usr/bin/caddy | grep -Fq "$CADDY_DEFAULT"; then
    die "Unexpected existing dpkg diversion for /usr/bin/caddy; inspect it manually."
  fi

  [[ -x "$CADDY_DEFAULT" && -x "$CADDY_CUSTOM" ]] || die "Caddy binaries are incomplete."
  ln -sfn "$CADDY_CUSTOM" /usr/bin/caddy
  [[ "$(readlink -f /usr/bin/caddy)" == "$CADDY_CUSTOM" ]] || die "Custom Caddy is not selected."
}

setup_service(){
  install -d -m 0755 "$DROPIN_DIR"
  cat >"$DROPIN_FILE" <<'EOF'
[Service]
User=sing-box
Group=sing-box
Environment=HOME=/var/lib/caddy
ExecStart=
ExecStart=/usr/bin/caddy run --environ --config /etc/caddy/caddy.jsonc --adapter jsonc
ExecReload=
ExecReload=/usr/bin/caddy reload --config /etc/caddy/caddy.jsonc --adapter jsonc --force
EOF
  systemctl daemon-reload
}

prepare_paths(){
  install -d -o sing-box -g sing-box -m 0700 /var/lib/caddy
  chown -R sing-box:sing-box /var/lib/caddy
  install -d -o sing-box -g sing-box -m 0750 /var/log/caddy
  chown root:sing-box /etc/caddy; chmod 0750 /etc/caddy
  if [[ -f "$CONFIG" ]]; then chown root:sing-box "$CONFIG"; chmod 0640 "$CONFIG"; fi
}

validate_installation(){
  log "Validating installed Caddy"
  /usr/bin/caddy version
  [[ "$NO_START" == true ]] && { log "Configuration validation skipped by --no-start."; return; }
  [[ -f "$CONFIG" ]] && runuser -u sing-box -- env HOME=/var/lib/caddy /usr/bin/caddy validate --config "$CONFIG" --adapter jsonc
}

start_caddy(){
  [[ "$NO_START" == true ]] && { log "Caddy installed; service remains masked and start is skipped by --no-start."; return; }
  [[ -f "$CONFIG" ]] || { log "Caddy is installed but remains masked because $CONFIG is absent."; return; }
  systemctl unmask caddy >/dev/null
  systemctl enable caddy
  if ! systemctl restart caddy; then systemctl --no-pager --full status caddy || true; journalctl -u caddy -n 50 --no-pager || true; die "Caddy failed to start."; fi
  systemctl is-active --quiet caddy || die "Caddy is not active."
}

main(){ parse_args "$@"; preflight; install_caddy; download_custom_caddy; setup_custom_binary; setup_service; prepare_paths; validate_installation; start_caddy; printf '\nCaddy installation completed.\n'; /usr/bin/caddy version; }
main "$@"
