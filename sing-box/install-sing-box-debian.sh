#!/usr/bin/env bash
# Install sing-box Stable from the official APT repository on Debian 12/13.
# Keep the vendor systemd unit and override only the runtime user/group.
set -Eeuo pipefail

readonly CONFIG="/etc/sing-box/config.json"
readonly DROPIN_DIR="/etc/systemd/system/sing-box.service.d"
readonly DROPIN_FILE="${DROPIN_DIR}/override.conf"
NO_START=false

log(){ printf '\n==> %s\n' "$*"; }
die(){ printf '\nERROR: %s\n' "$*" >&2; exit 1; }
usage(){ printf 'Usage: %s [--no-start]\n' "$0"; }

parse_args(){
  while (( $# )); do
    case "$1" in
      --no-start) NO_START=true;;
      -h|--help) usage; exit 0;;
      *) usage >&2; die "Unknown option: $1";;
    esac
    shift
  done
}

preflight(){
  [[ ${EUID} -eq 0 ]] || die "Run this script as root."
  . /etc/os-release
  [[ ${ID:-} == debian ]] || die "Only Debian is supported."
  case "${VERSION_ID:-}" in 12|13);; *) die "Only Debian 12 and Debian 13 are supported.";; esac
  getent passwd www-data >/dev/null || die "User 'www-data' does not exist."
  getent group www-data >/dev/null || die "Group 'www-data' does not exist."
  log "Environment: Debian ${VERSION_ID}, architecture: $(dpkg --print-architecture)"
}

install_sing_box(){
  log "Installing sing-box Stable from the official APT repository"

  # Prevent package installation/upgrade from starting sing-box before the
  # runtime identity and existing configuration have been prepared.
  systemctl stop sing-box >/dev/null 2>&1 || true
  systemctl mask sing-box >/dev/null

  apt-get update
  apt-get install -y ca-certificates curl
  install -d -m 0755 /etc/apt/keyrings
  curl -fsSL https://sing-box.app/gpg.key -o /etc/apt/keyrings/sagernet.asc
  chmod a+r /etc/apt/keyrings/sagernet.asc
  cat >/etc/apt/sources.list.d/sagernet.sources <<'EOF'
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
EOF

  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y sing-box
  systemctl stop sing-box >/dev/null 2>&1 || true
}

setup_service(){
  install -d -m 0755 "$DROPIN_DIR"
  cat >"$DROPIN_FILE" <<'EOF'
[Service]
User=www-data
Group=www-data
EOF
  systemctl daemon-reload
}

prepare_paths(){
  # StateDirectory=sing-box in the vendor unit would otherwise create/repair
  # /var/lib/sing-box for the vendor User=sing-box. With the User override,
  # keep the state directory explicitly owned by the selected runtime identity.
  install -d -o www-data -g www-data -m 0750 /var/lib/sing-box
  chown -R www-data:www-data /var/lib/sing-box
  install -d -o root -g www-data -m 0750 /etc/sing-box
  if [[ -f "$CONFIG" ]]; then
    chown root:www-data "$CONFIG"
    chmod 0640 "$CONFIG"
  fi
}

validate_installation(){
  log "Validating installed sing-box"
  sing-box version
  [[ "$NO_START" == true ]] && { log "Configuration validation skipped by --no-start."; return; }
  [[ -f "$CONFIG" ]] && runuser -u www-data -- sing-box check -c "$CONFIG"
}

start_sing_box(){
  [[ "$NO_START" == true ]] && { log "sing-box installed; service remains masked and start is skipped by --no-start."; return; }
  [[ -f "$CONFIG" ]] || { log "sing-box is installed but remains masked because $CONFIG is absent."; return; }

  systemctl unmask sing-box >/dev/null
  systemctl enable sing-box
  if ! systemctl restart sing-box; then
    systemctl --no-pager --full status sing-box || true
    journalctl -u sing-box -n 50 --no-pager || true
    die "sing-box failed to start."
  fi
  systemctl is-active --quiet sing-box || die "sing-box is not active."
}

main(){
  parse_args "$@"
  preflight
  install_sing_box
  setup_service
  prepare_paths
  validate_installation
  start_sing_box
  printf '\nsing-box installation completed.\n'
  sing-box version
}

main "$@"
