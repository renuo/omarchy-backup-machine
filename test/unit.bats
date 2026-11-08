setup() {
  UNIT="$BATS_TEST_DIRNAME/../systemd/backup-machine.service"
  export STATE_DIRECTORY="$BATS_TEST_TMPDIR/state"
  export RESTIC_REPOSITORY="rclone::smb:laptop_backups/me-delly"
  mkdir -p "$STATE_DIRECTORY"
}

# Runs ExecStopPost's script after undoing systemd's escaping: $$ is $, %% is %.
stop_post() {
  local script
  script=$(sed -n "s/^ExecStopPost=\/bin\/sh -c '\(.*\)'$/\1/p" "$UNIT" | sed 's/\$\$/$/g; s/%%/%/g')
  [ -n "$script" ]
  SERVICE_RESULT=$1 sh -c "$script"
}

@test "a successful run is kept as the last run and the last success" {
  stop_post success
  read -r result seconds <"$STATE_DIRECTORY/last-run"
  [ "$result" = success ]
  (( seconds > $(date +%s) - 60 ))
  cmp "$STATE_DIRECTORY/last-run" "$STATE_DIRECTORY/last-success"
}

@test "a successful run remembers the repository as initialized" {
  stop_post success
  [ "$(cat "$STATE_DIRECTORY/repository")" = "rclone::smb:laptop_backups/me-delly" ]
}

@test "a failed run leaves the last success alone" {
  echo "success 1" >"$STATE_DIRECTORY/last-success"
  stop_post exit-code
  [ "$(cut -d' ' -f1 "$STATE_DIRECTORY/last-run")" = exit-code ]
  [ "$(cat "$STATE_DIRECTORY/last-success")" = "success 1" ]
  [ ! -f "$STATE_DIRECTORY/repository" ]
}


# Runs ExecCondition's check the way systemd would, against a given host.
condition() {
  local script
  script=$(sed -n "s/^ExecCondition=\/usr\/bin\/timeout 3 \/usr\/bin\/bash -c '\(.*\)'$/\1/p" "$UNIT" | sed 's/\$\$/$/g')
  [ -n "$script" ]
  RCLONE_SMB_HOST=$1 timeout 3 bash -c "$script"
}

@test "skips the run when the NAS does not answer" {
  run condition 127.0.0.1
  [ "$status" -ne 0 ]
  [ "$status" -ne 255 ]
}
