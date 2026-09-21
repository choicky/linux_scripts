#!/usr/bin/env bash
# shellcheck disable=SC2016,SC1091,SC2329,SC2034
# Intentional literal rewriting and command doubles invoked by the sourced script.
# Isolated filesystem + command doubles. Never calls host systemd/APT/dpkg.
set -Eeuo pipefail
BASE=$(cd "$(dirname "$0")/../.." && pwd)
SANDBOX=$(mktemp -d)
trap 'rm -rf -- "$SANDBOX"' EXIT
export SANDBOX BASE
run_case(){
  local name=$1
  mkdir -p "$SANDBOX/$name"
  (
    set -Eeuo pipefail
    ROOT="$SANDBOX/$name"
    # Rewrite fixed production paths BEFORE sourcing; no privileged operations.
    sed -e "s@/usr/@$ROOT/usr/@g" -e "s@/etc/@$ROOT/etc/@g" \
      -e "s@/var/@$ROOT/var/@g" -e "s@/home/@$ROOT/home/@g" \
      -e "s@/run/@$ROOT/run/@g" \
      -e 's@"/$p/"@"$ROOT/$p/"@g' -e 's@"/$p"@"$ROOT/$p"@g' -e 's@"/${p:?}"@"$ROOT/${p:?}"@g' \
      -e 's@\[\[ -d /$p@[[ -d $ROOT/$p@g' \
      "$BASE/caddy/manage-caddy.sh" >"$ROOT/manager.sh"
    # shellcheck source=../manage-caddy.sh
    source "$ROOT/manager.sh"
    # GNU cp --parents must snapshot repository-relative paths in this harness.
    cp(){
      if [[ " $* " == *' --parents '* ]]; then
        local src=${*: -2:1} dst=${*: -1}
        src=${src#"$ROOT/"}
        (cd "$ROOT"; command cp -a --parents "$src" "$dst")
      else command cp "$@"; fi
    }
    # Windows cannot model Unix ownership; record ownership calls separately.
    install(){
      if [[ ${1:-} == -o ]]; then shift 4; fi
      if [[ $1 == -d ]]; then shift 3; mkdir -p "$@"; else shift 2; command cp "$@"; fi
    }
    WORK="$ROOT/work"
    mkdir -p "$WORK" "$BACKUP_ROOT" "$(dirname "$CUSTOM_BIN")" "$(dirname "$CONFIG")" \
      "$(dirname "$DROPIN")" "$LEGACY_DATA" "$CADDY_DATA" "$ROOT/usr/local/bin"
    : >"$WORK/alternatives"
    : >"$WORK/ports"
    ACTIVE=active ENABLED=enabled DIVERT=$CADDY_BIN
    printf 'legacy binary\n' >"$ROOT/usr/local/bin/caddy"
    printf 'old config\n' >"$CONFIG"
    printf 'old private data\n' >"$LEGACY_DATA/fixture"
    printf 'legacy unit\nUser=www-data\nGroup=www-data\n' >"$ROOT/etc/systemd/system/caddy.service"
    printf 'legacy override\n' >"$DROPIN"
    systemctl(){
      printf '%s\n' "$*" >>"$ROOT/systemctl.log"
      case $1 in
        is-enabled) echo "$ENABLED" ;;
        is-active) [[ $ACTIVE == active ]]; return $? ;;
        show)
          case $* in
            *MainPID*) echo "$$" ;;
            *LoadState*) echo loaded ;;
            *User*|*Group*)
              if [[ -f $ROOT/etc/systemd/system/caddy.service ]]; then echo www-data; else echo sing-box; fi ;;
            *Environment*) echo "HOME=$ROOT/var/lib/caddy" ;;
            *ExecStart*) echo "$CADDY_BIN run --config $CONFIG --adapter jsonc" ;;
            *ExecReload*) echo "$CADDY_BIN reload --config $CONFIG --adapter jsonc --force" ;;
            *) echo 'fixture state' ;;
          esac ;;
        cat) echo 'fixture unit' ;;
        stop) [[ ${FAIL_STOP:-0} == 0 ]] || return 1; ACTIVE=inactive ;;
        restart)
          [[ $name != upgrade_restart && $name != migrate_restart ]] || return 1
          ACTIVE=active ;;
        start) ACTIVE=active ;;
        enable) ENABLED=enabled ;;
        disable) ENABLED=disabled ;;
      esac
      return 0
    }
    readlink(){
      if [[ ${*: -1} == /proc/*/exe ]]; then echo "${EXECUTABLE:-$ROOT/usr/local/bin/caddy}"; else command readlink "$@"; fi
    }
    dpkg-divert(){
      case $1 in
        --truename) echo "$DIVERT" ;;
        --remove) command mv "$DEFAULT_BIN" "$CADDY_BIN"; DIVERT=$CADDY_BIN ;;
        --add) command mv "$CADDY_BIN" "$DEFAULT_BIN"; DIVERT=$DEFAULT_BIN ;;
      esac
    }
    update-alternatives(){
      printf '%s\n' "$*" >>"$ROOT/alternatives.log"
      case $1 in
        --query) [[ -s $ROOT/alt ]] || return 2; cat "$ROOT/alt" ;;
        --remove-all) rm -f "$ROOT/alt" "$CADDY_BIN" ;;
        --install) : ;;
        --set) ln -sf "$3" "$CADDY_BIN" ;;
        --auto) ln -sf "$CUSTOM_BIN" "$CADDY_BIN" ;;
      esac
    }
    chown(){ printf '%s\n' "$*" >>"$ROOT/chown.log"; }
    validate_config(){
      printf '%s\n' "${2:-root}" >>"$ROOT/validate-users.log"
      [[ ${FAIL_VALIDATE:-0} == 0 ]]
    }
    listeners(){ printf 'tcp:443\n'; }
    health(){ [[ $ACTIVE == active ]]; }
    case "$name" in
      missing_user)
        getent(){ return 2; }
        trap 'finish >"$ROOT/finish.log" 2>&1' EXIT
        setup_cmd migrate
        ;;
      storage)
        printf '{"storage":{"module":"file_system","root":"%s"}}\n' "$LEGACY_DATA" >"$CONFIG"
        printf 'newer certificate\n' >"$CADDY_DATA/fixture"
        migrate_tls
        migrate_tls
        grep -Fq "$CADDY_DATA" "$CONFIG"
        grep -q 'newer certificate' "$CADDY_DATA/fixture"
        grep -q 'old private data' "$LEGACY_DATA/fixture"
        grep -q -- "-R sing-box:sing-box $ROOT/var/lib/caddy" "$ROOT/chown.log"
        grep -q -- "root:sing-box $ROOT/etc/caddy $CONFIG" "$ROOT/chown.log"
        rm -rf "$LEGACY_DATA"
        migrate_tls
        rm -f "$ROOT/etc/systemd/system/caddy.service"
        install_dropin
        grep -Fxq 'User=sing-box' "$DROPIN"
        grep -Fxq 'Group=sing-box' "$DROPIN"
        grep -Fxq "Environment=HOME=$ROOT/var/lib/caddy" "$DROPIN"
        ;;
      migrate_success|migrate_validate|migrate_restart|install_success)
        # Full setup flow with isolated APT/systemd/identity doubles.
        printf '#!/bin/sh\nexit 0\n' >"$ROOT/usr/local/bin/caddy"
        chmod +x "$ROOT/usr/local/bin/caddy"
        printf '{"storage":{"module":"file_system","root":"%s"}}\n' "$LEGACY_DATA" >"$CONFIG"
        mkdir -p "$ROOT/etc/sing-box" "$ROOT/usr/lib/systemd/system"
        printf 'unchanged /home/tls reference\n' >"$ROOT/etc/sing-box/config.json"
        printf 'official sing-box unit\n' >"$ROOT/usr/lib/systemd/system/sing-box.service"
        preflight(){ :; }
        check_modules(){ :; }
        validate_config(){
          printf '%s\n' "${2:-root}" >>"$ROOT/validate-users.log"
          [[ $name != migrate_validate || ${2:-root} != sing-box ]]
        }
        install_official_repo(){ printf 'APT binary\n' >"$CADDY_BIN"; }
        trap 'finish >"$ROOT/finish.log" 2>&1' EXIT
        if [[ $name == install_success ]]; then
          mv "$ROOT/usr/local/bin/caddy" "$WORK/source"
          CADDY_CUSTOM_BINARY="$WORK/source"
          rm -f "$ROOT/etc/systemd/system/caddy.service"
          rm -rf "$LEGACY_DATA"
          printf '{}\n' >"$CONFIG"
          setup_cmd install
        else
          setup_cmd migrate
        fi
        [[ $TRANSACTION == 0 && $(cat "$BACKUP/result") == committed ]]
        grep -Fxq 'User=sing-box' "$DROPIN"
        grep -Fxq 'Group=sing-box' "$DROPIN"
        grep -q sing-box "$ROOT/validate-users.log"
        grep -q -- "-R sing-box:sing-box $ROOT/var/lib/caddy" "$ROOT/chown.log"
        grep -Fxq 'unchanged /home/tls reference' "$ROOT/etc/sing-box/config.json"
        grep -Fxq 'official sing-box unit' "$ROOT/usr/lib/systemd/system/sing-box.service"
        if grep -q 'sing-box.service' "$ROOT/systemctl.log"; then exit 1; fi
        ;;
      upgrade_*)
        rm -f "$ROOT/etc/systemd/system/caddy.service"
        printf '#!/bin/sh\n# old custom\nexit 0\n' >"$CUSTOM_BIN"
        command chmod +x "$CUSTOM_BIN"
        printf 'APT binary\n' >"$DEFAULT_BIN"
        ln -s "$CUSTOM_BIN" "$CADDY_BIN"
        DIVERT=$DEFAULT_BIN
        EXECUTABLE=$CUSTOM_BIN
        printf 'Name: caddy\nLink: %s\nStatus: manual\nValue: %s\nAlternative: %s\nPriority: 50\n' "$CADDY_BIN" "$CUSTOM_BIN" "$CUSTOM_BIN" >"$WORK/alternatives"
        command cp "$WORK/alternatives" "$ROOT/alt"
        preflight(){ :; }
        readlink(){
          if [[ ${*: -1} == /proc/*/exe || ${*: -1} == "$CADDY_BIN" ]]; then echo "$CUSTOM_BIN"; else command readlink "$@"; fi
        }
        build_custom(){
          [[ $name != upgrade_build ]] || return 1
          printf '#!/bin/sh\n# new custom\nexit 0\n' >"$WORK/caddy"
        }
        # Skip Unix mode changes on Windows; binary bytes/rename still exercised.
        chmod(){ :; }
        validate_config(){
          [[ ${2:-} == sing-box ]] || return 1
          [[ $name != upgrade_validate || $1 != "$WORK/caddy" ]]
        }
        health(){
          [[ $name != upgrade_health ]] || grep -q 'old custom' "$CUSTOM_BIN"
        }
        if [[ $name == upgrade_atomic ]]; then
          atomic_binary(){ printf 'partial replacement\n' >"$CUSTOM_BIN"; return 1; }
        fi
        trap 'finish >"$ROOT/finish.log" 2>&1' EXIT
        upgrade_cmd
        ;;
      legacy|inactive|failure|restore_failure)
        [[ $name != inactive ]] || { ACTIVE=inactive; ENABLED=disabled; }
        backup_current
        TRANSACTION=1
        printf 'APT binary\n' >"$DEFAULT_BIN"
        DIVERT=$DEFAULT_BIN
        printf '#!/bin/sh\n# new custom\nexit 0\n' >"$CUSTOM_BIN"
        printf 'new config\n' >"$CONFIG"
        printf 'new certificate\n' >"$LEGACY_DATA/new-fixture"
        rm -f "$ROOT/etc/systemd/system/caddy.service"
        printf 'new override\n' >"$DROPIN"
        printf 'registered\n' >"$ROOT/alt"
        if [[ $name == failure || $name == restore_failure ]]; then
          [[ $name != restore_failure ]] || FAIL_STOP=1
          trap 'finish >"$ROOT/finish.log" 2>&1' EXIT
          false
        fi
        restore_backup "$BACKUP"
        TRANSACTION=0
        grep -q 'old config' "$CONFIG"
        grep -q 'legacy unit' "$ROOT/etc/systemd/system/caddy.service"
        grep -q 'legacy override' "$DROPIN"
        grep -q 'old private data' "$LEGACY_DATA/fixture"
        grep -q -- "--reference=$BACKUP/files/var/lib/caddy $ROOT/var/lib/caddy" "$ROOT/chown.log"
        if [[ $ACTIVE == active ]]; then grep -q www-data "$ROOT/validate-users.log"; fi
        [[ -f $LEGACY_DATA/new-fixture && ! -e $CUSTOM_BIN ]]
        [[ $DIVERT == "$CADDY_BIN" && -f $CADDY_BIN && ! -e $DEFAULT_BIN ]]
        if [[ $name == inactive ]]; then [[ $ACTIVE == inactive && $ENABLED == disabled ]]; else [[ $ACTIVE == active ]]; fi
        ;;
      managed)
        printf '#!/bin/sh\n# old custom\nexit 0\n' >"$CUSTOM_BIN"
        command chmod +x "$CUSTOM_BIN"
        printf 'APT binary\n' >"$DEFAULT_BIN"
        ln -s "$CUSTOM_BIN" "$CADDY_BIN"
        DIVERT=$DEFAULT_BIN
        EXECUTABLE=$CUSTOM_BIN
        cat >"$WORK/alternatives" <<EOF
