#!/usr/bin/env bash
# Normalize certificate paths and single-file startup on an existing installation.
# No package installation, Caddy changes, or removal of old certificate storage.
set -Eeuo pipefail
readonly CONFIG=/etc/sing-box/config.json
readonly OLD_ROOT=/home/tls
readonly NEW_ROOT=/var/lib/caddy/.local/share/caddy
readonly DROPIN=/etc/systemd/system/sing-box.service.d/override.conf
readonly LOCAL_UNIT=/etc/systemd/system/sing-box.service
readonly DROPIN_DIR=/etc/systemd/system/sing-box.service.d
readonly EXPECTED='/usr/bin/sing-box -D /var/lib/sing-box -c /etc/sing-box/config.json run'
WORK='' BACKUP='' CHANGED=false ACTIVE=false HAD_DROPINS=false HAD_LOCAL=false ENABLED=false
log(){ printf '\n==> %s\n' "$*"; }
die(){ printf '\nERROR: %s\n' "$*" >&2; exit 1; }
cleanup(){
  local rc=$? failed=0 mode uid gid path entry
  trap - EXIT INT TERM HUP
  set +e
  if [[ "$CHANGED" == true ]]; then
    echo 'Migration failed; restoring original configuration and startup.' >&2
    systemctl stop sing-box || failed=1
    cp -a "$BACKUP/config.json" "$CONFIG" || failed=1
    if [[ "$HAD_LOCAL" == true ]]; then cp -a "$BACKUP/local.service" "$LOCAL_UNIT" || failed=1; fi
    rm -rf -- "$DROPIN_DIR" || failed=1
    if [[ "$HAD_DROPINS" == true ]]; then cp -a "$BACKUP/dropins" "$DROPIN_DIR" || failed=1; fi
    while IFS= read -r -d '' entry; do
      mode=${entry%% *}; entry=${entry#* }
      uid=${entry%% *}; entry=${entry#* }
      gid=${entry%% *}; path=${entry#* }
      chown -h "$uid:$gid" "$path" || failed=1
      [[ -L "$path" ]] || chmod "$mode" "$path" || failed=1
    done < "$BACKUP/permissions"
    systemctl daemon-reload || failed=1
    if [[ "$ENABLED" == true ]]; then systemctl reenable sing-box || failed=1; else systemctl disable sing-box || failed=1; fi
    if [[ "$ACTIVE" == true ]]; then
      systemctl restart sing-box && systemctl is-active --quiet sing-box || failed=1
    fi
    echo "Backup retained: $BACKUP" >&2
    [[ "$failed" == 0 ]] || echo 'ERROR: restoration incomplete; inspect sing-box.' >&2
    rc=1
  fi
  [[ -z "$WORK" ]] || rm -rf -- "$WORK"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

[[ $# == 0 ]] || die 'Usage: bash sing-box/migrate-caddy-cert-paths.sh (no arguments)'
[[ $EUID == 0 ]] || die 'Run as root.'
[[ -f "$CONFIG" && ! -L "$CONFIG" ]] || die "Expected regular config: $CONFIG"
[[ -x /usr/bin/sing-box ]] || die 'Missing /usr/bin/sing-box; use the installer first.'
for command in runuser systemctl flock; do command -v "$command" >/dev/null || die "Missing command: $command"; done
exec 9>/run/lock/sing-box-standardize.lock
flock -n 9 || die 'Another sing-box normalization is running.'
getent passwd www-data >/dev/null && getent group www-data >/dev/null || die 'www-data account/group missing.'
[[ "$(systemctl show sing-box -p User --value)" == www-data && "$(systemctl show sing-box -p Group --value)" == www-data ]] || die 'Expected existing www-data:www-data service; run convert-services-to-www-data.sh first.'
runuser -u www-data -- test -w /var/lib/sing-box || die 'www-data cannot write /var/lib/sing-box; fix state-directory ownership first.'
# Require the installed Stable package and its real vendor unit before removing
# any local unit. No APT operations or guesses about a missing vendor unit.
dpkg-query -W -f='${Status}' sing-box 2>/dev/null | grep -Fxq 'install ok installed' || die 'Stable sing-box package is not installed.'
if dpkg-query -W -f='${Status}' sing-box-beta 2>/dev/null | grep -Fxq 'install ok installed'; then die 'Remove sing-box-beta before normalization.'; fi
VENDOR=''
for path in /usr/lib/systemd/system/sing-box.service /lib/systemd/system/sing-box.service; do
  if [[ -f "$path" ]] && dpkg-query -L sing-box | grep -Fxq "$path"; then VENDOR="$path"; break; fi
done
[[ -n "$VENDOR" ]] || die 'Package-owned sing-box vendor unit missing; local unit was not removed.'
[[ ! -L "$LOCAL_UNIT" && ( ! -e "$LOCAL_UNIT" || -f "$LOCAL_UNIT" ) ]] || die 'Local unit is a symlink/mask; inspect it before normalization.'
[[ ! -L "$DROPIN_DIR" ]] || die 'Drop-in directory must not be a symlink.'
if systemctl is-enabled --quiet sing-box; then ENABLED=true; fi
START="$(systemctl show sing-box -p ExecStart --value)"
DIRECTORY='/usr/bin/sing-box -D /var/lib/sing-box -C /etc/sing-box run'
case "$START" in
  *"argv[]=$EXPECTED ;"*) ;;
  *"argv[]=$DIRECTORY ;"*)
    # Do not silently discard actual additional directory-mode configuration.
    mapfile -t extras < <(find /etc/sing-box -maxdepth 1 \( -name '*.json' -o -name '*.jsonc' \) ! -name config.json -print)
    if (( ${#extras[@]} )); then
      printf 'Additional directory configuration: %s\n' "${extras[@]}" >&2
      die 'Review additional JSON inputs before switching to config.json only.'
    fi
    ;;
  *) die "Unsupported ExecStart: $START";;
esac
[[ ! -L "$DROPIN" && ( ! -e "$DROPIN" || -f "$DROPIN" ) ]] || die 'Managed drop-in must be a regular file.'
if systemctl is-active --quiet sing-box; then ACTIVE=true; fi
WORK="$(mktemp -d /run/sing-box-normalize.XXXXXXXX)"
chown root:www-data "$WORK"; chmod 0750 "$WORK"
cp -a "$CONFIG" "$WORK/config.json"
# Replace only named JSON string fields, including when the input is minified.
sed -Ei 's#("(certificate_path|key_path)"[[:space:]]*:[[:space:]]*)"/home/tls/#\1"/var/lib/caddy/.local/share/caddy/#g' "$WORK/config.json"
[[ "$(grep -Fc "$OLD_ROOT" "$WORK/config.json" || true)" == 0 ]] || die 'Legacy references remain outside certificate/key fields; inspect config.'
chown root:www-data "$WORK/config.json"; chmod 0640 "$WORK/config.json"
# Check both rewritten and already-standard certificate/key references.
mapfile -t refs < <(grep -oE '"(certificate_path|key_path)"[[:space:]]*:[[:space:]]*"[^"]+"' "$WORK/config.json" || true)
for ref in "${refs[@]}"; do
  path="${ref#*:}"; path="${path#*\"}"; path="${path%\"}"
  runuser -u www-data -- test -r "$path" || die "Certificate/key not readable: $path. Wait for Caddy issuance before retrying."
done
log 'Validating candidate as www-data'
runuser -u www-data -- /usr/bin/sing-box -D /var/lib/sing-box check -c "$WORK/config.json" || die 'Candidate validation failed; live config/startup unchanged.'
printf '[Service]\nUser=www-data\nGroup=www-data\nStateDirectoryMode=0750\nExecStart=\nExecStart=%s\n' "$EXPECTED" > "$WORK/launch.conf"
if [[ ! -e "$DROPIN_DIR/zzzz-single-file.conf" && ! -e "$DROPIN_DIR/zzzz-caddy-single-file.conf" && ! -e "$LOCAL_UNIT" && "$ENABLED" == true && "$ACTIVE" == true && "$(systemctl show sing-box -p StateDirectoryMode --value)" == 0750 && "$(readlink -f "$(systemctl show sing-box -p FragmentPath --value)")" == "$(readlink -f "$VENDOR")" && "$(stat -c '%U:%G:%a' /etc/sing-box)" == root:www-data:750 && "$(stat -c '%U:%G:%a' /var/lib/sing-box)" == www-data:www-data:750 ]] && cmp -s "$DROPIN" "$WORK/launch.conf" && cmp -s "$CONFIG" "$WORK/config.json" && [[ "$START" == *"argv[]=$EXPECTED ;"* && "$(stat -c '%U:%G:%a' "$CONFIG")" == root:www-data:640 ]]; then
  log 'Already normalized; no files changed and no service restart.'
  exit 0
fi
BACKUP="/root/sing-box-migration-backup/$(date +%Y%m%d-%H%M%S)-$$"
install -d -m 0700 "$BACKUP"
cp -a "$CONFIG" "$BACKUP/config.json"
systemctl cat sing-box > "$BACKUP/service.txt"
if [[ -f "$LOCAL_UNIT" ]]; then HAD_LOCAL=true; cp -a "$LOCAL_UNIT" "$BACKUP/local.service"; fi
if [[ -d "$DROPIN_DIR" ]]; then HAD_DROPINS=true; cp -a "$DROPIN_DIR" "$BACKUP/dropins"; fi
: > "$BACKUP/permissions"
for path in /etc/sing-box /var/lib/sing-box /var/log/sing-box; do
  [[ ! -e "$path" ]] || find "$path" -printf '%m %U %G %p\0' >> "$BACKUP/permissions"
done
log "Backup: $BACKUP"
CHANGED=true
[[ "$ACTIVE" == false ]] || systemctl stop sing-box
# Match install-sing-box-debian.sh permissions and service layout.
install -d -o root -g www-data -m 0750 /etc/sing-box
install -d -o www-data -g www-data -m 0750 /var/lib/sing-box
chown -R www-data:www-data /var/lib/sing-box
chmod -R u+rwX /var/lib/sing-box
if [[ -d /var/log/sing-box ]]; then chown -R www-data:www-data /var/log/sing-box; fi
install -o root -g www-data -m 0640 "$WORK/config.json" "$CONFIG"
rm -f -- "$LOCAL_UNIT"
# Retire overrides generated by prior versions; retain unrelated drop-ins.
rm -f -- "$DROPIN_DIR/zzzz-single-file.conf" "$DROPIN_DIR/zzzz-caddy-single-file.conf"
install -d -m 0755 /etc/systemd/system/sing-box.service.d
install -o root -g root -m 0644 "$WORK/launch.conf" "$DROPIN"
systemctl daemon-reload
START="$(systemctl show sing-box -p ExecStart --value)"
[[ "$(readlink -f "$(systemctl show sing-box -p FragmentPath --value)")" == "$(readlink -f "$VENDOR")" ]] || die 'Vendor unit did not take effect.'
[[ "$START" == *"argv[]=$EXPECTED ;"* ]] || die 'Single-file override did not take effect.'
[[ "$(systemctl show sing-box -p User --value)" == www-data && "$(systemctl show sing-box -p Group --value)" == www-data ]] || die 'Unexpected runtime identity.'
[[ "$(systemctl show sing-box -p StateDirectoryMode --value)" == 0750 ]] || die 'StateDirectoryMode override did not take effect.'
systemctl reenable sing-box
systemctl is-enabled --quiet sing-box || die 'sing-box not enabled.'
systemctl restart sing-box
sleep 3
systemctl is-active --quiet sing-box || die 'sing-box failed after restart.'
[[ "$(stat -c '%U:%G:%a' /var/lib/sing-box)" == www-data:www-data:750 ]] || die 'Unexpected state-directory ownership/mode after restart.'
CHANGED=false
log 'SUCCESS: vendor unit, permissions, certificate paths and single-file startup normalized.'
systemctl show sing-box -p FragmentPath -p User -p Group -p ExecStart -p UnitFileState --no-pager
printf 'Backup: %s\nOld /home/tls retained. Service enabled and active.\n' "$BACKUP"
