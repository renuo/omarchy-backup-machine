#!/bin/bash

# What the panel asks of the NAS backup. `state` prints JSON and needs no
# root. `timer`, `backup` and `stop` print nothing unless they fail; polkit
# allows the last two without a password. Everything else changes root's
# files, talks to a person and runs in a terminal the panel opens, with sudo.

set -euo pipefail

TEMPLATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/templates"
ETC=${BACKUP_MACHINE_ETC:-/etc/backup-machine}
STATE_DIR=${BACKUP_MACHINE_STATE:-/var/lib/backup-machine}
CONFIG="$ETC/backup.env"
SERVICE=backup-machine.service
TIMER=backup-machine-daily.timer
RUN=${BACKUP_MACHINE_RUN:-/usr/local/lib/backup-machine/run}

usage() {
  echo "usage: ctl.sh state | connect | password | copy-password | init | edit config|excludes | timer on|off | backup | stop | schedule | log | snapshots | browse | shell" >&2
  exit 2
}

# The file is systemd's EnvironmentFile, not shell. Only KEY=value lines
# count, quotes optional, the last one wins.
setting() {
  local line value=""
  [[ -r $CONFIG ]] || return 0
  while IFS= read -r line || [[ -n $line ]]; do
    [[ $line =~ ^[[:space:]]*$1=(.*)$ ]] || continue
    value=${BASH_REMATCH[1]}
    if [[ $value =~ ^\"(.*)\"$ || $value =~ ^\'(.*)\'$ ]]; then value=${BASH_REMATCH[1]}; fi
  done <"$CONFIG"
  printf '%s' "$value"
}

bool() {
  "$@" && echo true || echo false
}

# $0 inside the quotes is the host, given as an argument rather than spliced in.
reachable() {
  # shellcheck disable=SC2016
  [[ -n $1 ]] && timeout 1 bash -c 'exec 3<>"/dev/tcp/$0/445"' "$1" 2>/dev/null
}

timestamp() {
  local _ seconds
  [[ -f $1 ]] && read -r _ seconds <"$1" && [[ $seconds =~ ^[0-9]+$ ]] && printf '%s' "$seconds" && return
  printf 0
}

state() {
  local repository host result="" enabled active next size
  repository=$(setting RESTIC_REPOSITORY)
  host=$(setting RCLONE_SMB_HOST)
  [[ -f $STATE_DIR/last-run ]] && read -r result _ <"$STATE_DIR/last-run"
  enabled=$(systemctl is-enabled "$TIMER" 2>/dev/null) || true
  active=$(systemctl is-active "$SERVICE" 2>/dev/null) || true
  next=$(systemctl list-timers --all --output=json "$TIMER" 2>/dev/null | jq -r '.[0].next // 0' 2>/dev/null) || true
  [[ $next =~ ^[0-9]+$ ]] || next=0
  size=$(jq -r '.total_size // 0' "$STATE_DIR/stats.json" 2>/dev/null) || true
  [[ $size =~ ^[0-9]+$ ]] || size=0
  jq -cn \
    --argjson installed "$(bool test -x "$RUN")" \
    --argjson btrfs "$(bool test "$(stat -f -c %T / 2>/dev/null)" = btrfs)" \
    --argjson config "$(bool test -f "$CONFIG")" \
    --argjson login "$(bool test -e "$ETC/nas.env")" \
    --argjson password "$(bool test -e "$ETC/password")" \
    --arg host "$host" \
    --arg repository "$repository" \
    --arg subvolumes "$(setting BACKUP_MACHINE_SUBVOLUMES)" \
    --arg forget "$(setting RESTIC_FORGET_ARGS)" \
    --argjson quotaGb "$(q=$(setting BACKUP_MACHINE_QUOTA_GB); [[ $q =~ ^[0-9]+$ ]] && echo "$q" || echo 0)" \
    --argjson reachable "$(bool reachable "$host")" \
    --argjson initialized "$(bool test -n "$repository" -a -f "$STATE_DIR/repository" -a "$(cat "$STATE_DIR/repository" 2>/dev/null)" = "$repository")" \
    --argjson timerEnabled "$(bool test "$enabled" = enabled)" \
    --argjson running "$(bool test "$active" = activating -o "$active" = active -o "$active" = deactivating)" \
    --argjson nextRun "$((next / 1000000))" \
    --arg result "$result" \
    --argjson lastRun "$(timestamp "$STATE_DIR/last-run")" \
    --argjson lastSuccess "$(timestamp "$STATE_DIR/last-success")" \
    --argjson size "$size" \
    '$ARGS.named'
}

# Writes a root-owned file from stdin.
put() {
  sudo install -D -m "$1" /dev/stdin "$2"
}

# restic as backup-machine.service runs it: same environment files, same cache.
as_service() {
  sudo systemd-run --pty --quiet --collect --wait \
    -p EnvironmentFile="$ETC/backup.env" \
    -p EnvironmentFile="$ETC/nas.env" \
    -E RESTIC_PASSWORD_FILE="$ETC/password" \
    -E RESTIC_CACHE_DIR=/var/cache/backup-machine \
    "$@"
}

# Asks for what 1Password's "[Renuo-NAS] Backup User" entry holds, tries it,
# and keeps the login readable by root only.
connect() {
  local address host share folder user secret obscured
  echo 'Open "[Renuo-NAS] Backup User" in 1Password and copy from it.'
  echo
  address=$(gum input --width 80 --header "Server Address" --placeholder "smb://NAS_ADDRESS/laptop_backups")
  [[ $address =~ ^(smb://)?([^/@]+@)?([^/]+)/([^/]+) ]] || {
    echo "Expected an address like smb://NAS_ADDRESS/laptop_backups, got '$address'."
    exit 1
  }
  host=${BASH_REMATCH[3]} share=${BASH_REMATCH[4]}
  user=$(gum input --width 80 --header "Username" --value backup-user)
  secret=$(gum input --width 80 --header "Password" --password)
  [[ -n $user && -n $secret ]] || exit 1
  folder=$(gum input --width 80 --header "Folder for this laptop on the share" --value "$(id -un)-$(hostname)")
  [[ $folder =~ ^[A-Za-z0-9_.-]+$ ]] || {
    echo "Use letters, digits, _, - and . for the folder."
    exit 1
  }
  obscured=$(printf '%s' "$secret" | rclone obscure -)

  echo "Trying $host…"
  RCLONE_SMB_HOST=$host RCLONE_SMB_USER=$user RCLONE_SMB_PASS=$obscured \
    rclone lsf --max-depth 1 ":smb:$share" >/dev/null || {
    echo "The NAS did not let us in. Are you at the office, and is the password right?"
    exit 1
  }

  printf 'RCLONE_SMB_USER=%s\nRCLONE_SMB_PASS=%s\n' "$user" "$obscured" | put 600 "$ETC/nas.env"
  if [[ -f $CONFIG ]]; then
    sed -e "s|^RCLONE_SMB_HOST=.*|RCLONE_SMB_HOST=$host|" \
      -e "s|^RESTIC_REPOSITORY=.*|RESTIC_REPOSITORY=rclone::smb:$share/$folder|" "$CONFIG" | put 644 "$CONFIG"
  else
    sed -e "s|@HOST@|$host|" -e "s|@SHARE@|$share|" -e "s|@HOSTNAME@|$folder|" "$TEMPLATE_DIR/backup.env" | put 644 "$CONFIG"
  fi
  [[ -f $ETC/excludes.txt ]] || put 644 "$ETC/excludes.txt" <"$TEMPLATE_DIR/excludes.txt"
  echo "Connected. Backups go to $share/$folder on $host."
}

# Never replaced: a new password would lock you out of every existing backup.
password() {
  local choice secret
  if sudo test -s "$ETC/password"; then
    echo "There is a password already; replacing it would lock you out of the backups made with it."
    return
  fi
  choice=$(gum choose --header "Encryption password" "Create a new one" "Enter the one I keep in 1Password")
  case $choice in
  "Create a new one") head -c 32 /dev/urandom | base64 | put 600 "$ETC/password" ;;
  "Enter"*)
    secret=$(gum input --width 80 --password --header "Password")
    [[ -n $secret ]] || exit 1
    printf '%s\n' "$secret" | put 600 "$ETC/password"
    ;;
  *) exit 1 ;;
  esac
  echo 'Done. Keep a copy in 1Password, in your Employee vault: without it nothing can be restored.'
}

# --sensitive keeps it out of Omarchy's clipboard history.
copy_password() {
  sudo cat "$ETC/password" | wl-copy --sensitive
  echo "Copied. Paste it into 1Password, in your Employee vault."
}

# Connects to a repository that exists already, as on a new laptop, and
# creates one otherwise.
init() {
  local repository
  repository=$(setting RESTIC_REPOSITORY)
  [[ -n $repository ]] || {
    echo "Connect to the NAS first."
    exit 1
  }
  echo "Repository: $repository"
  echo
  as_service sh -c 'if restic cat config >/dev/null 2>&1; then echo "It exists already, and the password opens it."; else restic init; fi'
  printf '%s' "$repository" | put 644 "$STATE_DIR/repository"
}

edit() {
  case ${1:-} in
  config | excludes)
    local file="$ETC/backup.env"
    [[ $1 == excludes ]] && file="$ETC/excludes.txt"
    sudoedit "$file"
    ;;
  *) usage ;;
  esac
}

