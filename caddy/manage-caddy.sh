#!/usr/bin/env bash
set -Eeuo pipefail

readonly CADDY_BIN="/usr/bin/caddy"
readonly CUSTOM_BIN="/usr/bin/caddy.custom"
readonly CONFIG="/etc/caddy/caddy.jsonc"
readonly BACKUP_ROOT="/var/backups/caddy-manager"

log(){ printf '[INFO] %s\n' "$*"; }
warn(){ printf '[WARN] %s\n' "$*" >&2; }
die(){ printf '[ERROR] %s\n' "$*" >&2; exit 1; }

require_root(){ [[ $EUID -eq 0 ]] || die "Run as root."; }

check_os(){
  . /etc/os-release
  [[ "$ID" == "debian" ]] || die "Debian only."
  case "$VERSION_ID" in 12|13) ;; *) warn "Debian $VERSION_ID is not explicitly tested.";; esac
}

check_legacy(){
  [[ -x /usr/local/bin/caddy ]] && warn "Legacy binary: /usr/local/bin/caddy"
  [[ -f /etc/systemd/system/caddy.service ]] && warn "Legacy local caddy.service detected."
  [[ -d /home/tls ]] && warn "Legacy TLS storage: /home/tls"
}

backup_current(){
  local d="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
  install -d -m 0700 "$d"
  for f in /usr/local/bin/caddy "$CUSTOM_BIN" "$CONFIG" /etc/systemd/system/caddy.service /etc/systemd/system/caddy.service.d/override.conf; do
    [[ -e "$f" ]] && cp -a --parents "$f" "$d/"
  done
  systemctl cat caddy.service >"$d/caddy.service.effective.txt" 2>/dev/null || true
  log "Backup: $d"
}

check_modules(){
  local bin="$CADDY_BIN" modules
  [[ -x "$bin" ]] || die "Missing $bin"
  modules="$("$bin" list-modules 2>/dev/null)" || die "Cannot list modules."
  grep -q 'layer4' <<<"$modules" || die "Missing caddy-l4."
  grep -q 'cloudflare' <<<"$modules" || die "Missing Cloudflare module."
  grep -q 'caddy.adapters.jsonc' <<<"$modules" || die "Missing jsonc adapter."
}

validate_config(){
  [[ -f "$CONFIG" ]] || die "Missing $CONFIG"
  "$CADDY_BIN" validate --config "$CONFIG" --adapter jsonc
}

status_cmd(){
  check_os
  command -v caddy || true
  caddy version 2>/dev/null || true
  update-alternatives --display caddy 2>/dev/null || true
  systemctl --no-pager --full status caddy.service || true
  check_legacy
}

check_cmd(){
  check_os
  check_modules
  validate_config
  systemctl is-enabled caddy.service >/dev/null 2>&1 || warn "caddy.service is not enabled."
  systemctl is-active caddy.service >/dev/null 2>&1 || warn "caddy.service is not active."
  log "Caddy checks passed."
}

install_cmd(){
  require_root
  check_os
  check_legacy
  backup_current
  if [[ -x /usr/local/bin/caddy || -f /etc/systemd/system/caddy.service || -d /home/tls ]]; then
    die "Legacy installation detected. v1 intentionally stops before migration."
  fi
  die "Fresh-install automation is safety-gated in v1 pending final APT/custom-binary implementation."
}

upgrade_cmd(){
  require_root
  check_os
  die "Upgrade is safety-gated in v1 pending build, validation, health-check and rollback implementation."
}

rollback_cmd(){
  require_root
  die "Automatic rollback is safety-gated in v1. Backups are under $BACKUP_ROOT."
}

usage(){
  echo "Usage: $0 {install|check|upgrade|rollback|status}"
}

case "${1:-}" in
  install) install_cmd ;;
  check) check_cmd ;;
  upgrade) upgrade_cmd ;;
  rollback) rollback_cmd ;;
  status) status_cmd ;;
  *) usage; exit 2 ;;
esac
