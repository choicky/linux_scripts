#!/usr/bin/env bash
# Reconcile an existing Caddy installation and its sing-box certificate paths.
# Existing /home/tls remains untouched. No live host is changed without --apply.
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG=/etc/caddy/caddy.jsonc
SING=/etc/sing-box/config.json
NEW=/var/lib/caddy/.local/share/caddy
APPLY=false
STORAGE_ONLY=false
CHANGED=false
STORAGE_MOVED=false
NEW_CREATED=false
BACKUP=""
WORK=""
CSTAGE=""
SSTAGE=""
SING_PRESENT=false
SING_ACTIVE=false
CADDY_ENABLED=false
OLD_NEW=""
STANDARD=true
log(){ printf '\n==> %s\n' "$*"; }
die(){ echo "ERROR: $*" >&2; exit 1; }
usage(){ echo "Usage: $0 [--apply] [--storage-only]"; }
for arg in "$@"; do
  case "$arg" in --apply) APPLY=true;; --storage-only) STORAGE_ONLY=true;; -h|--help) usage; exit 0;; *) usage >&2; die "Unknown option: $arg";; esac
done

rollback(){
  local rc=$1 failed=0 path
  trap - EXIT INT TERM
  set +e
  if [[ "$CHANGED" == true ]]; then
    echo 'Migration failed; restoring previous configuration and runtime.' >&2
    systemctl stop caddy || failed=1
    [[ "$SING_PRESENT" == false ]] || systemctl stop sing-box || failed=1
    if [[ "$NEW_CREATED" == true ]]; then rm -rf -- "$NEW" || failed=1; fi
    if [[ "$STORAGE_MOVED" == true ]]; then mv -- "$OLD_NEW" "$NEW" || failed=1; fi
    cp -a "$BACKUP/caddy.jsonc" "$CONFIG" || failed=1
    [[ "$SING_PRESENT" == false ]] || cp -a "$BACKUP/sing-box.json" "$SING" || failed=1
    if [[ "$STANDARD" == false ]]; then
      # Keep APT changes, but restore the old executable paths and effective unit.
      systemctl unmask caddy >/dev/null 2>&1
      for path in /usr/bin/caddy /usr/bin/caddy.custom /usr/bin/caddy.default /usr/local/bin/caddy; do
        if [[ -e "$BACKUP/binaries$path" || -L "$BACKUP/binaries$path" ]]; then
          rm -f -- "$path"
          cp -a "$BACKUP/binaries$path" "$path" || failed=1
        else
          rm -f -- "$path" || failed=1
        fi
      done
      cp -a "$BACKUP/fragment" /etc/systemd/system/caddy.service || failed=1
      rm -rf /etc/systemd/system/caddy.service.d
      if [[ -d "$BACKUP/dropins" ]]; then cp -a "$BACKUP/dropins" /etc/systemd/system/caddy.service.d || failed=1; fi
    fi
    systemctl daemon-reload || failed=1
    if [[ "$CADDY_ENABLED" == true ]]; then systemctl enable caddy; else systemctl disable caddy; fi
    systemctl restart caddy && systemctl is-active --quiet caddy || failed=1
    if [[ "$SING_ACTIVE" == true ]]; then systemctl restart sing-box && systemctl is-active --quiet sing-box || failed=1; fi
    echo "Backup retained: $BACKUP; APT package/diversion changes are not rolled back." >&2
    [[ "$failed" == 0 ]] || echo 'ERROR: restoration incomplete; inspect both services before retrying.' >&2
  fi
  [[ -z "$CSTAGE" ]] || rm -f -- "$CSTAGE"
  [[ -z "$SSTAGE" ]] || rm -f -- "$SSTAGE"
  [[ -z "$WORK" ]] || rm -rf -- "$WORK"
  exit "$rc"
}
trap 'rollback $?' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