quiet() {
  local out
  out=$("$@" 2>&1) || echo "$out"
}

browse() {
  local dir=/run/backup-machine-browse
  echo "Backups are at $dir/snapshots while this runs. Copy out what you need, then press Ctrl+C."
  echo
  (sleep 8 && uwsm-app -- nautilus "$dir/snapshots" >/dev/null 2>&1) &
  sudo mkdir -p "$dir"
  as_service restic mount --allow-other "$dir"
}

case ${1:-} in
state) state ;;
connect) connect ;;
password) password ;;
copy-password) copy_password ;;
init) init ;;
edit) edit "${2:-}" ;;
timer)
  case ${2:-} in
  on) quiet systemctl enable --now "$TIMER" ;;
  off) quiet systemctl disable --now "$TIMER" ;;
  *) usage ;;
  esac
  ;;
backup) quiet systemctl start --no-block "$SERVICE" ;;
stop) quiet systemctl stop "$SERVICE" ;;
schedule) sudo SYSTEMD_EDITOR=nvim systemctl edit "$TIMER" ;;
log) journalctl --unit "$SERVICE" --lines 200 --follow ;;
snapshots) as_service restic snapshots ;;
browse) browse ;;
shell)
  echo "restic is set up for the NAS. Try: restic snapshots"
  as_service bash
  ;;
*) usage ;;
esac
