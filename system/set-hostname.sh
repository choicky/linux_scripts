#!/usr/bin/env bash
# Change a Debian 12/13 hostname and matching /etc/hosts aliases safely.
set -Eeuo pipefail
export LC_ALL=C

readonly HOSTS="/etc/hosts"
NEW_HOSTNAME=""
OLD_HOSTNAME=""
BACKUP=""
STAGED=""
HOSTS_PENDING=false
HOSTNAME_PENDING=false
COMMITTED=false

log(){ printf '\n==> %s\n' "$*"; }
die(){ printf '\nERROR: %s\n' "$*" >&2; exit 1; }
usage(){ printf 'Usage: %s NEW_HOSTNAME\n       %s -h|--help\n' "$0" "$0"; }

cleanup(){
  local rc=$? restore=""
  trap - EXIT
  if [[ "$COMMITTED" == false && "$HOSTNAME_PENDING" == true ]]; then
    log "Restoring hostname: $OLD_HOSTNAME"
    hostnamectl set-hostname "$OLD_HOSTNAME" \
      || printf 'ERROR: Could not restore hostname; restore it manually.\n' >&2
  fi
  if [[ "$COMMITTED" == false && "$HOSTS_PENDING" == true ]] && ! cmp -s -- "$HOSTS" "$BACKUP"; then
    log "Restoring $HOSTS from $BACKUP"
    if restore=$(mktemp "${HOSTS}.restore.XXXXXX") &&
      cp --preserve=all -- "$BACKUP" "$restore" &&
      mv -fT -- "$restore" "$HOSTS"; then
      log "$HOSTS restored."
    else
      printf 'ERROR: Could not restore %s; backup retained at %s.\n' "$HOSTS" "$BACKUP" >&2
    fi
  fi
  [[ -z "$restore" ]] || rm -f -- "$restore" || true
  [[ -z "$STAGED" ]] || rm -f -- "$STAGED" || true
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

parse_args(){
  if (( $# == 1 )) && [[ "$1" == -h || "$1" == --help ]]; then
    usage
    exit 0
  fi
  (( $# == 1 )) || { usage >&2; die "Exactly one hostname is required."; }
  NEW_HOSTNAME=$1
  [[ -n "$NEW_HOSTNAME" && ${#NEW_HOSTNAME} -le 63 &&
    "$NEW_HOSTNAME" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] \
    || die "Hostname must be 1-63 ASCII letters/digits/hyphens, with no leading or trailing hyphen."
}

preflight(){
  [[ ${EUID} -eq 0 ]] || die "Run this script as root."
  . /etc/os-release
  [[ ${ID:-} == debian ]] || die "Only Debian is supported."
  case "${VERSION_ID:-}" in 12|13);; *) die "Only Debian 12 and Debian 13 are supported.";; esac
  OLD_HOSTNAME=$(hostnamectl --static) || die "Cannot read the current static hostname."
}

render_hosts(){
  local line ending rest comment result token field
  # Preserve whitespace, comments and even a missing final newline. The first
  # field is the address; only later, complete hostname fields may be replaced.
  while true; do
    line=""
    if IFS= read -r line; then
      ending=$'\n'
    else
      ending=""
      [[ -n "$line" ]] || break
    fi
    rest=${line%%#*}
    comment=${line#"$rest"}
    result=""
    field=0
    while [[ "$rest" =~ ^([[:space:]]*)([^[:space:]]+)(.*)$ ]]; do
      result+=${BASH_REMATCH[1]}
      token=${BASH_REMATCH[2]}
      rest=${BASH_REMATCH[3]}
      field=$((field + 1))
      if (( field > 1 )) && [[ "$token" == "$OLD_HOSTNAME" ]]; then
        token=$NEW_HOSTNAME
      fi
      result+=$token
    done
    printf '%s%s%s%s' "$result" "$rest" "$comment" "$ending" || return 1
  done
}

show_result(){
  log "hostnamectl --static"
  hostnamectl --static
  log "cat /etc/hostname"
  cat /etc/hostname
  log "$HOSTS entries for localhost or $NEW_HOSTNAME"
  awk -v name="$NEW_HOSTNAME" '{
    original=$0
    sub(/#.*/, "")
    for (i=2; i<=NF; i++)
      if ($i == "localhost" || $i == name) { print original; break }
  }' "$HOSTS"
  printf '\nA VPS reboot is usually unnecessary. Log in again via SSH to see the new shell prompt.\n'
}

main(){
  parse_args "$@"
  preflight
  if [[ "$NEW_HOSTNAME" == "$OLD_HOSTNAME" ]]; then
    log "Hostname is already $NEW_HOSTNAME; no changes needed."
    show_result
    return
  fi
  [[ -f "$HOSTS" && ! -L "$HOSTS" ]] || die "$HOSTS must be a regular file, not a symlink."
  BACKUP=$(mktemp "${HOSTS}.before-hostname-$(date +%Y%m%d-%H%M%S).XXXXXX")
  cp --preserve=all -- "$HOSTS" "$BACKUP" || die "Cannot back up $HOSTS."
  log "Backup created: $BACKUP"
  STAGED=$(mktemp "${HOSTS}.new.XXXXXX")
  render_hosts <"$BACKUP" >"$STAGED" || die "Cannot prepare updated $HOSTS."
  chown --reference="$BACKUP" "$STAGED" || die "Cannot preserve $HOSTS ownership."
  chmod --reference="$BACKUP" "$STAGED" || die "Cannot preserve $HOSTS permissions."

  # Abort if another writer changed hosts while we prepared the replacement.
  cmp -s -- "$HOSTS" "$BACKUP" || die "$HOSTS changed during preparation; rerun after other writers finish."
  if cmp -s -- "$STAGED" "$BACKUP"; then
    log "No matching old hostname fields in $HOSTS; leaving it unchanged."
  else
    HOSTS_PENDING=true
    mv -fT -- "$STAGED" "$HOSTS" || die "Cannot atomically replace $HOSTS; hostname has not been changed."
  fi
  HOSTNAME_PENDING=true
  hostnamectl set-hostname "$NEW_HOSTNAME" || die "Cannot set hostname; attempting rollback."
  [[ $(hostnamectl --static) == "$NEW_HOSTNAME" && $(cat /etc/hostname) == "$NEW_HOSTNAME" ]] \
    || die "Hostname verification failed; attempting rollback."
  COMMITTED=true
  log "Hostname changed from $OLD_HOSTNAME to $NEW_HOSTNAME."
  show_result
}

main "$@"
