#!/usr/bin/env bash
#
# migrate-caddy-debian.sh
#
# One-time migration from the old/manual Caddy layout to the standard layout
# installed by install-caddy-debian.sh.
#
# Expected old layout:
#   binary:  /usr/local/bin/caddy
#   unit:    /etc/systemd/system/caddy.service
#   config:  /etc/caddy/caddy.jsonc
#   storage: /home/tls
#
# The script deliberately keeps the old binary, unit backup and /home/tls so
# rollback remains possible. It does not modify sing-box configuration.

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly INSTALLER="${SCRIPT_DIR}/install-caddy-debian.sh"

readonly CONFIG="/etc/caddy/caddy.jsonc"
readonly OLD_BINARY="/usr/local/bin/caddy"
readonly OLD_UNIT="/etc/systemd/system/caddy.service"
readonly OLD_STORAGE="/home/tls"
readonly NEW_STORAGE="/var/lib/caddy/.local/share/caddy"

readonly BACKUP_ROOT="/root/caddy-migration-backup"
readonly BACKUP_DIR="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"

MIGRATION_STARTED=false
OLD_CADDY_STOPPED=false

log() { printf '\n==> %s\n' "$*"; }
die() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }

on_error() {
    local exit_code="${1:-$?}"

    if [[ "${MIGRATION_STARTED}" == true && "${OLD_CADDY_STOPPED}" == true ]]; then
        printf '\nERROR: Caddy migration stopped before completion. Restoring the old Caddy service...\n' >&2

        # Keep any APT packages already installed. Restore only the old manual
        # binary and unit that this migration moved out of the live paths.
        if [[ -f "${BACKUP_DIR}/caddy.old" && -f "${BACKUP_DIR}/caddy.service.old" ]]; then
            cp -a "${BACKUP_DIR}/caddy.old" "${OLD_BINARY}"
            cp -a "${BACKUP_DIR}/caddy.service.old" "${OLD_UNIT}"
            cp -a "${BACKUP_DIR}/caddy.jsonc.old" "${CONFIG}"

            # A drop-in created by the new installer would also modify the
            # restored old unit, so remove only that migration-created drop-in.
            rm -f /etc/systemd/system/caddy.service.d/override.conf
            rmdir /etc/systemd/system/caddy.service.d 2>/dev/null || true

            systemctl daemon-reload
            if systemctl start caddy; then
                printf 'Old Caddy service restored and started.\n' >&2
            else
                printf 'WARNING: automatic restoration could not start old Caddy.\n' >&2
                systemctl --no-pager --full status caddy >&2 || true
            fi
        fi

        printf 'Backup: %s\n' "${BACKUP_DIR}" >&2
        printf 'Old TLS storage retained: %s\n' "${OLD_STORAGE}" >&2
    fi

    exit "${exit_code}"
}

trap 'on_error $?' ERR

preflight() {
    [[ ${EUID} -eq 0 ]] || die "Run this script as root."
    [[ -f "${INSTALLER}" ]] || die "Missing installer: ${INSTALLER}"
    [[ -x "${OLD_BINARY}" ]] || die "Old Caddy binary not found: ${OLD_BINARY}"
    [[ -f "${OLD_UNIT}" ]] || die "Old Caddy unit not found: ${OLD_UNIT}"
    [[ -f "${CONFIG}" ]] || die "Caddy config not found: ${CONFIG}"
    [[ -d "${OLD_STORAGE}" ]] || die "Old Caddy storage not found: ${OLD_STORAGE}"

    getent passwd sing-box >/dev/null ||
        die "User 'sing-box' does not exist. Install official sing-box first."

    systemctl is-active --quiet caddy ||
        die "Old caddy.service is not active; inspect the server before migrating."

    # All of these VPSes use the same Caddy FileStorage layout, although their
    # domain names differ. Require the legacy root to be configured explicitly
    # and verify the expected FileStorage subdirectories rather than matching
    # any domain name.
    grep -Eq '"root"[[:space:]]*:[[:space:]]*"/home/tls"' "${CONFIG}" ||
        die "Caddy storage root is not /home/tls; inspect it before migrating."
    [[ -d "${OLD_STORAGE}/certificates" ]] ||
        die "Missing ${OLD_STORAGE}/certificates."
    [[ -d "${OLD_STORAGE}/acme" ]] ||
        die "Missing ${OLD_STORAGE}/acme."
}

