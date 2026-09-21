#!/usr/bin/env bash
# Upgrade Caddy Stable on the standard linux_scripts layout.
# The matching prebuilt custom binary is downloaded and verified before APT
# changes the installed package, so an unavailable custom release is harmless.
set -Eeuo pipefail

readonly CONFIG="/etc/caddy/caddy.jsonc"
readonly CADDY_DEFAULT="/usr/bin/caddy.default"
readonly CADDY_CUSTOM="/usr/bin/caddy.custom"
readonly RELEASE_REPO="choicky/caddy-custom-build"
readonly MODULE_L4="github.com/mholt/caddy-l4"
readonly MODULE_CF_IP="github.com/WeidiDeng/caddy-cloudflare-ip"

TMPDIR=""
BACKUP_CUSTOM=""
SERVICE_WAS_ACTIVE=false
SERVICE_WAS_ENABLED=false
SERVICE_TOUCHED=false

log(){ printf '\n==> %s\n' "$*"; }
die(){ printf '\nERROR: %s\n' "$*" >&2; exit 1; }

cleanup(){
  [[ -z "$TMPDIR" ]] || rm -rf "$TMPDIR"
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
}

candidate_version(){
  apt-get update
  local raw
  raw="$(apt-cache policy caddy | awk '/Candidate:/ {print $2; exit}')"
  [[ -n "$raw" && "$raw" != "(none)" ]] || die "No Caddy candidate is available from APT."
  # Debian package versions may include a revision; the upstream binary version
  # is the leading semantic version.
  if [[ "$raw" =~ ^([0-9]+\.[0-9]+\.[0-9]+) ]]; then
    printf 'v%s\n' "${BASH_REMATCH[1]}"
  else
    die "Cannot map APT candidate version to an upstream Caddy version: $raw"
  fi
}

download_and_verify(){
  local version="$1" asset modules
  asset="caddy-linux-${ARCH}"
  TMPDIR="$(mktemp -d)"

  log "Downloading matching custom Caddy ${version} before upgrading APT"
  curl -fL --retry 3 -o "${TMPDIR}/${asset}" "https://github.com/${RELEASE_REPO}/releases/download/${version}/${asset}" ||
    die "Matching custom Caddy release ${version} is not available. APT Caddy was not changed."
  curl -fL --retry 3 -o "${TMPDIR}/SHA256SUMS" "https://github.com/${RELEASE_REPO}/releases/download/${version}/SHA256SUMS" ||
    die "SHA256SUMS for custom Caddy ${version} is not available. APT Caddy was not changed."

  (cd "$TMPDIR" && grep -E "[[:space:]]+${asset}$" SHA256SUMS | sha256sum -c -) ||
    die "SHA256 verification failed. APT Caddy was not changed."

  chmod 0755 "${TMPDIR}/${asset}"
  [[ "$(version_of "${TMPDIR}/${asset}")" == "$version" ]] || die "Downloaded custom Caddy has the wrong version."

  modules="$("${TMPDIR}/${asset}" list-modules --packages)"
  grep -Fq "$MODULE_L4" <<<"$modules" || die "Downloaded custom Caddy is missing caddy-l4."
  grep -Fq "$MODULE_CF_IP" <<<"$modules" || die "Downloaded custom Caddy is missing caddy-cloudflare-ip."
  grep -Fq 'caddy.adapters.jsonc github.com/caddyserver/caddy/v2' <<<"$modules" || die "Downloaded custom Caddy is missing built-in JSONC support."

  log "Validating the current configuration with the new custom binary"
  runuser -u www-data -- env HOME=/var/lib/caddy "${TMPDIR}/${asset}" validate --config "$CONFIG" --adapter jsonc
}

rollback_runtime(){
  local rc="$1"
  trap - ERR
  printf '\nERROR: Caddy upgrade failed after the service was touched. Attempting runtime rollback...\n' >&2

  if [[ -n "$BACKUP_CUSTOM" && -f "$BACKUP_CUSTOM" ]]; then
    install -m 0755 "$BACKUP_CUSTOM" "$CADDY_CUSTOM" || true
    ln -sfn "$CADDY_CUSTOM" /usr/bin/caddy || true
  fi

  systemctl unmask caddy >/dev/null 2>&1 || true
  if [[ "$SERVICE_WAS_ENABLED" == true ]]; then
    systemctl enable caddy >/dev/null 2>&1 || true
  fi
  if [[ "$SERVICE_WAS_ACTIVE" == true ]]; then
    systemctl restart caddy >/dev/null 2>&1 || true
  fi

  systemctl --no-pager --full status caddy >&2 || true
  journalctl -u caddy -n 50 --no-pager >&2 || true
  exit "$rc"
}

upgrade(){
  local target="$1" asset="caddy-linux-${ARCH}"

  BACKUP_CUSTOM="${TMPDIR}/caddy.custom.old"
  cp -a "$CADDY_CUSTOM" "$BACKUP_CUSTOM"

  log "Stopping and masking Caddy"
  SERVICE_TOUCHED=true
  trap 'rollback_runtime $?' ERR
  systemctl stop caddy
  systemctl mask caddy >/dev/null

  log "Upgrading the official Caddy APT package"
  DEBIAN_FRONTEND=noninteractive apt-get install -y --only-upgrade -o Dpkg::Options::="--force-confold" caddy

  [[ "$(version_of "$CADDY_DEFAULT")" == "$target" ]] ||
    die "APT Caddy version does not match prepared custom Caddy ${target}."

  log "Installing the verified custom Caddy"
  install -m 0755 "${TMPDIR}/${asset}" "$CADDY_CUSTOM"
  ln -sfn "$CADDY_CUSTOM" /usr/bin/caddy

  [[ "$(version_of /usr/bin/caddy)" == "$target" ]] || die "Active custom Caddy version mismatch."

  log "Validating configuration as www-data"
  runuser -u www-data -- env HOME=/var/lib/caddy /usr/bin/caddy validate --config "$CONFIG" --adapter jsonc

  systemctl unmask caddy >/dev/null
  systemctl enable caddy >/dev/null
  systemctl restart caddy
  systemctl is-active --quiet caddy || die "Caddy is not active after upgrade."

  trap - ERR
  SERVICE_TOUCHED=false
}

main(){
  preflight

  local current target
  current="$(version_of "$CADDY_DEFAULT")"
  target="$(candidate_version)"

  log "Caddy versions"
  printf 'Installed APT Caddy: %s\n' "$current"
  printf 'APT candidate:       %s\n' "$target"

  if [[ "$current" == "$target" ]]; then
    printf '\nCaddy is already up to date.\n'
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
