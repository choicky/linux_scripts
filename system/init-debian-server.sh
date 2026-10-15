#!/bin/bash
set -euo pipefail

# Safe baseline initializer for fresh Debian 12/13 VPS instances.
# Phase 1 prepares the host and creates/verifies an administrative sudo user.
# Phase 2 hardens SSH only after that user has been tested in a separate SSH session.

usage() {
  cat <<'EOF'
Usage:
  sudo bash system/init-debian-server.sh prepare --user USER [--swap-gib N] [--timezone ZONE] [--authorized-key FILE]
  sudo env SSH_CONNECTION="$SSH_CONNECTION" bash system/init-debian-server.sh harden --user USER [--client-host HOST]
  sudo bash system/init-debian-server.sh status  --user USER

Defaults:
  --swap-gib 2
  --timezone Asia/Shanghai

Workflow:
  1. Run "prepare".
  2. In a NEW terminal, verify: ssh USER@server ; sudo -v ; sudo whoami
  3. Keep that verified session open and run "harden".
  4. Open another new terminal and verify USER can still log in.

Password authentication intentionally remains enabled. Direct root SSH login is
disabled only in the explicit "harden" phase.
EOF
}

die() { echo "FAILED: $*" >&2; exit 1; }
log() { printf '\n==> %s\n' "$*"; }
ok() { echo "OK: $*"; }
changed() { echo "CHANGED: $*"; }
skipped() { echo "SKIPPED: $*"; }

[[ $EUID -eq 0 ]] || die "Run this script as root (or via sudo)."

ACTION="${1:-}"
[[ -n "$ACTION" ]] || { usage; exit 1; }
shift

