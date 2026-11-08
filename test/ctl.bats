setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../ctl.sh"
  PATH="$BATS_TEST_DIRNAME/fakebin:$PATH"
  export NAS_BACKUP_ETC="$BATS_TEST_TMPDIR/etc"
  export NAS_BACKUP_STATE="$BATS_TEST_TMPDIR/state"
  export NAS_BACKUP_RUN="$BATS_TEST_TMPDIR/run"
  export FAKE_ARGS="$BATS_TEST_TMPDIR/args"
  export FAKE_SYSTEMD="$BATS_TEST_TMPDIR/systemd"
  export FAKE_GUM_ANSWERS="$BATS_TEST_TMPDIR/answers"
  export FAKE_CLIPBOARD="$BATS_TEST_TMPDIR/clipboard"
  CONFIG="$NAS_BACKUP_ETC/backup.env"
  mkdir -p "$FAKE_SYSTEMD"
  : >"$FAKE_ARGS"
}

settings() {
  mkdir -p "$NAS_BACKUP_ETC"
  printf '%s\n' "$@" >"$CONFIG"
}

answers() {
  printf '%s\n' "$@" >"$FAKE_GUM_ANSWERS"
}

state_field() {
  run bash "$SCRIPT" state
  [ "$status" -eq 0 ]
  jq -c ".$1" <<<"$output"
}

@test "state of a fresh machine is all empty" {
  run bash "$SCRIPT" state
  [ "$status" -eq 0 ]
  [ "$(jq -c 'del(.btrfs)' <<<"$output")" = '{"installed":false,"config":false,"login":false,"password":false,"host":"","repository":"","subvolumes":"","forget":"","quotaGb":0,"reachable":false,"initialized":false,"timerEnabled":false,"running":false,"nextRun":0,"result":"","lastRun":0,"lastSuccess":0,"size":0}' ]
}

@test "state reads the settings the way systemd does" {
  settings 'RCLONE_SMB_HOST=nas.example' '# RESTIC_REPOSITORY=old' 'RESTIC_REPOSITORY="rclone::smb:laptop_backups/me-delly"' 'NAS_BACKUP_SUBVOLUMES=/ /home' 'RESTIC_FORGET_ARGS=--keep-hourly 24' 'NAS_BACKUP_QUOTA_GB=2000'
  run bash "$SCRIPT" state
  [ "$(jq -c '[.config, .host, .repository, .subvolumes, .forget, .quotaGb]' <<<"$output")" = '[true,"nas.example","rclone::smb:laptop_backups/me-delly","/ /home","--keep-hourly 24",2000]' ]
}

@test "state sees root's secret files without reading them" {
  settings 'RCLONE_SMB_HOST=nas.example'
  touch "$NAS_BACKUP_ETC/nas.env" "$NAS_BACKUP_ETC/password"
  chmod 000 "$NAS_BACKUP_ETC/nas.env" "$NAS_BACKUP_ETC/password"
  run bash "$SCRIPT" state
  [ "$(jq -c '[.login, .password]' <<<"$output")" = '[true,true]' ]
}

@test "state reads a quota that is not a number as none" {
  settings 'NAS_BACKUP_QUOTA_GB=2TB'
  [ "$(state_field quotaGb)" = 0 ]
}

@test "state knows the run script is installed" {
  touch "$NAS_BACKUP_RUN"
  chmod +x "$NAS_BACKUP_RUN"
  [ "$(state_field installed)" = true ]
}

@test "state counts the repository initialized only while it is the one set up" {
  settings 'RESTIC_REPOSITORY=rclone::smb:share/a'
  mkdir -p "$NAS_BACKUP_STATE"
  printf %s 'rclone::smb:share/a' >"$NAS_BACKUP_STATE/repository"
  [ "$(state_field initialized)" = true ]
  settings 'RESTIC_REPOSITORY=rclone::smb:share/b'
  [ "$(state_field initialized)" = false ]
}

@test "state reports runs, the size on the NAS and systemd's view" {
  mkdir -p "$NAS_BACKUP_STATE"
  echo "exit-code 1762600000" >"$NAS_BACKUP_STATE/last-run"
  echo "success 1762500000" >"$NAS_BACKUP_STATE/last-success"
  echo '{"total_size":123456789,"total_file_count":5}' >"$NAS_BACKUP_STATE/stats.json"
  echo enabled >"$FAKE_SYSTEMD/nas-backup.timer.enabled"
  echo activating >"$FAKE_SYSTEMD/nas-backup.service.active"
  echo '[{"next":1762650000123456}]' >"$FAKE_SYSTEMD/timers.json"
  run bash "$SCRIPT" state
  [ "$(jq -c '[.result, .lastRun, .lastSuccess, .size, .timerEnabled, .running, .nextRun]' <<<"$output")" = '["exit-code",1762600000,1762500000,123456789,true,true,1762650000]' ]
}

