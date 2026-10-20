#!/usr/bin/env bash
# Install Caddy Stable package support on Debian 12/13 and Ubuntu 24.04/26.04
# and select the matching prebuilt custom binary from choicky/caddy-custom-build.
# The managed runtime state (drop-in, identity, permissions) is established by
# the shared normalization component, not duplicated here.
set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly NORMALIZE="${SCRIPT_DIR}/normalize-caddy-services.sh"
readonly CONFIG="/etc/caddy/caddy.jsonc"
readonly CADDY_DEFAULT="/usr/bin/caddy.default"
readonly CADDY_CUSTOM="/usr/bin/caddy.custom"
readonly RELEASE_REPO="choicky/caddy-custom-build"
readonly MODULE_L4="github.com/mholt/caddy-l4"
readonly MODULE_CF_IP="github.com/WeidiDeng/caddy-cloudflare-ip"
readonly OS_RELEASE="/etc/os-release"
readonly CADDY_REPO_PREFIX="https://dl.cloudsmith.io/public/caddy/stable/"
readonly SUPPORTED_DISTRIBUTIONS="Debian 12, Debian 13, Ubuntu 24.04 LTS, Ubuntu 26.04 LTS"
DISTRO_LABEL=""
NO_START=false
CHECK_OS=false
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
usage(){ printf 'Usage: %s [--no-start] [--check-os]\n' "$0"; }

parse_args(){ while (( $# )); do case "$1" in --no-start) NO_START=true;; --check-os) CHECK_OS=true;; -h|--help) usage; exit 0;; *) usage >&2; die "Unknown option: $1";; esac; shift; done; }

require_supported_os(){
  [[ -f "$OS_RELEASE" && -r "$OS_RELEASE" && -s "$OS_RELEASE" ]] \
    || die "Cannot read a non-empty regular file at $OS_RELEASE; refusing to guess the distribution."
  local ID="" VERSION_ID=""
  # shellcheck disable=SC1090
  . "$OS_RELEASE" || die "$OS_RELEASE is not a parsable os-release file."
  case "${ID:-}" in
    debian)
      case "${VERSION_ID:-}" in
        12|13) DISTRO_LABEL="Debian ${VERSION_ID}"; return 0;;
        *) die "Debian '${VERSION_ID:-unknown}' is not supported. Supported: ${SUPPORTED_DISTRIBUTIONS}.";;
      esac;;
    ubuntu)
      case "${VERSION_ID:-}" in
        24.04|26.04) DISTRO_LABEL="Ubuntu ${VERSION_ID} LTS"; return 0;;
        *) die "Ubuntu '${VERSION_ID:-unknown}' is not supported. Supported: ${SUPPORTED_DISTRIBUTIONS}.";;
      esac;;
    "") die "$OS_RELEASE has no ID field; refusing to guess the distribution.";;
    *) die "Distribution '${ID}' is not supported. Having apt-get is not sufficient. Supported: ${SUPPORTED_DISTRIBUTIONS}.";;
  esac
}

caddy_repo_candidate(){
  # Echo the APT candidate version, but only when the candidate is published by
  # the official Caddy repository. Ubuntu also ships its own distro build of
  # caddy (Debian does not), so a version alone cannot prove that the
  # caddy-stable source actually loaded.
  #
  # A repository line belongs to the version entry printed directly above it
  # and to no other version: the Installed and Candidate header lines repeat
  # those versions without any origin, so matching a version number anywhere in
  # the output would attribute the first repository line to the wrong version.
  local policy raw origins origin first approved
  policy="$(LC_ALL=C apt-cache policy caddy)"
  raw="$(sed -n 's/^ *Candidate: \([^ ]*\).*/\1/p' <<<"$policy")"
  [[ -n "$raw" && "$raw" != '(none)' ]] || die "No Caddy APT candidate available."
  origins="$(awk -v want="$raw" '
    /^[[:space:]]*Version table:/ { table = 1; next }
    /^[^[:space:]]/ { table = 0; cur = ""; next }
    !table { next }
    $1 ~ /^[0-9]+$/ && $2 ~ /^[a-z][a-z0-9+.-]*:/ { if (cur == want) print $2; next }
    $NF ~ /^[0-9]+$/ { cur = ($1 == "***" || $1 == "::") ? $2 : $1 }
  ' <<<"$policy")"
  [[ -n "$origins" ]] \
    || die "The Caddy APT candidate $raw has no repository origin in the apt-cache policy version table; refusing to guess where it comes from."
  approved=false
  first=''
  while IFS= read -r origin; do
    [[ -n "$origin" ]] || continue
    [[ -n "$first" ]] || first="$origin"
    case "$origin" in "$CADDY_REPO_PREFIX"*) approved=true;; esac
  done <<<"$origins"
  [[ "$approved" == true ]] \
    || die "The Caddy APT candidate $raw comes from '${first}', not the official Caddy repository at ${CADDY_REPO_PREFIX}. The caddy-stable source probably failed to load (network or signing-key problem) and this is a distribution build; fix the repository before continuing."
  printf '%s\n' "$raw"
}

