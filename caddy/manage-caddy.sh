#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly CADDY_BIN=/usr/bin/caddy CUSTOM_BIN=/usr/bin/caddy.custom
readonly DEFAULT_BIN=/usr/bin/caddy.default CONFIG=/etc/caddy/caddy.jsonc
readonly DROPIN=/etc/systemd/system/caddy.service.d/override.conf
readonly BACKUP_ROOT=/var/backups/caddy-manager
readonly CADDY_DATA=/var/lib/caddy/.local/share/caddy LEGACY_DATA=/home/tls
readonly -a SNAPSHOT_PATHS=(usr/local/bin/caddy usr/bin/caddy.custom etc/caddy
  etc/systemd/system/caddy.service etc/systemd/system/caddy.service.d
  run/systemd/system/caddy.service run/systemd/system/caddy.service.d
  etc/systemd/system/multi-user.target.wants/caddy.service
  home/tls var/lib/caddy)
WORK='' BACKUP='' TRANSACTION=0 POLICY=0 ATOMIC=''
log(){ printf '[INFO] %s\n' "$*"; }
warn(){ printf '[WARN] %s\n' "$*" >&2; }
die(){ warn "$*"; exit 1; }
require_root(){ [[ $EUID -eq 0 ]] || die 'Run as root.'; }
check_os(){
  # shellcheck disable=SC1091
  . /etc/os-release
  [[ $ID == debian && $VERSION_ID =~ ^(12|13)$ ]] || die 'Debian 12/13 required.'
}
exists(){ [[ -e $1 || -L $1 ]]; }
quiet(){ "$@" >"$WORK/command.log" 2>&1 || { warn "${1##*/} failed; diagnostic output withheld because it may contain secrets."; return 1; }; }
policy_restore(){
  (( POLICY )) || return 0
  rm -f /usr/sbin/policy-rc.d || return 1
  if exists "$WORK/policy-rc.d"; then cp -a "$WORK/policy-rc.d" /usr/sbin/policy-rc.d || return 1; fi
  POLICY=0
}
finish(){
  local rc=$?
  trap - EXIT ERR INT TERM HUP
  set +e
  policy_restore || { warn "Could not restore policy-rc.d; inspect $WORK before further package operations."; rc=1; }
  if (( TRANSACTION )); then
    warn "Transaction failed; restoring $BACKUP"
    # Run with errexit in a separate process: never suppress errors in restoration.
    ( set -Eeuo pipefail; restore_backup "$BACKUP" )
    # Conditional invocation would disable errexit in restore_backup.
    # shellcheck disable=SC2181
    if (( $? != 0 )); then
      warn "ROLLBACK FAILED. Backup retained at $BACKUP; manual recovery required."
      rc=1
    else
      warn 'Previous runtime and service state restored and verified.'
    fi
    (( rc != 0 )) || rc=1
  fi
  [[ -z $ATOMIC ]] || rm -f -- "$ATOMIC"
  if [[ -n $WORK ]] && (( ! POLICY )); then rm -rf -- "$WORK"; fi
  exit "$rc"
}
init(){
  require_root; check_os
  local tool
  for tool in flock systemctl dpkg-divert update-alternatives ss tar runuser timeout; do
    command -v "$tool" >/dev/null || die "Missing prerequisite: $tool"
  done
  install -d -m 0700 "$BACKUP_ROOT"
  exec 9>/run/lock/caddy-manager.lock
  flock -n 9 || die 'Another caddy-manager operation is running.'
  WORK=$(mktemp -d /var/tmp/caddy-manager.XXXXXXXX)
  trap finish EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM HUP
}
check_modules(){
  local bin=${1:-$CADDY_BIN} modules id
  [[ -x $bin ]] || die "Missing executable: $bin"
  modules=$("$bin" list-modules 2>/dev/null) || die 'Cannot list Caddy modules.'
  for id in layer4 http.ip_sources.cloudflare caddy.adapters.jsonc; do
    grep -Fxq "$id" <<<"$modules" || die "Missing module: $id"
  done
}
validate_config(){
  local bin=${1:-$CADDY_BIN} user=${2:-root}
  [[ -f $CONFIG ]] || die "Missing $CONFIG"
  quiet timeout 120 runuser -u "$user" -- "$bin" validate --config "$CONFIG" --adapter jsonc || die "JSONC validation failed as $user."
}
check_layout(){
  local divert
  divert=$(dpkg-divert --truename "$CADDY_BIN")
  [[ $divert == "$CADDY_BIN" || $divert == "$DEFAULT_BIN" ]] || die 'Foreign Caddy diversion; resolve manually.'
  if [[ $divert == "$DEFAULT_BIN" ]]; then
    [[ $(dpkg-divert --listpackage "$CADDY_BIN") == LOCAL ]] || die 'Caddy diversion is owned by another package.'
    [[ -x $DEFAULT_BIN ]] || die 'Missing diverted official binary.'
  else
    ! exists "$DEFAULT_BIN" || die 'Unmanaged caddy.default exists.'
  fi
  if update-alternatives --query caddy >"$WORK/alternatives" 2>/dev/null; then
    [[ $divert == "$DEFAULT_BIN" ]] || die 'Alternatives without expected diversion.'
    grep -Fxq "Link: $CADDY_BIN" "$WORK/alternatives" || die 'Foreign alternatives link.'
    ! grep -q '^ ' "$WORK/alternatives" || die 'Alternatives slave links are not supported.'
    local path
    while read -r path; do
      [[ $path == "$DEFAULT_BIN" || $path == "$CUSTOM_BIN" ]] || die 'Foreign alternatives candidate.'
    done < <(sed -n 's/^Alternative: //p' "$WORK/alternatives")
  else
    : >"$WORK/alternatives"
  fi
}
listeners(){
  local pid=$1
  ss -H -lntup | awk -v p="pid=$pid," 'index($0,p) {n=split($5,a,":"); print $1 ":" a[n]}' | sort -u
}
health(){
  local ports=$1 expected=${2:-} pid token actual attempt
  for ((attempt=0; attempt<15; attempt++)); do
    if systemctl is-active --quiet caddy.service; then
      pid=$(systemctl show -p MainPID --value caddy.service)
      if [[ $pid =~ ^[1-9][0-9]*$ ]] && kill -0 "$pid" 2>/dev/null; then
        actual=$(readlink -f "/proc/$pid/exe")
        if [[ -z $expected || $actual == "$(readlink -f "$expected")" ]]; then
          listeners "$pid" >"$WORK/listening"
          local missing=0
          while read -r token; do
            [[ -z $token ]] || grep -Fxq "$token" "$WORK/listening" || missing=1
          done <"$ports"
          if (( ! missing )); then return 0; fi
        fi
      fi
    fi
    sleep 1
  done
  warn 'Health check failed (active state, executable/MainPID or required TCP/UDP ports).'
  return 1
}
preflight(){
  check_layout
  [[ -f $CONFIG ]] || die "Place JSONC at $CONFIG first."
  local state pid exe token link
  # Explicitly reject unusual enablement links we cannot faithfully snapshot.
  while IFS= read -r -d '' link; do
    case $link in
      /etc/systemd/system/caddy.service|/run/systemd/system/caddy.service|/etc/systemd/system/multi-user.target.wants/caddy.service) ;;
      *) die "Unsupported Caddy enablement/alias link: $link" ;;
    esac
  done < <(find /etc/systemd/system /run/systemd/system -type l -lname '*caddy.service' -print0)
  state=$(systemctl is-enabled caddy.service 2>/dev/null || true)
  case $state in enabled|disabled|static|not-found|'') ;; *) die "Unsupported service enable state: $state";; esac
  [[ $(systemctl show -p LoadState --value caddy.service) != masked ]] || die 'Caddy is masked.'
  : >"$WORK/ports"
  if systemctl is-active --quiet caddy.service; then
    pid=$(systemctl show -p MainPID --value caddy.service)
    exe=$(readlink -f "/proc/$pid/exe")
    case $exe in /usr/local/bin/caddy|/usr/bin/caddy|/usr/bin/caddy.custom|/usr/bin/caddy.default) ;; *) die 'Unsupported running executable; cannot guarantee rollback.';; esac
    listeners "$pid" >"$WORK/ports"
    health "$WORK/ports" "$exe"
    validate_config "$exe" "$(systemctl show -p User --value caddy.service)"
  fi
  for token in ${CADDY_REQUIRED_PORTS:-}; do
    [[ $token =~ ^(tcp|udp):([0-9]+)$ ]] || die 'CADDY_REQUIRED_PORTS must contain tcp:PORT / udp:PORT tokens.'
    (( 10#${BASH_REMATCH[2]} > 0 && 10#${BASH_REMATCH[2]} <= 65535 )) || die 'Invalid port.'
    printf '%s\n' "$token" >>"$WORK/ports"
  done
  [[ -s $WORK/ports ]] || die 'No running listeners: explicitly set CADDY_REQUIRED_PORTS.'
}
backup_current(){
  local p
  BACKUP=$(mktemp -d "$BACKUP_ROOT/$(date -u +%Y%m%dT%H%M%SZ).XXXXXXXX")
  install -d -m 0700 "$BACKUP/files"
  for p in "${SNAPSHOT_PATHS[@]}"; do
    if exists "/$p"; then cp -a --parents "/$p" "$BACKUP/files/"; fi
  done
  # Save the APT binary only if it predates the transaction; never remove the package.
  for p in usr/bin/caddy usr/bin/caddy.default; do
    if exists "/$p"; then cp -a --parents "/$p" "$BACKUP/files/"; fi
  done
  cp "$WORK/alternatives" "$BACKUP/alternatives"
  dpkg-divert --truename "$CADDY_BIN" >"$BACKUP/divert"
  systemctl is-enabled caddy.service >"$BACKUP/enabled" 2>/dev/null || true
  if systemctl is-active --quiet caddy.service; then
    printf 'active\n' >"$BACKUP/active"
    local pid
    pid=$(systemctl show -p MainPID --value caddy.service)
    readlink -f "/proc/$pid/exe" >"$BACKUP/executable"
    listeners "$pid" >"$BACKUP/old-ports"
  else
    printf 'inactive\n' >"$BACKUP/active"
    : >"$BACKUP/old-ports"
  fi
  systemctl show -p User --value caddy.service >"$BACKUP/user"
  systemctl cat caddy.service >"$BACKUP/effective-unit" 2>/dev/null || true
  systemctl show caddy.service >"$BACKUP/service-state" 2>/dev/null || true
  printf '1\n' >"$BACKUP/format"
  log "Backup: $BACKUP"
}
stop_caddy(){
  if [[ $(systemctl show -p LoadState --value caddy.service) != not-found ]]; then
    systemctl stop caddy.service
  fi
}
atomic_binary(){
  local source=$1 target=$2
  ATOMIC=$(mktemp "$(dirname "$target")/.caddy-manager.XXXXXXXX")
  install -o root -g root -m 0755 "$source" "$ATOMIC"
  mv -fT "$ATOMIC" "$target"
  ATOMIC=''
}
restore_backup(){
  local d=$1 p old_divert current path priority mode value
  [[ $(cat "$d/format") == 1 ]] || die 'Unsupported/incomplete backup.'
  stop_caddy
  # Remove only the manager-supported alternatives group, using its public API.
  if update-alternatives --query caddy >/dev/null 2>&1; then update-alternatives --remove-all caddy; fi
  old_divert=$(cat "$d/divert")
  current=$(dpkg-divert --truename "$CADDY_BIN")
  if [[ $current != "$old_divert" ]]; then
    if [[ $old_divert == "$CADDY_BIN" ]]; then
      rm -f "$CADDY_BIN"
      dpkg-divert --remove --divert "$DEFAULT_BIN" --rename "$CADDY_BIN"
    else
      dpkg-divert --add --divert "$DEFAULT_BIN" --rename "$CADDY_BIN"
    fi
  fi
  for p in "${SNAPSHOT_PATHS[@]}"; do
    # TLS trees are overlaid, never deleted: retain certificates issued since backup.
    case $p in home/tls|var/lib/caddy)
      if exists "$d/files/$p"; then
        mkdir -p "/$p"
        cp -a "$d/files/$p/." "/$p/"
      fi ;;
    *)
      rm -rf -- "/${p:?}"
      if exists "$d/files/$p"; then mkdir -p "$(dirname "/$p")"; cp -a "$d/files/$p" "/$p"; fi ;;
    esac
  done
  for p in usr/bin/caddy.default usr/bin/caddy; do
    if exists "$d/files/$p"; then
      rm -f "/$p"
      cp -a "$d/files/$p" "/$p"
    fi
  done
  if [[ -s $d/alternatives ]]; then
    path=''
    while IFS= read -r p; do
      case $p in
        'Alternative: '*) path=${p#Alternative: } ;;
        'Priority: '*) priority=${p#Priority: }; update-alternatives --install "$CADDY_BIN" caddy "$path" "$priority" ;;
      esac
    done <"$d/alternatives"
    mode=$(sed -n 's/^Status: //p' "$d/alternatives")
    value=$(sed -n 's/^Value: //p' "$d/alternatives")
    if [[ $mode == auto ]]; then update-alternatives --auto caddy; else update-alternatives --set caddy "$value"; fi
  fi
  systemctl daemon-reload
  case $(cat "$d/enabled") in
    enabled) systemctl enable caddy.service ;;
    disabled|not-found|'')
      if [[ $(systemctl show -p LoadState --value caddy.service) != not-found ]]; then systemctl disable caddy.service; fi ;;
    static) : ;;
  esac
  if [[ $(cat "$d/active") == active ]]; then
    local exe
    exe=$(cat "$d/executable")
    validate_config "$exe" "$(cat "$d/user")"
    systemctl start caddy.service
    health "$d/old-ports" "$exe"
  else
    ! systemctl is-active --quiet caddy.service || die 'Could not restore inactive state.'
  fi
  printf 'restored\n' >"$d/result"
}
install_official_repo(){
  # Block maintainer-script service starts/restarts until our validated activation.
  if exists /usr/sbin/policy-rc.d; then cp -a /usr/sbin/policy-rc.d "$WORK/policy-rc.d"; fi
  POLICY=1
  rm -f /usr/sbin/policy-rc.d
  printf '#!/bin/sh\nexit 101\n' >/usr/sbin/policy-rc.d
  chmod 0755 /usr/sbin/policy-rc.d
  export DEBIAN_FRONTEND=noninteractive
  quiet apt-get update
  quiet apt-get install -y debian-keyring debian-archive-keyring apt-transport-https ca-certificates curl gnupg
  quiet curl --fail --silent --show-error --location --retry 3 --connect-timeout 15 --max-time 120 https://dl.cloudsmith.io/public/caddy/stable/gpg.key -o "$WORK/key"
  quiet gpg --batch --yes --dearmor -o "$WORK/key.gpg" "$WORK/key"
  quiet curl --fail --silent --show-error --location --retry 3 --connect-timeout 15 --max-time 120 https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt -o "$WORK/repo"
  [[ -s $WORK/key.gpg && -s $WORK/repo ]] || die 'Empty repository download.'
  install -m 0644 "$WORK/key.gpg" /usr/share/keyrings/caddy-stable-archive-keyring.gpg
  install -m 0644 "$WORK/repo" /etc/apt/sources.list.d/caddy-stable.list
  quiet apt-get update
  local apt_version
  apt_version=$(apt-cache madison caddy | awk -F '|' '$3 ~ /dl.cloudsmith.io\/public\/caddy\/stable/ {gsub(/ /,"",$2); print $2}' | sort -V | tail -n 1)
  [[ -n $apt_version ]] || die 'No Caddy package from official Stable repository.'
  quiet apt-get install -y "caddy=$apt_version"
  policy_restore
}
install_custom_binary(){
  local source=$1
  if [[ $(dpkg-divert --truename "$CADDY_BIN") == "$CADDY_BIN" ]]; then
    dpkg-divert --add --divert "$DEFAULT_BIN" --rename "$CADDY_BIN"
  fi
  atomic_binary "$source" "$CUSTOM_BIN"
  update-alternatives --install "$CADDY_BIN" caddy "$DEFAULT_BIN" 10
  update-alternatives --install "$CADDY_BIN" caddy "$CUSTOM_BIN" 50
  update-alternatives --set caddy "$CUSTOM_BIN"
}
check_service_contract(){
  local start reload
  start=$(systemctl show -p ExecStart --value caddy.service)
  reload=$(systemctl show -p ExecReload --value caddy.service)
  [[ $start == *"$CADDY_BIN run --config $CONFIG --adapter jsonc"* ]] || die 'Effective ExecStart differs from the managed JSONC command.'
  [[ $reload == *"$CADDY_BIN reload --config $CONFIG --adapter jsonc --force"* ]] || die 'Effective ExecReload differs from the managed JSONC command.'
}
install_dropin(){
  install -d -m 0755 "$(dirname "$DROPIN")"
  cat >"$DROPIN" <<'UNIT'
[Service]
ExecStart=
ExecStart=/usr/bin/caddy run --config /etc/caddy/caddy.jsonc --adapter jsonc
ExecReload=
ExecReload=/usr/bin/caddy reload --config /etc/caddy/caddy.jsonc --adapter jsonc --force
UNIT
  chmod 0644 "$DROPIN"
  systemctl daemon-reload
  [[ $(systemctl show -p User --value caddy.service) == caddy ]] || die 'Effective service user must be caddy.'
  [[ $(systemctl show -p Group --value caddy.service) == caddy ]] || die 'Effective service group must be caddy.'
  check_service_contract
}
migrate_tls(){
  if [[ -d $LEGACY_DATA ]]; then
    install -d -o caddy -g caddy -m 0700 "$CADDY_DATA"
    # Never overwrite an already-populated destination with stale legacy storage.
    cp -an "$LEGACY_DATA/." "$CADDY_DATA/"
    chown -R caddy:caddy "$CADDY_DATA"
    sed -i "s#\"/home/tls/\{0,1\}\"#\"$CADDY_DATA\"#g" "$CONFIG"
  fi
  if grep -q '/home/tls' "$CONFIG"; then die 'Unresolved legacy storage reference; use a literal /home/tls storage root.'; fi
  chown root:caddy "$CONFIG"
  chmod 0640 "$CONFIG"
}
build_custom(){
  local version actual
  command -v curl >/dev/null || die 'Install curl first.'
  command -v go >/dev/null || die 'Install a current Go toolchain first.'
  command -v xcaddy >/dev/null || die 'Install xcaddy first.'
  log 'Fetching latest Stable release and building custom Caddy (this can take several minutes).'
  quiet curl --fail --silent --show-error --location --retry 3 --connect-timeout 15 --max-time 120 https://api.github.com/repos/caddyserver/caddy/releases/latest -o "$WORK/release.json"
  version=$(sed -n 's/^[[:space:]]*"tag_name":[[:space:]]*"\(v[0-9]*\.[0-9]*\.[0-9]*\)".*/\1/p' "$WORK/release.json")
  [[ $version =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die 'Cannot determine latest Stable version.'
  # xcaddy uses its cwd for temporary Go files; keep everything private and disposable.
  (cd "$WORK"; quiet timeout "${CADDY_BUILD_TIMEOUT:-1800}" xcaddy build "$version" --output "$WORK/caddy" \
    --with github.com/mholt/caddy-l4 \
    --with github.com/WeidiDeng/caddy-cloudflare-ip \
    --with github.com/caddyserver/jsonc-adapter) || die 'xcaddy build failed or timed out.'
  actual=$("$WORK/caddy" version 2>/dev/null)
  [[ ${actual%% *} == "$version" ]] || die 'Built version differs from requested Stable release.'
  log "Built $version"
  check_modules "$WORK/caddy"
  validate_config "$WORK/caddy"
}
commit_transaction(){
  printf 'committed\n' >"$BACKUP/result"
  TRANSACTION=0
  local -a backups=()
  local d keep=${CADDY_BACKUP_KEEP:-5}
  # Only prune completed transactions. Failed/incomplete snapshots need human review.
  mapfile -t backups < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '20*' | sort -r)
  local count=0
  for d in "${backups[@]}"; do
    [[ -f $d/result && $(cat "$d/result") == committed ]] || continue
    count=$((count+1))
    if (( count > keep )); then rm -rf -- "$d"; fi
  done
  log "Committed successfully. Backup: $BACKUP"
}
upgrade_cmd(){
  preflight
  [[ -x $CUSTOM_BIN && $(readlink -f "$CADDY_BIN") == "$CUSTOM_BIN" ]] || die 'Run install/migrate to establish the managed layout first.'
  [[ ! -f /etc/systemd/system/caddy.service && ! -f /run/systemd/system/caddy.service ]] || die 'Run migrate to restore the official unit first.'
  [[ $(systemctl show -p User --value caddy.service) == caddy ]] || die 'Run migrate first.'
  [[ $(systemctl show -p Group --value caddy.service) == caddy ]] || die 'Effective group must be caddy.'
  [[ -f $DROPIN ]] || die 'Managed JSONC drop-in missing; run install/migrate.'
  [[ $(dpkg-divert --truename "$CADDY_BIN") == "$DEFAULT_BIN" && -s $WORK/alternatives ]] || die 'Managed diversion/alternatives missing.'
  check_service_contract
  build_custom
  # Permit traversal for caddy validation; all other temporary files remain private.
  chmod 0711 "$WORK"
  chmod 0755 "$WORK/caddy"
  validate_config "$WORK/caddy" caddy
  backup_current
  TRANSACTION=1
  atomic_binary "$WORK/caddy" "$CUSTOM_BIN"
  validate_config "$CUSTOM_BIN" caddy
  systemctl restart caddy.service
  health "$WORK/ports" "$CUSTOM_BIN"
  commit_transaction
}
setup_cmd(){
  local mode=$1 source=${CADDY_CUSTOM_BINARY:-} p
  preflight
  if [[ $mode == install ]]; then
    [[ ! -f /etc/systemd/system/caddy.service && ! -x /usr/local/bin/caddy ]] || die 'Legacy installation detected; use migrate.'
    [[ -n $source && -x $source ]] || die 'Set CADDY_CUSTOM_BINARY to a custom executable.'
  else
    if [[ -z $source ]]; then
      if [[ -x $CUSTOM_BIN && $(readlink -f "$CADDY_BIN") == "$CUSTOM_BIN" ]]; then
        source=$CUSTOM_BIN
      else
        source=/usr/local/bin/caddy
      fi
    fi
  fi
  check_modules "$source"
  quiet "$source" version
  validate_config "$source"
  cp "$source" "$WORK/caddy"
  chmod 0755 "$WORK/caddy"
  backup_current
  TRANSACTION=1
  stop_caddy
  # Refresh mutable storage with the writer stopped, before migration changes it.
  for p in home/tls var/lib/caddy; do
    if [[ -d /$p ]]; then
      cp -a --parents "/$p" "$BACKUP/files/"
    fi
  done
  install_official_repo
  if [[ $mode == migrate ]]; then
    rm -f /etc/systemd/system/caddy.service /run/systemd/system/caddy.service
    rm -f /etc/systemd/system/multi-user.target.wants/caddy.service
    # Legacy overrides can retain www-data or old paths; backed up as complete trees.
    rm -rf /etc/systemd/system/caddy.service.d /run/systemd/system/caddy.service.d
  fi
  install_custom_binary "$WORK/caddy"
  migrate_tls
  install_dropin
  validate_config "$CUSTOM_BIN" caddy
  systemctl enable caddy.service
  systemctl restart caddy.service
  health "$WORK/ports" "$CUSTOM_BIN"
  commit_transaction
  log "Keep $LEGACY_DATA until manual post-migration verification."
}
rollback_cmd(){
  local d=${1:-}
  check_layout
  if [[ -z $d ]]; then
    local candidate
    while read -r candidate; do
      if [[ -f $candidate/result && $(cat "$candidate/result") == committed ]]; then d=$candidate; break; fi
    done < <(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '20*' | sort -r)
  fi
  [[ -n $d ]] || die 'No committed backup; specify an explicit backup directory.'
  d=$(realpath -e "$d")
  [[ $d == "$BACKUP_ROOT/"* && -f $d/format && ! -L $d ]] || die 'Invalid backup directory.'
  [[ $(stat -c %u "$d") == 0 && $(stat -c %a "$d") == 700 ]] || die 'Backup must be root-owned, mode 0700.'
  # Preserve current runtime as a rescue snapshot before an explicit rollback.
  backup_current
  TRANSACTION=1
  restore_backup "$d"
  TRANSACTION=0
  log "Restored $d; rescue snapshot: $BACKUP"
}
status_cmd(){
  "$CADDY_BIN" version 2>/dev/null || true
  update-alternatives --display caddy 2>/dev/null || true
  # Avoid systemctl status/journal output, which can expose configuration secrets.
  systemctl show caddy.service -p LoadState -p ActiveState -p SubState -p MainPID -p User -p Group -p UnitFileState
}
check_cmd(){
  preflight
  check_modules
  check_service_contract
  validate_config "$CADDY_BIN" caddy
  health "$WORK/ports" "$CADDY_BIN"
  log 'Caddy checks passed.'
}
usage(){
  printf '%s\n' "Usage: $0 {install|migrate|upgrade|rollback [BACKUP_DIR]|check|status}" \
    'Fresh install: sudo env CADDY_CUSTOM_BINARY=/path/caddy CADDY_REQUIRED_PORTS="tcp:80 tcp:443" bash caddy/manage-caddy.sh install' \
    'Upgrade prerequisites: current Go, xcaddy, curl; no experimental caddy upgrade is used.'
}
main(){
  case ${1:-} in install|migrate|upgrade|rollback|check|status) ;; *) usage; return 2;; esac
  [[ ${CADDY_BACKUP_KEEP:-5} =~ ^[1-9][0-9]*$ ]] || die 'CADDY_BACKUP_KEEP must be a positive integer.'
  init
  case $1 in
    install|migrate) setup_cmd "$1" ;;
    upgrade) upgrade_cmd ;;
    rollback) rollback_cmd "${2:-}" ;;
    check) check_cmd ;;
    status) status_cmd ;;
  esac
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
