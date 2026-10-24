#!/bin/sh
# OpenWrt ZeroTier site routes for R3S/R4S.
# Does not install/join ZeroTier or change Tailscale/sing-box.
set -eu

NETWORK_ID=233ccaac273aa22d
CONFIG=/etc/zerotier-site-route.conf
SELF=/usr/sbin/zerotier-site-route
CRON=/etc/crontabs/root
TAG='# zerotier-site-route managed'
ACTION=${1:-}
ROLE=${2:-}

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "$*"; }
require_root() { [ "$(id -u)" -eq 0 ] || die "run as root"; }
role_values() {
    case "$ROLE" in
        r3s) LAN=192.168.13.1/24; PEER_LAN=192.168.10; PEER_ZT=192.168.192.10 ;;
        r4s) LAN=192.168.10.1/24; PEER_LAN=192.168.13; PEER_ZT=192.168.192.13 ;;
        *) die "role must be r3s or r4s" ;;
    esac
    FIRST="${PEER_LAN}.0/25"
    SECOND="${PEER_LAN}.128/25"
}
load_role() {
    [ -f "$CONFIG" ] || die "not installed; use install r3s|r4s"
    ROLE=$(sed -n 's/^ROLE=\(r3s\|r4s\)$/\1/p' "$CONFIG" | head -n 1)
    role_values
}
device() {
    zerotier-cli listnetworks 2>/dev/null |
        awk -v id="$NETWORK_ID" '
          $1=="200" && $2=="listnetworks" && $3==id {
            for (i=4; i<=NF-2; i++)
              if ($i=="OK" && $(i+1) ~ /^(PRIVATE|PUBLIC)$/ &&
                  $(i+2) ~ /^[[:alnum:]_.-]+$/) {
                print $(i+2); exit
              }
          }'
}
zt_section() {
    uci -q show zerotier 2>/dev/null | awk -v id="$NETWORK_ID" '
      /^zerotier\.[^.]+\.id=/ {
        split($0,a,"="); v=a[2]; gsub(/\047|\042/,"",v)
        if (v==id) {
          k=a[1]; sub(/^zerotier\./,"",k); sub(/\.id$/,"",k)
          print k; exit
        }
      }'
}
validate_role() {
    ip -4 -o addr show | awk -v ip="$LAN" '$4==ip {ok=1} END {exit !ok}' ||
        die "wrong router role or LAN IP; expected $LAN"
}
validate() {
    command -v zerotier-cli >/dev/null || die "zerotier-cli missing"
    command -v ip >/dev/null || die "ip command missing"
    ZT_DEV=$(device)
    [ -n "$ZT_DEV" ] || die "ZeroTier network $NETWORK_ID not ready"
    ip link show dev "$ZT_DEV" >/dev/null 2>&1 || die "device $ZT_DEV missing"
    ip -4 route get "$PEER_ZT" | grep -q "dev $ZT_DEV" ||
        die "peer ZeroTier IP not routed via $ZT_DEV"
    ip -4 addr show dev "$ZT_DEV" | grep -q 'inet 192\.168\.192\.' ||
        die "ZeroTier address missing on $ZT_DEV"
}
desired() {
    ip -4 route show "$1" | grep -F "via $PEER_ZT dev $ZT_DEV" | grep -q 'metric 100'
}
apply() {
    validate
    for subnet in "$FIRST" "$SECOND"; do
        if ! desired "$subnet"; then
            ip -4 route replace "$subnet" via "$PEER_ZT" dev "$ZT_DEV" metric 100 ||
                die "could not install route $subnet"
        fi
    done
}
check() {
    validate_role
    validate
    for subnet in "$FIRST" "$SECOND"; do
        desired "$subnet" || die "route missing: $subnet"
    done
    for addr in "${PEER_LAN}.1" "${PEER_LAN}.200"; do
        ip -4 route get "$addr" | grep -q "dev $ZT_DEV" ||
            die "route selection incorrect: $addr"
    done
    nat_check
    info "PASS: $ROLE via $ZT_DEV; two /25 routes selected; ZeroTier NAT not detected"
}
nat_check() {
    [ -n "${ZT_DEV:-}" ] || die "ZeroTier device not resolved"
    section=$(zt_section)
    [ -n "$section" ] || die "ZeroTier UCI section missing"
    [ "$(uci -q get "zerotier.$section.fw_allow_masq" 2>/dev/null || true)" != 1 ] ||
        die "ZeroTier NAT enabled in UCI"
    command -v nft >/dev/null || die "nft missing"
    rules=$(nft list chain inet fw4 srcnat 2>&1) ||
        die "cannot inspect active NAT: $rules"
    if printf '%s\n' "$rules" | grep -F "$ZT_DEV" | grep -q masquerade; then
        die "target ZeroTier NAT still active"
    fi
    [ -f /var/run/zerotier-one/_fw4/srcnat.nft ] ||
        die "ZeroTier NAT include missing"
    if grep -F "$ZT_DEV" /var/run/zerotier-one/_fw4/srcnat.nft |
        grep -q masquerade; then
        die "target ZeroTier generated NAT rule remains"
    fi
}
cron_add() {
    touch "$CRON"
    sed -i '\|# zerotier-site-route managed$|d' "$CRON"
    printf '* * * * * %s reconcile >/dev/null 2>&1 %s\n' "$SELF" "$TAG" >> "$CRON"
    /etc/init.d/cron enable
    /etc/init.d/cron reload
}
cron_remove() {
    [ -f "$CRON" ] || return 0
    sed -i '\|/usr/sbin/zerotier-site-route|d' "$CRON"
    /etc/init.d/cron reload
}
nat_disable() {
    # Change only this network's ZeroTier NAT setting.
    section=$(zt_section)
    [ -n "$section" ] || die "ZeroTier UCI network section not found"
    uci -q delete "zerotier.$section.fw_allow_masq" || true
    uci commit zerotier
    info "ZeroTier NAT disabled in UCI; runtime firewall rules are not modified"
}

