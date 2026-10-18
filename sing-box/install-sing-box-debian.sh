#!/usr/bin/env bash
# Install the stable sing-box package from the official APT repository on
# Debian and Ubuntu. This script deliberately installs "sing-box", never
# "sing-box-beta". The vendor systemd unit is kept; a script-managed drop-in
# standardizes the runtime identity and config path.
#
# Usage: bash sing-box/install-sing-box-debian.sh [--no-start] [--key-file FILE]
set -Eeuo pipefail

readonly CONFIG="/etc/sing-box/config.json"
readonly KEYRING="/etc/apt/keyrings/sagernet.asc"
readonly SOURCES="/etc/apt/sources.list.d/sagernet.sources"
readonly DROPIN_DIR="/etc/systemd/system/sing-box.service.d"
readonly DROPIN_FILE="${DROPIN_DIR}/override.conf"
readonly EXPECTED_EXEC="/usr/bin/sing-box -D /var/lib/sing-box -c /etc/sing-box/config.json run"

NO_START=false
KEY_FILE=""
KEY_TMP=""
CONFIG_CHECKED=false
SERVICE_STOPPED_BY_US=false
WAS_ACTIVE=false
WAS_ENABLED=false
WAS_MASKED=false

log(){ printf '\n==> %s\n' "$*"; }
die(){ printf '\nERROR: %s\n' "$*" >&2; exit 1; }
usage(){ printf 'Usage: %s [--no-start] [--key-file FILE]\n' "$0"; }

cleanup(){
  local rc=$?
  trap - EXIT INT TERM HUP
  [[ -z "$KEY_TMP" ]] || rm -f -- "$KEY_TMP" 2>/dev/null || true
  # If this run masked the service, ensure it is unmasked on every exit path.
  # The mask is only used as a transient guard during package installation.
  if [[ "$WAS_MASKED" == false ]] && systemctl show sing-box -p LoadState --value 2>/dev/null | grep -qi masked; then
    systemctl unmask sing-box >/dev/null 2>&1 || true
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi
  if (( rc != 0 )); then
    # Restore prior runtime state on failure.
    if [[ "$WAS_ACTIVE" == true && "$SERVICE_STOPPED_BY_US" == true ]]; then
      systemctl start sing-box >/dev/null 2>&1 || true
    fi
    if [[ "$WAS_ACTIVE" == false && "$SERVICE_STOPPED_BY_US" == true ]]; then
      systemctl stop sing-box >/dev/null 2>&1 || true
    fi
    if [[ "$WAS_ENABLED" == false ]]; then
      systemctl disable sing-box >/dev/null 2>&1 || true
    fi
    printf '\nInstallation failed. Prior service state restored where possible.\n' >&2
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
  case "${ID:-}" in
    debian) :;;
    ubuntu) :;;
    *) die "Only Debian and Ubuntu are supported.";;
  esac
  getent passwd www-data >/dev/null || die "User 'www-data' does not exist."
  getent group www-data >/dev/null || die "Group 'www-data' does not exist."
  log "Environment: ${PRETTY_NAME:-${ID} ${VERSION_ID:-}}, architecture: $(dpkg --print-architecture)"
}

record_service_state(){
  if systemctl is-active --quiet sing-box 2>/dev/null; then
    WAS_ACTIVE=true
  fi
  if systemctl is-enabled --quiet sing-box 2>/dev/null; then
    WAS_ENABLED=true
  fi
  # Check if already masked (pre-existing, not ours).
  local load_state
  load_state="$(systemctl show sing-box -p LoadState --value 2>/dev/null || true)"
  if [[ "$load_state" == "masked" ]]; then
    WAS_MASKED=true
  fi
}

ensure_gpg_key(){
  install -d -m 0755 /etc/apt/keyrings

  # 1. Reuse an existing valid key if present.
  if [[ -f "$KEYRING" && -s "$KEYRING" ]]; then
    if gpg --no-default-keyring --keyring "$KEYRING" --list-keys >/dev/null 2>&1 \
       || grep -q 'BEGIN.*PUBLIC KEY' "$KEYRING" 2>/dev/null; then
      log "Reusing existing valid GPG key: $KEYRING"
      chown root:root "$KEYRING"
      chmod 0644 "$KEYRING"
      return 0
    fi
  fi

  # 2. Try to install from a user-supplied key file.
  if [[ -n "$KEY_FILE" ]]; then
    log "Using local SagerNet key: $KEY_FILE"
    KEY_TMP=$(mktemp /etc/apt/keyrings/.sagernet.asc.XXXXXX)
    cat -- "$KEY_FILE" >"$KEY_TMP" || die "Cannot read local key: $KEY_FILE"
  else
    log "Downloading official GPG key (10s connect, 30s per attempt, at most 3 attempts)"
    KEY_TMP=$(mktemp /etc/apt/keyrings/.sagernet.asc.XXXXXX)
    if ! curl -4 -fsSL --connect-timeout 10 --max-time 30 \
      --retry 2 --retry-delay 2 --retry-max-time 95 \
      https://sing-box.app/gpg.key -o "$KEY_TMP" 2>/dev/null; then
      rm -f -- "$KEY_TMP" 2>/dev/null || true
      KEY_TMP=""
      cat >&2 <<'EOF'

============================================================
GPG key download failed or timed out.

The official GPG key can be manually downloaded from a trusted
machine with internet access:

  URL:  https://sing-box.app/gpg.key

Place it on this server at:

  /etc/apt/keyrings/sagernet.asc

Then rerun this installer. It will detect and reuse the
valid manually-supplied key without attempting another download.

Alternatively, supply the key via:

  bash install-sing-box-debian.sh --key-file /path/to/sagernet.asc

Do not disable APT signature verification.
============================================================
EOF
      die "GPG key download failed; no valid existing key found at $KEYRING."
    fi
  fi

  # 3. Validate and atomically install the downloaded key.
  [[ -s "$KEY_TMP" ]] || die "GPG key is empty."
  chown root:root "$KEY_TMP"
  chmod 0644 "$KEY_TMP"
  mv -f -- "$KEY_TMP" "$KEYRING"
  KEY_TMP=""
  log "GPG key installed: $KEYRING"
}