[[ $EUID == 0 ]] || die 'Run as root.'
. /etc/os-release
[[ "${ID:-}" == debian && "${VERSION_ID:-}" =~ ^(12|13)$ ]] || die 'Only Debian 12/13 supported.'
for command in python3 runuser systemctl dpkg-divert dpkg-query flock sed readlink stat; do command -v "$command" >/dev/null || die "Missing command: $command"; done
exec 9>/run/lock/caddy-migration.lock
flock -n 9 || die 'Another Caddy migration is running.'
getent passwd www-data >/dev/null && getent group www-data >/dev/null || die 'www-data account/group required.'
[[ -f "$CONFIG" && ! -L "$CONFIG" ]] || die 'Expected regular /etc/caddy/caddy.jsonc.'
[[ -f "$SCRIPT_DIR/migration-config.py" && -f "$SCRIPT_DIR/install-caddy-debian.sh" ]] || die 'Run from a complete repository checkout.'
systemctl is-active --quiet caddy || die 'Caddy must be active before migration.'
[[ "$(systemctl show caddy -p User --value)" == www-data && "$(systemctl show caddy -p Group --value)" == www-data ]] || die 'Expected Caddy running as www-data:www-data; review identity conversion first.'
START="$(systemctl show caddy -p ExecStart --value)"
[[ "$START" == *"$CONFIG"* && "$START" == *"--adapter jsonc"* ]] || die 'Expected Caddy JSONC service arguments.'
CORE="$(sed -n 's/.*path=\([^ ;]*\).*/\1/p' <<<"$START")"
case "$CORE" in /usr/bin/caddy|/usr/local/bin/caddy|/usr/bin/caddy.custom) ;; *) die "Unsupported executable path: $CORE";; esac
[[ -x "$CORE" ]] || die 'Caddy binary missing.'
FRAGMENT="$(systemctl show caddy -p FragmentPath --value)"
[[ -f "$FRAGMENT" && "$FRAGMENT" != /dev/null ]] || die 'Caddy unit fragment missing.'
# Other drop-in directories could override the managed /etc drop-in.
DROPINS="$(systemctl show caddy -p DropInPaths --value)"
for path in $DROPINS; do [[ "$path" == /etc/systemd/system/caddy.service.d/* ]] || die "Review external drop-in: $path"; done
if systemctl is-enabled --quiet caddy; then CADDY_ENABLED=true; fi
if [[ -e "$SING" ]]; then
  [[ -f "$SING" && ! -L "$SING" ]] || die 'Expected regular sing-box config.'
  SING_PRESENT=true
  [[ "$(systemctl show sing-box -p User --value)" == www-data && "$(systemctl show sing-box -p Group --value)" == www-data ]] || die 'Expected sing-box running as www-data:www-data.'
  SING_START="$(systemctl show sing-box -p ExecStart --value)"
  [[ "$SING_START" == *"$SING"* && "$SING_START" != *"-C "* && "$SING_START" != *"--config-directory"* ]] || die 'Expected sing-box single-file configuration.'
  SING_CORE="$(sed -n 's/.*path=\([^ ;]*\).*/\1/p' <<<"$SING_START")"
  [[ -x "$SING_CORE" ]] || die 'Missing service sing-box executable.'
  if systemctl is-active --quiet sing-box; then SING_ACTIVE=true; fi
fi
STANDARD=false
if [[ -L /usr/bin/caddy && "$(readlink -f /usr/bin/caddy)" == /usr/bin/caddy.custom && -x /usr/bin/caddy.default && -x /usr/bin/caddy.custom ]] &&
   dpkg-query -W -f='${Status}\n' caddy 2>/dev/null | grep -Fxq 'install ok installed' &&
   dpkg-divert --list /usr/bin/caddy | grep -Fq '/usr/bin/caddy.default' &&
   [[ "$FRAGMENT" == /usr/lib/systemd/system/caddy.service || "$FRAGMENT" == /lib/systemd/system/caddy.service ]] &&
   [[ "$CORE" == /usr/bin/caddy ]]; then STANDARD=true; fi
[[ "$STORAGE_ONLY" == false || "$STANDARD" == true ]] || die '--storage-only requires standard binary/service layout.'
WORK="$(mktemp -d /tmp/caddy-reconcile.XXXXXXXX)"
SING_ARG=-
[[ "$SING_PRESENT" == false ]] || SING_ARG="$SING"
python3 "$SCRIPT_DIR/migration-config.py" "$CONFIG" "$SING_ARG" "$WORK/caddy.jsonc" "$WORK/sing-box.json" > "$WORK/plan.json"
SOURCE="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["source"])' "$WORK/plan.json")"
[[ -d "$SOURCE" && ! -L "$SOURCE" && -d "$SOURCE/certificates" ]] || die "Missing real certificate storage: $SOURCE"
[[ ! -L "$NEW" ]] || die 'Destination storage must not be a symlink.'
for path in /var/lib/caddy /var/lib/caddy/.local /var/lib/caddy/.local/share; do
  [[ ! -L "$path" ]] || die "Storage parent must not be a symlink: $path"
done
# Refuse live-storage symlinks: copying them would leave credentials outside the
# managed tree and ownership changes could affect unrelated files.
[[ -z "$(find "$SOURCE" -type l -print -quit)" ]] || die 'Review symlinks inside certificate storage first.'
SING_CHANGES="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["sing_changes"])' "$WORK/plan.json")"
log "Standard installation: $STANDARD; Caddy storage: $SOURCE; sing-box path changes: $SING_CHANGES"
if [[ "$STANDARD" == true && "$SOURCE" == "$NEW" && "$SING_CHANGES" == 0 ]]; then
  runuser -u www-data -- env HOME=/var/lib/caddy "$CORE" validate --config "$CONFIG" --adapter jsonc
  [[ "$SING_PRESENT" == false ]] || runuser -u www-data -- "$SING_CORE" -D /var/lib/sing-box check -c "$SING"
  log 'Already standardized; no files changed and no services restarted.'
  exit 0
fi
if [[ "$APPLY" == false ]]; then
  log 'Read-only plan complete. Rerun with --apply to reconcile Caddy and sing-box.'
  exit 0
fi
# Prepare package/custom core before stopping production. No package/core changes
# are needed when the installation layout is already standard.
if [[ "$STANDARD" == false ]]; then
  bash "$SCRIPT_DIR/install-caddy-debian.sh" --prepare-only "$WORK/prepared"
fi
ID="$(date +%Y%m%d-%H%M%S)-$$"
BACKUP="/root/caddy-migration-backup/$ID"
install -d -m 0700 "$BACKUP"
cp -a "$CONFIG" "$BACKUP/caddy.jsonc"
[[ "$SING_PRESENT" == false ]] || cp -a "$SING" "$BACKUP/sing-box.json"
cp -a "$FRAGMENT" "$BACKUP/fragment"
if [[ -d /etc/systemd/system/caddy.service.d ]]; then cp -a /etc/systemd/system/caddy.service.d "$BACKUP/dropins"; fi
for path in /usr/bin/caddy /usr/bin/caddy.custom /usr/bin/caddy.default /usr/local/bin/caddy; do
  if [[ -e "$path" || -L "$path" ]]; then
    install -d -m 0700 "$BACKUP/binaries$(dirname "$path")"
    cp -a "$path" "$BACKUP/binaries$path"
  fi
done
printf 'Old storage retained: %s\nStandard layout before run: %s\n' "$SOURCE" "$STANDARD" > "$BACKUP/README.txt"
CHANGED=true
systemctl stop caddy
# Stop sing-box only if its certificate references will change, or its old
# references might be invalid while storage is replaced. Preserve inactive state.
if [[ "$SING_PRESENT" == true ]]; then systemctl stop sing-box; fi
if [[ "$STANDARD" == false ]]; then
  rm -f /usr/local/bin/caddy /etc/systemd/system/caddy.service
  systemctl daemon-reload
  bash "$SCRIPT_DIR/install-caddy-debian.sh" --prepared-dir "$WORK/prepared" --no-start
  CORE=/usr/bin/caddy
fi
if [[ "$SOURCE" != "$NEW" ]]; then
  install -d -o www-data -g www-data -m 0700 /var/lib/caddy
  install -d -o www-data -g www-data -m 0700 /var/lib/caddy/.local /var/lib/caddy/.local/share
  if [[ -e "$NEW" ]]; then
    OLD_NEW="${NEW}.before-migration-$ID"
    mv -- "$NEW" "$OLD_NEW"
    STORAGE_MOVED=true
    printf 'Previous destination storage: %s\n' "$OLD_NEW" >> "$BACKUP/README.txt"
  fi
  NEW_CREATED=true
  install -d -o www-data -g www-data -m 0700 "$NEW"
  cp -a "$SOURCE/." "$NEW/"
  chown -R www-data:www-data "$NEW"
fi
# Check all rewritten and existing standard certificate references before switch.
while IFS= read -r path; do runuser -u www-data -- test -r "$path" || die "Certificate/key not readable: $path"; done < <(python3 -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1]))["references"]))' "$WORK/plan.json" | sed '/^$/d')
CSTAGE="/etc/caddy/.migration-$ID.jsonc"
install -o root -g www-data -m 0640 "$WORK/caddy.jsonc" "$CSTAGE"
runuser -u www-data -- env HOME=/var/lib/caddy "$CORE" validate --config "$CSTAGE" --adapter jsonc
if [[ "$SING_PRESENT" == true ]]; then
  SSTAGE="/etc/sing-box/.migration-$ID.json"
  install -o root -g www-data -m 0640 "$WORK/sing-box.json" "$SSTAGE"
  runuser -u www-data -- "$SING_CORE" -D /var/lib/sing-box check -c "$SSTAGE"
