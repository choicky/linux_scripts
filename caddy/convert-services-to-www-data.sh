#!/usr/bin/env bash
# One-time conversion for servers already migrated with the earlier layout:
# run Caddy and sing-box as www-data:www-data without reinstalling packages.
set -Eeuo pipefail

CADDY_CONFIG=/etc/caddy/caddy.jsonc
SINGBOX_CONFIG=/etc/sing-box/config.json

log(){ printf '\n==> %s\n' "$*"; }
die(){ printf '\nERROR: %s\n' "$*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || die "Run this script as root."
getent passwd www-data >/dev/null || die "User 'www-data' does not exist."
getent group www-data >/dev/null || die "Group 'www-data' does not exist."
[[ -f "$CADDY_CONFIG" ]] || die "Missing $CADDY_CONFIG"
[[ -f "$SINGBOX_CONFIG" ]] || die "Missing $SINGBOX_CONFIG"

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
EOF

log "Updating ownership"
chown -R www-data:www-data /var/lib/caddy
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

log "Current runtime identities"
systemctl show caddy -p User -p Group
systemctl show sing-box -p User -p Group
ps -eo user,group,pid,comm | grep -E '[c]addy|[s]ing-box' || true

printf '\nConversion completed.\n'
