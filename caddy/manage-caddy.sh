#!/usr/bin/env bash
set -Eeuo pipefail

readonly CADDY_BIN="/usr/bin/caddy"
readonly CUSTOM_BIN="/usr/bin/caddy.custom"
readonly DEFAULT_BIN="/usr/bin/caddy.default"
readonly CONFIG="/etc/caddy/caddy.jsonc"
readonly DROPIN="/etc/systemd/system/caddy.service.d/override.conf"
readonly BACKUP_ROOT="/var/backups/caddy-manager"
readonly CADDY_DATA="/var/lib/caddy/.local/share/caddy"
readonly LEGACY_DATA="/home/tls"

log(){ printf '[INFO] %s\n' "$*"; }
warn(){ printf '[WARN] %s\n' "$*" >&2; }
die(){ printf '[ERROR] %s\n' "$*" >&2; exit 1; }
require_root(){ [[ $EUID -eq 0 ]] || die "Run as root."; }

check_os(){ . /etc/os-release; [[ "$ID" == "debian" ]] || die "Debian only."; case "$VERSION_ID" in 12|13) ;; *) warn "Debian $VERSION_ID is not explicitly tested.";; esac; }

legacy_present(){ [[ -x /usr/local/bin/caddy || -f /etc/systemd/system/caddy.service || -d "$LEGACY_DATA" ]]; }
check_legacy(){
  [[ -x /usr/local/bin/caddy ]] && warn "Legacy binary: /usr/local/bin/caddy"
  [[ -f /etc/systemd/system/caddy.service ]] && warn "Legacy local caddy.service detected."
  [[ -d "$LEGACY_DATA" ]] && warn "Legacy TLS storage: $LEGACY_DATA"
}

backup_current(){
  local d="$BACKUP_ROOT/$(date +%Y%m%d-%H%M%S)"
  install -d -m 0700 "$d"
  for f in /usr/local/bin/caddy "$CUSTOM_BIN" "$CONFIG" /etc/systemd/system/caddy.service "$DROPIN"; do
    [[ -e "$f" ]] && cp -a --parents "$f" "$d/"
  done
  [[ -d "$LEGACY_DATA" ]] && cp -a "$LEGACY_DATA" "$d/home-tls"
  systemctl cat caddy.service >"$d/caddy.service.effective.txt" 2>/dev/null || true
  log "Backup: $d"
}

check_modules(){
  local bin="${1:-$CADDY_BIN}" modules
  [[ -x "$bin" ]] || die "Missing $bin"
  modules="$("$bin" list-modules 2>/dev/null)" || die "Cannot list modules."
  grep -q 'layer4' <<<"$modules" || die "Missing caddy-l4."
  grep -q 'cloudflare' <<<"$modules" || die "Missing Cloudflare module."
  grep -q 'caddy.adapters.jsonc' <<<"$modules" || die "Missing jsonc adapter."
}

validate_config(){ local bin="${1:-$CADDY_BIN}"; [[ -f "$CONFIG" ]] || die "Missing $CONFIG"; "$bin" validate --config "$CONFIG" --adapter jsonc; }

install_official_repo(){
  apt-get update
  apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gnupg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | tee /etc/apt/sources.list.d/caddy-stable.list >/dev/null
  chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg /etc/apt/sources.list.d/caddy-stable.list
  apt-get update
  apt-get install -y caddy
}

install_custom_binary(){
  local source="${CADDY_CUSTOM_BINARY:-}"
  [[ -n "$source" && -x "$source" ]] || die "Set CADDY_CUSTOM_BINARY to an executable custom Caddy binary."
  check_modules "$source"
  if ! dpkg-divert --list "$CADDY_BIN" | grep -q .; then dpkg-divert --divert "$DEFAULT_BIN" --rename "$CADDY_BIN"; fi
  install -o root -g root -m 0755 "$source" "$CUSTOM_BIN"
  update-alternatives --install "$CADDY_BIN" caddy "$DEFAULT_BIN" 10
  update-alternatives --install "$CADDY_BIN" caddy "$CUSTOM_BIN" 50
  update-alternatives --auto caddy
}

