#!/usr/bin/env bash
#
# migrate-caddy-deployment.sh
#
# One-time, evidence-based migration from a legacy/manual Caddy deployment to
# the standard layout established by install-caddy-apt.sh plus the shared
# normalization component.
#
# Legacy arrangements are detected from first-hand evidence rather than
# hardcoded assumptions:
#   - a legacy Caddy binary  (/usr/local/bin/caddy),
#   - a locally-created unit (/etc/systemd/system/caddy.service),
#   - a shadowing local sing-box unit (/etc/systemd/system/sing-box.service)
#     that hides the package unit,
#   - a non-standard Caddy FileStorage root declared in /etc/caddy/caddy.jsonc
#     (verified by the presence of the storage's acme/ and certificates/
#     subdirectories), and
#   - sing-box certificate/key references that still point into such a root.
#
# The historical /home/tls layout is supported, as are other storage roots
# backed by the same evidence. Storage data is copied (never moved); the
# legacy root is retained as the rollback source. Certificate references are
# remapped only for the verified old-root -> standard-root correspondence;
# explicit external PEM files are left in place. Before any runtime-identity
# change or activation, every effective certificate and key reference is
# re-verified with an actual read test as www-data — whether or not its path
# changed — and migration stops before applying further changes when safe
# runtime access cannot be established. Ambiguous references are never
# guessed: migration stops.
#
# A regular local unit at /etc/systemd/system/sing-box.service shadows the
# official package unit and would make the normalization component refuse the
# service. Migration therefore backs up and removes such a shadowing unit once
# the package unit is proven to exist, so normalization can reconcile sing-box
# onto www-data without the installer or normalizer having to accept a masked
# local override. --skip-sing-box leaves the shadowing unit untouched.
#
# Package/binary/runtime-state reconciliation is delegated: this script never
# duplicates installer or normalization logic. sing-box configuration
# migration (formerly sing-box/migrate-caddy-cert-paths.sh, intentionally
# deleted) is performed here: back up, rewrite only mapped certificate/key
# fields, verify readability as the runtime user, and validate with the
# installed sing-box binary as www-data before anything is applied.
#
# Rollback boundaries (documented honestly):
#   - pre-migration binaries, units, drop-ins, configurations and permission
#     metadata are restored, and previously-active services are restarted;
#   - APT package installation performed by the reused installer is NOT
#     reversed (no package downgrade); a created dpkg diversion may remain and
#     is reported;
#   - legacy storage data is retained in place, so even a completed migration
#     can be reverted manually.
#
# Usage: bash caddy/migrate-caddy-deployment.sh [--skip-sing-box]

set -Eeuo pipefail

readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly INSTALLER="${SCRIPT_DIR}/install-caddy-apt.sh"
readonly NORMALIZE="${SCRIPT_DIR}/normalize-caddy-services.sh"

readonly CONFIG="/etc/caddy/caddy.jsonc"
readonly STANDARD_STORAGE="/var/lib/caddy/.local/share/caddy"
readonly OLD_BINARY="/usr/local/bin/caddy"
readonly OLD_UNIT="/etc/systemd/system/caddy.service"
readonly CADDY_DROPIN_DIR="/etc/systemd/system/caddy.service.d"
readonly SINGBOX_CONFIG="/etc/sing-box/config.json"
readonly SINGBOX_DROPIN_DIR="/etc/systemd/system/sing-box.service.d"
readonly SINGBOX_LOCAL_UNIT="/etc/systemd/system/sing-box.service"
readonly SINGBOX_VENDOR_UNIT="/usr/lib/systemd/system/sing-box.service"
readonly SINGBOX_STATE="/var/lib/sing-box"

readonly BACKUP_ROOT="/root/caddy-migration-backup"
readonly BACKUP_DIR="${BACKUP_ROOT}/$(date +%Y%m%d-%H%M%S)"

