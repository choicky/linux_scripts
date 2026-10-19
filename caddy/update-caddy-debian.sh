#!/usr/bin/env bash
# Upgrade Caddy Stable on the standard linux_scripts layout.
# The matching prebuilt custom binary is downloaded and verified before APT
# changes the installed package, so an unavailable custom release is harmless.
# Even when no upgrade is needed, the shared normalization component still
# reconciles the managed service state and verifies APT protection.
set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly NORMALIZE="${SCRIPT_DIR}/normalize-caddy-services.sh"
readonly CONFIG="/etc/caddy/caddy.jsonc"
readonly CADDY_DEFAULT="/usr/bin/caddy.default"
readonly CADDY_CUSTOM="/usr/bin/caddy.custom"
readonly RELEASE_REPO="choicky/caddy-custom-build"
readonly MODULE_L4="github.com/mholt/caddy-l4"
readonly MODULE_CF_IP="github.com/WeidiDeng/caddy-cloudflare-ip"

BUILD_DIR=""
BACKUP_CUSTOM=""
SERVICE_WAS_ACTIVE=false
SERVICE_WAS_ENABLED=false
SERVICE_TOUCHED=false

log(){ printf '\n==> %s\n' "$*"; }
die(){ printf '\nERROR: %s\n' "$*" >&2; if [[ "$SERVICE_TOUCHED" == true ]]; then rollback_runtime 1; fi; exit 1; }

cleanup(){
  [[ -z "$BUILD_DIR" ]] || rm -rf "$BUILD_DIR"
}
trap cleanup EXIT

version_of(){
  "$1" version | awk '{print $1}'
}

preflight(){
  [[ ${EUID} -eq 0 ]] || die "Run this script as root."
  . /etc/os-release
  [[ ${ID:-} == debian ]] || die "Only Debian is supported."
  case "${VERSION_ID:-}" in 12|13);; *) die "Only Debian 12 and Debian 13 are supported.";; esac
  getent passwd www-data >/dev/null || die "User 'www-data' does not exist."
  [[ -f "$CONFIG" ]] || die "Missing $CONFIG"
  [[ -x "$CADDY_DEFAULT" ]] || die "Missing $CADDY_DEFAULT; use install-caddy-debian.sh first."
  [[ -x "$CADDY_CUSTOM" ]] || die "Missing $CADDY_CUSTOM; use install-caddy-debian.sh first."
  [[ -L /usr/bin/caddy ]] || die "/usr/bin/caddy is not the expected symlink."
  [[ "$(readlink -f /usr/bin/caddy)" == "$CADDY_CUSTOM" ]] || die "/usr/bin/caddy does not point to $CADDY_CUSTOM."
  dpkg-query -W -f='${Status}\n' caddy 2>/dev/null | grep -Fxq 'install ok installed' || die "APT package caddy is not installed."
  dpkg-divert --list /usr/bin/caddy | grep -Fq "$CADDY_DEFAULT" || die "Expected dpkg diversion to $CADDY_DEFAULT is missing."
  case "$(dpkg --print-architecture)" in amd64) ARCH=amd64;; arm64) ARCH=arm64;; *) die "Unsupported architecture.";; esac
  systemctl is-active --quiet caddy && SERVICE_WAS_ACTIVE=true
  systemctl is-enabled --quiet caddy && SERVICE_WAS_ENABLED=true
  return 0
}

candidate_version(){
  apt-get update >&2
  local raw
  raw="$(LC_ALL=C apt-cache policy caddy | awk '/Candidate:/ {print $2; exit}')"
  [[ -n "$raw" && "$raw" != "(none)" ]] || die "No Caddy candidate is available from APT."
  raw="${raw#*:}"
  if [[ "$raw" =~ ^([0-9]+\.[0-9]+\.[0-9]+)([-+~].*)?$ ]]; then
    printf 'v%s\n' "${BASH_REMATCH[1]}"
  else
    die "Cannot map APT candidate version to an upstream Caddy version: $raw"
  fi
}

download_and_verify(){
  local version="$1" asset modules
  asset="caddy-linux-${ARCH}"
  BUILD_DIR="$(mktemp -d)"

  log "Downloading matching custom Caddy ${version} before upgrading APT"
  curl -fL --retry 3 -o "${BUILD_DIR}/${asset}" "https://github.com/${RELEASE_REPO}/releases/download/${version}/${asset}" ||
    die "Matching custom Caddy release ${version} is not available. APT Caddy was not changed."
  curl -fL --retry 3 -o "${BUILD_DIR}/SHA256SUMS" "https://github.com/${RELEASE_REPO}/releases/download/${version}/SHA256SUMS" ||
    die "SHA256SUMS for custom Caddy ${version} is not available. APT Caddy was not changed."

  (cd "$BUILD_DIR" && grep -E "[[:space:]]+${asset}$" SHA256SUMS | sha256sum -c -) ||
    die "SHA256 verification failed. APT Caddy was not changed."

  chmod 0755 "${BUILD_DIR}/${asset}"
  [[ "$(version_of "${BUILD_DIR}/${asset}")" == "$version" ]] || die "Downloaded custom Caddy has the wrong version."

  modules="$("${BUILD_DIR}/${asset}" list-modules --packages)"
  grep -Fq "$MODULE_L4" <<<"$modules" || die "Downloaded custom Caddy is missing caddy-l4."
  grep -Fq "$MODULE_CF_IP" <<<"$modules" || die "Downloaded custom Caddy is missing caddy-cloudflare-ip."
  grep -Fq 'caddy.adapters.jsonc github.com/caddyserver/caddy/v2' <<<"$modules" || die "Downloaded custom Caddy is missing built-in JSONC support."

  # mktemp creates a root-only directory; www-data must traverse it to validate.
  chmod 0711 "$BUILD_DIR"
  log "Validating the current configuration with the new custom binary"
  runuser -u www-data -- env HOME=/var/lib/caddy "${BUILD_DIR}/${asset}" validate --config "$CONFIG" --adapter jsonc
  apt-get install --download-only -y --only-upgrade "caddy=$PACKAGE_VERSION"
}

