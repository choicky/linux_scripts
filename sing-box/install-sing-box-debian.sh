#!/usr/bin/env bash
# Install the stable sing-box package from the official APT repository on Debian 12/13.
# This script deliberately installs "sing-box", never "sing-box-beta".
# Keep the vendor systemd unit; override the runtime identity and config path.
set -Eeuo pipefail

readonly CONFIG="/etc/sing-box/config.json"
readonly DROPIN_DIR="/etc/systemd/system/sing-box.service.d"
readonly DROPIN_FILE="${DROPIN_DIR}/override.conf"
NO_START=false
KEY_FILE=""
KEY_TMP=""
CONFIG_CHECKED=false
START_PENDING=false

log(){ printf '\n==> %s\n' "$*"; }
die(){ printf '\nERROR: %s\n' "$*" >&2; exit 1; }
usage(){ printf 'Usage: %s [--no-start] [--key-file FILE]\n' "$0"; }

cleanup(){
  local rc=$?
  trap - EXIT
  [[ -z "$KEY_TMP" ]] || rm -f -- "$KEY_TMP" || true
  if [[ "$START_PENDING" == true ]]; then
    # Stop first, including a queued automatic restart, then retain the mask
    # until a later invocation has validated the configuration again.
    systemctl stop sing-box || true
    systemctl mask sing-box || true
    systemctl --no-pager --full status sing-box || true
    journalctl -u sing-box -n 50 --no-pager || true
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

parse_args(){
  while (( $# )); do
    case "$1" in
      --no-start) NO_START=true;;
      --key-file)
        (( $# >= 2 )) && [[ -n "$2" ]] || die "--key-file requires a file path."
        KEY_FILE=$2
        shift
        [[ -f "$KEY_FILE" && -s "$KEY_FILE" ]] || die "Key must be an existing, non-empty regular file: $KEY_FILE"
        ;;
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

install_key(){
  install -d -m 0755 /etc/apt/keyrings
  # A same-directory rename preserves an existing key on download/copy failure.
  KEY_TMP=$(mktemp /etc/apt/keyrings/.sagernet.asc.XXXXXX)
  if [[ -n "$KEY_FILE" ]]; then
    log "Using local SagerNet key: $KEY_FILE"
    cat -- "$KEY_FILE" >"$KEY_TMP" || die "Cannot read local key: $KEY_FILE"
  else
    log "Downloading official GPG key over IPv4 (10s connect, 30s per attempt, at most 3 attempts)"
    if ! curl -4 -fsSL --connect-timeout 10 --max-time 30 \
      --retry 2 --retry-delay 2 --retry-max-time 95 \
      https://sing-box.app/gpg.key -o "$KEY_TMP"; then
      die "Official GPG key download failed; existing key preserved. Retry with --key-file FILE obtained from a trusted machine."
    fi
  fi
  [[ -s "$KEY_TMP" ]] || die "GPG key is empty; existing key preserved."
  chown root:root "$KEY_TMP"
  chmod 0644 "$KEY_TMP"
  mv -f -- "$KEY_TMP" /etc/apt/keyrings/sagernet.asc
  KEY_TMP=""
}

install_sing_box(){
  log "Installing sing-box Stable from the official APT repository"

  # Prevent package installation/upgrade from starting sing-box before the
  # runtime identity and existing configuration have been prepared.
  # stop also works on a masked unit, including after an interrupted run.
  if ! systemctl stop sing-box; then
    [[ $(systemctl show sing-box -p LoadState --value) == not-found ]] \
      || die "Cannot stop existing sing-box service."
  fi
  systemctl mask sing-box >/dev/null

  # Repair/install the key before refreshing an already configured SagerNet
  # repository. Only bootstrap the downloader when online mode needs it.
  if [[ -z "$KEY_FILE" ]] && { ! command -v curl >/dev/null || [[ ! -s /etc/ssl/certs/ca-certificates.crt ]]; }; then
    apt-get -o Acquire::ForceIPv4=true update
    apt-get -o Acquire::ForceIPv4=true install -y ca-certificates curl
  fi
  install_key
  cat >/etc/apt/sources.list.d/sagernet.sources <<'EOF'
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
EOF

  apt-get -o Acquire::ForceIPv4=true update
  DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::ForceIPv4=true install -y ca-certificates curl sing-box
  dpkg-query -W -f='${Status}\n' sing-box 2>/dev/null | grep -Fxq 'install ok installed' || die "Stable sing-box package was not installed."
  if dpkg-query -W -f='${Status}\n' sing-box-beta 2>/dev/null | grep -Fxq 'install ok installed'; then
    die "sing-box-beta is installed. Remove it before using this stable-package installer."
  fi
  systemctl stop sing-box
}

setup_service(){
  install -d -m 0755 "$DROPIN_DIR"
  cat >"$DROPIN_FILE" <<'EOF'
[Service]
User=www-data
Group=www-data
ExecStart=
ExecStart=/usr/bin/sing-box -D /var/lib/sing-box -c /etc/sing-box/config.json run
EOF
  systemctl daemon-reload
}

prepare_paths(){
  # StateDirectory=sing-box in the vendor unit would otherwise create/repair
  # /var/lib/sing-box for the vendor User=sing-box. With the User override,
  # keep the state directory explicitly owned by the selected runtime identity.
  install -d -o www-data -g www-data -m 0750 /var/lib/sing-box
  chown -R www-data:www-data /var/lib/sing-box
  chmod -R u+rwX /var/lib/sing-box
  # Existing deployments commonly write access/error logs here. Convert the
  # whole log tree so the new www-data runtime can continue using them.
  if [[ -d /var/log/sing-box ]]; then
    chown -R www-data:www-data /var/log/sing-box
  fi
  install -d -o root -g www-data -m 0750 /etc/sing-box
  if [[ -f "$CONFIG" ]]; then
    chown root:www-data "$CONFIG"
    chmod 0640 "$CONFIG"
  fi
}

validate_installation(){
  log "Validating installed sing-box"
  /usr/bin/sing-box version
  if [[ -f "$CONFIG" ]]; then
    runuser -u www-data -- /usr/bin/sing-box -D /var/lib/sing-box check -c "$CONFIG" \
      || die "Configuration check failed as www-data; service remains stopped and masked."
    CONFIG_CHECKED=true
  else
    log "$CONFIG is absent; skipping configuration check and service startup."
  fi
}

verify_service(){
  local effective_exec
  systemctl is-active --quiet sing-box || die "sing-box is not active."
  [[ $(systemctl show sing-box -p User --value) == www-data ]] || die "Effective User is not www-data."
  [[ $(systemctl show sing-box -p Group --value) == www-data ]] || die "Effective Group is not www-data."
  effective_exec=$(systemctl show sing-box -p ExecStart --value)
  # Require one command with exactly the intended binary and arguments.
  local expected='^\{ path=/usr/bin/sing-box ; argv\[\]=/usr/bin/sing-box -D /var/lib/sing-box -c /etc/sing-box/config\.json run ;[^{}]*\}$'
  [[ "$effective_exec" =~ $expected ]] || die "Unexpected effective ExecStart: $effective_exec"
}

start_sing_box(){
  [[ "$NO_START" == true ]] && { log "sing-box installed; service remains masked and start is skipped by --no-start."; return; }
  [[ -f "$CONFIG" ]] || { log "sing-box is installed but remains masked because $CONFIG is absent."; return; }
  [[ "$CONFIG_CHECKED" == true ]] || die "Refusing startup without a successful configuration check."

  START_PENDING=true
  systemctl unmask sing-box >/dev/null
  systemctl enable sing-box
  if ! systemctl restart sing-box; then
    die "sing-box failed to start."
  fi
  verify_service
  START_PENDING=false
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
  /usr/bin/sing-box version
}

main "$@"
