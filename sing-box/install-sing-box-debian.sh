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
readonly KEYRING_DIR="/etc/apt/keyrings"
readonly DROPIN_DIR="/etc/systemd/system/sing-box.service.d"
readonly RUN_DROPIN_DIR="/run/systemd/system/sing-box.service.d"
readonly DROPIN_FILE="${DROPIN_DIR}/override.conf"
readonly EXPECTED_EXEC="/usr/bin/sing-box -D /var/lib/sing-box -c /etc/sing-box/config.json run"
readonly DROPIN_CONTENT="[Service]
User=www-data
Group=www-data
ExecStart=
ExecStart=${EXPECTED_EXEC}"
readonly GPG_URL="https://sing-box.app/gpg.key"
# Official SagerNet/sing-box APT signing key (Project S <contact@sagernet.org>).
# Independently corroborated by the issuer fingerprint in the repository's
# signed InRelease file (https://deb.sagernet.org/InRelease). Do not change
# this constant without re-verifying both sources.
readonly GPG_FINGERPRINT="2C317FBD5D886B4E89BAE8DA6D9152172A2B2F0C"

NO_START=false
KEY_FILE=""
KEY_TMP=""
WORK_DIR=""
CONFIG_CHECKED=false
SERVICE_WAS_ACTIVE=false
SERVICE_WAS_ENABLED=false
SERVICE_WAS_MASKED=false
SERVICE_UNIT_PRESENT=false
PACKAGE_CHANGED=false
PACKAGE_VERSION_BEFORE=""
PACKAGE_VERSION_RECORDED=false
DROPIN_CHANGED=false
SOURCES_CHANGED=false
SOURCES_BACKUP=""
SOURCES_TMP=""
DROPIN_TMP=""
PERMS_MANIFEST=""
PERMS_CHANGED=false

log(){ printf '\n==> %s\n' "$*"; }
die(){ printf '\nERROR: %s\n' "$*" >&2; exit 1; }
usage(){ printf 'Usage: %s [--no-start] [--key-file FILE]\n' "$0"; }

cleanup(){
  local rc=$?
  trap - EXIT INT TERM HUP
  set +e
  [[ -z "$KEY_TMP" ]] || rm -f -- "$KEY_TMP" 2>/dev/null
  [[ -z "$SOURCES_TMP" ]] || rm -f -- "$SOURCES_TMP" 2>/dev/null
  [[ -z "$DROPIN_TMP" ]] || rm -f -- "$DROPIN_TMP" 2>/dev/null
  if (( rc != 0 )) && [[ "$PACKAGE_VERSION_RECORDED" == true ]]; then
    # apt/dpkg can change the package and still exit non-zero; do not miss
    # that when deciding whether the running service needs a restart.
    local installed_after
    installed_after="$(dpkg-query -W -f='${Version}' sing-box 2>/dev/null || true)"
    [[ "$installed_after" == "$PACKAGE_VERSION_BEFORE" ]] || PACKAGE_CHANGED=true
  fi
  if (( rc != 0 )); then
    rollback
    printf '\nInstallation failed. Prior service state and installer-managed files were restored where possible.\n' >&2
    systemctl --no-pager --full status sing-box 2>/dev/null
    journalctl -u sing-box -n 50 --no-pager 2>/dev/null
  fi
  [[ -z "$WORK_DIR" ]] || rm -rf -- "$WORK_DIR"
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
        [[ -f "$KEY_FILE" && -s "$KEY_FILE" && ! -L "$KEY_FILE" ]] \
          || die "Key must be an existing, non-empty regular file (not a symlink): $KEY_FILE"
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
    debian|ubuntu) :;;
    *) die "Only Debian and Ubuntu are supported.";;
  esac
  getent passwd www-data >/dev/null || die "User 'www-data' does not exist."
  getent group www-data >/dev/null || die "Group 'www-data' does not exist."
  local command
  for command in systemctl dpkg dpkg-query apt-get getent install find mktemp runuser cmp; do
    command -v "$command" >/dev/null 2>&1 || die "Missing required command: $command"
  done
  log "Environment: ${PRETTY_NAME:-${ID} ${VERSION_ID:-}}, architecture: $(dpkg --print-architecture)"
}

