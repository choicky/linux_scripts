#!/usr/bin/env bash
# Rewrite sing-box certificate/key references from the legacy Caddy storage
# (/home/tls) to the standard Caddy storage, then validate as www-data.
set -Eeuo pipefail

readonly CONFIG="/etc/sing-box/config.json"
readonly OLD_ROOT="/home/tls"
readonly NEW_ROOT="/var/lib/caddy/.local/share/caddy"

log(){ printf '\n==> %s\n' "$*"; }
die(){ printf '\nERROR: %s\n' "$*" >&2; exit 1; }

[[ ${EUID} -eq 0 ]] || die "Run this script as root."
[[ -f "$CONFIG" ]] || die "Missing $CONFIG"
[[ -d "$NEW_ROOT" ]] || die "Missing new Caddy storage: $NEW_ROOT"
getent passwd www-data >/dev/null || die "User 'www-data' does not exist."

mapfile -t refs < <(grep -oE '"(certificate_path|key_path)"[[:space:]]*:[[:space:]]*"[^"]+"' "$CONFIG" | grep -F "$OLD_ROOT/" || true)

if (( ${#refs[@]} == 0 )); then
  if grep -Fq "$OLD_ROOT" "$CONFIG"; then
    die "$CONFIG still contains $OLD_ROOT outside certificate_path/key_path; inspect it manually."
  fi
  printf 'No legacy certificate_path/key_path references found. Nothing to do.\n'
  exit 0
fi

log "Legacy certificate/key references"
printf '%s\n' "${refs[@]}"

# Verify every referenced destination exists before changing the config.
for ref in "${refs[@]}"; do
  path="${ref#*:}"
  path="${path#*\"}"
  path="${path%\"}"
  new_path="${path/#$OLD_ROOT/$NEW_ROOT}"
  [[ -f "$new_path" ]] || die "Migrated certificate/key not found: $new_path"
done

backup="${CONFIG}.before-caddy-storage-migration-$(date +%Y%m%d-%H%M%S)"
cp -a "$CONFIG" "$backup"
log "Backup created: $backup"

# Keep the running configuration intact until candidate validation succeeds.
stage="$(mktemp /etc/sing-box/.cert-migration.XXXXXX.json)"
trap 'rm -f "$stage"' EXIT
cp -a "$CONFIG" "$stage"
sed -Ei '/"(certificate_path|key_path)"[[:space:]]*:/ s#"/home/tls/#"/var/lib/caddy/.local/share/caddy/#g' "$stage"
chown root:www-data "$stage"
chmod 0640 "$stage"
remaining="$(grep -n -F "$OLD_ROOT" "$stage" || true)"
if [[ -n "$remaining" ]]; then
  printf '%s\n' "$remaining" >&2
  die "Legacy references remain. Original config unchanged; inspect manually."
fi
log "Validating sing-box candidate as www-data"
runuser -u www-data -- /usr/bin/sing-box check -c "$stage" ||
  die "sing-box validation failed. Original config unchanged."
mv -f "$stage" "$CONFIG"

log "Certificate paths migrated successfully"
grep -nE '"(certificate_path|key_path)"' "$CONFIG" || true
printf '\nBackup retained: %s\n' "$backup"
printf 'Old Caddy storage is not removed by this script.\n'