SKIP_SINGBOX=false
LEGACY_BINARY_PRESENT=false
LEGACY_UNIT_PRESENT=false
SINGBOX_LOCAL_UNIT_PRESENT=false
IMPLICIT_ROOT=false
OLD_CADDY_ACTIVE=false
OLD_CADDY_ENABLED=false
CADDY_PREPARED=false
SINGBOX_ACTIVE=false
SINGBOX_CHANGED=false
SINGBOX_LOCAL_UNIT_REMOVED=false
PERMS_MANIFEST=""
declare -a OLD_STORAGE_ROOTS=()
declare -a SB_MAPPED_REFS=()
declare -a SB_OTHER_REFS=()

log(){ printf '\n==> %s\n' "$*"; }

on_error(){
  local exit_code="${1:-$?}" failed=0 entry mode uid gid path
  trap - ERR
  set +e
  [[ "$SINGBOX_CHANGED" == true || "$SINGBOX_LOCAL_UNIT_REMOVED" == true \
     || "$CADDY_PREPARED" == true ]] || exit "$exit_code"

  printf '\nERROR: migration stopped before completion. Restoring pre-migration state...\n' >&2

  systemctl stop caddy >/dev/null 2>&1
  systemctl stop sing-box >/dev/null 2>&1

  if [[ "$CADDY_PREPARED" == true ]]; then
    # Keep any APT packages already installed by the reused installer;
    # restore only the live files this migration moved out of place.
    if [[ -f "$BACKUP_DIR/caddy.old" ]]; then
      cp -a -- "$BACKUP_DIR/caddy.old" "$OLD_BINARY" || failed=1
    fi
    if [[ -f "$BACKUP_DIR/caddy.service.old" ]]; then
      rm -f "$OLD_UNIT"
      cp -a -- "$BACKUP_DIR/caddy.service.old" "$OLD_UNIT" || failed=1
    fi
    cp -a -- "$BACKUP_DIR/caddy.jsonc.old" "$CONFIG" || failed=1

    # A drop-in created by the installer would also modify the restored old
    # unit, so remove only the migration-created managed drop-in and restore
    # whatever existed before.
    rm -f "$CADDY_DROPIN_DIR/override.conf"
    if [[ -d "$BACKUP_DIR/caddy-dropins.old" ]]; then
      rm -f "$CADDY_DROPIN_DIR"/*.conf
      cp -a "$BACKUP_DIR/caddy-dropins.old"/. "$CADDY_DROPIN_DIR"/ || failed=1
    elif [[ -d "$CADDY_DROPIN_DIR" ]]; then
      rm -rf "$CADDY_DROPIN_DIR"
    fi
    # A diverted stock binary can remain; the restored legacy unit runs the
    # old /usr/local/bin/caddy regardless. Reversing dpkg state is out of
    # scope for this rollback and is reported instead.
    if dpkg-divert --list /usr/bin/caddy >/dev/null 2>&1; then
      printf 'WARNING: the dpkg diversion created by the installer remains in place.\n' >&2
    fi
    [[ -L /usr/bin/caddy ]] && rm -f /usr/bin/caddy
  fi

  if [[ "$SINGBOX_CHANGED" == true || "$SINGBOX_LOCAL_UNIT_REMOVED" == true ]]; then
    if [[ "$SINGBOX_CHANGED" == true && -f "$BACKUP_DIR/sing-box-config.old" ]]; then
      cp -a -- "$BACKUP_DIR/sing-box-config.old" "$SINGBOX_CONFIG" || failed=1
    fi
    # The unified managed drop-in would also modify a restored shadowing local
    # unit, so undo drop-in state before restoring the unit itself.
    if [[ -d "$BACKUP_DIR/sing-box-dropins.old" ]]; then
      rm -rf "$SINGBOX_DROPIN_DIR"
      cp -a "$BACKUP_DIR/sing-box-dropins.old" "$SINGBOX_DROPIN_DIR" || failed=1
    elif [[ -d "$SINGBOX_DROPIN_DIR" ]]; then
      rm -rf "$SINGBOX_DROPIN_DIR"
    fi
    if [[ "$SINGBOX_LOCAL_UNIT_REMOVED" == true && -f "$BACKUP_DIR/sing-box.service.local.old" ]]; then
      rm -f -- "$SINGBOX_LOCAL_UNIT"
      cp -a -- "$BACKUP_DIR/sing-box.service.local.old" "$SINGBOX_LOCAL_UNIT" || failed=1
    fi
  fi

  if [[ -n "$PERMS_MANIFEST" && -f "$PERMS_MANIFEST" ]]; then
    while IFS= read -r -d '' entry; do
      mode=${entry%% *}; entry=${entry#* }
      uid=${entry%% *}; entry=${entry#* }
      gid=${entry%% *}; path=${entry#* }
      [[ -e "$path" || -L "$path" ]] || continue
      chown -h "$uid:$gid" "$path" || failed=1
      [[ -L "$path" ]] || chmod "$mode" "$path" || failed=1
    done <"$PERMS_MANIFEST"
  fi

  systemctl daemon-reload
  if [[ "$OLD_CADDY_ENABLED" == true ]]; then
    systemctl enable caddy >/dev/null 2>&1
  else
    systemctl disable caddy >/dev/null 2>&1
  fi
  if [[ "$OLD_CADDY_ACTIVE" == true ]]; then
    if systemctl start caddy; then
      printf 'Old Caddy service restored and started.\n' >&2
    else
      printf 'WARNING: automatic restoration could not start old Caddy.\n' >&2
      systemctl --no-pager --full status caddy >&2
    fi
  fi
  if [[ "$SINGBOX_ACTIVE" == true ]]; then
    systemctl start sing-box >/dev/null 2>&1 || printf 'WARNING: could not restart sing-box.\n' >&2
  fi

  [[ "$failed" == 0 ]] || printf 'ERROR: rollback was incomplete; inspect caddy and sing-box manually.\n' >&2
  printf 'Backup: %s\n' "$BACKUP_DIR" >&2
  printf 'Legacy storage is retained; this script never deletes it.\n' >&2
  exit "$exit_code"
}
trap 'on_error $?' ERR

die(){ printf '\nERROR: %s\n' "$*" >&2; if [[ "$CADDY_PREPARED" == true || "$SINGBOX_CHANGED" == true || "$SINGBOX_LOCAL_UNIT_REMOVED" == true ]]; then on_error 1; fi; exit 1; }
usage(){ printf 'Usage: %s [--skip-sing-box]\n' "$0"; }

parse_args(){
  while (( $# )); do
    case "$1" in
      --skip-sing-box) SKIP_SINGBOX=true;;
      -h|--help) usage; exit 0;;
      *) usage >&2; die "Unknown option: $1";;
    esac
    shift
  done
}

escape_re(){
  case "$1" in *'#'*) die "Path containing '#' is not supported for evidence rewriting: $1";; esac
  # Escape every BRE metacharacter ( \ ^ $ . [ ] ( ) { } * + ? | ) so the path
  # can be embedded literally in the s#...# rewrites below. '/' is intentionally
  # left unescaped because '#' is the sed delimiter used there.
  printf '%s' "$1" | sed -e 's/[].[^$*+?(){}|\\]/\\&/g'
}

detect_legacy_layout(){
  log "Detecting the existing Caddy deployment from evidence"

  if [[ -e "$OLD_BINARY" ]]; then
    [[ -f "$OLD_BINARY" ]] || die "$OLD_BINARY exists but is not a regular file."
    LEGACY_BINARY_PRESENT=true
    printf '  legacy binary: %s\n' "$OLD_BINARY"
  fi
  if [[ -e "$OLD_UNIT" ]]; then
    [[ -f "$OLD_UNIT" ]] || die "$OLD_UNIT exists but is not a regular file."
    LEGACY_UNIT_PRESENT=true
    printf '  legacy unit:   %s\n' "$OLD_UNIT"
  fi

  # A regular local sing-box unit shadows the package-owned unit and makes
  # normalization refuse the service, so it is legacy evidence even when
  # Caddy itself already looks standard. The removal preflight (the package
  # unit must exist, and the path must not be a symlink or masked) runs here,
  # before any change is made.
  if [[ $SKIP_SINGBOX == false && -e "$SINGBOX_LOCAL_UNIT" ]]; then
    if [[ -L "$SINGBOX_LOCAL_UNIT" || ! -f "$SINGBOX_LOCAL_UNIT" ]]; then
      die "$SINGBOX_LOCAL_UNIT is a symlink (for example masked) or not a regular file; resolve that state before migrating."
    fi
    [[ -f "$SINGBOX_VENDOR_UNIT" || -f /lib/systemd/system/sing-box.service ]] \
      || die "Refusing to remove $SINGBOX_LOCAL_UNIT: no package-owned sing-box unit exists, so removing the local override would leave sing-box with no unit at all."
    SINGBOX_LOCAL_UNIT_PRESENT=true
    printf '  shadowing local sing-box unit: %s\n' "$SINGBOX_LOCAL_UNIT"
  fi

  local -a roots=() value
  mapfile -t roots < <(
    grep -oE '"root"[[:space:]]*:[[:space:]]*"[^"]*"' "$CONFIG" \
      | sed -E 's/.*"([^"]*)"$/\1/' | sort -u
  )
  for value in "${roots[@]}"; do
    [[ "$value" == /* ]] || continue
    [[ "$value" == "$STANDARD_STORAGE" ]] && continue
    if [[ ! -d "$value" ]]; then
      # If the referenced root is gone but standard storage with ACME data
      # exists, the storage migration already happened; only the remaining
      # layout components can still need migrating.
      if [[ -d "$STANDARD_STORAGE/acme" ]]; then
        printf '  note: root %s is missing while standard storage exists; assuming storage was migrated already.\n' "$value"
        continue
      fi
      die "Caddy storage root '$value' is referenced in $CONFIG but does not exist. Refusing to guess; inspect the configuration."
    fi
    if [[ -d "$value/acme" && -d "$value/certificates" ]]; then
      OLD_STORAGE_ROOTS+=("$value")
      printf '  legacy FileStorage root: %s\n' "$value"
    elif [[ -d "$value/acme" || -d "$value/certificates" ]]; then
      die "'$value' looks partially like a Caddy storage root (only acme/ or only certificates/). Stop: resolve the ambiguity before migrating."
    else
      printf '  note: root %s has no FileStorage evidence (not treated as storage)\n' "$value"
    fi
  done

  if (( ${#OLD_STORAGE_ROOTS[@]} > 1 )); then
    printf 'Detected storage roots: %s\n' "${OLD_STORAGE_ROOTS[*]}" >&2
    die "Multiple legacy FileStorage roots were detected; their contents cannot be merged into standard storage safely. Stop."
  fi

  # Implicit default storage: a legacy unit that sets Environment=HOME=x and a
  # config without an explicit storage root means Caddy used x/.local/share/caddy.
  if (( ${#OLD_STORAGE_ROOTS[@]} == 0 )); then
    local home old_home unit_file
    home=""
    for unit_file in "$OLD_UNIT" "$CADDY_DROPIN_DIR"/*.conf; do
      [[ -f "$unit_file" ]] || continue
      old_home="$(sed -nE 's/^[[:space:]]*Environment=HOME=([^[:space:]]+).*/\1/p' "$unit_file" | tail -n1)"
      [[ -n "$old_home" ]] && home=$old_home
    done
    if [[ -n "$home" && "$home" != /var/lib/caddy && -d "$home/.local/share/caddy/acme" \
          && -d "$home/.local/share/caddy/certificates" ]]; then
      OLD_STORAGE_ROOTS+=("$home/.local/share/caddy")
      IMPLICIT_ROOT=true
      printf '  implicit FileStorage root from unit HOME=%s\n' "$home"
    fi
  fi
  if (( ${#OLD_STORAGE_ROOTS[@]} > 0 )) && [[ -d "$STANDARD_STORAGE" ]]; then
    die "$STANDARD_STORAGE already exists while legacy root '${OLD_STORAGE_ROOTS[0]}' still holds data; refusing to overwrite existing standard storage."
  fi

  if [[ "$LEGACY_BINARY_PRESENT" == false && "$LEGACY_UNIT_PRESENT" == false \
        && "$SINGBOX_LOCAL_UNIT_PRESENT" == false && ${#OLD_STORAGE_ROOTS[@]} == 0 ]]; then
    log "No legacy deployment evidence found; the Caddy layout already appears standard."
    printf 'For runtime-state reconciliation use: bash caddy/normalize-caddy-services.sh --both\n'
    trap - ERR
    exit 0
  fi

  if systemctl is-active --quiet caddy; then OLD_CADDY_ACTIVE=true; fi
  if systemctl is-enabled --quiet caddy 2>/dev/null; then OLD_CADDY_ENABLED=true; fi
}

classify_singbox_references(){
  [[ -f "$SINGBOX_CONFIG" ]] || { log "No sing-box configuration present; skipping sing-box reference handling."; return 0; }
  [[ $SKIP_SINGBOX == true ]] && { log "sing-box handling skipped by --skip-sing-box."; return 0; }

  log "Classifying sing-box certificate/key references"
  local -a refs=() ref root
  mapfile -t refs < <(
    grep -oE '"(certificate_path|key_path)"[[:space:]]*:[[:space:]]*"[^"]+"' "$SINGBOX_CONFIG" \
      | sed -E 's/.*"([^"]*)"$/\1/' | sort -u
  )
  for ref in "${refs[@]}"; do
    local matched=false
    for root in ${OLD_STORAGE_ROOTS[@]+"${OLD_STORAGE_ROOTS[@]}"}; do
      if [[ "$ref" == "$root"/* ]]; then
        SB_MAPPED_REFS+=("$ref")
        matched=true
        break
      fi
    done
    [[ "$matched" == true ]] && continue
    SB_OTHER_REFS+=("$ref")
  done

  if (( ${#SB_MAPPED_REFS[@]} )); then
    printf '  references mapped to standard storage: %s\n' "${#SB_MAPPED_REFS[@]}"
  fi
  if (( ${#SB_OTHER_REFS[@]} )); then
    printf '  external/standard references kept in place: %s\n' "${#SB_OTHER_REFS[@]}"
  fi

  # Residual old-root references outside certificate/key fields would be
  # business guesses the migration must not make (the deleted helper stopped
  # for exactly these).
  for root in ${OLD_STORAGE_ROOTS[@]+"${OLD_STORAGE_ROOTS[@]}"}; do
    grep -Fq -- "$root" "$SINGBOX_CONFIG" || continue
    local total in_fields
    total=$( { grep -oF -- "$root" "$SINGBOX_CONFIG" || true; } | wc -l )
    in_fields=$( { grep -oE '"(certificate_path|key_path)"[[:space:]]*:[[:space:]]*"[^"]*"' "$SINGBOX_CONFIG" \
      | { grep -oF -- "$root" || true; }; } | wc -l )
    if (( total > in_fields )); then
      grep -nF -- "$root" "$SINGBOX_CONFIG" >&2
      die "sing-box references $root outside certificate_path/key_path fields; review those usages before migrating."
    fi
  done
}

backup_pre_migration(){
  log "Backing up the pre-migration deployment to $BACKUP_DIR"
  install -d -m 0700 "$BACKUP_DIR"
  [[ "$LEGACY_BINARY_PRESENT" == true ]] && cp -a -- "$OLD_BINARY" "$BACKUP_DIR/caddy.old"
  [[ "$LEGACY_UNIT_PRESENT" == true ]] && cp -a -- "$OLD_UNIT" "$BACKUP_DIR/caddy.service.old"
  cp -a -- "$CONFIG" "$BACKUP_DIR/caddy.jsonc.old"
  [[ -d "$CADDY_DROPIN_DIR" ]] && cp -a "$CADDY_DROPIN_DIR" "$BACKUP_DIR/caddy-dropins.old"
  if [[ -f "$SINGBOX_CONFIG" && $SKIP_SINGBOX == false ]]; then
    cp -a -- "$SINGBOX_CONFIG" "$BACKUP_DIR/sing-box-config.old"
    [[ -d "$SINGBOX_DROPIN_DIR" ]] && cp -a "$SINGBOX_DROPIN_DIR" "$BACKUP_DIR/sing-box-dropins.old"
    if systemctl is-active --quiet sing-box; then SINGBOX_ACTIVE=true; fi
  fi

  PERMS_MANIFEST="$BACKUP_DIR/permissions"
  : >"$PERMS_MANIFEST"
  local path
  for path in /etc/caddy /var/log/caddy /var/lib/caddy /etc/sing-box /var/lib/sing-box /var/log/sing-box; do
    [[ -e "$path" ]] || continue
    find "$path" -xdev -printf '%m %U %G %p\0' >>"$PERMS_MANIFEST" \
      || die "Cannot snapshot permissions for $path."
  done

  {
    printf 'Legacy storage retained in place (never deleted): %s\n' "${OLD_STORAGE_ROOTS[*]:-none}"
    printf 'Rollback restores files, units, drop-ins, permission metadata and prior service activity, but keeps APT packages and any created dpkg diversion.\n'
    printf 'Migration started: %s\n' "$(date --iso-8601=seconds)"
  } >"$BACKUP_DIR/README.txt"
}

prepare_for_installer(){
  log "Stopping legacy Caddy and preserving its live paths"
  systemctl stop caddy >/dev/null 2>&1 || true
  CADDY_PREPARED=true
  # Keep the old binary/unit only in the timestamped backup and remove the
  # live paths so the official package unit becomes authoritative.
  # Legacy storage roots are intentionally untouched.
  rm -f "$OLD_BINARY"
  rm -f "$OLD_UNIT"
  systemctl daemon-reload
  systemctl disable caddy >/dev/null 2>&1 || true
}

run_installer(){
  log "Installing the standard layout via the shared installer"
  bash "$INSTALLER" --no-start
}

migrate_storage_and_config(){
  if (( ${#OLD_STORAGE_ROOTS[@]} == 0 )); then
    log "No legacy storage root to migrate"
    return 0
  fi
  local old_root=${OLD_STORAGE_ROOTS[0]} escaped
  log "Copying Caddy storage $old_root -> $STANDARD_STORAGE (source retained)"

  # Agreed permission matrix: /var/lib/caddy itself is 0755 so ordinary
  # users can list file names, but the FileStorage tree stays restrictive —
  # cp -a preserves the legacy modes and the storage root is pinned to 0700;
  # nothing here recursively loosens sensitive ACME/certificate data.
  install -d -o www-data -g www-data -m 0755 /var/lib/caddy
  install -d -o www-data -g www-data -m 0700 "$STANDARD_STORAGE"
  # Copy, never move: the legacy root remains the primary rollback source and
  # must not be deleted merely because the new path exists.
  cp -a -- "$old_root/." "$STANDARD_STORAGE/" || die "Failed to copy storage from $old_root."
  chown -R www-data:www-data /var/lib/caddy
  chmod 0755 /var/lib/caddy
  chmod 0700 "$STANDARD_STORAGE"

  # Rewrite only the JSONC FileStorage root. Domain names differ between
  # servers, so migration must not depend on any certificate/domain path.
  # An implicit default root needs no rewrite: the managed drop-in sets
  # HOME=/var/lib/caddy, so Caddy resolves the standard path by default.
  if [[ "$IMPLICIT_ROOT" == true ]]; then
    log "Implicit default storage migrated; Caddy now resolves it under the managed HOME"
    return 0
  fi
  escaped=$(escape_re "$old_root")
  cp -a -- "$CONFIG" "$BACKUP_DIR/caddy.jsonc.before-storage-rewrite"
  sed -Ei "s#(\"root\"[[:space:]]*:[[:space:]]*)\"$escaped\"#\\1\"$STANDARD_STORAGE\"#" "$CONFIG"
  if ! grep -Eq "\"root\"[[:space:]]*:[[:space:]]*\"$(escape_re "$STANDARD_STORAGE")\"" "$CONFIG"; then
    die "Failed to rewrite the Caddy storage root in $CONFIG."
  fi
  chown root:www-data "$CONFIG"
  chmod 0640 "$CONFIG"
}

relocate_singbox_local_unit(){
  [[ $SKIP_SINGBOX == true ]] && return 0
  [[ -f "$SINGBOX_LOCAL_UNIT" ]] || return 0
  # Detection already proved the package unit exists and that this path is a
  # regular shadowing unit. Retain the backup before removal so a failed
  # rollback can restore the exact pre-migration unit.
  log "Removing the shadowing local sing-box unit so the package unit becomes authoritative"
  cp -a -- "$SINGBOX_LOCAL_UNIT" "$BACKUP_DIR/sing-box.service.local.old" \
    || die "Cannot back up $SINGBOX_LOCAL_UNIT."
  rm -f -- "$SINGBOX_LOCAL_UNIT" || die "Cannot remove $SINGBOX_LOCAL_UNIT."
  SINGBOX_LOCAL_UNIT_REMOVED=true
  systemctl daemon-reload
}

migrate_singbox_config(){
  [[ -f "$SINGBOX_CONFIG" ]] || return 0
  [[ $SKIP_SINGBOX == true ]] && return 0
  if (( ${#SB_MAPPED_REFS[@]} == 0 )); then
    log "sing-box has no references under a legacy storage root; configuration unchanged."
    return 0
  fi

  local old_root=${OLD_STORAGE_ROOTS[0]} candidate ref escaped
  [[ -x /usr/bin/sing-box ]] || die "sing-box references legacy storage but /usr/bin/sing-box is not installed; cannot validate the migration."
  candidate="$BACKUP_DIR/sing-box-config.candidate"
  cp -a -- "$SINGBOX_CONFIG" "$candidate"
  escaped=$(escape_re "$old_root")

  log "Rewriting mapped certificate/key references in the sing-box candidate"
  # Replace only named JSON string fields, including when the input is
  # minified; the mapping is old-root -> standard-root only.
  sed -Ei "s#(\"(certificate_path|key_path)\"[[:space:]]*:[[:space:]]*)\"$escaped/#\\1\"$STANDARD_STORAGE/#g" "$candidate"
  if grep -Fq -- "$old_root" "$candidate"; then
    die "Legacy references remain in the candidate outside the mapped fields; inspect $SINGBOX_CONFIG."
  fi

  # Verify the correspondence: every referenced file must exist at its
  # destination and be readable by the runtime identity, not just parse.
  local -a check_refs=()
  mapfile -t check_refs < <(
    grep -oE '"(certificate_path|key_path)"[[:space:]]*:[[:space:]]*"[^"]+"' "$candidate" \
      | sed -E 's/.*"([^"]*)"$/\1/' | sort -u
  )
  [[ -d "$SINGBOX_STATE" ]] || install -d -o www-data -g www-data -m 0755 "$SINGBOX_STATE"
  for ref in "${check_refs[@]}"; do
    [[ -e "$ref" ]] || die "Referenced certificate/key does not exist: $ref. Wait for Caddy issuance before retrying; nothing was applied."
    runuser -u www-data -- test -r "$ref" \
      || die "Referenced certificate/key is not readable by www-data: $ref. Nothing was applied."
  done

  log "Validating the sing-box candidate as www-data"
  runuser -u www-data -- /usr/bin/sing-box -D "$SINGBOX_STATE" check -c "$candidate" \
    || die "sing-box candidate validation failed; the live configuration was not changed."

  SINGBOX_CHANGED=true
  install -o root -g www-data -m 0640 "$candidate" "$SINGBOX_CONFIG"
  log "Applied migrated sing-box configuration (original retained in $BACKUP_DIR)"
}

verify_singbox_runtime_readability(){
  # The shared normalizer below switches sing-box to the www-data runtime
  # identity, and activation restarts the service with these files. Every
  # effective certificate/key reference must therefore already be readable
  # as www-data before any of that happens — including external paths
  # whose location the migration does not change. This is an actual
  # file-read test under the runtime identity, not a config parse:
  # 'sing-box check' alone does not prove the process can open the files.
  [[ $SKIP_SINGBOX == true ]] && return 0
  [[ -f "$SINGBOX_CONFIG" ]] || return 0

  log "Verifying every effective certificate/key reference is readable as www-data"
  local -a refs=() ref
  mapfile -t refs < <(
    grep -oE '"(certificate_path|key_path)"[[:space:]]*:[[:space:]]*"[^"]+"' "$SINGBOX_CONFIG" \
      | sed -E 's/.*"([^"]*)"$/\1/' | sort -u
  )
  for ref in "${refs[@]}"; do
    [[ -e "$ref" ]] \
      || die "Referenced certificate/key does not exist: $ref. Restore the file or remove the reference before migrating; the runtime identity has not been changed."
    runuser -u www-data -- test -r "$ref" \
      || die "Referenced certificate/key is not readable by www-data: $ref. Grant the runtime identity access (for example chgrp www-data and chmod g+r on the file, with traversable parent directories, or move the certificate into managed Caddy storage) before migrating; the runtime identity has not been changed."
  done
  if (( ${#refs[@]} )); then
    printf '  all %s certificate/key references readable as www-data\n' "${#refs[@]}"
  fi
}

normalize_once(){
  # When sing-box handling is skipped, reconcile only Caddy so a shadowing or
  # otherwise non-normalized sing-box unit is never touched.
  if [[ $SKIP_SINGBOX == true ]]; then
    log "Running the shared normalization component once for Caddy (sing-box skipped)"
    bash "$NORMALIZE" --caddy
    return
  fi
  log "Running the shared normalization component once for both services"
  bash "$NORMALIZE" --both
}

validate_and_activate(){
  log "Validating the migrated Caddy configuration as www-data"
  runuser -u www-data -- env HOME=/var/lib/caddy \
    /usr/bin/caddy validate --config "$CONFIG" --adapter jsonc

  if [[ "$OLD_CADDY_ACTIVE" == true ]]; then
    log "Activating the migrated Caddy service"
    systemctl unmask caddy >/dev/null
    systemctl enable caddy
    if ! systemctl restart caddy; then
      systemctl --no-pager --full status caddy || true
      journalctl -u caddy -n 80 --no-pager || true
      die "Migrated Caddy failed to start."
    fi
    systemctl is-active --quiet caddy || die "Migrated Caddy is not active."
  else
    log "Caddy was not running before migration; leaving it stopped and disabled."
    printf 'Review the deployment, then enable/start it when ready.\n'
  fi

  if [[ "$SINGBOX_CHANGED" == true ]]; then
    if [[ "$SINGBOX_ACTIVE" == true ]]; then
      log "Restarting sing-box once to load the migrated configuration"
      systemctl restart sing-box
      systemctl is-active --quiet sing-box || die "sing-box failed after restart."
    else
      log "sing-box was not running before migration; leaving it stopped."
    fi
  fi
}

main(){
  parse_args "$@"

  [[ ${EUID} -eq 0 ]] || die "Run this script as root."
  [[ -f "$INSTALLER" ]] || die "Missing installer: $INSTALLER"
  [[ -f "$NORMALIZE" ]] || die "Missing normalization component: $NORMALIZE"
  [[ -f "$CONFIG" ]] || die "Caddy config not found: $CONFIG"
  [[ ! -L "$CONFIG" ]] || die "$CONFIG is a symlink; refusing to follow it."
  getent passwd www-data >/dev/null || die "User 'www-data' does not exist."
  getent group www-data >/dev/null || die "Group 'www-data' does not exist."
  local command
  for command in systemctl runuser install cp sed grep find awk chown chmod stat dpkg-divert; do
    command -v "$command" >/dev/null 2>&1 || die "Missing required command: $command"
  done
  # The installer owns the supported-distribution matrix. Check it before
  # stopping services or moving any legacy path, so an unsupported host cannot
  # be left mid-migration by a failure that happens later inside the installer.
  local detected_os
  detected_os="$(bash "$INSTALLER" --check-os)" \
    || die "This distribution is not supported by the Caddy APT installer; nothing was changed."
  log "Supported distribution: ${detected_os}"

  detect_legacy_layout
  classify_singbox_references
  backup_pre_migration
  prepare_for_installer
  run_installer
  migrate_storage_and_config
  migrate_singbox_config
  verify_singbox_runtime_readability
  relocate_singbox_local_unit
  normalize_once
  validate_and_activate

  CADDY_PREPARED=false
  SINGBOX_CHANGED=false
  SINGBOX_LOCAL_UNIT_REMOVED=false
  trap - ERR

  log "Migration completed"
  printf 'Backup: %s\n' "$BACKUP_DIR"
  if (( ${#OLD_STORAGE_ROOTS[@]} )); then
    printf 'Legacy storage retained: %s (verify, then archive manually when you decide)\n' "${OLD_STORAGE_ROOTS[0]}"
  fi
  printf 'Standard storage: %s\n' "$STANDARD_STORAGE"
}

main "$@"