configure_repository(){
  log "Configuring SagerNet APT repository (deb822 format)"
  cat >"$SOURCES" <<'EOF'
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
EOF
  chown root:root "$SOURCES"
  chmod 0644 "$SOURCES"
}

install_packages(){
  log "Installing sing-box Stable from the official APT repository"

  # Ensure essential tools are available before attempting repository operations.
  if ! command -v curl >/dev/null 2>&1; then
    apt-get -o Acquire::ForceIPv4=true update
    DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::ForceIPv4=true install -y ca-certificates curl
  fi

  ensure_gpg_key
  configure_repository

  apt-get -o Acquire::ForceIPv4=true update
  DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::ForceIPv4=true install -y ca-certificates curl sing-box

  dpkg-query -W -f='${Status}\n' sing-box 2>/dev/null | grep -Fxq 'install ok installed' \
    || die "Stable sing-box package was not installed."
  if dpkg-query -W -f='${Status}\n' sing-box-beta 2>/dev/null | grep -Fxq 'install ok installed'; then
    die "sing-box-beta is installed. Remove it before using this stable-package installer."
  fi
}

setup_service(){
  log "Configuring unified systemd drop-in"

  # Remove all existing sing-box service drop-ins to ensure no previous
  # customization overrides the unified configuration. This includes
  # previously created customizations such as 20-resolved.conf,
  # zzzz-single-file.conf, zzzz-caddy-single-file.conf, etc.
  if [[ -d "$DROPIN_DIR" ]]; then
    if [[ -L "$DROPIN_DIR" ]]; then
      die "Drop-in directory is a symlink; refusing to follow: $DROPIN_DIR"
    fi
    rm -f -- "$DROPIN_DIR"/*.conf
  fi

  install -d -m 0755 "$DROPIN_DIR"
  cat >"$DROPIN_FILE" <<'EOF'
[Service]
User=www-data
Group=www-data
ExecStart=
ExecStart=/usr/bin/sing-box -D /var/lib/sing-box -c /etc/sing-box/config.json run
EOF
  chown root:root "$DROPIN_FILE"
  chmod 0644 "$DROPIN_FILE"
  systemctl daemon-reload
}

normalize_permissions(){
  log "Normalizing filesystem permissions and ownership"

  # /etc/sing-box/ — root:www-data, 0755
  if [[ -L /etc/sing-box ]]; then
    die "/etc/sing-box is a symlink; refusing to follow."
  fi
  install -d -o root -g www-data -m 0755 /etc/sing-box
  chown root:www-data /etc/sing-box
  chmod 0755 /etc/sing-box

  # /etc/sing-box/config.json — root:www-data, 0644
  if [[ -L "$CONFIG" ]]; then
    die "$CONFIG is a symlink; refusing to follow."
  fi
  if [[ -f "$CONFIG" ]]; then
    chown root:www-data "$CONFIG"
    chmod 0644 "$CONFIG"
  fi

  # /var/lib/sing-box/ — www-data:www-data, 0755
  if [[ -L /var/lib/sing-box ]]; then
    die "/var/lib/sing-box is a symlink; refusing to follow."
  fi
  install -d -o www-data -g www-data -m 0755 /var/lib/sing-box
  chown www-data:www-data /var/lib/sing-box
  chmod 0755 /var/lib/sing-box
  # Normalize existing state files (not following symlinks).
  find /var/lib/sing-box -xdev -type f -exec chmod 0644 {} + 2>/dev/null || true
  find /var/lib/sing-box -xdev -type d -exec chmod 0755 {} + 2>/dev/null || true
  find /var/lib/sing-box -xdev -type f -exec chown www-data:www-data {} + 2>/dev/null || true
  find /var/lib/sing-box -xdev -type d -exec chown www-data:www-data {} + 2>/dev/null || true

  # /var/log/sing-box/ — www-data:www-data, 0755 (when managed by the installer)
  if [[ -e /var/log/sing-box ]]; then
    if [[ -L /var/log/sing-box ]]; then
      die "/var/log/sing-box is a symlink; refusing to follow."
    fi
    install -d -o www-data -g www-data -m 0755 /var/log/sing-box
    chown www-data:www-data /var/log/sing-box
    chmod 0755 /var/log/sing-box
    find /var/log/sing-box -xdev -type f -exec chmod 0644 {} + 2>/dev/null || true
    find /var/log/sing-box -xdev -type d -exec chmod 0755 {} + 2>/dev/null || true
    find /var/log/sing-box -xdev -type f -exec chown www-data:www-data {} + 2>/dev/null || true
    find /var/log/sing-box -xdev -type d -exec chown www-data:www-data {} + 2>/dev/null || true
  fi

  # Systemd drop-in files — root:root, 0644 (dir 0755)
  if [[ -d "$DROPIN_DIR" && ! -L "$DROPIN_DIR" ]]; then
    chown root:root "$DROPIN_DIR"
    chmod 0755 "$DROPIN_DIR"
    find "$DROPIN_DIR" -xdev -type f -exec chown root:root {} + 2>/dev/null || true
    find "$DROPIN_DIR" -xdev -type f -exec chmod 0644 {} + 2>/dev/null || true
  fi

  # Keyring and sources — root:root, 0644
  if [[ -f "$KEYRING" && ! -L "$KEYRING" ]]; then
    chown root:root "$KEYRING"
    chmod 0644 "$KEYRING"
  fi
  if [[ -f "$SOURCES" && ! -L "$SOURCES" ]]; then
    chown root:root "$SOURCES"
    chmod 0644 "$SOURCES"
  fi
}

validate_installation(){
  log "Validating installed sing-box"
  /usr/bin/sing-box version
  if [[ -L "$CONFIG" ]]; then
    die "$CONFIG is a symlink; refusing to validate."
  fi
  if [[ -f "$CONFIG" ]]; then
    runuser -u www-data -- /usr/bin/sing-box -D /var/lib/sing-box check -c "$CONFIG" \
      || die "Configuration check failed as www-data."
    CONFIG_CHECKED=true
  else
    log "$CONFIG is absent; skipping configuration check and service startup."
  fi
}

verify_service_config(){
  local effective_exec load_state
  load_state="$(systemctl show sing-box -p LoadState --value 2>/dev/null || true)"
  [[ "$load_state" != "masked" ]] || die "sing-box is unexpectedly masked."
  [[ "$load_state" != "not-found" ]] || die "sing-box unit not found."
  [[ "$(systemctl show sing-box -p User --value)" == "www-data" ]] \
    || die "Effective User is not www-data."
  [[ "$(systemctl show sing-box -p Group --value)" == "www-data" ]] \
    || die "Effective Group is not www-data."
  effective_exec="$(systemctl show sing-box -p ExecStart --value)"
  local expected='^\{ path=/usr/bin/sing-box ; argv\[\]=/usr/bin/sing-box -D /var/lib/sing-box -c /etc/sing-box/config\.json run ;[^{}]*\}$'
  [[ "$effective_exec" =~ $expected ]] \
    || die "Unexpected effective ExecStart: $effective_exec"
}

start_sing_box(){
  # Ensure the service is unmasked (handles previously-masked state).
  systemctl unmask sing-box >/dev/null 2>&1 || true
  systemctl daemon-reload

  if [[ "$NO_START" == true ]]; then
    log "sing-box installed; --no-start specified, service start skipped."
    # On --no-start, leave the service in a stopped but unmasked and enabled state.
    if [[ "$WAS_ACTIVE" == true ]]; then
      systemctl stop sing-box >/dev/null 2>&1 || true
    fi
    systemctl enable sing-box >/dev/null 2>&1 || true
    log "Service is unmasked and enabled but not started."
    return 0
  fi

  [[ -f "$CONFIG" ]] || { log "sing-box is installed but $CONFIG is absent; service not started."; return 0; }
  [[ "$CONFIG_CHECKED" == true ]] || die "Refusing startup without a successful configuration check."

  systemctl enable sing-box
  if [[ "$WAS_ACTIVE" == true ]]; then
    systemctl restart sing-box || die "sing-box failed to restart."
  else
    systemctl start sing-box || die "sing-box failed to start."
  fi
  verify_service_config
  log "sing-box is enabled and running."
}

main(){
  parse_args "$@"
  preflight
  record_service_state

  # Only stop the running service if it is currently active and we will be
  # modifying the package or service configuration.
  if [[ "$WAS_ACTIVE" == true ]]; then
    log "Stopping sing-box for installation"
    systemctl stop sing-box || true
    SERVICE_STOPPED_BY_US=true
  fi

  # Unmask a previously masked service before proceeding.
  if [[ "$WAS_MASKED" == true ]]; then
    log "Unmasking previously masked sing-box service"
    systemctl unmask sing-box >/dev/null 2>&1 || true
    systemctl daemon-reload >/dev/null 2>&1 || true
  fi

  install_packages
  setup_service
  normalize_permissions
  validate_installation
  start_sing_box
  printf '\nsing-box installation completed.\n'
  /usr/bin/sing-box version
}

main "$@"
