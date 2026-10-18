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
#            jsonc ExecStart/ExecReload for /etc/caddy/caddy.jsonc. Sensitive
#            state stays restrictive: /var/lib/caddy 0700 www-data,
#            /etc/caddy 0750 root:www-data, caddy.jsonc 0640 root:www-data,
#            /var/log/caddy 0750 www-data.
#   sing-box www-data:www-data; unified drop-in with StateDirectoryMode=0755
#            and ExecStart=/usr/bin/sing-box -D /var/lib/sing-box
#            -c /etc/sing-box/config.json run  (single-file mode; "-c" is
#            never replaced by "-C"). Ordinary paths use the installer policy:
#            directories 0755, ordinary files 0644, executables 0755.
#            /etc/sing-box/config.json is 0644 because the frozen sing-box
#            installer normalizes that tree that way.
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
WORK_DIR=""
PERMS_MANIFEST=""

log(){ printf '\n==> %s\n' "$*"; }
die(){ printf '\nERROR: %s\n' "$*" >&2; exit 1; }
usage(){ printf 'Usage: %s (--caddy | --sing-box | --both)\n' "$0"; }

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
        backup="$WORK_DIR/backups$(dirname "$dir")"
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
  [[ "$(owner_mode "$CADDY_STATE")" == "www-data:www-data 700" ]] || return 1
  if [[ -e "$CADDY_LOG" ]]; then
    [[ -d "$CADDY_LOG" && ! -L "$CADDY_LOG" ]] || die "$CADDY_LOG exists but is not a directory."
    [[ "$(owner_mode "$CADDY_LOG")" == "www-data:www-data 750" ]] || return 1
  fi
  [[ -d "$CADDY_ETC" && ! -L "$CADDY_ETC" ]] || die "$CADDY_ETC must be a real directory."
  [[ "$(owner_mode "$CADDY_ETC")" == "root:www-data 750" ]] || return 1
  if [[ -e "$CADDY_CONFIG" ]]; then
    [[ -f "$CADDY_CONFIG" && ! -L "$CADDY_CONFIG" ]] || die "$CADDY_CONFIG exists but is not a regular file."
    [[ "$(owner_mode "$CADDY_CONFIG")" == "root:www-data 640" ]] || return 1
  fi
  return 0
}

reconcile_caddy(){
  log "Reconciling caddy service state"

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
  install -d -o www-data -g www-data -m 0700 "$CADDY_STATE"
  chown -R www-data:www-data "$CADDY_STATE"
  chmod 0700 "$CADDY_STATE"

  if [[ -e "$CADDY_LOG" ]]; then
    snapshot_perm "$CADDY_LOG"
    install -d -o www-data -g www-data -m 0750 "$CADDY_LOG"
    chown -R www-data:www-data "$CADDY_LOG"
    chmod 0750 "$CADDY_LOG"
  fi

  snapshot_perm "$CADDY_ETC"
  chown root:www-data "$CADDY_ETC"
  chmod 0750 "$CADDY_ETC"
  if [[ -e "$CADDY_CONFIG" ]]; then
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
    # The frozen installer normalizes this tree to 0644; keep identical values
    # so installer and normalization never oscillate.
    [[ "$(owner_mode "$SINGBOX_CONFIG")" == "root:www-data 644" ]] || return 1
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

  # Permission policy identical to install-sing-box-debian.sh: ordinary
  # directories 0755, ordinary files 0644, executables 0755. TLS private keys
  # live in Caddy storage (/var/lib/caddy, 0700), not in these trees.
  local tree owner user_name group_name
  for tree in "$SINGBOX_ETC" "$SINGBOX_STATE"; do
    owner=root:www-data
    [[ "$tree" == "$SINGBOX_STATE" ]] && owner=www-data:www-data
    user_name=${owner%%:*}; group_name=${owner##*:}
    snapshot_perm "$tree"
    install -d -o "$user_name" -g "$group_name" -m 0755 "$tree"
    find "$tree" -xdev -type d -exec chmod 0755 {} +
    find "$tree" -xdev -type f -perm /111 -exec chmod 0755 {} +
    find "$tree" -xdev -type f ! -perm /111 -exec chmod 0644 {} +
    find "$tree" -xdev \( -type d -o -type f \) -exec chown "$owner" {} +
  done
  if [[ -e "$SINGBOX_LOG" ]]; then
    snapshot_perm "$SINGBOX_LOG"
    install -d -o www-data -g www-data -m 0755 "$SINGBOX_LOG"
    find "$SINGBOX_LOG" -xdev -type d -exec chmod 0755 {} +
    find "$SINGBOX_LOG" -xdev -type f -perm /111 -exec chmod 0755 {} +
    find "$SINGBOX_LOG" -xdev -type f ! -perm /111 -exec chmod 0644 {} +
    find "$SINGBOX_LOG" -xdev \( -type d -o -type f \) -exec chown www-data:www-data {} +
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