backup_old_installation() {
    log "Backing up the old Caddy installation to ${BACKUP_DIR}"

    install -d -m 0700 "${BACKUP_DIR}"
    cp -a "${OLD_BINARY}" "${BACKUP_DIR}/caddy.old"
    cp -a "${OLD_UNIT}" "${BACKUP_DIR}/caddy.service.old"
    cp -a "${CONFIG}" "${BACKUP_DIR}/caddy.jsonc.old"

    # The TLS tree can be large. Keep the original /home/tls in place as the
    # primary rollback copy rather than duplicating it into /root.
    {
        printf 'Old storage retained in place: %s\n' "${OLD_STORAGE}"
        printf 'Migration started: %s\n' "$(date --iso-8601=seconds)"
    } >"${BACKUP_DIR}/README.txt"
}

prepare_for_installer() {
    log "Stopping old Caddy and preserving the old systemd unit"

    systemctl stop caddy
    MIGRATION_STARTED=true
    OLD_CADDY_STOPPED=true

    # Keep the old binary in the timestamped backup and remove only the live
    # path; /home/tls is intentionally untouched.
    rm -f "${OLD_BINARY}"

    # Move the old locally-created unit out of systemd's live search path.
    # The official package can then install its vendor unit normally.
    rm -f "${OLD_UNIT}"
    systemctl daemon-reload

    # Prevent the package vendor unit from starting /etc/caddy/Caddyfile if the
    # host reboots before migration completes.
    systemctl disable caddy >/dev/null 2>&1 || true
}

run_installer() {
    log "Installing the new Caddy layout"
    bash "${INSTALLER}" --no-start
}

migrate_storage_and_config() {
    log "Migrating Caddy storage"

    install -d -o sing-box -g sing-box -m 0700 "${NEW_STORAGE}"

    # Copy, do not move: /home/tls remains an untouched rollback source.
    cp -a "${OLD_STORAGE}/." "${NEW_STORAGE}/"
    chown -R sing-box:sing-box /var/lib/caddy

    # Rewrite only the JSONC FileStorage root. Domain names differ between
    # servers, so migration must not depend on any certificate/domain path.
    cp -a "${CONFIG}" "${BACKUP_DIR}/caddy.jsonc.before-storage-rewrite"
    sed -Ei 's#("root"[[:space:]]*:[[:space:]]*)"/home/tls"#\\1"/var/lib/caddy/.local/share/caddy"#' "${CONFIG}"

    grep -Eq '"root"[[:space:]]*:[[:space:]]*"/var/lib/caddy/.local/share/caddy"' "${CONFIG}" ||
        die "Failed to rewrite the Caddy storage root."

    chown root:sing-box "${CONFIG}"
    chmod 0640 "${CONFIG}"
}

validate_and_start() {
    log "Validating migrated configuration"

    runuser -u sing-box -- env HOME=/var/lib/caddy \
        /usr/bin/caddy validate --config "${CONFIG}" --adapter jsonc

    systemctl enable caddy
    if ! systemctl restart caddy; then
        systemctl --no-pager --full status caddy || true
        journalctl -u caddy -n 80 --no-pager || true
        die "Migrated Caddy failed to start. Old files remain available in ${BACKUP_DIR} and ${OLD_STORAGE}."
    fi

    if ! systemctl is-active --quiet caddy; then
        systemctl --no-pager --full status caddy || true
        journalctl -u caddy -n 80 --no-pager || true
        die "Migrated Caddy failed to start. Old files remain available in ${BACKUP_DIR} and ${OLD_STORAGE}."
    fi

    log "Migration completed"
    printf 'Backup: %s\n' "${BACKUP_DIR}"
    printf 'Old TLS storage retained: %s\n' "${OLD_STORAGE}"
    printf 'New TLS storage: %s\n' "${NEW_STORAGE}"
}

check_sing_box_references() {
    [[ -d /etc/sing-box ]] || return

    log "Checking sing-box for legacy /home/tls references"

    local matches
    matches="$(grep -R -n -F '/home/tls' /etc/sing-box 2>/dev/null || true)"

    if [[ -n "${matches}" ]]; then
        printf '%s\n' "${matches}"
        printf '\nIMPORTANT: sing-box still references /home/tls.\n'
        printf 'Update those certificate/key paths to the new Caddy storage after verifying them.\n'
        printf 'Do not remove /home/tls until no service references it.\n'
    else
        printf 'No /home/tls references found under /etc/sing-box.\n'
    fi
}

main() {
    preflight
    backup_old_installation
    prepare_for_installer
    run_installer
    migrate_storage_and_config
    validate_and_start
    check_sing_box_references
    OLD_CADDY_STOPPED=false
    MIGRATION_STARTED=false
}

main "$@"