@test "state reads garbled run and stats files as nothing" {
  mkdir -p "$NAS_BACKUP_STATE"
  echo "success soon" >"$NAS_BACKUP_STATE/last-run"
  echo "oops" >"$NAS_BACKUP_STATE/stats.json"
  run bash "$SCRIPT" state
  [ "$(jq -c '[.lastRun, .size]' <<<"$output")" = '[0,0]' ]
}

@test "state calls a host nobody answers on unreachable" {
  settings 'RCLONE_SMB_HOST=127.0.0.1'
  [ "$(state_field reachable)" = false ]
}

@test "connect keeps the login root-only and points the repository at this laptop's folder" {
  answers smb://nas.example/laptop_backups backup-user s3cret me-delly
  run bash "$SCRIPT" connect
  [ "$status" -eq 0 ]
  grep -qx 'rclone lsf --max-depth 1 :smb:laptop_backups | nas.example backup-user obscured:s3cret' "$FAKE_ARGS"
  [ "$(cat "$NAS_BACKUP_ETC/nas.env")" = $'RCLONE_SMB_USER=backup-user\nRCLONE_SMB_PASS=obscured:s3cret' ]
  [ "$(stat -c %a "$NAS_BACKUP_ETC/nas.env")" = 600 ]
  grep -qx 'RCLONE_SMB_HOST=nas.example' "$CONFIG"
  grep -qx 'RESTIC_REPOSITORY=rclone::smb:laptop_backups/me-delly' "$CONFIG"
  [ "$(stat -c %a "$CONFIG")" = 644 ]
  cmp "$NAS_BACKUP_ETC/excludes.txt" "$BATS_TEST_DIRNAME/../templates/excludes.txt"
}

@test "connect asks for the password hidden" {
  answers smb://nas.example/laptop_backups backup-user s3cret me-delly
  bash "$SCRIPT" connect
  grep -q 'gum input .*--header Password --password' "$FAKE_ARGS"
}

@test "connect takes an address without smb:// and with a user in it" {
  answers backup-user@nas.example/laptop_backups/ignored backup-user s3cret me-delly
  run bash "$SCRIPT" connect
  [ "$status" -eq 0 ]
  grep -qx 'RCLONE_SMB_HOST=nas.example' "$CONFIG"
}

@test "connect changes only the NAS in existing settings" {
  settings 'RCLONE_SMB_HOST=old' 'RESTIC_REPOSITORY=rclone::smb:old/old' 'RESTIC_FORGET_ARGS=--keep-daily 3'
  answers smb://nas.example/laptop_backups backup-user s3cret me-delly
  run bash "$SCRIPT" connect
  [ "$(cat "$CONFIG")" = $'RCLONE_SMB_HOST=nas.example\nRESTIC_REPOSITORY=rclone::smb:laptop_backups/me-delly\nRESTIC_FORGET_ARGS=--keep-daily 3' ]
}

@test "connect writes nothing when the NAS refuses" {
  answers smb://nas.example/laptop_backups backup-user wrong me-delly
  FAKE_RCLONE_REFUSE=1 run bash "$SCRIPT" connect
  [ "$status" -eq 1 ]
  [[ $output == *"did not let us in"* ]]
  [ ! -e "$NAS_BACKUP_ETC/nas.env" ]
}

@test "connect refuses an address without a share" {
  answers smb://nas.example
  run bash "$SCRIPT" connect
  [ "$status" -eq 1 ]
  [[ $output == *"Expected an address"* ]]
}

@test "connect refuses a folder name that is not plain" {
  answers smb://nas.example/laptop_backups backup-user s3cret "../other"
  run bash "$SCRIPT" connect
  [ "$status" -eq 1 ]
  [ ! -e "$NAS_BACKUP_ETC/nas.env" ]
}

@test "password creates a long random one only root can read" {
  answers "Create a new one"
  run bash "$SCRIPT" password
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$NAS_BACKUP_ETC/password")" = 600 ]
  [ "$(wc -c <"$NAS_BACKUP_ETC/password")" -ge 40 ]
  [[ $output == *"1Password"* ]]
}

