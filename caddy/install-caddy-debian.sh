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
PREPARE_ONLY=""
PREPARED_DIR=""
BUILD_DIR=""
SERVICE_TOUCHED=false
RUNTIME_READY=false
WAS_MASKED=false
cleanup(){
  local rc=$?
  trap - EXIT
  if (( rc != 0 )) && [[ "$SERVICE_TOUCHED" == true ]]; then
    systemctl stop caddy >/dev/null 2>&1 || true
    systemctl disable caddy >/dev/null 2>&1 || true
    # Only expose the unit again when its custom binary/drop-in/paths are ready.
    # Preserve a mask that predated this attempt on failure.
    if [[ "$RUNTIME_READY" == true && "$WAS_MASKED" == false ]]; then
      systemctl unmask caddy >/dev/null 2>&1 || true
      systemctl daemon-reload || true
      printf '\nInstallation failed; Caddy is stopped and disabled. Fix the error and rerun.\n' >&2
    else
      systemctl mask caddy >/dev/null 2>&1 || true
      printf '\nInstallation failed; Caddy remains stopped and masked. Complete installation before deployment.\n' >&2
    fi
  fi
  [[ -z "$BUILD_DIR" ]] || rm -rf "$BUILD_DIR"
  exit "$rc"
}
trap cleanup EXIT

log(){ printf '\n==> %s\n' "$*"; }
die(){ printf '\nERROR: %s\n' "$*" >&2; exit 1; }
usage(){ printf 'Usage: %s [--no-start] [--prepare-only DIR | --prepared-dir DIR]\n' "$0"; }

