#!/usr/bin/env bash
# Shared normalization component for the standard linux_scripts deployment.
#
# Reconciles the *runtime state* of the selected services to the managed
# layout without installing packages, migrating data, rewriting certificate
# references, or changing application configuration:
#
#   - systemd runtime identity and startup command via one managed drop-in
#   - ownership and modes of the managed paths
#   - validation under the runtime identity before any applied restart
#   - restart only when a systemd unit change must take effect on a running
#     service; stopped/disabled state is always preserved
#
# This script is repeatable and idempotent: a fully compliant installation is
# left untouched (no file writes, no daemon-reload, no service restarts).
#
# Target state (the installers are the layout authorities; these values match
# them exactly so installer and normalization never oscillate):
#   caddy    www-data:www-data; HOME=/var/lib/caddy; managed drop-in with the
#            jsonc ExecStart/ExecReload for /etc/caddy/caddy.jsonc.
#   sing-box www-data:www-data; unified drop-in with StateDirectoryMode=0755
#            and ExecStart=/usr/bin/sing-box -D /var/lib/sing-box
#            -c /etc/sing-box/config.json run  (single-file mode; "-c" is
#            never replaced by "-C").
#
# Agreed permission matrix:
#   /etc/caddy                  root:www-data 0755
#   /etc/caddy/caddy.jsonc      root:www-data 0640
#   /etc/sing-box               root:www-data 0755
#   /etc/sing-box/config.json   root:www-data 0640
#   /var/lib/caddy              www-data:www-data 0755
#   /var/lib/sing-box           www-data:www-data 0755
#   /var/log/caddy              www-data:www-data 0755
#   /var/log/sing-box           www-data:www-data 0755
#   systemd drop-in directories root:root 0755, drop-in files root:root 0644
#   ordinary non-sensitive files 0644, executables 0755
#
# The policy is deliberately small and explicit (the installers use the
# identical rules): managed top-level directories are set to the exact matrix
# owner and mode, everything inside belongs to the matrix owner, and modes
# inside a tree are capped at the ordinary defaults but existing stricter
# modes are never relaxed — 0600 private keys and 0700 Caddy storage
# subdirectories survive every run. Ordinary users can list file names in the
# normal config, working and log directories without sudo; content stays
# protected by file modes and by the stricter sensitive subdirectories.
#
# Both services running as www-data means sing-box reads Caddy-managed
# certificates directly from Caddy storage; this script never copies
# certificates and never uses ACLs, supplementary groups or sync daemons.
#
# Usage: bash caddy/normalize-caddy-services.sh (--caddy | --sing-box | --both)
set -Eeuo pipefail

readonly CADDY_CONFIG="/etc/caddy/caddy.jsonc"
readonly CADDY_DROPIN_DIR="/etc/systemd/system/caddy.service.d"
readonly CADDY_DROPIN="${CADDY_DROPIN_DIR}/override.conf"
readonly CADDY_STATE="/var/lib/caddy"
readonly CADDY_LOG="/var/log/caddy"
readonly CADDY_ETC="/etc/caddy"
readonly SINGBOX_CONFIG="/etc/sing-box/config.json"
readonly SINGBOX_ETC="/etc/sing-box"
readonly SINGBOX_STATE="/var/lib/sing-box"
readonly SINGBOX_LOG="/var/log/sing-box"
readonly SINGBOX_DROPIN_DIR="/etc/systemd/system/sing-box.service.d"
readonly SINGBOX_RUN_DROPIN_DIR="/run/systemd/system/sing-box.service.d"
readonly SINGBOX_DROPIN="${SINGBOX_DROPIN_DIR}/override.conf"
readonly SINGBOX_LOCAL_UNIT="/etc/systemd/system/sing-box.service"
readonly SINGBOX_EXEC='/usr/bin/sing-box -D /var/lib/sing-box -c /etc/sing-box/config.json run'

readonly CADDY_DROPIN_CONTENT='[Service]
User=www-data
Group=www-data
Environment=HOME=/var/lib/caddy
ExecStart=
ExecStart=/usr/bin/caddy run --environ --config /etc/caddy/caddy.jsonc --adapter jsonc
ExecReload=
ExecReload=/usr/bin/caddy reload --config /etc/caddy/caddy.jsonc --adapter jsonc --force'