@test "password takes the one kept in 1Password on a new laptop" {
  answers "Enter the one I keep in 1Password" "kept-secret"
  run bash "$SCRIPT" password
  [ "$(cat "$NAS_BACKUP_ETC/password")" = kept-secret ]
}

@test "password never replaces an existing one" {
  mkdir -p "$NAS_BACKUP_ETC"
  echo old >"$NAS_BACKUP_ETC/password"
  run bash "$SCRIPT" password
  [ "$(cat "$NAS_BACKUP_ETC/password")" = old ]
  [[ $output == *"lock you out"* ]]
}

@test "copy-password reads it as root and hands it to the clipboard as sensitive" {
  mkdir -p "$NAS_BACKUP_ETC"
  echo s3cret >"$NAS_BACKUP_ETC/password"
  run bash "$SCRIPT" copy-password
  grep -qx "sudo cat $NAS_BACKUP_ETC/password" "$FAKE_ARGS"
  grep -qx 'wl-copy --sensitive' "$FAKE_ARGS"
  [ "$(cat "$FAKE_CLIPBOARD")" = s3cret ]
}

@test "init creates a missing repository with the service's settings and remembers it" {
  settings 'RESTIC_REPOSITORY=rclone::smb:share/me' 'RESTIC_FORGET_ARGS=--keep-hourly 24 --keep-daily 30'
  touch "$NAS_BACKUP_ETC/nas.env"
  run bash "$SCRIPT" init
  [ "$status" -eq 0 ]
  grep -qx "restic init | rclone::smb:share/me | $NAS_BACKUP_ETC/password | --keep-hourly 24 --keep-daily 30" "$FAKE_ARGS"
  [ "$(cat "$NAS_BACKUP_STATE/repository")" = 'rclone::smb:share/me' ]
}

@test "init connects to a repository that exists already" {
  settings 'RESTIC_REPOSITORY=rclone::smb:share/me'
  touch "$NAS_BACKUP_ETC/nas.env"
  FAKE_RESTIC_EXISTS=1 run bash "$SCRIPT" init
  [[ $output == *"exists already"* ]]
  ! grep -q '^restic init' "$FAKE_ARGS"
}

@test "init wants the NAS first" {
  run bash "$SCRIPT" init
  [ "$status" -eq 1 ]
  [ "$output" = "Connect to the NAS first." ]
}

@test "edit opens root's files with sudoedit" {
  run bash "$SCRIPT" edit config
  run bash "$SCRIPT" edit excludes
  [ "$(cat "$FAKE_ARGS")" = "sudoedit $NAS_BACKUP_ETC/backup.env
sudoedit $NAS_BACKUP_ETC/excludes.txt" ]
}

@test "timer, backup and stop go to the system units quietly" {
  bash "$SCRIPT" timer on
  bash "$SCRIPT" timer off
  bash "$SCRIPT" backup
  run bash "$SCRIPT" stop
  [ "$output" = "" ]
  [ "$(cat "$FAKE_ARGS")" = "systemctl enable --now nas-backup.timer
systemctl disable --now nas-backup.timer
systemctl start --no-block nas-backup.service
systemctl stop nas-backup.service" ]
}

@test "a refused unit change prints systemd's complaint" {
  FAKE_SYSTEMCTL_FAIL="Access denied" run bash "$SCRIPT" timer on
  [ "$output" = "Access denied" ]
}

@test "schedule edits the timer with nvim as root" {
  bash "$SCRIPT" schedule
  grep -qx 'sudo SYSTEMD_EDITOR=nvim systemctl edit nas-backup.timer' "$FAKE_ARGS"
}

@test "snapshots runs restic as the service would" {
  settings 'RESTIC_REPOSITORY=rclone::smb:share/me'
  touch "$NAS_BACKUP_ETC/nas.env"
  run bash "$SCRIPT" snapshots
  grep -q "^sudo systemd-run --pty --quiet --collect --wait -p EnvironmentFile=$NAS_BACKUP_ETC/backup.env -p EnvironmentFile=$NAS_BACKUP_ETC/nas.env" "$FAKE_ARGS"
  grep -qx "restic snapshots | rclone::smb:share/me | $NAS_BACKUP_ETC/password | " "$FAKE_ARGS"
}

@test "an unknown command prints usage" {
  run bash "$SCRIPT" frobnicate
  [ "$status" -eq 2 ]
  [[ $output == usage:* ]]
}