install_dropin(){
  install -d -m 0755 "$(dirname "$DROPIN")"
  cat >"$DROPIN" <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/caddy run --environ --config /etc/caddy/caddy.jsonc --adapter jsonc
ExecReload=
ExecReload=/usr/bin/caddy reload --config /etc/caddy/caddy.jsonc --adapter jsonc --force
EOF
  systemctl daemon-reload
}

migrate_tls(){
  [[ -d "$LEGACY_DATA" ]] || return 0
  install -d -o caddy -g caddy -m 0700 "$CADDY_DATA"
  cp -a "$LEGACY_DATA"/. "$CADDY_DATA"/
  chown -R caddy:caddy "$CADDY_DATA"
  grep -q '/home/tls' "$CONFIG" && sed -i "s#/home/tls#$CADDY_DATA#g" "$CONFIG"
}

migrate_cmd(){
  require_root; check_os
  legacy_present || die "No legacy Caddy layout detected."
  [[ -f "$CONFIG" ]] || die "Missing $CONFIG"
  [[ -x /usr/local/bin/caddy ]] || die "Expected legacy /usr/local/bin/caddy."
  check_modules /usr/local/bin/caddy
  /usr/local/bin/caddy validate --config "$CONFIG" --adapter jsonc
  backup_current
  systemctl stop caddy.service || true
  local staged="/root/caddy-migrate-custom.$$"
  cp -a /usr/local/bin/caddy "$staged"
  rm -f /etc/systemd/system/caddy.service
  systemctl daemon-reload
  install_official_repo
  CADDY_CUSTOM_BINARY="$staged" install_custom_binary
  rm -f "$staged"
  migrate_tls
  install_dropin
  validate_config
  systemctl enable caddy.service
  if ! systemctl restart caddy.service || ! systemctl is-active --quiet caddy.service; then
    die "Migration validation/start failed. Backup is available under $BACKUP_ROOT; automatic rollback is not enabled yet."
  fi
  log "Legacy Caddy migration completed. Keep $LEGACY_DATA until post-migration verification is complete."
}

status_cmd(){ check_os; command -v caddy || true; caddy version 2>/dev/null || true; update-alternatives --display caddy 2>/dev/null || true; systemctl --no-pager --full status caddy.service || true; check_legacy; }
check_cmd(){ check_os; check_modules; validate_config; systemctl is-enabled caddy.service >/dev/null 2>&1 || warn "caddy.service is not enabled."; systemctl is-active caddy.service >/dev/null 2>&1 || warn "caddy.service is not active."; log "Caddy checks passed."; }

install_cmd(){
  require_root; check_os; check_legacy
  legacy_present && { backup_current; die "Legacy installation detected. Use: $0 migrate"; }
  [[ -f "$CONFIG" ]] || die "Place caddy.jsonc at $CONFIG before installation."
  backup_current
  install_official_repo
  install_custom_binary
  install_dropin
  validate_config
  systemctl enable --now caddy.service
  systemctl is-active --quiet caddy.service || die "caddy.service failed to start."
  log "Caddy installation completed."
}

upgrade_cmd(){ require_root; check_os; die "Upgrade remains safety-gated pending automatic rollback implementation."; }
rollback_cmd(){ require_root; die "Automatic rollback remains safety-gated. Backups are under $BACKUP_ROOT."; }

usage(){
  cat <<EOF
Usage: $0 {install|migrate|check|upgrade|rollback|status}

Fresh install:
  CADDY_CUSTOM_BINARY=/path/to/custom-caddy sudo -E $0 install

Legacy migration:
  sudo $0 migrate
EOF
}

case "${1:-}" in
  install) install_cmd ;;
  migrate) migrate_cmd ;;
  check) check_cmd ;;
  upgrade) upgrade_cmd ;;
  rollback) rollback_cmd ;;
  status) status_cmd ;;
  *) usage; exit 2 ;;
esac