ADMIN_USER=""
AUTHORIZED_KEY=""
CLIENT_HOST=""
SWAP_GIB=2
TIMEZONE="Asia/Shanghai"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) [[ $# -ge 2 ]] || die "--user requires a value"; ADMIN_USER="$2"; shift 2 ;;
    --swap-gib) [[ $# -ge 2 ]] || die "--swap-gib requires a value"; SWAP_GIB="$2"; shift 2 ;;
    --client-host) [[ $# -ge 2 ]] || die "--client-host requires a value"; CLIENT_HOST="$2"; shift 2 ;;
    --authorized-key) [[ $# -ge 2 ]] || die "--authorized-key requires a public key file"; AUTHORIZED_KEY="$2"; shift 2 ;;
    --timezone) [[ $# -ge 2 ]] || die "--timezone requires a value"; TIMEZONE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ "$ACTION" =~ ^(prepare|harden|status)$ ]] || die "Action must be prepare, harden, or status."
[[ -n "$ADMIN_USER" ]] || die "--user USER is required."
[[ "$ADMIN_USER" != root ]] || die "Choose a non-root administrative user."
[[ "$ADMIN_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Invalid user name."
[[ "$SWAP_GIB" =~ ^[0-9]+$ ]] || die "--swap-gib must be a non-negative integer."

source /etc/os-release
[[ "${ID:-}" == "debian" ]] || die "This script supports Debian only."
case "${VERSION_ID:-}" in 12|13) ;; *) die "Supported Debian versions are 12 and 13." ;; esac

ensure_admin_user() {
  if id "$ADMIN_USER" >/dev/null 2>&1; then
    skipped "Administrative user '$ADMIN_USER' already exists."
  else
    log "Creating administrative user '$ADMIN_USER'"
    adduser "$ADMIN_USER"
    changed "Created user '$ADMIN_USER'."
  fi

  if id -nG "$ADMIN_USER" | tr ' ' '\n' | grep -qx sudo; then
    skipped "User '$ADMIN_USER' is already in sudo group."
  else
    usermod -aG sudo "$ADMIN_USER"
    changed "Added '$ADMIN_USER' to sudo group."
  fi
}

verify_admin_user() {
  id "$ADMIN_USER" >/dev/null 2>&1 || die "User '$ADMIN_USER' does not exist."
  id -nG "$ADMIN_USER" | tr ' ' '\n' | grep -qx sudo || die "User '$ADMIN_USER' is not in sudo group."
  local password_status
  password_status="$(passwd -S "$ADMIN_USER" | awk '{print $2}')"
  [[ "$password_status" == "P" ]] || die "User '$ADMIN_USER' does not have an active password (passwd status: $password_status)."
  ok "Administrative user '$ADMIN_USER' exists, has sudo membership, and has an active password."
}

validate_public_key() {
  [[ -z "$AUTHORIZED_KEY" ]] && return 0
  [[ -f "$AUTHORIZED_KEY" ]] || die "Public key file not found: $AUTHORIZED_KEY"
  command -v ssh-keygen >/dev/null || die "ssh-keygen not found."
  # Accept exactly one plain public key, never a private key or authorized_keys options.
  [[ "$(awk 'NF { n++ } END { print n+0 }' "$AUTHORIZED_KEY")" == 1 ]] || die "Provide exactly one public key."
  grep -Eq '^(ssh-ed25519|ssh-rsa|ecdsa-sha2-[^[:space:]]+|sk-[^[:space:]]+)[[:space:]]+[A-Za-z0-9+/]+={0,2}([[:space:]].*)?$' "$AUTHORIZED_KEY" || die "Invalid public key format."
  ssh-keygen -lf "$AUTHORIZED_KEY" >/dev/null || die "Invalid public key."
}

install_admin_key() {
  [[ -z "$AUTHORIZED_KEY" ]] && return 0
  local user_home user_group key_type key_blob
  user_home="$(getent passwd "$ADMIN_USER" | cut -d: -f6)"
  user_group="$(id -gn "$ADMIN_USER")"
  [[ -d "$user_home" && "$user_home" != / ]] || die "Invalid administrator home directory."
  [[ ! -L "$user_home/.ssh" && ! -L "$user_home/.ssh/authorized_keys" ]] || die "Refusing symlinked SSH key paths."
  install -d -o "$ADMIN_USER" -g "$user_group" -m 0700 "$user_home/.ssh"
  touch "$user_home/.ssh/authorized_keys"
  read -r key_type key_blob _ <<< "$(awk 'NF { sub(/\r$/, ""); print; exit }' "$AUTHORIZED_KEY")"
  if ! awk -v t="$key_type" -v k="$key_blob" '$1 == t && $2 == k { found=1 } END { exit !found }' "$user_home/.ssh/authorized_keys"; then
    printf '\n%s %s\n' "$key_type" "$key_blob" >> "$user_home/.ssh/authorized_keys"
  fi
  chown "$ADMIN_USER:$user_group" "$user_home/.ssh/authorized_keys"
  chmod 0600 "$user_home/.ssh/authorized_keys"
  ok "Administrator public key installed; existing keys retained."
}

setup_swap() {
  (( SWAP_GIB > 0 )) || { skipped "Swap creation disabled (--swap-gib 0)."; return; }

  if swapon --noheadings --show=NAME | grep -q .; then
    skipped "Active swap already exists; leaving it unchanged."
    swapon --show
    return
  fi

  [[ ! -e /swapfile ]] || die "/swapfile exists but is not active; inspect it manually."

  local required_bytes available_bytes margin_bytes
  required_bytes=$((SWAP_GIB * 1024 * 1024 * 1024))
  margin_bytes=$((1024 * 1024 * 1024))
  available_bytes="$(df --output=avail -B1 / | tail -n1 | tr -d ' ')"
  [[ "$available_bytes" =~ ^[0-9]+$ ]] || die "Could not determine available disk space."
  (( available_bytes >= required_bytes + margin_bytes )) ||
    die "Not enough free disk space for ${SWAP_GIB} GiB swap plus 1 GiB safety margin."

  log "Creating ${SWAP_GIB} GiB swapfile"
  if ! fallocate -l "${SWAP_GIB}G" /swapfile; then
    rm -f /swapfile
    dd if=/dev/zero of=/swapfile bs=1M count="$((SWAP_GIB * 1024))" status=progress
  fi
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile

  if grep -qE '^/swapfile[[:space:]]' /etc/fstab; then
    skipped "/etc/fstab already contains /swapfile."
  else
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
    changed "Added /swapfile to /etc/fstab."
  fi
  changed "Enabled ${SWAP_GIB} GiB swapfile."
}

configure_fail2ban() {
  log "Configuring fail2ban for SSH"
  local ports
  ports="$(sshd -T | awk '$1 == "port" { print $2 }' | paste -sd, -)"
  [[ "$ports" =~ ^[0-9]+(,[0-9]+)*$ ]] || die "Cannot determine SSH ports for fail2ban."
  local cfg=/etc/fail2ban/jail.d/sshd.local
  local tmp
  tmp="$(mktemp)"
  cat >"$tmp" <<EOF
[sshd]
enabled = true
port = $ports
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
EOF

  install -d -m 0755 /etc/fail2ban/jail.d
  if [[ -f "$cfg" ]] && cmp -s "$tmp" "$cfg"; then
    skipped "$cfg already has the desired configuration."
  else
    install -m 0644 "$tmp" "$cfg"
    changed "Installed $cfg."
  fi
  rm -f "$tmp"

  systemctl enable fail2ban >/dev/null
  if systemctl is-active --quiet fail2ban; then
    systemctl restart fail2ban
  else
    systemctl start fail2ban
  fi

  local attempt ready=false
  for attempt in {1..10}; do
    if fail2ban-client ping 2>/dev/null | grep -q 'Server replied: pong' &&
       fail2ban-client status sshd >/dev/null 2>&1; then
      ready=true
      break
    fi
    sleep 1
  done
  [[ "$ready" == true ]] || die "fail2ban sshd jail did not become ready within 10 attempts."
  ok "fail2ban daemon and sshd jail are active."
}

ssh_config_for() {
  local user="${1:-}" client client_port server server_port
  if [[ -z "$user" ]]; then sshd -T; return; fi
  read -r client client_port server server_port <<< "${SSH_CONNECTION:-}"
  [[ -n "$client" && "$client_port" =~ ^[0-9]+$ && -n "$server" && "$server_port" =~ ^[0-9]+$ ]] ||
    die 'SSH_CONNECTION is required for connection-specific checks. Preserve it with sudo env SSH_CONNECTION="$SSH_CONNECTION" bash ...'
  local client_host="${CLIENT_HOST:-$client}"
  [[ "$client_host" != *','* && "$client_host" != *'='* && "$client_host" != *[[:space:]]* ]] || die "Invalid client hostname."
  if [[ -z "$CLIENT_HOST" ]] && sshd -T | grep -qx 'usedns yes'; then
    die "UseDNS is enabled; provide --client-host with the verified client hostname (or address if no verified reverse DNS)."
  fi
  sshd -T -C "user=$user,addr=$client,host=$client_host,laddr=$server,lport=$server_port"
}

ssh_effective_value() {
  local key="$1" user="${2:-}"
  ssh_config_for "$user" | awk -v wanted="$key" '$1 == wanted { print $2; exit }'
}

check_ssh_hardened() {
  local user="${1:-$ADMIN_USER}" root_login password_auth kbd_auth pubkey_auth max_auth
  root_login="$(ssh_effective_value permitrootlogin "$user")"
  password_auth="$(ssh_effective_value passwordauthentication "$user")"
  kbd_auth="$(ssh_effective_value kbdinteractiveauthentication "$user")"
  pubkey_auth="$(ssh_effective_value pubkeyauthentication "$user")"
  max_auth="$(ssh_effective_value maxauthtries "$user")"

  [[ "$root_login" == "no" ]] || { echo "Effective PermitRootLogin is '$root_login', expected 'no'." >&2; return 1; }
  [[ "$password_auth" == "yes" ]] || { echo "Effective PasswordAuthentication is '$password_auth', expected 'yes'." >&2; return 1; }
  [[ "$kbd_auth" == "no" ]] || { echo "Effective KbdInteractiveAuthentication is '$kbd_auth', expected 'no'." >&2; return 1; }
  [[ "$pubkey_auth" == "yes" ]] || { echo "Effective PubkeyAuthentication is '$pubkey_auth', expected 'yes'." >&2; return 1; }
  [[ "$max_auth" == "4" ]] || { echo "Effective MaxAuthTries is '$max_auth', expected '4'." >&2; return 1; }
  ok "Effective SSH configuration matches policy for $user at the current client address (current connection context)."
}

prepare() {
  command -v sshd >/dev/null || die "sshd not found."
  validate_public_key
  # On key-only images a password alone does not establish a login path.
  if [[ "$(ssh_effective_value passwordauthentication)" != yes && -z "$AUTHORIZED_KEY" ]]; then
    die "SSH password login is disabled. Rerun prepare with --authorized-key /path/to/admin.pub, then test a new SSH session."
  fi
  log "Updating APT metadata and ensuring baseline packages are installed"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    sudo fail2ban ca-certificates curl git rsync vim-tiny

  if [[ "$(timedatectl show -p Timezone --value)" == "$TIMEZONE" ]]; then
    skipped "Timezone is already $TIMEZONE."
  else
    timedatectl set-timezone "$TIMEZONE"
    changed "Timezone set to $TIMEZONE."
  fi

  ensure_admin_user
  verify_admin_user
  install_admin_key
  setup_swap
  configure_fail2ban

  log "Phase 1 complete"
  cat <<EOF
DO NOT close this root session yet.

Open a NEW terminal and verify:
  ssh $ADMIN_USER@SERVER
  sudo -v
  sudo whoami

Only after that succeeds, run:
  sudo env SSH_CONNECTION=\"\$SSH_CONNECTION\" bash system/init-debian-server.sh harden --user $ADMIN_USER
EOF
}

harden() {
  verify_admin_user
  ssh_config_for "$ADMIN_USER" >/dev/null
  command -v sshd >/dev/null 2>&1 || die "sshd not found."

  log "Preparing SSH hardening drop-in"
  install -d -m 0755 /etc/ssh/sshd_config.d
  local cfg=/etc/ssh/sshd_config.d/00-vps-baseline.conf
  local tmp backup="" cfg_changed=0
  tmp="$(mktemp)"
  cat >"$tmp" <<'EOF'
# Managed by linux_scripts/system/init-debian-server.sh
# Password login remains enabled by design; direct root SSH login is disabled.
PermitRootLogin no
PasswordAuthentication yes
KbdInteractiveAuthentication no
PubkeyAuthentication yes
MaxAuthTries 4
EOF

  if [[ -f "$cfg" ]] && cmp -s "$tmp" "$cfg"; then
    skipped "$cfg already has the desired content."
    rm -f "$tmp"
  else
    if [[ -f "$cfg" ]]; then
      backup="${cfg}.before-init-$(date +%Y%m%d%H%M%S)"
      cp -a "$cfg" "$backup"
    fi
    install -m 0644 "$tmp" "$cfg"
    rm -f "$tmp"
    cfg_changed=1
    changed "Installed $cfg."
  fi

  if ! sshd -t; then
    if (( cfg_changed )); then
      if [[ -n "$backup" ]]; then cp -a "$backup" "$cfg"; else rm -f "$cfg"; fi
    fi
    die "sshd syntax validation failed; previous drop-in state restored when changed."
  fi

  # Verify the merged/effective configuration BEFORE touching the running daemon.
  if ! check_ssh_hardened "$ADMIN_USER" || ! check_ssh_hardened root; then
    if (( cfg_changed )); then
      if [[ -n "$backup" ]]; then cp -a "$backup" "$cfg"; else rm -f "$cfg"; fi
    fi
    die "Effective SSH policy did not match expectations; previous drop-in state restored when changed."
  fi

  # Restore the file and reload the previous policy on any apply/check failure.
  if ! systemctl reload ssh || ! systemctl is-active --quiet ssh ||
     ! check_ssh_hardened "$ADMIN_USER" || ! check_ssh_hardened root; then
    if (( cfg_changed )); then
      if [[ -n "$backup" ]]; then cp -a "$backup" "$cfg"; else rm -f "$cfg"; fi
    fi
    if sshd -t && systemctl reload ssh && systemctl is-active --quiet ssh; then
      die "SSH apply failed; previous configuration restored and reloaded."
    fi
    die "SSH apply and recovery failed. Keep this session open and use the VPS console to inspect ssh.service."
  fi

  log "Effective SSH settings"
  sshd -T | grep -Ei 'permitrootlogin|passwordauthentication|pubkeyauthentication|kbdinteractiveauthentication|maxauthtries'

  log "Phase 2 complete"
  cat <<EOF
Keep this session open. In another NEW terminal verify:
  ssh $ADMIN_USER@SERVER
  sudo -v

Expected: password login works for $ADMIN_USER; direct root SSH login is refused.
EOF
}

status() {
  echo "=== OS ==="
  cat /etc/os-release
  echo "=== USER ==="
  id "$ADMIN_USER" || true
  passwd -S "$ADMIN_USER" 2>/dev/null || true
  echo "=== MEMORY / SWAP ==="
  free -h
  swapon --show
  echo "=== SSH EFFECTIVE CONFIG ==="
  sshd -T 2>/dev/null | grep -Ei 'permitrootlogin|passwordauthentication|pubkeyauthentication|kbdinteractiveauthentication|maxauthtries' || true
  echo "=== FAIL2BAN ==="
  systemctl is-active fail2ban 2>/dev/null || true
  fail2ban-client ping 2>/dev/null || true
  fail2ban-client status sshd 2>/dev/null || true
  echo "=== LISTENERS ==="
  ss -lntup
}

case "$ACTION" in
  prepare) prepare ;;
  harden) harden ;;
  status) status ;;
esac