readonly SINGBOX_DROPIN_CONTENT='[Service]
User=www-data
Group=www-data
StateDirectoryMode=0755
ExecStart=
ExecStart=/usr/bin/sing-box -D /var/lib/sing-box -c /etc/sing-box/config.json run'

DO_CADDY=false
DO_SINGBOX=false
CADDY_DRIFT=false
SINGBOX_DRIFT=false
CADDY_UNIT_CHANGED=false
SINGBOX_UNIT_CHANGED=false
CADDY_APPLIED=false
SINGBOX_APPLIED=false
CADDY_WAS_ACTIVE=false
SINGBOX_WAS_ACTIVE=false
WORK_DIR=""
PERMS_MANIFEST=""

log(){ printf '\n==> %s\n' "$*"; }
die(){ printf '\nERROR: %s\n' "$*" >&2; exit 1; }
usage(){ printf 'Usage: %s (--caddy | --sing-box | --both)\n' "$0"; }

restore_service(){
  # A previously running service whose unit was changed must end up running
  # the restored unit, not the failed candidate; restarting is the only way
  # to converge a process that already picked up the candidate. Services
  # that were stopped or disabled before normalization are never started.
  local svc=$1 was_active=$2 unit_changed=$3
  [[ "$was_active" == true ]] || return 0
  if [[ "$unit_changed" == true ]]; then
    systemctl restart "$svc" >/dev/null 2>&1 || systemctl start "$svc" >/dev/null 2>&1 || true
  elif ! systemctl is-active --quiet "$svc"; then
    systemctl start "$svc" >/dev/null 2>&1 || true
  fi
  if systemctl is-active --quiet "$svc"; then
    printf 'Recovered: %s is active again with the restored configuration.\n' "$svc" >&2
    return 0
  fi
  printf 'WARNING: rollback could not restore the previously running %s service; inspect "systemctl status %s".\n' "$svc" "$svc" >&2
  return 1
}

