#!/usr/bin/env bash
#
# install-caddy-debian.sh
#
# Install Caddy Stable on a clean Debian 12/13 host and replace the stock
# binary with a custom build containing the modules used on this VPS.
#
# Prerequisite:
#   Install sing-box from its official Stable APT repository first.
#
# This script intentionally does NOT migrate an existing Caddy installation.
# Use migrate-caddy-debian.sh for an old/manual deployment.

set -Eeuo pipefail

readonly CONFIG="/etc/caddy/caddy.jsonc"
readonly DROPIN_DIR="/etc/systemd/system/caddy.service.d"
readonly DROPIN_FILE="${DROPIN_DIR}/override.conf"
readonly CADDY_DEFAULT="/usr/bin/caddy.default"
readonly CADDY_CUSTOM="/usr/bin/caddy.custom"

readonly MODULE_L4="github.com/mholt/caddy-l4"
readonly MODULE_CF_IP="github.com/WeidiDeng/caddy-cloudflare-ip"
readonly MODULE_JSONC="github.com/caddyserver/jsonc-adapter"

NO_START=false

log() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    printf 'Usage: %s [--no-start]\n' "$0"
}

parse_args() {
    while (( $# )); do
        case "$1" in
            --no-start) NO_START=true ;;
            -h|--help) usage; exit 0 ;;
            *) usage >&2; die "Unknown option: $1" ;;
        esac
        shift
    done
}

preflight() {
    [[ ${EUID} -eq 0 ]] || die "Run this script as root."
    [[ -r /etc/os-release ]] || die "/etc/os-release not found."

    # shellcheck disable=SC1091
    . /etc/os-release
    [[ ${ID:-} == "debian" ]] || die "Only Debian is supported."
    case "${VERSION_ID:-}" in
        12|13) ;;
        *) die "Only Debian 12 and Debian 13 are supported." ;;
    esac

    command -v systemctl >/dev/null || die "systemd is required."
    getent passwd sing-box >/dev/null ||
        die "User 'sing-box' does not exist. Install official sing-box first."
    getent group sing-box >/dev/null ||
        die "Group 'sing-box' does not exist. Install official sing-box first."

    # A manual installation belongs to the migration path. An existing APT
    # package is fine: apt-get install is idempotent and also makes retries
    # after an interrupted migration straightforward.
    [[ ! -e /usr/local/bin/caddy ]] ||
        die "Existing /usr/local/bin/caddy detected. Use migrate-caddy-debian.sh."

    log "Environment: Debian ${VERSION_ID}"
}

install_caddy() {
    log "Installing Caddy Stable from the official APT repository"

    apt-get update
    apt-get install -y debian-keyring debian-archive-keyring apt-transport-https curl gpg

    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' |
        gpg --dearmor --yes -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
        -o /etc/apt/sources.list.d/caddy-stable.list
    chmod 0644 \
        /usr/share/keyrings/caddy-stable-archive-keyring.gpg \
        /etc/apt/sources.list.d/caddy-stable.list

    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y -o Dpkg::Options::="--force-confold" caddy

    # The package may start the stock service automatically. Stop it until the
    # custom binary, JSONC command line and service identity are ready.
    systemctl stop caddy
}

install_xcaddy() {
    log "Installing xcaddy from the official repository"

    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/xcaddy/gpg.key' |
        gpg --dearmor --yes -o /usr/share/keyrings/caddy-xcaddy-archive-keyring.gpg
    curl -1sLf 'https://dl.cloudsmith.io/public/caddy/xcaddy/debian.deb.txt' \
        -o /etc/apt/sources.list.d/caddy-xcaddy.list
    chmod 0644 \
        /usr/share/keyrings/caddy-xcaddy-archive-keyring.gpg \
        /etc/apt/sources.list.d/caddy-xcaddy.list

    apt-get update
    apt-get install -y golang-go xcaddy
}

build_custom_caddy() {
    log "Building custom Caddy"

    local tmpdir
    tmpdir="$(mktemp -d)"
    trap 'rm -rf "$tmpdir"' RETURN

    xcaddy build latest \
        --output "${tmpdir}/caddy" \
        --with "${MODULE_L4}" \
        --with "${MODULE_CF_IP}" \
        --with "${MODULE_JSONC}"

    [[ -x "${tmpdir}/caddy" ]] || die "xcaddy build failed."

    local modules
    modules="$("${tmpdir}/caddy" list-modules --packages)"
    grep -Fq "${MODULE_L4}" <<<"${modules}" || die "Missing caddy-l4."
    grep -Fq "${MODULE_CF_IP}" <<<"${modules}" || die "Missing caddy-cloudflare-ip."
    grep -Fq "${MODULE_JSONC}" <<<"${modules}" || die "Missing jsonc-adapter."

    install -m 0755 "${tmpdir}/caddy" "${CADDY_CUSTOM}"
    trap - RETURN
    rm -rf "${tmpdir}"
}