record_service_state(){
  if systemctl is-active --quiet sing-box 2>/dev/null; then
    SERVICE_WAS_ACTIVE=true
  fi
  if systemctl is-enabled --quiet sing-box 2>/dev/null; then
    SERVICE_WAS_ENABLED=true
  fi
  local load_state
  load_state="$(systemctl show sing-box -p LoadState --value 2>/dev/null || true)"
  [[ "$load_state" != "not-found" ]] && SERVICE_UNIT_PRESENT=true
  if [[ "$load_state" == "masked" ]]; then
    SERVICE_WAS_MASKED=true
  fi
}

check_preconditions(){
  local path
  for path in /etc/sing-box /var/lib/sing-box /var/log/sing-box \
              "$KEYRING_DIR" "$DROPIN_DIR" "$RUN_DROPIN_DIR"; do
    [[ -L "$path" ]] && die "Refusing to follow symlink at managed path: $path"
    [[ ! -e "$path" || -d "$path" ]] || die "Managed path is not a directory: $path"
  done
  for path in "$KEYRING" "$SOURCES"; do
    [[ -L "$path" ]] && die "Refusing to follow symlink at managed path: $path"
    [[ ! -e "$path" || -f "$path" ]] || die "Managed path is not a regular file: $path"
  done
  [[ ! -L "$DROPIN_FILE" ]] || die "Refusing to follow symlink: $DROPIN_FILE"
  [[ ! -e "$CONFIG" || -f "$CONFIG" ]] \
    || die "$CONFIG exists but is not a regular file."
  [[ ! -L "$CONFIG" ]] || die "$CONFIG is a symlink; refusing to follow it."
  if [[ "$SERVICE_WAS_ACTIVE" == true && ! -f "$CONFIG" ]]; then
    # Never take down a running service when we cannot validate its configured
    # startup path. The operator must provide the configuration first.
    die "$CONFIG is missing; refusing to stop or reconfigure the running sing-box service."
  fi
}

unmask_service(){
  local load_state
  load_state="$(systemctl show sing-box -p LoadState --value 2>/dev/null || true)"
  if [[ "$load_state" == "masked" ]]; then
    log "Unmasking previously masked sing-box service"
    systemctl unmask sing-box >/dev/null
    systemctl daemon-reload
  fi
}