case "$ACTION" in
    install)
        require_root
        role_values
        [ -f "$0" ] || die "run from a saved script file"
        [ -d /etc/crontabs ] || die "cron not installed"
        validate
        validate_role
        [ -n "$(zt_section)" ] || die "ZeroTier UCI section missing"
        if [ -f "$CONFIG" ]; then
            previous=$(sed -n 's/^ROLE=//p' "$CONFIG" | head -n 1)
            [ "$previous" = "$ROLE" ] || die "already installed for $previous; uninstall first"
        fi
        if [ "$0" != "$SELF" ]; then
            cp "$0" "${SELF}.tmp" || die "script copy failed"
            chmod 0755 "${SELF}.tmp"
            mv -f "${SELF}.tmp" "$SELF"
        fi
        printf 'ROLE=%s\n' "$ROLE" > "${CONFIG}.tmp"
        chmod 0644 "${CONFIG}.tmp"
        mv -f "${CONFIG}.tmp" "$CONFIG"
        nat_disable
        apply
        # Remove only the known legacy cron entry; leave the legacy script for manual review.
        [ -f "$CRON" ] && sed -i '\|^\* \* \* \* \* /usr/sbin/zerotier-lan-routes$|d' "$CRON"
        cron_add
        info "Installed for $ROLE. Check with: $SELF check"
        ;;
    reconcile)
        load_role
        # Cron may run before ZeroTier comes online; do not disrupt other routes.
        if command -v zerotier-cli >/dev/null && [ -n "$(device)" ]; then apply; fi
        ;;
    check) load_role; check ;;
    uninstall)
        require_root
        load_role
        for subnet in "$FIRST" "$SECOND"; do
            if ip -4 route show "$subnet" | grep -F "via $PEER_ZT " |
                grep -q 'metric 100'; then
                ip -4 route del "$subnet" via "$PEER_ZT" metric 100 ||
                    die "cannot remove $subnet; keeping installation for retry"
            fi
        done
        cron_remove
        rm -f "$CONFIG" "$SELF"
        info "Removed managed routes and cron; ZeroTier NAT configuration is left unchanged"
        ;;
    *) echo "Usage: $0 install r3s|r4s | reconcile | check | uninstall" >&2; exit 2 ;;
esac