parse_args(){
  while (( $# )); do
    case "$1" in
      --no-start) NO_START=true;;
      --prepare-only|--prepared-dir)
        (( $# >= 2 )) || die "Missing directory for $1"
        [[ "$2" == /* ]] || die "Preparation directory must be absolute."
        if [[ "$1" == --prepare-only ]]; then PREPARE_ONLY="$2"; else PREPARED_DIR="$2"; fi
        shift;;
      -h|--help) usage; exit 0;;
      *) usage >&2; die "Unknown option: $1";;
    esac
    shift
  done
  [[ -z "$PREPARE_ONLY" || -z "$PREPARED_DIR" ]] || die "Preparation options are mutually exclusive."
}


preflight(){
  [[ ${EUID} -eq 0 ]] || die "Run this script as root."
  . /etc/os-release
  [[ ${ID:-} == debian ]] || die "Only Debian is supported."
  case "${VERSION_ID:-}" in 12|13);; *) die "Only Debian 12 and Debian 13 are supported.";; esac
  getent passwd www-data >/dev/null || die "User 'www-data' does not exist."
  getent group www-data >/dev/null || die "Group 'www-data' does not exist."
  [[ -n "$PREPARE_ONLY" || ! -e /usr/local/bin/caddy ]] || die "Existing /usr/local/bin/caddy detected. Use migrate-caddy-debian.sh."
  case "$(dpkg --print-architecture)" in amd64) ARCH=amd64;; arm64) ARCH=arm64;; *) die "Unsupported architecture: $(dpkg --print-architecture). Only amd64 and arm64 are provided.";; esac
  case "$(systemctl is-enabled caddy 2>/dev/null || true)" in
    masked|masked-runtime) WAS_MASKED=true;;
  esac
  log "Environment: Debian ${VERSION_ID}, architecture: ${ARCH}"
}

install_caddy(){
  log "Preparing the official Caddy APT repository"

  apt-get update
  apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gpg
  curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt -o /etc/apt/sources.list.d/caddy-stable.list
  chmod 0644 /usr/share/keyrings/caddy-stable-archive-keyring.gpg /etc/apt/sources.list.d/caddy-stable.list
  apt-get update
  # Resolve the repository candidate before touching the running service.
  PACKAGE_VERSION="$(LC_ALL=C apt-cache policy caddy | awk '/Candidate:/ {print $2; exit}')"
  [[ -n "$PACKAGE_VERSION" && "$PACKAGE_VERSION" != '(none)' ]] || die "No Caddy APT candidate available."
  CADDY_VERSION="v${PACKAGE_VERSION#*:}"
  [[ "$CADDY_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Unsupported Caddy package version: $PACKAGE_VERSION"
}

install_caddy_package(){
  # Downloads, checksum, version and module checks have all passed by now.
  log "Installing verified Caddy package ${PACKAGE_VERSION}"
  if ! systemctl stop caddy; then
    [[ "$(systemctl show caddy -p LoadState --value)" == not-found ]] || die "Cannot stop existing Caddy."
  fi
  SERVICE_TOUCHED=true
  systemctl mask caddy >/dev/null
  local -a download_policy=()
  [[ -z "$PREPARED_DIR" ]] || download_policy+=(--no-download)
  DEBIAN_FRONTEND=noninteractive apt-get install -y --reinstall "${download_policy[@]}" -o Dpkg::Options::="--force-confold" "caddy=$PACKAGE_VERSION"
  systemctl stop caddy
  systemctl disable caddy >/dev/null 2>&1 || true
  install -m 0755 "$BUILD_DIR/caddy-linux-${ARCH}" "$CADDY_CUSTOM"
}

download_custom_caddy(){
  local version asset
  version="$CADDY_VERSION"
  asset="caddy-linux-${ARCH}"
  BUILD_DIR="$(mktemp -d)"
  log "Downloading custom Caddy ${version} for linux/${ARCH}"
  curl -fL --retry 3 -o "${BUILD_DIR}/${asset}" "https://github.com/${RELEASE_REPO}/releases/download/${version}/${asset}" ||
    die "Custom build ${version}/${asset} is unavailable. Publish the matching release in ${RELEASE_REPO}, then retry. Caddy service and binary have not been changed by this run."
  curl -fL --retry 3 -o "${BUILD_DIR}/SHA256SUMS" "https://github.com/${RELEASE_REPO}/releases/download/${version}/SHA256SUMS"
  (cd "$BUILD_DIR" && grep -E "[[:space:]]+${asset}$" SHA256SUMS | sha256sum -c -) || die "SHA256 verification failed for ${asset}."
  chmod 0755 "${BUILD_DIR}/${asset}"
  [[ "$("${BUILD_DIR}/${asset}" version | awk '{print $1}')" == "$version" ]] || die "Custom Caddy version does not match APT Caddy: ${version}."
  local modules
  modules="$("${BUILD_DIR}/${asset}" list-modules --packages)"
  grep -Fq "$MODULE_L4" <<<"$modules" || die "Missing caddy-l4."
  grep -Fq "$MODULE_CF_IP" <<<"$modules" || die "Missing caddy-cloudflare-ip."
  grep -Fq 'caddy.adapters.jsonc github.com/caddyserver/caddy/v2' <<<"$modules" || die "Missing built-in JSONC adapter."
  log "Custom binary verified; preparing the exact APT package before stopping Caddy"
  apt-get install --download-only --reinstall -y "caddy=$PACKAGE_VERSION"
}

save_prepared(){
  [[ ! -e "$PREPARE_ONLY" ]] || die "Preparation destination already exists: $PREPARE_ONLY"
  install -d -m 0700 "$PREPARE_ONLY"
  install -m 0755 "$BUILD_DIR/caddy-linux-${ARCH}" "$PREPARE_ONLY/caddy-linux-${ARCH}"
  cp "$BUILD_DIR/SHA256SUMS" "$PREPARE_ONLY/SHA256SUMS"
  printf '%s\n' "$PACKAGE_VERSION" > "$PREPARE_ONLY/package-version"
  printf '%s\n' "$ARCH" > "$PREPARE_ONLY/architecture"
  log "Prepared installation resources; running Caddy was not stopped."
}

load_prepared(){
  [[ -d "$PREPARED_DIR" && ! -L "$PREPARED_DIR" ]] || die "Invalid prepared directory."
  [[ "$(stat -c %u "$PREPARED_DIR")" == 0 && "$(stat -c %a "$PREPARED_DIR")" == 700 ]] || die "Prepared directory must be root-owned, mode 0700."
  PACKAGE_VERSION="$(cat "$PREPARED_DIR/package-version")"
  [[ "$PACKAGE_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Invalid prepared package version."
  [[ "$(cat "$PREPARED_DIR/architecture")" == "$ARCH" ]] || die "Prepared architecture mismatch."
  local asset="caddy-linux-${ARCH}" modules
  # Recheck the local bundle immediately before installation.
  (cd "$PREPARED_DIR" && grep -E "[[:space:]]+${asset}$" SHA256SUMS | sha256sum -c -) || die "Prepared checksum failed."
  [[ "$("$PREPARED_DIR/$asset" version | awk '{print $1}')" == "v$PACKAGE_VERSION" ]] || die "Prepared version mismatch."
  modules="$("$PREPARED_DIR/$asset" list-modules --packages)"
  grep -Fq "$MODULE_L4" <<<"$modules" || die "Missing caddy-l4."
  grep -Fq "$MODULE_CF_IP" <<<"$modules" || die "Missing Cloudflare IP module."
  grep -Fq 'caddy.adapters.jsonc github.com/caddyserver/caddy/v2' <<<"$modules" || die "Missing JSONC adapter."
  BUILD_DIR="$(mktemp -d)"
  install -m 0755 "$PREPARED_DIR/$asset" "$BUILD_DIR/$asset"
}

setup_custom_binary(){
  log "Registering stock and custom Caddy binaries"

  # Keep the package-managed binary behind a dpkg diversion. Package upgrades
  # then have one unambiguous destination for the stock binary.
  local diversion
  diversion="$(dpkg-divert --listpackage /usr/bin/caddy 2>/dev/null || true)"
  if [[ -z "$diversion" ]]; then
    dpkg-divert --add --rename --divert "$CADDY_DEFAULT" /usr/bin/caddy
  elif ! dpkg-divert --list /usr/bin/caddy | grep -Fq "$CADDY_DEFAULT"; then
    die "Unexpected existing dpkg diversion for /usr/bin/caddy; inspect it manually."
  fi

  [[ -x "$CADDY_DEFAULT" && -x "$CADDY_CUSTOM" ]] || die "Caddy binaries are incomplete."
  [[ "$("$CADDY_DEFAULT" version | awk '{print $1}')" == "v$PACKAGE_VERSION" ]] || die "Installed APT core version does not match prepared version."
  ln -sfn "$CADDY_CUSTOM" /usr/bin/caddy
  [[ "$(readlink -f /usr/bin/caddy)" == "$CADDY_CUSTOM" ]] || die "Custom Caddy is not selected."
}

setup_service(){
  install -d -m 0755 "$DROPIN_DIR"
  cat >"$DROPIN_FILE" <<'EOF'
[Service]
User=www-data
Group=www-data
Environment=HOME=/var/lib/caddy
ExecStart=
ExecStart=/usr/bin/caddy run --environ --config /etc/caddy/caddy.jsonc --adapter jsonc
ExecReload=
ExecReload=/usr/bin/caddy reload --config /etc/caddy/caddy.jsonc --adapter jsonc --force
EOF
  systemctl daemon-reload
}

prepare_paths(){
  # Caddy and PHP-FPM use the standard Debian web-service identity. sing-box is
  # configured the same way by install-sing-box-debian.sh, so all three can
  # access Caddy-managed certificates without ACLs or permission-sync scripts.
  install -d -o www-data -g www-data -m 0700 /var/lib/caddy
  chown -R www-data:www-data /var/lib/caddy
  install -d -o www-data -g www-data -m 0750 /var/log/caddy
  chown -R www-data:www-data /var/log/caddy
  chown root:www-data /etc/caddy; chmod 0750 /etc/caddy
  if [[ -f "$CONFIG" ]]; then chown root:www-data "$CONFIG"; chmod 0640 "$CONFIG"; fi
}

validate_installation(){
  log "Validating installed Caddy"
  /usr/bin/caddy version
  [[ "$NO_START" == true ]] && { log "Configuration validation skipped by --no-start."; return; }
  if [[ -f "$CONFIG" ]]; then
    runuser -u www-data -- env HOME=/var/lib/caddy /usr/bin/caddy validate --config "$CONFIG" --adapter jsonc
  else
    log "$CONFIG is absent; no configuration to validate yet."
  fi
  return 0
}

start_caddy(){
  # Successful installation must expose the www-data unit to deployment tools.
  # Disabled/stopped is enough to prevent boot startup; a mask hides User/ExecStart.
  systemctl unmask caddy >/dev/null
  systemctl daemon-reload
  if [[ "$NO_START" == true || ! -f "$CONFIG" ]]; then
    systemctl stop caddy
    systemctl disable caddy >/dev/null 2>&1
    log "Caddy installed: stopped, disabled and unmasked; configuration can now be deployed."
    systemctl show caddy -p User -p Group -p ExecStart --no-pager
    return 0
  fi
  systemctl enable caddy
  if ! systemctl restart caddy; then systemctl --no-pager --full status caddy || true; journalctl -u caddy -n 50 --no-pager || true; die "Caddy failed to start."; fi
  systemctl is-active --quiet caddy || die "Caddy is not active."
}

main(){
  parse_args "$@"
  preflight
  if [[ -n "$PREPARED_DIR" ]]; then
    load_prepared
  else
    install_caddy
    download_custom_caddy
  fi
  if [[ -n "$PREPARE_ONLY" ]]; then save_prepared; return 0; fi
  install_caddy_package
  setup_custom_binary
  setup_service
  prepare_paths
  RUNTIME_READY=true
  validate_installation
  start_caddy
  printf '\nCaddy installation completed.\n'
  /usr/bin/caddy version
}
main "$@"
