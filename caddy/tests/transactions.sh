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
    # Production binaries are root-owned; tests use the invoking user's ownership.
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
    printf 'legacy unit\n' >"$ROOT/etc/systemd/system/caddy.service"
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
            *User*|*Group*) echo caddy ;;
            *) echo 'fixture state' ;;
          esac ;;
        cat) echo 'fixture unit' ;;
        stop) [[ ${FAIL_STOP:-0} == 0 ]] || return 1; ACTIVE=inactive ;;
        restart)
          [[ $name != upgrade_restart ]] || return 1
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
    validate_config(){ [[ ${FAIL_VALIDATE:-0} == 0 ]]; }
    listeners(){ printf 'tcp:443\n'; }
    health(){ [[ $ACTIVE == active ]]; }
    case "$name" in
      migration_guard|migration_acl_error)
        certificate_check(){
          echo "certificate-check $1" >"$ROOT/gate.log"
          if [[ $name == migration_guard ]]; then return 1; else return 2; fi
        }
        preflight(){ echo 'unexpected-preflight' >"$ROOT/mutated"; return 1; }
        trap 'finish >"$ROOT/finish.log" 2>&1' EXIT
        setup_cmd migrate
        ;;
      readonly_paths|readonly_acl)
        require_root(){ :; }
        init(){ echo 'unexpected-init' >"$ROOT/mutated"; return 1; }
        certificate_check(){ echo "$1" >"$ROOT/readonly.log"; }
        if [[ $name == readonly_paths ]]; then main check-cert-paths; else main check-cert-access; fi
        [[ ! -e $ROOT/mutated ]]
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
        check_service_contract(){ :; }
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
        # Recovery must never depend on the sing-box path/ACL preflight gate.
        certificate_check(){ die 'Unexpected certificate gate during rollback.'; }
        restore_backup "$BACKUP"
        TRANSACTION=0
        grep -q 'old config' "$CONFIG"
        grep -q 'legacy unit' "$ROOT/etc/systemd/system/caddy.service"
        grep -q 'legacy override' "$DROPIN"
        grep -q 'old private data' "$LEGACY_DATA/fixture"
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
    grep -q 'restored and verified' "$SANDBOX/$name/finish.log"
  fi
  echo "PASS: $name keeps/restores old binary"
done

for name in migration_guard migration_acl_error; do
  set +e
  run_case "$name" >"$SANDBOX/$name.log" 2>&1
  rc=$?
  set -e
  [[ $rc != 0 ]]
  [[ ! -e $SANDBOX/$name/mutated && ! -e $SANDBOX/$name/systemctl.log ]]
  [[ -z $(find "$SANDBOX/$name/var/backups/caddy-manager" -mindepth 1 -print -quit) ]]
  grep -q 'old config' "$SANDBOX/$name/etc/caddy/caddy.jsonc"
  grep -q 'old private data' "$SANDBOX/$name/home/tls/fixture"
  grep -q 'legacy unit' "$SANDBOX/$name/etc/systemd/system/caddy.service"
  echo "PASS: $name aborts before validation/backup/service/storage changes"
done
for name in readonly_paths readonly_acl; do
  run_case "$name"
  echo "PASS: $name bypasses all mutating initialization"
done
