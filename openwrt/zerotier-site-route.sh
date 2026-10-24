#!/bin/sh
# OpenWrt ZeroTier site routes for R3S/R4S.
# Does not install/join ZeroTier or change Tailscale/sing-box.
set -eu

NETWORK_ID=233ccaac273aa22d
CONFIG=/etc/zerotier-site-route.conf
SELF=/usr/sbin/zerotier-site-route
CRON=/etc/crontabs/root
OLD=/usr/sbin/zerotier-lan-routes
TAG='# zerotier-site-route managed'
ACTION=${1:-}
ROLE=${2:-}

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "$*"; }
require_root() { [ "$(id -u)" -eq 0 ] || die "run as root"; }
role_values() {
    case "$ROLE" in
        r3s) LAN=192.168.13.0/24; PEER_LAN=192.168.10; PEER_ZT=192.168.192.10 ;;
        r4s) LAN=192.168.10.0/24; PEER_LAN=192.168.13; PEER_ZT=192.168.192.13 ;;
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
        awk -v id="$NETWORK_ID" '$1=="200" && $2=="listnetworks" && $3==id && $6=="OK" {print $8; exit}'
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
    validate
    for subnet in "$FIRST" "$SECOND"; do
        desired "$subnet" || die "route missing: $subnet"
    done
    for addr in "${PEER_LAN}.1" "${PEER_LAN}.200"; do
        ip -4 route get "$addr" | grep -q "dev $ZT_DEV" ||
            die "route selection incorrect: $addr"
    done
    if uci -q get zerotier.Choicky_Zerotier.fw_allow_masq | grep -q '^1$'; then
        die "ZeroTier NAT enabled in UCI"
    fi
    if nft list chain inet fw4 srcnat 2>/dev/null |
        grep -E 'oifname.*masquerade.*ZeroTier' >/dev/null; then
        die "ZeroTier NAT still active"
    fi
    info "PASS: $ROLE via $ZT_DEV; two /25 routes selected; ZeroTier NAT not detected"
}
cron_add() {
    touch "$CRON"
    sed -i '\|/usr/sbin/zerotier-site-route|d' "$CRON"
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
    section=$(uci -q show zerotier | awk -F '[.=]' -v id="$NETWORK_ID" '$3=="id" && $0 ~ id {print $2; exit}')
    [ -n "$section" ] || die "ZeroTier UCI network section not found"
    uci -q delete "zerotier.$section.fw_allow_masq" || true
    uci commit zerotier
    # The generator is package-specific; do not restart ZeroTier or flush fw4.
    # Reconcile the generated include and active NAT only when explicitly requested.
    if command -v zerotier-fw4 >/dev/null; then
        info "NAT disabled in UCI; run 'zerotier-site-route sync-nat' to regenerate firewall integration"
    fi
}
sync_nat() {
    command -v zerotier-fw4 >/dev/null || die "zerotier-fw4 missing"
    [ -f /var/run/zerotier-one/_fw4/srcnat.nft ] ||
        die "ZeroTier srcnat include missing"
    zerotier-fw4 -s || die "zerotier-fw4 regeneration failed"
    if grep -q masquerade /var/run/zerotier-one/_fw4/srcnat.nft; then
        die "generated NAT remains; refusing firewall reload"
    fi
    /etc/init.d/firewall reload || die "firewall reload failed"
    if nft list chain inet fw4 srcnat 2>/dev/null | grep -E 'oifname.*masquerade.*ZeroTier' >/dev/null; then
        die "ZeroTier NAT still active after reload"
    fi
    info "PASS: ZeroTier NAT absent after regeneration"
}
case "$ACTION" in
    install)
        require_root
        role_values
        [ -f "$0" ] || die "run from a saved script file"
        [ -d /etc/crontabs ] || die "cron not installed"
        validate
        [ "$(ip -4 route show dev br-lan | grep -c "$LAN" || true)" -ge 1 ] ||
            info "WARNING: expected LAN $LAN not confirmed on br-lan"
        if [ -f "$CONFIG" ]; then
            previous=$(sed -n 's/^ROLE=//p' "$CONFIG" | head -n 1)
            [ "$previous" = "$ROLE" ] || die "already installed for $previous; uninstall first"
        fi
        install -m 0755 "$0" "$SELF"
        printf 'ROLE=%s\n' "$ROLE" > "$CONFIG"
        chmod 0644 "$CONFIG"
        nat_disable
        apply
        # Remove only the known legacy cron entry; leave the legacy script for manual review.
        [ -f "$CRON" ] && sed -i '\|/usr/sbin/zerotier-lan-routes|d' "$CRON"
        cron_add
        info "Installed for $ROLE. Check with: $SELF check"
        ;;
    reconcile)
        load_role
        # Cron may run before ZeroTier comes online; do not disrupt other routes.
        if command -v zerotier-cli >/dev/null && [ -n "$(device)" ]; then apply; fi
        ;;
    check) load_role; check ;;
    sync-nat) require_root; load_role; sync_nat ;;
    uninstall)
        require_root
        load_role
        cron_remove
        if command -v zerotier-cli >/dev/null && [ -n "$(device)" ]; then
            ZT_DEV=$(device)
            for subnet in "$FIRST" "$SECOND"; do
                if desired "$subnet"; then
                    ip -4 route del "$subnet" via "$PEER_ZT" dev "$ZT_DEV" metric 100 || true
                fi
            done
        fi
        rm -f "$CONFIG" "$SELF"
        info "Removed managed routes and cron; ZeroTier NAT configuration is left unchanged"
        ;;
    *) echo "Usage: $0 install r3s|r4s | reconcile | check | sync-nat | uninstall" >&2; exit 2 ;;
esac
