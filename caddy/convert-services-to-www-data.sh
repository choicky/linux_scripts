#!/usr/bin/env bash
# One-time conversion for servers already migrated with the earlier layout:
# run Caddy and sing-box as www-data:www-data without reinstalling packages.
set -Eeuo pipefail

CADDY_CONFIG=/etc/caddy/caddy.jsonc
SINGBOX_CONFIG=/etc/sing-box/config.json

log(){ printf '\n==> %s\n' "$*"; }
die(){ printf '\nERROR: %s\n' "$*" >&2; if [[ "${CHANGED:-false}" == true ]]; then rollback 1; fi; exit 1; }

[[ ${EUID} -eq 0 ]] || die "Run this script as root."
getent passwd www-data >/dev/null || die "User 'www-data' does not exist."
getent group www-data >/dev/null || die "Group 'www-data' does not exist."
[[ -f "$CADDY_CONFIG" ]] || die "Missing $CADDY_CONFIG"
[[ -f "$SINGBOX_CONFIG" ]] || die "Missing $SINGBOX_CONFIG"

# Back up overrides and permission metadata before changing either service.
BACKUP_DIR="$(mktemp -d /root/www-data-conversion.XXXXXXXX)"
CHANGED=false
for service in caddy sing-box; do
  if systemctl is-active --quiet "$service"; then
    touch "$BACKUP_DIR/$service.active"
  fi
  if [[ -f "/etc/systemd/system/$service.service.d/override.conf" ]]; then
    cp -a "/etc/systemd/system/$service.service.d/override.conf" "$BACKUP_DIR/$service.override"
  fi
done
for path in /var/lib/caddy /var/log/caddy /var/lib/sing-box /var/log/sing-box /etc/caddy /etc/sing-box; do
  if [[ -e "$path" ]]; then
    find "$path" -printf '%m %U %G %p\0' >> "$BACKUP_DIR/permissions"
  fi
done
rollback() {
  local rc="$1" mode uid gid path entry service
  trap - ERR
  set +e
  echo "ERROR: conversion failed; restoring overrides and permissions." >&2
  systemctl stop caddy sing-box
  for service in caddy sing-box; do
    if [[ -f "$BACKUP_DIR/$service.override" ]]; then
      cp -a "$BACKUP_DIR/$service.override" "/etc/systemd/system/$service.service.d/override.conf"
    else
      rm -f "/etc/systemd/system/$service.service.d/override.conf"
    fi
  done
  while IFS= read -r -d '' entry; do
    mode=${entry%% *}; entry=${entry#* }
    uid=${entry%% *}; entry=${entry#* }
    gid=${entry%% *}; path=${entry#* }
    chown -h "$uid:$gid" "$path"
    [[ -L "$path" ]] || chmod "$mode" "$path"
  done < "$BACKUP_DIR/permissions"
  systemctl daemon-reload
  for service in caddy sing-box; do
    if [[ -f "$BACKUP_DIR/$service.active" ]]; then
      systemctl start "$service" || systemctl --no-pager --full status "$service"
    fi
  done
  echo "Backup retained: $BACKUP_DIR" >&2
  exit "$rc"
}
trap 'rollback $?' ERR
CHANGED=true
log "Stopping Caddy and sing-box"
systemctl stop caddy sing-box

log "Updating service overrides"
install -d -m 0755 /etc/systemd/system/caddy.service.d
cat >/etc/systemd/system/caddy.service.d/override.conf <<'EOF'
[Service]
User=www-data
Group=www-data
Environment=HOME=/var/lib/caddy
ExecStart=
ExecStart=/usr/bin/caddy run --environ --config /etc/caddy/caddy.jsonc --adapter jsonc
ExecReload=
ExecReload=/usr/bin/caddy reload --config /etc/caddy/caddy.jsonc --adapter jsonc --force
EOF

install -d -m 0755 /etc/systemd/system/sing-box.service.d
cat >/etc/systemd/system/sing-box.service.d/override.conf <<'EOF'
[Service]
User=www-data
Group=www-data
StateDirectoryMode=0750
EOF

log "Updating ownership"
install -d -o www-data -g www-data -m 0700 /var/lib/caddy
chown -R www-data:www-data /var/lib/caddy
install -d -o www-data -g www-data -m 0750 /var/log/caddy
chown -R www-data:www-data /var/log/caddy
chown root:www-data /etc/caddy "$CADDY_CONFIG"
chmod 0750 /etc/caddy
chmod 0640 "$CADDY_CONFIG"

install -d -o www-data -g www-data -m 0750 /var/lib/sing-box
chown -R www-data:www-data /var/lib/sing-box
if [[ -d /var/log/sing-box ]]; then
  chown -R www-data:www-data /var/log/sing-box
fi
chown root:www-data /etc/sing-box "$SINGBOX_CONFIG"
chmod 0750 /etc/sing-box
chmod 0640 "$SINGBOX_CONFIG"

systemctl daemon-reload

log "Validating configurations as www-data"
runuser -u www-data -- env HOME=/var/lib/caddy /usr/bin/caddy validate --config "$CADDY_CONFIG" --adapter jsonc
runuser -u www-data -- /usr/bin/sing-box check -c "$SINGBOX_CONFIG"

log "Starting services"
systemctl restart caddy
systemctl restart sing-box
systemctl is-active --quiet caddy || die "Caddy is not active."
sleep 1
[[ "$(systemctl is-active sing-box)" == active ]] || {
  systemctl --no-pager --full status sing-box || true
  journalctl -u sing-box -n 30 --no-pager || true
  die "sing-box is not active."
}

CHANGED=false
trap - ERR
log "Current runtime identities"
systemctl show caddy -p User -p Group
systemctl show sing-box -p User -p Group
ps -eo user,group,pid,comm | grep -E '[c]addy|[s]ing-box' || true

printf '\nConversion completed. Backup: %s\n' "$BACKUP_DIR"