ensure_tools(){
  local -a missing=()
  command -v curl >/dev/null 2>&1 || missing+=(curl)
  command -v gpg >/dev/null 2>&1 || missing+=(gnupg)
  [[ -s /etc/ssl/certs/ca-certificates.crt ]] || missing+=(ca-certificates)
  (( ${#missing[@]} == 0 )) && return 0

  log "Installing required tools: ${missing[*]}"
  if ! DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::ForceIPv4=true install -y "${missing[@]}"; then
    apt-get -o Acquire::ForceIPv4=true update
    DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::ForceIPv4=true install -y "${missing[@]}"
  fi
}

key_fingerprints(){
  local file=$1 home raw
  home=$(mktemp -d)
  chmod 0700 "$home"
  if ! raw="$(GNUPGHOME="$home" LC_ALL=C gpg --batch --no-tty --no-options \
      --no-permission-warning --with-colons --show-keys -- "$file" 2>/dev/null)"; then
    rm -rf -- "$home"
    return 1
  fi
  rm -rf -- "$home"
  printf '%s\n' "$raw" | awk -F: '
    $1 == "pub" { primary = 1; next }
    $1 == "sub" { primary = 0; next }
    $1 == "fpr" && primary { print toupper($10); primary = 0 }
  '
}

validate_key_file(){
  local file=$1 fingerprints
  [[ -f "$file" && -s "$file" && ! -L "$file" ]] || return 1
  fingerprints="$(key_fingerprints "$file")" || return 1
  [[ -n "$fingerprints" ]] || return 1
  # Reject key files that contain anything besides the single official
  # primary key. APT would otherwise trust every key in the file.
  [[ "$(printf '%s\n' "$fingerprints" | wc -l)" -eq 1 ]] || return 1
  [[ "$fingerprints" == "$GPG_FINGERPRINT" ]]
}

ensure_gpg_key(){
  install -d -o root -g root -m 0755 "$KEYRING_DIR"

  if [[ -n "$KEY_FILE" ]]; then
    log "Validating local SagerNet key: $KEY_FILE"
    validate_key_file "$KEY_FILE" \
      || die "Local key is not the official SagerNet key (expected fingerprint $GPG_FINGERPRINT)."
    KEY_TMP=$(mktemp "$KEYRING_DIR/.sagernet.asc.XXXXXX")
    cat -- "$KEY_FILE" >"$KEY_TMP"
  else
    if [[ -f "$KEYRING" && -s "$KEYRING" ]]; then
      if validate_key_file "$KEYRING"; then
        log "Reusing existing official GPG key: $KEYRING"
        chown root:root "$KEYRING"
        chmod 0644 "$KEYRING"
        return 0
      fi
      log "Existing GPG key is not the official SagerNet key; replacing it only after a validated key is available."
    fi

    log "Downloading official GPG key over IPv4 (10s connect, 30s per attempt, at most 3 attempts)"
    KEY_TMP=$(mktemp "$KEYRING_DIR/.sagernet.asc.XXXXXX")
    if ! curl -4 -fsSL --connect-timeout 10 --max-time 30 \
      --retry 2 --retry-delay 2 --retry-max-time 95 \
      "$GPG_URL" -o "$KEY_TMP" 2>/dev/null; then
      rm -f -- "$KEY_TMP" 2>/dev/null
      KEY_TMP=""
      cat >&2 <<'EOF'

============================================================
GPG key download failed or timed out.

The official GPG key can be manually downloaded from a trusted
machine with internet access:

  URL:  https://sing-box.app/gpg.key

Place it on this server at:

  /etc/apt/keyrings/sagernet.asc

Then rerun this installer. It will validate and reuse the
manually-supplied key without attempting another download.

Alternatively, supply the key via:

  bash install-sing-box-debian.sh --key-file /path/to/sagernet.asc

Do not disable APT signature verification.
============================================================
EOF
      die "GPG key download failed; any existing key was left untouched."
    fi
  fi

  [[ -s "$KEY_TMP" ]] || die "GPG key is empty; any existing key was left untouched."
  if ! validate_key_file "$KEY_TMP"; then
    rm -f -- "$KEY_TMP" 2>/dev/null
    KEY_TMP=""
    die "Key is not the official SagerNet key (expected fingerprint $GPG_FINGERPRINT); any existing key was left untouched."
  fi
  chown root:root "$KEY_TMP"
  chmod 0644 "$KEY_TMP"
  mv -f -- "$KEY_TMP" "$KEYRING"
  KEY_TMP=""
  log "Official SagerNet GPG key installed: $KEYRING"
}

configure_repository(){
  install -d -o root -g root -m 0755 "$(dirname "$SOURCES")"
  local desired
  SOURCES_TMP=$(mktemp "$(dirname "$SOURCES")/.sagernet.sources.XXXXXX")
  desired=$SOURCES_TMP
  cat >"$desired" <<'EOF'
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
EOF
  chown root:root "$desired"
  chmod 0644 "$desired"

  if [[ -f "$SOURCES" ]] && cmp -s "$desired" "$SOURCES"; then
    rm -f -- "$desired"
    SOURCES_TMP=""
    log "SagerNet APT repository already configured"
    return 0
  fi

  if [[ -f "$SOURCES" ]]; then
    SOURCES_BACKUP="$WORK_DIR/sagernet.sources"
    cp -a -- "$SOURCES" "$SOURCES_BACKUP"
  fi
  mv -f -- "$desired" "$SOURCES"
  SOURCES_TMP=""
  SOURCES_CHANGED=true
  log "Configuring SagerNet APT repository (deb822 format)"
}

install_packages(){
  if dpkg-query -W -f='${Status}\n' sing-box-beta 2>/dev/null | grep -Fxq 'install ok installed'; then
    die "sing-box-beta is installed. Remove it before using this stable-package installer."
  fi

  local before after
  before="$(dpkg-query -W -f='${Version}' sing-box 2>/dev/null || true)"
  PACKAGE_VERSION_BEFORE=$before
  PACKAGE_VERSION_RECORDED=true
  log "Installing sing-box Stable from the official APT repository"
  apt-get -o Acquire::ForceIPv4=true update
  DEBIAN_FRONTEND=noninteractive apt-get -o Acquire::ForceIPv4=true install -y \
    ca-certificates curl gnupg sing-box

  dpkg-query -W -f='${Status}\n' sing-box 2>/dev/null | grep -Fxq 'install ok installed' \
    || die "Stable sing-box package was not installed."
  if dpkg-query -W -f='${Status}\n' sing-box-beta 2>/dev/null | grep -Fxq 'install ok installed'; then
    die "sing-box-beta is installed. Remove it before using this stable-package installer."
  fi

  after="$(dpkg-query -W -f='${Version}' sing-box 2>/dev/null || true)"
  if [[ "$before" != "$after" ]]; then
    PACKAGE_CHANGED=true
    log "sing-box package changed: ${before:-not installed} -> ${after:-unknown}"
  fi
}

backup_dropin_dir(){
  local src=$1 dest=$2
  [[ -d "$src" ]] || return 0
  install -d -m 0700 "$dest"
  local -a files=()
  shopt -s nullglob
  files=("$src"/*.conf)
  shopt -u nullglob
  (( ${#files[@]} == 0 )) && return 0
  cp -a -- "${files[@]}" "$dest"/
}

restore_dropin_dir(){
  local src=$1 backup=$2
  if [[ -d "$src" ]]; then
    rm -f -- "$src"/*.conf
  else
    install -d -m 0755 "$src"
  fi
  if [[ -d "$backup" ]]; then
    cp -a -- "$backup"/. "$src"/
  fi
}

restore_dropins(){
  restore_dropin_dir "$DROPIN_DIR" "$WORK_DIR/dropins/etc"
  restore_dropin_dir "$RUN_DROPIN_DIR" "$WORK_DIR/dropins/run"
  systemctl daemon-reload 2>/dev/null
}

dropin_is_current(){
  [[ -f "$DROPIN_FILE" && ! -L "$DROPIN_FILE" ]] || return 1
  cmp -s <(printf '%s\n' "$DROPIN_CONTENT") "$DROPIN_FILE" || return 1
  local -a others=()
  shopt -s nullglob
  others=("$DROPIN_DIR"/*.conf "$RUN_DROPIN_DIR"/*.conf)
  shopt -u nullglob
  local file
  for file in "${others[@]}"; do
    [[ "$file" == "$DROPIN_FILE" ]] || return 1
  done
  return 0
}

setup_service(){
  log "Checking unified systemd drop-in"
  if dropin_is_current; then
    log "Unified systemd drop-in is already current"
    return 0
  fi

  backup_dropin_dir "$DROPIN_DIR" "$WORK_DIR/dropins/etc"
  backup_dropin_dir "$RUN_DROPIN_DIR" "$WORK_DIR/dropins/run"
  DROPIN_CHANGED=true

  # Remove every previous sing-box drop-in, including runtime copies created
  # by earlier installer or migration attempts.
  local dir
  for dir in "$DROPIN_DIR" "$RUN_DROPIN_DIR"; do
    [[ -d "$dir" ]] || continue
    rm -f -- "$dir"/*.conf
  done

  install -d -o root -g root -m 0755 "$DROPIN_DIR"
  DROPIN_TMP=$(mktemp "$DROPIN_DIR/.override.conf.XXXXXX")
  printf '%s\n' "$DROPIN_CONTENT" >"$DROPIN_TMP"
  chown root:root "$DROPIN_TMP"
  chmod 0644 "$DROPIN_TMP"
  mv -f -- "$DROPIN_TMP" "$DROPIN_FILE"
  DROPIN_TMP=""
  systemctl daemon-reload
  log "Installed unified systemd drop-in: $DROPIN_FILE"
}

snapshot_permissions(){
  PERMS_MANIFEST="$WORK_DIR/permissions"
  : >"$PERMS_MANIFEST"
  local path
  for path in /etc/sing-box /var/lib/sing-box /var/log/sing-box \
              "$DROPIN_DIR" "$RUN_DROPIN_DIR" "$KEYRING_DIR" "$KEYRING" "$SOURCES"; do
    [[ -e "$path" || -L "$path" ]] || continue
    find "$path" -xdev -printf '%m %U %G %p\0' >>"$PERMS_MANIFEST" \
      || die "Cannot snapshot permissions for $path."
  done
  PERMS_CHANGED=true
}

restore_permissions(){
  local entry mode uid gid path failed=0
  while IFS= read -r -d '' entry; do
    mode=${entry%% *}; entry=${entry#* }
    uid=${entry%% *}; entry=${entry#* }
    gid=${entry%% *}; path=${entry#* }
    [[ -e "$path" || -L "$path" ]] || continue
    chown -h "$uid:$gid" "$path" || failed=1
    [[ -L "$path" ]] || chmod "$mode" "$path" || failed=1
  done <"$PERMS_MANIFEST"
  return "$failed"
}

normalize_tree(){
  local path=$1 owner=$2 dir_mode=$3 file_mode=$4
  [[ -e "$path" ]] || return 0
  find "$path" -xdev -type d -exec chmod "$dir_mode" {} +
  find "$path" -xdev -type f -exec chmod "$file_mode" {} +
  find "$path" -xdev -type d -exec chown "$owner" {} +
  find "$path" -xdev -type f -exec chown "$owner" {} +
}

normalize_permissions(){
  log "Normalizing filesystem permissions and ownership"

  # /etc/sing-box/ -- root:www-data, 0755; ordinary files 0644.
  install -d -o root -g www-data -m 0755 /etc/sing-box
  normalize_tree /etc/sing-box root:www-data 0755 0644

  # /var/lib/sing-box/ -- www-data:www-data, 0755; ordinary files 0644.
  install -d -o www-data -g www-data -m 0755 /var/lib/sing-box
  normalize_tree /var/lib/sing-box www-data:www-data 0755 0644

  # /var/log/sing-box/ is normalized only when it already exists.
  if [[ -e /var/log/sing-box ]]; then
    install -d -o www-data -g www-data -m 0755 /var/log/sing-box
    normalize_tree /var/log/sing-box www-data:www-data 0755 0644
  fi

  # Systemd drop-in files -- root:root, 0644 (directory 0755).
  install -d -o root -g root -m 0755 "$DROPIN_DIR"
  normalize_tree "$DROPIN_DIR" root:root 0755 0644
  if [[ -d "$RUN_DROPIN_DIR" ]]; then
    normalize_tree "$RUN_DROPIN_DIR" root:root 0755 0644
  fi

  # APT signing key and repository definition -- root:root, 0644.
  install -d -o root -g root -m 0755 "$KEYRING_DIR"
  [[ ! -e "$KEYRING" ]] || { chown root:root "$KEYRING"; chmod 0644 "$KEYRING"; }
  [[ ! -e "$SOURCES" ]] || { chown root:root "$SOURCES"; chmod 0644 "$SOURCES"; }
}

validate_installation(){
  log "Validating installed sing-box"
  [[ -x /usr/bin/sing-box ]] || die "/usr/bin/sing-box is missing or not executable."
  /usr/bin/sing-box version
  if [[ -f "$CONFIG" ]]; then
    runuser -u www-data -- /usr/bin/sing-box -D /var/lib/sing-box check -c "$CONFIG" \
      || die "Configuration check failed as www-data."
    CONFIG_CHECKED=true
  else
    log "$CONFIG is absent; skipping configuration check and service startup."
  fi
}

verify_service_config(){
  local effective_exec load_state state_dir_mode
  load_state="$(systemctl show sing-box -p LoadState --value 2>/dev/null || true)"
  [[ "$load_state" != "masked" ]] || die "sing-box is unexpectedly masked."
  [[ "$load_state" != "not-found" ]] || die "sing-box unit not found."
  [[ "$(systemctl show sing-box -p User --value)" == "www-data" ]] \
    || die "Effective User is not www-data."
  [[ "$(systemctl show sing-box -p Group --value)" == "www-data" ]] \
    || die "Effective Group is not www-data."
  state_dir_mode="$(systemctl show sing-box -p StateDirectoryMode --value 2>/dev/null || true)"
  [[ -z "$state_dir_mode" || "$state_dir_mode" == "0755" ]] \
    || die "Effective StateDirectoryMode is not 0755: $state_dir_mode"
  effective_exec="$(systemctl show sing-box -p ExecStart --value)"
  local expected='^\{ path=/usr/bin/sing-box ; argv\[\]=/usr/bin/sing-box -D /var/lib/sing-box -c /etc/sing-box/config\.json run ;[^{}]*\}$'
  [[ "$effective_exec" =~ $expected ]] \
    || die "Unexpected effective ExecStart: $effective_exec"
}

verify_service_runtime(){
  local state
  state="$(systemctl is-active sing-box 2>/dev/null || true)"
  [[ "$state" == "active" ]] || die "sing-box is not active (state: ${state:-unknown})."
  if systemctl is-failed --quiet sing-box 2>/dev/null; then
    die "sing-box is in a failed state."
  fi
}

reconcile_service(){
  # Validate the unit's effective configuration before starting, stopping or
  # restarting anything, so a bad drop-in cannot cause a wrong-config start.
  verify_service_config

  if [[ "$NO_START" == true ]]; then
    if ! systemctl is-enabled --quiet sing-box 2>/dev/null; then
      systemctl enable sing-box >/dev/null
    fi
    systemctl stop sing-box >/dev/null 2>&1 || true
    [[ "$(systemctl is-active sing-box 2>/dev/null || true)" != "active" ]] \
      || die "sing-box is still active despite --no-start."
    log "sing-box is unmasked and enabled but not started (--no-start)."
    return 0
  fi

  if [[ ! -f "$CONFIG" ]]; then
    # A running service with a missing config was rejected before any change.
    systemctl stop sing-box >/dev/null 2>&1 || true
    [[ "$(systemctl is-active sing-box 2>/dev/null || true)" != "active" ]] \
      || die "sing-box is still active although $CONFIG is absent."
    log "sing-box is installed but $CONFIG is absent; service not started."
    return 0
  fi
  [[ "$CONFIG_CHECKED" == true ]] || die "Refusing startup without a successful configuration check."

  if ! systemctl is-enabled --quiet sing-box 2>/dev/null; then
    systemctl enable sing-box >/dev/null
  fi
  if [[ "$SERVICE_WAS_ACTIVE" == true ]]; then
    if [[ "$DROPIN_CHANGED" == true || "$PACKAGE_CHANGED" == true ]]; then
      systemctl restart sing-box || die "sing-box failed to restart."
    elif ! systemctl is-active --quiet sing-box; then
      systemctl start sing-box || die "sing-box failed to start."
    fi
  else
    systemctl start sing-box || die "sing-box failed to start."
  fi
  verify_service_config
  verify_service_runtime
  log "sing-box is enabled and running."
}

rollback(){
  local failed=0
  set +e
  if [[ "$DROPIN_CHANGED" == true ]]; then
    restore_dropins || failed=1
  fi
  if [[ "$SOURCES_CHANGED" == true ]]; then
    if [[ -n "$SOURCES_BACKUP" && -f "$SOURCES_BACKUP" ]]; then
      cp -a -- "$SOURCES_BACKUP" "$SOURCES" || failed=1
    else
      rm -f -- "$SOURCES" || failed=1
    fi
  fi
  if [[ "$PERMS_CHANGED" == true && -f "$PERMS_MANIFEST" ]]; then
    restore_permissions || failed=1
  fi

  if [[ "$SERVICE_UNIT_PRESENT" == true || "$PACKAGE_CHANGED" == true ]]; then
    if [[ "$SERVICE_WAS_ENABLED" == true ]]; then
      systemctl enable sing-box >/dev/null 2>&1 || failed=1
    elif [[ "$SERVICE_WAS_MASKED" != true ]]; then
      # is-enabled reports "masked" rather than the underlying enablement, so
      # a pre-existing mask does not justify disabling the unit on rollback.
      systemctl disable sing-box >/dev/null 2>&1 || failed=1
    fi
    if [[ "$SERVICE_WAS_ACTIVE" == true ]]; then
      if systemctl is-active --quiet sing-box 2>/dev/null; then
        if [[ "$DROPIN_CHANGED" == true || "$PACKAGE_CHANGED" == true ]]; then
          systemctl restart sing-box >/dev/null 2>&1 || failed=1
        fi
      else
        systemctl start sing-box >/dev/null 2>&1 || failed=1
      fi
      systemctl is-active --quiet sing-box 2>/dev/null || failed=1
    else
      systemctl stop sing-box >/dev/null 2>&1 || failed=1
    fi
  fi
  [[ "$failed" == 0 ]] || printf 'WARNING: rollback was incomplete; inspect sing-box before continuing.\n' >&2
  return "$failed"
}

main(){
  parse_args "$@"
  preflight
  WORK_DIR=$(mktemp -d)
  record_service_state
  unmask_service
  check_preconditions
  snapshot_permissions
  ensure_tools
  ensure_gpg_key
  configure_repository
  setup_service
  install_packages
  normalize_permissions
  validate_installation
  reconcile_service
  printf '\nsing-box installation completed.\n'
  /usr/bin/sing-box version
}

main "$@"