cleanup(){
  local rc=$?
  trap - EXIT INT TERM HUP
  set +e
  if (( rc != 0 )) && { [[ "$CADDY_APPLIED" == true ]] || [[ "$SINGBOX_APPLIED" == true ]]; }; then
    printf '\nNormalization failed; restoring managed drop-ins and permission metadata where possible...\n' >&2
    if [[ "$CADDY_APPLIED" == true ]]; then
      rm -f -- "$CADDY_DROPIN"
      local f
      for f in "$WORK_DIR"/backups/caddy/*.conf; do
        [[ -f "$f" ]] || continue
        install -d -m 0755 "$CADDY_DROPIN_DIR"
        cp -a -- "$f" "$CADDY_DROPIN_DIR"/
      done
    fi
    if [[ "$SINGBOX_APPLIED" == true ]]; then
      local dir backup
      for dir in "$SINGBOX_DROPIN_DIR" "$SINGBOX_RUN_DROPIN_DIR"; do
        # Match the fixed relative backup layout used when snapshots were taken.
        case "$dir" in
          "$SINGBOX_DROPIN_DIR") backup="$WORK_DIR/backups/etc/systemd/system";;
          *) backup="$WORK_DIR/backups/run/systemd/system";;
        esac
        [[ -d "$dir" ]] && rm -f -- "$dir"/*.conf
        install -d -m 0755 "$(dirname "$dir")"
        [[ -d "$backup" ]] && cp -a -- "$backup"/. "$dir"/
      done
    fi
    if [[ -n "$PERMS_MANIFEST" && -f "$PERMS_MANIFEST" ]]; then
      local entry mode uid gid path
      while IFS= read -r -d '' entry; do
        mode=${entry%% *}; entry=${entry#* }
        uid=${entry%% *}; entry=${entry#* }
        gid=${entry%% *}; path=${entry#* }
        [[ -e "$path" || -L "$path" ]] || continue
        chown -h "$uid:$gid" "$path"
        [[ -L "$path" ]] || chmod "$mode" "$path"
      done <"$PERMS_MANIFEST"
    fi
    systemctl daemon-reload
    local services_recovered=true
    if [[ "$CADDY_APPLIED" == true ]]; then
      restore_service caddy "$CADDY_WAS_ACTIVE" "$CADDY_UNIT_CHANGED" || services_recovered=false
    fi
    if [[ "$SINGBOX_APPLIED" == true ]]; then
      restore_service sing-box "$SINGBOX_WAS_ACTIVE" "$SINGBOX_UNIT_CHANGED" || services_recovered=false
    fi
    if [[ "$services_recovered" == true ]]; then
      printf 'Rollback complete: managed files, permissions and previously running services were restored.\n' >&2
    else
      printf 'ERROR: rollback is INCOMPLETE: files were restored but service recovery failed.\n' >&2
    fi
    printf 'Backup retained: %s\n' "$WORK_DIR" >&2
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

parse_args(){
  local seen=false
  while (( $# )); do
    case "$1" in
      --caddy)    [[ "$seen" == false ]] || die "Select exactly one mode."; DO_CADDY=true; seen=true;;
      --sing-box) [[ "$seen" == false ]] || die "Select exactly one mode."; DO_SINGBOX=true; seen=true;;
      --both)     [[ "$seen" == false ]] || die "Select exactly one mode."; DO_CADDY=true; DO_SINGBOX=true; seen=true;;
      -h|--help) usage; exit 0;;
      *) usage >&2; die "Unknown option: $1";;
    esac
    shift
  done
  [[ "$seen" == true ]] || { usage >&2; die "A service selection mode is required: --caddy, --sing-box or --both."; }
}

preflight(){
  [[ ${EUID} -eq 0 ]] || die "Run this script as root."
  getent passwd www-data >/dev/null || die "User 'www-data' does not exist."
  getent group www-data >/dev/null || die "Group 'www-data' does not exist."
  local command
  for command in systemctl runuser stat find install chown chmod cmp readlink grep dpkg-query; do
    command -v "$command" >/dev/null 2>&1 || die "Missing required command: $command"
  done
  if [[ "$DO_CADDY" == true ]]; then
    [[ -x /usr/bin/caddy ]] || die "/usr/bin/caddy is missing; run caddy/install-caddy-debian.sh first."
  fi
  if [[ "$DO_SINGBOX" == true ]]; then
    if ! dpkg-query -W -f='${Status}\n' sing-box 2>/dev/null | grep -Fxq 'install ok installed'; then
      log "sing-box package is not installed; nothing to normalize for sing-box."
      DO_SINGBOX=false
    fi
  fi
  if [[ "$DO_CADDY$DO_SINGBOX" != *true* ]]; then
    log "No managed services selected or present; nothing to do."
    exit 0
  fi
  WORK_DIR="$(mktemp -d /run/normalize-caddy-services.XXXXXXXX)"
  chmod 0700 "$WORK_DIR"
  PERMS_MANIFEST="$WORK_DIR/permissions"
  : >"$PERMS_MANIFEST"
}

snapshot_perm(){
  local path=$1
  [[ -e "$path" || -L "$path" ]] || return 0
  find "$path" -xdev -printf '%m %U %G %p\0' >>"$PERMS_MANIFEST" \
    || die "Cannot snapshot permissions for $path."
}

owner_mode(){ stat -c '%U:%G %a' "$1" 2>/dev/null || printf 'missing\n'; }

cap_tree(){
  # Apply the agreed permission policy to one managed tree: everything
  # belongs to $owner, and modes are capped at the ordinary defaults
  # (directories and executables 0755, ordinary files 0644). Existing modes
  # that are already at or stricter than the cap are left untouched, so
  # private keys (0600) and sensitive Caddy storage subdirectories (0700)
  # are never relaxed. Managed top-level directories are set exactly by the
  # caller with install -d.
  local tree=$1 owner=$2 mode path
  find "$tree" -xdev \( -type d -o -type f \) -exec chown "$owner" {} + \
    || die "Cannot change ownership under $tree."
  while IFS= read -r -d '' mode && IFS= read -r -d '' path; do
    if (( 8#$mode & ~8#755 )); then chmod 0755 "$path" || die "Cannot cap $path."; fi
  done < <(find "$tree" -xdev -type d -printf '%m\0%p\0')
  while IFS= read -r -d '' mode && IFS= read -r -d '' path; do
    if (( 8#$mode & ~8#755 )); then chmod 0755 "$path" || die "Cannot cap $path."; fi
  done < <(find "$tree" -xdev -type f -perm /111 -printf '%m\0%p\0')
  while IFS= read -r -d '' mode && IFS= read -r -d '' path; do
    if (( 8#$mode & ~8#644 )); then chmod 0644 "$path" || die "Cannot cap $path."; fi
  done < <(find "$tree" -xdev -type f ! -perm /111 -printf '%m\0%p\0')
}

# ---------------- caddy ----------------

caddy_desired_dropin_current(){
  [[ -d "$CADDY_DROPIN_DIR" ]] || return 1
  [[ ! -L "$CADDY_DROPIN" ]] || die "$CADDY_DROPIN is a symlink; refusing to follow it."
  [[ -f "$CADDY_DROPIN" ]] || return 1
  cmp -s <(printf '%s\n' "$CADDY_DROPIN_CONTENT") "$CADDY_DROPIN" || return 1
  [[ "$(owner_mode "$CADDY_DROPIN")" == "root:root 644" ]] || return 1
  [[ "$(owner_mode "$CADDY_DROPIN_DIR")" == "root:root 755" ]] || return 1
  return 0
}

caddy_paths_current(){
  [[ "$(owner_mode "$CADDY_STATE")" == "www-data:www-data 755" ]] || return 1
  if [[ -e "$CADDY_LOG" ]]; then
    [[ -d "$CADDY_LOG" && ! -L "$CADDY_LOG" ]] || die "$CADDY_LOG exists but is not a directory."
    [[ "$(owner_mode "$CADDY_LOG")" == "www-data:www-data 755" ]] || return 1
  fi
  [[ -d "$CADDY_ETC" && ! -L "$CADDY_ETC" ]] || die "$CADDY_ETC must be a real directory."
  [[ "$(owner_mode "$CADDY_ETC")" == "root:www-data 755" ]] || return 1
  if [[ -e "$CADDY_CONFIG" ]]; then
    [[ -f "$CADDY_CONFIG" && ! -L "$CADDY_CONFIG" ]] || die "$CADDY_CONFIG exists but is not a regular file."
    [[ "$(owner_mode "$CADDY_CONFIG")" == "root:www-data 640" ]] || return 1
  fi
  return 0
}

reconcile_caddy(){
  log "Reconciling caddy service state"

  CADDY_WAS_ACTIVE=false
  if systemctl is-active --quiet caddy; then CADDY_WAS_ACTIVE=true; fi

  [[ ! -L "$CADDY_STATE" ]] || die "$CADDY_STATE is a symlink; refusing to follow it."
  [[ ! -L "$CADDY_DROPIN_DIR" ]] || die "$CADDY_DROPIN_DIR is a symlink; refusing to follow it."

  local dropin_ok paths_ok
  dropin_ok=false; caddy_desired_dropin_current && dropin_ok=true
  paths_ok=false; caddy_paths_current && paths_ok=true
  CADDY_DRIFT=false
  [[ "$dropin_ok" == true && "$paths_ok" == true ]] || CADDY_DRIFT=true
  CADDY_UNIT_CHANGED=false
  [[ "$dropin_ok" == true ]] || CADDY_UNIT_CHANGED=true

  if [[ "$CADDY_DRIFT" == false ]]; then
    log "caddy is already compliant; no changes"
    return 0
  fi

  # Changes are applied before any restart is attempted; validating under the
  # runtime identity protects a currently-running deployment.
  if systemctl is-active --quiet caddy && [[ -f "$CADDY_CONFIG" ]]; then
    log "Validating $CADDY_CONFIG as www-data"
    runuser -u www-data -- env HOME="$CADDY_STATE" /usr/bin/caddy validate \
      --config "$CADDY_CONFIG" --adapter jsonc \
      || die "Configuration validation failed as www-data; nothing was changed."
  fi

  install -d -o root -g root -m 0755 "$CADDY_DROPIN_DIR"
  snapshot_perm "$CADDY_DROPIN_DIR"
  mkdir -p "$WORK_DIR/backups/caddy"
  [[ -f "$CADDY_DROPIN" ]] && cp -a -- "$CADDY_DROPIN" "$WORK_DIR/backups/caddy"/

  # Only the managed override.conf is rewritten; unrelated caddy drop-ins are
  # preserved, matching install-caddy-debian.sh.
  local tmp
  tmp=$(mktemp "$CADDY_DROPIN_DIR/.override.conf.XXXXXX")
  printf '%s\n' "$CADDY_DROPIN_CONTENT" >"$tmp"
  chown root:root "$tmp"
  chmod 0644 "$tmp"
  CADDY_APPLIED=true
  mv -f -- "$tmp" "$CADDY_DROPIN"
  log "Installed managed caddy drop-in: $CADDY_DROPIN"

  snapshot_perm "$CADDY_STATE"
  install -d -o www-data -g www-data -m 0755 "$CADDY_STATE"
  cap_tree "$CADDY_STATE" www-data:www-data

  if [[ -e "$CADDY_LOG" ]]; then
    snapshot_perm "$CADDY_LOG"
    install -d -o www-data -g www-data -m 0755 "$CADDY_LOG"
    cap_tree "$CADDY_LOG" www-data:www-data
  fi

  snapshot_perm "$CADDY_ETC"
  install -d -o root -g www-data -m 0755 "$CADDY_ETC"
  if [[ -e "$CADDY_CONFIG" ]]; then
    # The managed config is pinned to exactly 0640 (not merely capped) so a
    # file left world-readable by an older release converges on the matrix.
    chown root:www-data "$CADDY_CONFIG"
    chmod 0640 "$CADDY_CONFIG"
  fi

  systemctl daemon-reload

  local user group
  user="$(systemctl show caddy -p User --value 2>/dev/null || true)"
  group="$(systemctl show caddy -p Group --value 2>/dev/null || true)"
  [[ "$user" == www-data && "$group" == www-data ]] \
    || die "Effective caddy identity is ${user:-?}:${group:-?}, not www-data:www-data; a local unit or mask overrides the managed drop-in."

  if [[ "$CADDY_UNIT_CHANGED" == true ]] && systemctl is-active --quiet caddy; then
    log "Restarting caddy to apply the reconciled unit"
    systemctl restart caddy
    local state
    state="$(systemctl is-active caddy)"
    [[ "$state" == active ]] || die "caddy failed to become active after restart; inspect 'systemctl status caddy'."
  else
    log "caddy is not running; stopped/disabled state preserved"
  fi
}

# ---------------- sing-box ----------------

singbox_dropin_current(){
  [[ ! -L "$SINGBOX_DROPIN" ]] || die "$SINGBOX_DROPIN is a symlink; refusing to follow it."
  [[ -f "$SINGBOX_DROPIN" ]] || return 1
  cmp -s <(printf '%s\n' "$SINGBOX_DROPIN_CONTENT") "$SINGBOX_DROPIN" || return 1
  [[ "$(owner_mode "$SINGBOX_DROPIN")" == "root:root 644" ]] || return 1
  local file
  for file in "$SINGBOX_DROPIN_DIR"/*.conf "$SINGBOX_RUN_DROPIN_DIR"/*.conf; do
    [[ -e "$file" ]] || continue
    [[ "$file" == "$SINGBOX_DROPIN" ]] || return 1
  done
  return 0
}

singbox_paths_current(){
  [[ -d "$SINGBOX_ETC" && ! -L "$SINGBOX_ETC" ]] || die "$SINGBOX_ETC must be a real directory."
  [[ "$(owner_mode "$SINGBOX_ETC")" == "root:www-data 755" ]] || return 1
  if [[ -e "$SINGBOX_CONFIG" ]]; then
    [[ -f "$SINGBOX_CONFIG" && ! -L "$SINGBOX_CONFIG" ]] || die "$SINGBOX_CONFIG exists but is not a regular file."
    # config.json is pinned to 0640 by both this script and the sing-box
    # installer, so neither run ever reverses the other.
    [[ "$(owner_mode "$SINGBOX_CONFIG")" == "root:www-data 640" ]] || return 1
  fi
  [[ -d "$SINGBOX_STATE" && ! -L "$SINGBOX_STATE" ]] || die "$SINGBOX_STATE must be a real directory."
  [[ "$(owner_mode "$SINGBOX_STATE")" == "www-data:www-data 755" ]] || return 1
  if [[ -e "$SINGBOX_LOG" ]]; then
    [[ -d "$SINGBOX_LOG" && ! -L "$SINGBOX_LOG" ]] || die "$SINGBOX_LOG exists but is not a directory."
    [[ "$(owner_mode "$SINGBOX_LOG")" == "www-data:www-data 755" ]] || return 1
  fi
  [[ "$(owner_mode "$SINGBOX_DROPIN_DIR")" == "root:root 755" ]] || return 1
  return 0
}

singbox_exec_current(){
  local exec
  exec="$(systemctl show sing-box -p ExecStart --value 2>/dev/null || true)"
  [[ "$exec" == *"argv[]=$SINGBOX_EXEC ;"* ]]
}

reconcile_singbox(){
  log "Reconciling sing-box service state"

  SINGBOX_WAS_ACTIVE=false
  if systemctl is-active --quiet sing-box; then SINGBOX_WAS_ACTIVE=true; fi

  if [[ -e "$SINGBOX_LOCAL_UNIT" || -L "$SINGBOX_LOCAL_UNIT" ]]; then
    # Removing a shadowing local unit is a migration decision (it may carry
    # bespoke settings), not runtime normalization.
    die "Local unit $SINGBOX_LOCAL_UNIT shadows the package-owned unit; resolve it first (caddy/migrate-caddy-deployment.sh, or the installers, handle layout changes)."
  fi

  local load_state
  load_state="$(systemctl show sing-box -p LoadState --value 2>/dev/null || true)"
  [[ "$load_state" == "masked" ]] && die "sing-box is masked; unmask it (or rerun the installer) before normalizing."

  local current_exec config_dir
  current_exec="$(systemctl show sing-box -p ExecStart --value 2>/dev/null || true)"
  if [[ "$current_exec" =~ -C[[:space:]]+([^[:space:]\;]+) ]]; then
    config_dir=${BASH_REMATCH[1]}
    if [[ -d "$config_dir" ]]; then
      local -a extras=()
      mapfile -t extras < <(
        find "$config_dir" -maxdepth 1 \
          \( -name '*.json' -o -name '*.jsonc' \) ! -name config.json -print 2>/dev/null
      )
      if (( ${#extras[@]} )); then
        printf 'Additional directory-mode inputs:\n  %s\n' "${extras[@]}" >&2
        die "Refusing to replace -C $config_dir with -c $SINGBOX_CONFIG because those inputs would be silently omitted; merge them into config.json first."
      fi
    fi
  fi

  if systemctl is-active --quiet sing-box && [[ ! -f "$SINGBOX_CONFIG" ]]; then
    die "$SINGBOX_CONFIG is missing; refusing to reconfigure the running sing-box service."
  fi

  local dropin_ok paths_ok exec_ok
  dropin_ok=false; singbox_dropin_current && dropin_ok=true
  paths_ok=false; singbox_paths_current && paths_ok=true
  exec_ok=false; singbox_exec_current && exec_ok=true
  SINGBOX_DRIFT=false
  SINGBOX_UNIT_CHANGED=false
  [[ "$dropin_ok" == true && "$exec_ok" == true ]] || SINGBOX_UNIT_CHANGED=true
  [[ "$dropin_ok" == true && "$paths_ok" == true && "$exec_ok" == true ]] || SINGBOX_DRIFT=true

  if [[ "$SINGBOX_DRIFT" == false ]]; then
    log "sing-box is already compliant; no changes"
    return 0
  fi

  if systemctl is-active --quiet sing-box; then
    log "Validating $SINGBOX_CONFIG as www-data"
    runuser -u www-data -- /usr/bin/sing-box -D "$SINGBOX_STATE" check -c "$SINGBOX_CONFIG" \
      || die "sing-box validation failed as www-data; nothing was changed."
  fi

  mkdir -p "$WORK_DIR/backups/etc/systemd/system" "$WORK_DIR/backups/run/systemd/system"
  snapshot_perm "$SINGBOX_DROPIN_DIR"
  snapshot_perm "$SINGBOX_RUN_DROPIN_DIR"
  cp -a -- "$SINGBOX_DROPIN_DIR"/*.conf "$WORK_DIR/backups/etc/systemd/system/" 2>/dev/null || true
  cp -a -- "$SINGBOX_RUN_DROPIN_DIR"/*.conf "$WORK_DIR/backups/run/systemd/system/" 2>/dev/null || true

  # Converge on the installer's unified drop-in convention: every previous
  # sing-box drop-in (etc and run) is replaced by the managed override.conf.
  local dir
  for dir in "$SINGBOX_DROPIN_DIR" "$SINGBOX_RUN_DROPIN_DIR"; do
    [[ -d "$dir" ]] || continue
    rm -f -- "$dir"/*.conf
  done
  install -d -o root -g root -m 0755 "$SINGBOX_DROPIN_DIR"
  local tmp
  tmp=$(mktemp "$SINGBOX_DROPIN_DIR/.override.conf.XXXXXX")
  printf '%s\n' "$SINGBOX_DROPIN_CONTENT" >"$tmp"
  chown root:root "$tmp"
  chmod 0644 "$tmp"
  SINGBOX_APPLIED=true
  mv -f -- "$tmp" "$SINGBOX_DROPIN"
  log "Installed unified sing-box drop-in: $SINGBOX_DROPIN"

  # Permission policy identical to install-sing-box-debian.sh: managed
  # top-level directories carry the exact matrix owner/mode (0755), inner
  # modes are capped but never relaxed, and config.json is pinned to 0640
  # because it can hold proxy credentials. TLS private keys live in Caddy
  # storage, whose sensitive subdirectories keep their stricter modes.
  local tree owner user_name group_name
  for tree in "$SINGBOX_ETC" "$SINGBOX_STATE"; do
    owner=root:www-data
    [[ "$tree" == "$SINGBOX_STATE" ]] && owner=www-data:www-data
    user_name=${owner%%:*}; group_name=${owner##*:}
    snapshot_perm "$tree"
    install -d -o "$user_name" -g "$group_name" -m 0755 "$tree"
    cap_tree "$tree" "$owner"
  done
  if [[ -e "$SINGBOX_LOG" ]]; then
    snapshot_perm "$SINGBOX_LOG"
    install -d -o www-data -g www-data -m 0755 "$SINGBOX_LOG"
    cap_tree "$SINGBOX_LOG" www-data:www-data
  fi
  if [[ -e "$SINGBOX_CONFIG" ]]; then
    chown root:www-data "$SINGBOX_CONFIG"
    chmod 0640 "$SINGBOX_CONFIG"
  fi

  systemctl daemon-reload

  local user group
  user="$(systemctl show sing-box -p User --value 2>/dev/null || true)"
  group="$(systemctl show sing-box -p Group --value 2>/dev/null || true)"
  [[ "$user" == www-data && "$group" == www-data ]] \
    || die "Effective sing-box identity is ${user:-?}:${group:-?}, not www-data:www-data."
  singbox_exec_current \
    || die "Effective sing-box ExecStart did not become the managed single-file invocation."

  if [[ "$SINGBOX_UNIT_CHANGED" == true ]] && systemctl is-active --quiet sing-box; then
    log "Restarting sing-box to apply the reconciled unit"
    systemctl restart sing-box
    local state
    state="$(systemctl is-active sing-box)"
    [[ "$state" == active ]] || die "sing-box failed to become active after restart; inspect 'systemctl status sing-box'."
  else
    log "sing-box unit unchanged or not running; runtime state preserved"
  fi
}

main(){
  parse_args "$@"
  preflight
  if [[ "$DO_CADDY" == true ]]; then reconcile_caddy; fi
  if [[ "$DO_SINGBOX" == true ]]; then reconcile_singbox; fi

  log "Normalization summary"
  if [[ "$DO_CADDY" == true ]]; then
    if [[ "$CADDY_DRIFT" == true ]]; then printf 'caddy: reconciled\n'; else printf 'caddy: compliant (no changes)\n'; fi
  fi
  if [[ "$DO_SINGBOX" == true ]]; then
    if [[ "$SINGBOX_DRIFT" == true ]]; then printf 'sing-box: reconciled\n'; else printf 'sing-box: compliant (no changes)\n'; fi
  fi
  if [[ "$DO_CADDY" == true ]]; then systemctl show caddy -p User -p Group --no-pager; fi
  if [[ "$DO_SINGBOX" == true ]]; then systemctl show sing-box -p User -p Group -p ExecStart --no-pager; fi
}

main "$@"