setup_custom_binary() {
    log "Registering stock and custom Caddy binaries"

    # Preserve the package-managed binary as caddy.default. Future Caddy package
    # upgrades can continue updating that diverted file without overwriting the
    # selected custom binary.
    if [[ ! -e "${CADDY_DEFAULT}" ]]; then
        # Follow Caddy's documented Debian custom-build procedure. This is a
        # local administrator diversion, so package upgrades keep the stock
        # binary at caddy.default instead of replacing our selected binary.
        dpkg-divert --divert "${CADDY_DEFAULT}" --rename /usr/bin/caddy
    fi

    [[ -x "${CADDY_DEFAULT}" ]] || die "Official Caddy binary is missing."
    [[ -x "${CADDY_CUSTOM}" ]] || die "Custom Caddy binary is missing."

    update-alternatives --install /usr/bin/caddy caddy "${CADDY_DEFAULT}" 10
    update-alternatives --install /usr/bin/caddy caddy "${CADDY_CUSTOM}" 50
    update-alternatives --set caddy "${CADDY_CUSTOM}"

    [[ "$(readlink -f /usr/bin/caddy)" == "${CADDY_CUSTOM}" ]] ||
        die "Custom Caddy is not selected."
}

setup_service() {
    log "Adding the minimal systemd drop-in"

    install -d -m 0755 "${DROPIN_DIR}"
    cat >"${DROPIN_FILE}" <<'EOF'
[Service]
User=sing-box
Group=sing-box
Environment=HOME=/var/lib/caddy

ExecStart=
ExecStart=/usr/bin/caddy run --environ --config /etc/caddy/caddy.jsonc --adapter jsonc

ExecReload=
ExecReload=/usr/bin/caddy reload --config /etc/caddy/caddy.jsonc --adapter jsonc --force
EOF

    # Keep the package unit itself untouched. Only the runtime identity and the
    # JSONC-specific command line differ from the official defaults.
    systemctl daemon-reload
}

prepare_paths() {
    log "Preparing Caddy paths"

    install -d -o sing-box -g sing-box -m 0700 /var/lib/caddy

    # The Debian package starts Caddy once during installation. It may therefore
    # already have created files below /var/lib/caddy as user caddy. Caddy will
    # run as sing-box after our drop-in, so normalize the fresh data tree.
    chown -R sing-box:sing-box /var/lib/caddy

    # Runtime logs normally go to journald. Our JSONC configurations may also
    # use file outputs such as /var/log/caddy/error.log, so create only the
    # containing directory and let Caddy create/rotate the actual log files.
    install -d -o sing-box -g sing-box -m 0750 /var/log/caddy

    # Configuration stays root-managed; the Caddy runtime only needs read
    # access. The configuration file may be deployed after this installer.
    chown root:sing-box /etc/caddy
    chmod 0750 /etc/caddy
    if [[ -f "${CONFIG}" ]]; then
        chown root:sing-box "${CONFIG}"
        chmod 0640 "${CONFIG}"
    fi
}

validate_installation() {
    log "Validating installed Caddy"

    /usr/bin/caddy version

    local modules
    modules="$(/usr/bin/caddy list-modules --packages)"
    grep -Fq "${MODULE_L4}" <<<"${modules}" || die "Missing caddy-l4."
    grep -Fq "${MODULE_CF_IP}" <<<"${modules}" || die "Missing caddy-cloudflare-ip."
    grep -Fq "${MODULE_JSONC}" <<<"${modules}" || die "Missing jsonc-adapter."

    if [[ "${NO_START}" == true ]]; then
        log "Configuration validation skipped by --no-start."
    elif [[ -f "${CONFIG}" ]]; then
        runuser -u sing-box -- env HOME=/var/lib/caddy \
            /usr/bin/caddy validate --config "${CONFIG}" --adapter jsonc
    else
        log "${CONFIG} does not exist; configuration validation is skipped."
    fi
}

start_caddy() {
    if [[ "${NO_START}" == true ]]; then
        log "Caddy installed; start skipped by --no-start."
        return
    fi

    if [[ ! -f "${CONFIG}" ]]; then
        # Do not start a production service with an unintended/default config.
        systemctl disable caddy >/dev/null 2>&1 || true
        log "Caddy is installed but not started because ${CONFIG} is absent."
        return
    fi

    log "Enabling and starting Caddy"
    systemctl enable caddy
    systemctl restart caddy

    if ! systemctl is-active --quiet caddy; then
        systemctl --no-pager --full status caddy || true
        journalctl -u caddy -n 50 --no-pager || true
        die "Caddy failed to start."
    fi
}

main() {
    parse_args "$@"
    preflight
    install_caddy
    install_xcaddy
    build_custom_caddy
    setup_custom_binary
    setup_service
    prepare_paths
    validate_installation
    start_caddy

    printf '\nCaddy installation completed.\n'
    printf 'Version: '
    /usr/bin/caddy version
    printf 'Binary: %s\n' "$(readlink -f /usr/bin/caddy)"
    printf 'Config: %s\n' "${CONFIG}"
}

main "$@"
