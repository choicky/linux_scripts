#!/bin/bash
set -euo pipefail

# Safe baseline initializer for fresh Debian 12/13 VPS instances.
# Phase 1 prepares the host and creates/verifies an administrative sudo user.
# Phase 2 hardens SSH only after that user has been tested in a separate SSH session.

usage() {
  cat <<'EOF'
Usage:
  sudo bash system/init-debian-server.sh prepare --user USER [--swap-gib N] [--timezone ZONE]
  sudo bash system/init-debian-server.sh harden  --user USER
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
SWAP_GIB=2
TIMEZONE="Asia/Shanghai"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user) [[ $# -ge 2 ]] || die "--user requires a value"; ADMIN_USER="$2"; shift 2 ;;
    --swap-gib) [[ $# -ge 2 ]] || die "--swap-gib requires a value"; SWAP_GIB="$2"; shift 2 ;;
    --timezone) [[ $# -ge 2 ]] || die "--timezone requires a value"; TIMEZONE="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

[[ "$ACTION" =~ ^(prepare|harden|status)$ ]] || die "Action must be prepare, harden, or status."
[[ -n "$ADMIN_USER" ]] || die "--user USER is required."
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
  local cfg=/etc/fail2ban/jail.d/sshd.local
  local tmp
  tmp="$(mktemp)"
  cat >"$tmp" <<'EOF'
[sshd]
enabled = true
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
    cfg_changed=1
    changed "Installed $cfg."
  fi
  rm -f "$tmp"

  systemctl enable fail2ban >/dev/null
  if systemctl is-active --quiet fail2ban; then
    systemctl restart fail2ban
  else
    systemctl start fail2ban
  fi

  fail2ban-client ping | grep -q 'Server replied: pong' || die "fail2ban daemon did not respond to ping."
  fail2ban-client status sshd >/dev/null || die "fail2ban sshd jail is not active."
  ok "fail2ban daemon and sshd jail are active."
}

ssh_effective_value() {
  local key="$1"
  sshd -T | awk -v wanted="$key" '$1 == wanted { print $2; exit }'
}

check_ssh_hardened() {
  local root_login password_auth kbd_auth pubkey_auth max_auth
  root_login="$(ssh_effective_value permitrootlogin)"
  password_auth="$(ssh_effective_value passwordauthentication)"
  kbd_auth="$(ssh_effective_value kbdinteractiveauthentication)"
  pubkey_auth="$(ssh_effective_value pubkeyauthentication)"
  max_auth="$(ssh_effective_value maxauthtries)"

  [[ "$root_login" == "no" ]] || { echo "Effective PermitRootLogin is '$root_login', expected 'no'." >&2; return 1; }
  [[ "$password_auth" == "yes" ]] || { echo "Effective PasswordAuthentication is '$password_auth', expected 'yes'." >&2; return 1; }
  [[ "$kbd_auth" == "no" ]] || { echo "Effective KbdInteractiveAuthentication is '$kbd_auth', expected 'no'." >&2; return 1; }
  [[ "$pubkey_auth" == "yes" ]] || { echo "Effective PubkeyAuthentication is '$pubkey_auth', expected 'yes'." >&2; return 1; }
  [[ "$max_auth" == "4" ]] || { echo "Effective MaxAuthTries is '$max_auth', expected '4'." >&2; return 1; }
  ok "Effective SSH configuration matches the intended policy."
}

prepare() {
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
  sudo bash system/init-debian-server.sh harden --user $ADMIN_USER
EOF
}

harden() {
  verify_admin_user
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
    changed "Installed $cfg."
  fi

  if ! sshd -t; then
    if (( cfg_changed )); then [[ -n "$backup" ]] && cp -a "$backup" "$cfg" || rm -f "$cfg"; fi
    die "sshd syntax validation failed; previous drop-in state restored when changed."
  fi

  # Verify the merged/effective configuration BEFORE touching the running daemon.
  if ! check_ssh_hardened; then
    if (( cfg_changed )); then [[ -n "$backup" ]] && cp -a "$backup" "$cfg" || rm -f "$cfg"; fi
    die "Effective SSH policy did not match expectations; previous drop-in state restored when changed."
  fi

  systemctl reload ssh
  systemctl is-active --quiet ssh || die "SSH service is not active after reload."
  check_ssh_hardened || die "Effective SSH policy changed unexpectedly after reload."

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