fi
mv -f -- "$CSTAGE" "$CONFIG"
if [[ "$SING_PRESENT" == true ]]; then mv -f -- "$SSTAGE" "$SING"; fi
systemctl unmask caddy >/dev/null
systemctl daemon-reload
if [[ "$CADDY_ENABLED" == true ]]; then systemctl enable caddy; else systemctl disable caddy; fi
systemctl restart caddy
if [[ "$SING_ACTIVE" == true ]]; then systemctl restart sing-box; fi
sleep 3
systemctl is-active --quiet caddy || die 'Caddy failed after restart.'
[[ "$SING_ACTIVE" == false ]] || systemctl is-active --quiet sing-box || die 'sing-box failed after restart.'
[[ "$(systemctl show caddy -p User --value)" == www-data && "$(systemctl show caddy -p Group --value)" == www-data ]] || die 'Unexpected Caddy service identity.'
[[ "$(readlink -f /usr/bin/caddy)" == /usr/bin/caddy.custom ]] || die 'Unexpected Caddy binary selection.'
FINAL_START="$(systemctl show caddy -p ExecStart --value)"
[[ "$FINAL_START" == *"path=/usr/bin/caddy ;"* && "$FINAL_START" == *"$CONFIG"* ]] || die 'Unexpected effective Caddy startup command.'
CHANGED=false
log "SUCCESS: standard layout and certificate paths. Backup: $BACKUP"
echo 'Retain /home/tls and destination backup until actual websites/proxy nodes have been tested.'
systemctl show caddy -p User -p Group -p ExecStart --no-pager