Name: caddy
Link: $CADDY_BIN
Status: manual
Value: $CUSTOM_BIN

Alternative: $DEFAULT_BIN
Priority: 10

Alternative: $CUSTOM_BIN
Priority: 50
EOF
        command cp "$WORK/alternatives" "$ROOT/alt"
        backup_current
        printf '#!/bin/sh\n# new custom\nexit 0\n' >"$CUSTOM_BIN"
        restore_backup "$BACKUP"
        grep -q 'old custom' "$CUSTOM_BIN"
        grep -q 'old custom' "$CADDY_BIN"
        grep -q -- "--set caddy $CUSTOM_BIN" "$ROOT/alternatives.log"
        ;;
    esac
  )
}
for name in legacy inactive managed; do
  run_case "$name"
  echo "PASS: $name restoration"
done
# Invoke without an if/! context: Bash otherwise disables errexit inside functions.
set +e
run_case failure >"$SANDBOX/failure.log" 2>&1
rc=$?
set -e
[[ $rc == 1 ]]
grep -q 'restored and verified' "$SANDBOX/failure/finish.log"
grep -q 'old config' "$SANDBOX/failure/etc/caddy/caddy.jsonc"
echo 'PASS: EXIT trap automatically restores after failure'
set +e
run_case restore_failure >"$SANDBOX/restore_failure.log" 2>&1
rc=$?
set -e
[[ $rc == 1 ]]
grep -q 'ROLLBACK FAILED' "$SANDBOX/restore_failure/finish.log"
if grep -q 'restored and verified' "$SANDBOX/restore_failure/finish.log"; then exit 1; fi
echo 'PASS: rollback failure is surfaced and never reported as recovered'

