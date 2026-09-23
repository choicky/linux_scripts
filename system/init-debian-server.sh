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
  sudo bash system/init-debian-server.sh status --user USER

Defaults:
  --swap-gib 2
  --timezone Asia/Shanghai

Workflow:
  1. Run "prepare".
  2. In a NEW terminal, verify: ssh USER@server ; sudo -v ; sudo whoami
  3. Keep that verified session open and run "harden".
  4. Open another new terminal and verify USER can still log in.

The script intentionally keeps SSH password authentication enabled and disables
direct root SSH login only in the explicit "harden" phase.
EOF
}

die() { echo "ERROR: $*" >&2; exit 1; }
log() { printf '\n==> %s\n' "$*"; }

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
    log "Administrative user '$ADMIN_USER' already exists"
  else
    log "Creating administrative user '$ADMIN_USER'"
    adduser "$ADMIN_USER"
  fi
  usermod -aG sudo "$ADMIN_USER"
}

verify_admin_user() {
  id "$ADMIN_USER" >/dev/null 2>&1 || die "User '$ADMIN_USER' does not exist."
  id -nG "$ADMIN_USER" | tr ' ' '\n' | grep -qx sudo || die "User '$ADMIN_USER' is not in sudo group."
  local status
  status="$(passwd -S "$ADMIN_USER" | awk '{print $2}')"
  [[ "$status" == "P" ]] || die "User '$ADMIN_USER' does not have an active password (passwd status: $status)."
}

setup_swap() {
  (( SWAP_GIB > 0 )) || { log "Swap creation disabled (--swap-gib 0)"; return; }
  if swapon --noheadings --show=NAME | grep -q .; then
    log "Swap already exists; leaving it unchanged"
    swapon --show
    return
  fi
  [[ ! -e /swapfile ]] || die "/swapfile exists but is not active; inspect it manually."
  log "Creating ${SWAP_GIB} GiB swapfile"
  fallocate -l "${SWAP_GIB}G" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count="$((SWAP_GIB * 1024))" status=progress
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -qE '^/swapfile[[:space:]]' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
}

configure_fail2ban() {
  log "Configuring fail2ban for SSH"
  install -d -m 0755 /etc/fail2ban/jail.d
  cat >/etc/fail2ban/jail.d/sshd.local <<'EOF'
[sshd]
enabled = true
backend = systemd
maxretry = 5
findtime = 10m
bantime = 1h
EOF
  systemctl enable --now fail2ban
}

prepare() {
  log "Updating APT metadata and installing baseline packages"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y     sudo fail2ban ca-certificates curl git rsync vim-tiny

  log "Setting timezone to $TIMEZONE"
  timedatectl set-timezone "$TIMEZONE"

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
  log "Writing SSH hardening drop-in"
  install -d -m 0755 /etc/ssh/sshd_config.d
  local cfg=/etc/ssh/sshd_config.d/90-vps-baseline.conf
  local tmp
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' EXIT
  cat >"$tmp" <<'EOF'
# Managed by linux_scripts/system/init-debian-server.sh
# Password login remains enabled by design; direct root SSH login is disabled.
PermitRootLogin no
PasswordAuthentication yes
KbdInteractiveAuthentication no
PubkeyAuthentication yes
MaxAuthTries 4
EOF
  install -m 0644 "$tmp" "$cfg"

  if ! sshd -t; then
    rm -f "$cfg"
    die "sshd validation failed; the new drop-in was removed."
  fi

  systemctl reload ssh
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
  fail2ban-client status sshd 2>/dev/null || true
  echo "=== LISTENERS ==="
  ss -lntup
}

case "$ACTION" in
  prepare) prepare ;;
  harden) harden ;;
  status) status ;;
esac
