#!/usr/bin/env bash
# Normalize certificate paths and single-file startup on an existing installation.
# No package installation, Caddy changes, or removal of old certificate storage.
set -Eeuo pipefail
readonly CONFIG=/etc/sing-box/config.json
readonly OLD_ROOT=/home/tls
readonly NEW_ROOT=/var/lib/caddy/.local/share/caddy
readonly DROPIN=/etc/systemd/system/sing-box.service.d/zzzz-single-file.conf
readonly EXPECTED='/usr/bin/sing-box -D /var/lib/sing-box -c /etc/sing-box/config.json run'
WORK='' BACKUP='' CHANGED=false ACTIVE=false HAD_DROPIN=false
log(){ printf '\n==> %s\n' "$*"; }
die(){ printf '\nERROR: %s\n' "$*" >&2; exit 1; }
cleanup(){
  local rc=$? failed=0
  trap - EXIT INT TERM HUP
  set +e
  if [[ "$CHANGED" == true ]]; then
    echo 'Migration failed; restoring original configuration and startup.' >&2
    if [[ "$ACTIVE" == true ]]; then systemctl stop sing-box || failed=1; fi
    cp -a "$BACKUP/config.json" "$CONFIG" || failed=1
    if [[ "$HAD_DROPIN" == true ]]; then
      cp -a "$BACKUP/launch.conf" "$DROPIN" || failed=1
    else
      rm -f -- "$DROPIN" || failed=1
    fi
    systemctl daemon-reload || failed=1
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
printf '[Service]\nUser=www-data\nGroup=www-data\nExecStart=\nExecStart=%s\n' "$EXPECTED" > "$WORK/launch.conf"
if cmp -s "$CONFIG" "$WORK/config.json" && [[ "$START" == *"argv[]=$EXPECTED ;"* && "$(stat -c '%U:%G:%a' "$CONFIG")" == root:www-data:640 ]]; then
  log 'Already normalized; no files changed and no service restart.'
  exit 0
fi
BACKUP="/root/sing-box-migration-backup/$(date +%Y%m%d-%H%M%S)-$$"
install -d -m 0700 "$BACKUP"
cp -a "$CONFIG" "$BACKUP/config.json"
systemctl cat sing-box > "$BACKUP/service.txt"
if [[ -f "$DROPIN" ]]; then HAD_DROPIN=true; cp -a "$DROPIN" "$BACKUP/launch.conf"; fi
log "Backup: $BACKUP"
CHANGED=true
[[ "$ACTIVE" == false ]] || systemctl stop sing-box
install -o root -g www-data -m 0640 "$WORK/config.json" "$CONFIG"
install -d -m 0755 /etc/systemd/system/sing-box.service.d
install -o root -g root -m 0644 "$WORK/launch.conf" "$DROPIN"
systemctl daemon-reload
START="$(systemctl show sing-box -p ExecStart --value)"
[[ "$START" == *"argv[]=$EXPECTED ;"* ]] || die 'Single-file override did not take effect.'
[[ "$(systemctl show sing-box -p User --value)" == www-data && "$(systemctl show sing-box -p Group --value)" == www-data ]] || die 'Unexpected runtime identity.'
if [[ "$ACTIVE" == true ]]; then
  systemctl restart sing-box
  sleep 3
  systemctl is-active --quiet sing-box || die 'sing-box failed after restart.'
fi
CHANGED=false
log 'SUCCESS: certificate paths and single-file startup normalized.'
systemctl show sing-box -p User -p Group -p ExecStart --no-pager
printf 'Backup: %s\nOld /home/tls retained. Previously inactive service remains stopped.\n' "$BACKUP"