preflight(){
  [[ ${EUID} -eq 0 ]] || die "Run this script as root."
  require_supported_os
  getent passwd www-data >/dev/null || die "User 'www-data' does not exist."
  getent group www-data >/dev/null || die "Group 'www-data' does not exist."
  [[ ! -e /usr/local/bin/caddy ]] || die "Existing /usr/local/bin/caddy detected. Use caddy/migrate-caddy-deployment.sh."
  case "$(dpkg --print-architecture)" in amd64) ARCH=amd64;; arm64) ARCH=arm64;; *) die "Unsupported architecture: $(dpkg --print-architecture). Only amd64 and arm64 are provided.";; esac
  case "$(systemctl is-enabled caddy 2>/dev/null || true)" in
    masked|masked-runtime) WAS_MASKED=true;;
  esac
  log "Environment: ${DISTRO_LABEL}, architecture: ${ARCH}"
}

install_caddy(){
  log "Preparing the official Caddy APT repository"

  apt-get update
  # The Cloudsmith repository carries its own signed-by keyring and modern apt
  # speaks HTTPS natively, so debian-keyring/debian-archive-keyring/
  # apt-transport-https are not consulted here. They are also universe-only
  # packages on Ubuntu, where a disabled universe pocket would abort install.
  apt-get install -y ca-certificates curl gpg
  curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/gpg.key | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt -o /etc/apt/sources.list.d/caddy-stable.list
  chmod 0644 /usr/share/keyrings/caddy-stable-archive-keyring.gpg /etc/apt/sources.list.d/caddy-stable.list
  apt-get update
  # Resolve the repository candidate before touching the running service.
  PACKAGE_VERSION="$(caddy_repo_candidate)"
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
  DEBIAN_FRONTEND=noninteractive apt-get install -y -o Dpkg::Options::="--force-confold" "caddy=$PACKAGE_VERSION"
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
  apt-get install --download-only -y "caddy=$PACKAGE_VERSION"
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
  ln -sfn "$CADDY_CUSTOM" /usr/bin/caddy
  [[ "$(readlink -f /usr/bin/caddy)" == "$CADDY_CUSTOM" ]] || die "Custom Caddy is not selected."
}

setup_service(){
  # The shared normalizer owns the managed drop-in and path permissions so
  # install/update/migrate cannot drift apart from each other.
  log "Normalizing the managed caddy service state"
  [[ -f "$NORMALIZE" ]] || die "Missing normalization component: $NORMALIZE"
  bash "$NORMALIZE" --caddy
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

expose_unit(){
  # Normalization inspects effective unit properties, which requires the unit
  # to be unmasked. start_caddy still re-applies the final enable/restart or
  # stop/disable state afterwards.
  log "Exposing the unit for normalization"
  systemctl unmask caddy >/dev/null
  systemctl daemon-reload
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
  # --check-os reports the detected distribution without root privileges and
  # without touching APT, systemd or files, so callers can validate the
  # supported matrix before doing any work.
  if [[ "$CHECK_OS" == true ]]; then
    require_supported_os
    printf '%s\n' "$DISTRO_LABEL"
    exit 0
  fi
  preflight; install_caddy; download_custom_caddy; install_caddy_package; setup_custom_binary; expose_unit; setup_service; RUNTIME_READY=true; validate_installation; start_caddy; printf '\nCaddy installation completed.\n'; /usr/bin/caddy version;
}
main "$@"