rollback_runtime(){
  local rc="$1"
  trap - ERR
  printf '\nERROR: Caddy upgrade failed after the service was touched. Attempting runtime rollback...\n' >&2

  if [[ -n "$BACKUP_CUSTOM" && -f "$BACKUP_CUSTOM" ]]; then
    install -m 0755 "$BACKUP_CUSTOM" "$CADDY_CUSTOM" || true
    ln -sfn "$CADDY_CUSTOM" /usr/bin/caddy || true
  fi

  systemctl stop caddy >/dev/null 2>&1 || true
  systemctl unmask caddy >/dev/null 2>&1 || true
  if [[ "$SERVICE_WAS_ENABLED" == true ]]; then
    systemctl enable caddy >/dev/null 2>&1 || true
  else
    systemctl disable caddy >/dev/null 2>&1 || true
  fi
  if [[ "$SERVICE_WAS_ACTIVE" == true ]]; then
    systemctl restart caddy >/dev/null 2>&1 || true
  fi

  systemctl --no-pager --full status caddy >&2 || true
  journalctl -u caddy -n 50 --no-pager >&2 || true
  exit "$rc"
}

normalize_state(){
  # Reconcile the managed drop-in/identity/permissions and re-assert that the
  # dpkg diversion and the /usr/bin/caddy symlink still select the custom
  # binary (verified in preflight). dpkg-divert is the protection mechanism:
  # a plain `apt upgrade` moves the stock binary to $CADDY_DEFAULT behind the
  # diversion, so the running deployment keeps using the verified custom
  # binary. No apt-mark hold or pinning is used because each would block the
  # stock security updates that this script needs as its version source.
  log "Reconciling managed service state"
  [[ -f "$NORMALIZE" ]] || die "Missing normalization component: $NORMALIZE"
  bash "$NORMALIZE" --caddy
}

upgrade(){
  local target="$1" asset="caddy-linux-${ARCH}"

  BACKUP_CUSTOM="${BUILD_DIR}/caddy.custom.old"
  cp -a "$CADDY_CUSTOM" "$BACKUP_CUSTOM"

  log "Stopping and masking Caddy"
  SERVICE_TOUCHED=true
  trap 'rollback_runtime $?' ERR
  systemctl stop caddy
  systemctl mask caddy >/dev/null

  log "Upgrading the official Caddy APT package"
  DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade -o Dpkg::Options::="--force-confold" "caddy=$PACKAGE_VERSION"

  [[ "$(version_of "$CADDY_DEFAULT")" == "$target" ]] ||
    die "APT Caddy version does not match prepared custom Caddy ${target}."

  log "Installing the verified custom Caddy"
  install -m 0755 "${BUILD_DIR}/${asset}" "$CADDY_CUSTOM"
  ln -sfn "$CADDY_CUSTOM" /usr/bin/caddy

  [[ "$(version_of /usr/bin/caddy)" == "$target" ]] || die "Active custom Caddy version mismatch."

  log "Validating configuration as www-data"
  runuser -u www-data -- env HOME=/var/lib/caddy /usr/bin/caddy validate --config "$CONFIG" --adapter jsonc

  systemctl unmask caddy >/dev/null
  if [[ "$SERVICE_WAS_ENABLED" == true ]]; then
    systemctl enable caddy >/dev/null
  else
    systemctl disable caddy >/dev/null
  fi

  # Reconcile unit state before the restart so a single restart applies both
  # the new binary and any corrected drop-in without restarting twice.
  normalize_state

  if [[ "$SERVICE_WAS_ACTIVE" == true ]]; then
    systemctl restart caddy
    systemctl is-active --quiet caddy || die "Caddy is not active after upgrade."
  fi

  trap - ERR
  SERVICE_TOUCHED=false
}

main(){
  preflight

  local current target
  current="$(version_of "$CADDY_DEFAULT")"
  target="$(candidate_version)"
  PACKAGE_VERSION="$(LC_ALL=C apt-cache policy caddy | awk '/Candidate:/ {print $2; exit}')"

  log "Caddy versions"
  printf 'Installed APT Caddy: %s\n' "$current"
  printf 'APT candidate:       %s\n' "$target"

  if [[ "$current" == "$target" && "$(version_of "$CADDY_CUSTOM")" == "$target" ]]; then
    printf '\nCaddy is already up to date.\n'
    # The no-upgrade path still reconciles managed state; it must not exit
    # before normalization or the APT protection check above.
    normalize_state
    exit 0
  fi

  download_and_verify "$target"
  upgrade "$target"

  log "Upgrade completed"
  printf 'Stock Caddy:  %s\n' "$(version_of "$CADDY_DEFAULT")"
  printf 'Custom Caddy: %s\n' "$(version_of "$CADDY_CUSTOM")"
  printf 'Active Caddy: %s\n' "$(version_of /usr/bin/caddy)"
  systemctl show caddy -p User -p Group
}

main "$@"