for name in upgrade_build upgrade_validate upgrade_atomic upgrade_restart upgrade_health; do
  set +e
  run_case "$name" >"$SANDBOX/$name.log" 2>&1
  rc=$?
  set -e
  [[ $rc != 0 ]]
  grep -q 'old custom' "$SANDBOX/$name/usr/bin/caddy.custom"
  [[ -f $SANDBOX/$name/systemctl.log ]] || { cat "$SANDBOX/$name.log" "$SANDBOX/$name/finish.log"; exit 1; }
  if [[ $name == upgrade_build || $name == upgrade_validate ]]; then
    if grep -q 'restart\|stop' "$SANDBOX/$name/systemctl.log"; then exit 1; fi
  else
    grep -q 'restored and verified' "$SANDBOX/$name/finish.log" || { cat "$SANDBOX/$name.log" "$SANDBOX/$name/finish.log"; exit 1; }
  fi
  echo "PASS: $name keeps/restores old binary"
done

for name in storage migrate_success install_success; do
  run_case "$name"
  echo "PASS: $name uses shared user without touching sing-box"
done
for name in missing_user migrate_validate migrate_restart; do
  set +e
  run_case "$name" >"$SANDBOX/$name.log" 2>&1
  rc=$?
  set -e
  [[ $rc != 0 ]]
  grep -q 'User=www-data' "$SANDBOX/$name/etc/systemd/system/caddy.service"
  if [[ $name == missing_user ]]; then
    [[ ! -f $SANDBOX/$name/systemctl.log ]]
  else
    grep -q 'restored and verified' "$SANDBOX/$name/finish.log" || { cat "$SANDBOX/$name/finish.log"; exit 1; }
    grep -q www-data "$SANDBOX/$name/validate-users.log"
    grep -q -- '--reference=' "$SANDBOX/$name/chown.log"
    grep -Fxq 'unchanged /home/tls reference' "$SANDBOX/$name/etc/sing-box/config.json"
  fi
  echo "PASS: $name preserves/restores old service and ownership"
done
