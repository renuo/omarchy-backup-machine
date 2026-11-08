setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../libexec/run"
  PATH="$BATS_TEST_DIRNAME/fakebin:$PATH"
  export NAS_BACKUP_SNAPSHOT_DIR="$BATS_TEST_TMPDIR/snapshots"
  export STATE_DIRECTORY="$BATS_TEST_TMPDIR/state"
  export FAKE_ARGS="$BATS_TEST_TMPDIR/args"
  export NAS_BACKUP_SUBVOLUMES="/ /home"
  export RESTIC_FORGET_ARGS="--keep-hourly 24 --keep-daily 30"
  export NAS_BACKUP_ARGS="--exclude-caches --one-file-system"
  mkdir -p "$STATE_DIRECTORY"
  : >"$FAKE_ARGS"
}

@test "snapshots every subvolume read-only and backs up the snapshots" {
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -qx "btrfs subvolume snapshot -r / $NAS_BACKUP_SNAPSHOT_DIR/root" "$FAKE_ARGS"
  grep -qx "btrfs subvolume snapshot -r /home $NAS_BACKUP_SNAPSHOT_DIR/home" "$FAKE_ARGS"
  grep -q "^restic backup $NAS_BACKUP_SNAPSHOT_DIR/root $NAS_BACKUP_SNAPSHOT_DIR/home --exclude-file=/etc/nas-backup/excludes.txt --exclude-caches --one-file-system |" "$FAKE_ARGS"
}

@test "names deeper subvolumes after their path" {
  NAS_BACKUP_SUBVOLUMES="/var/lib/machines" run bash "$SCRIPT"
  grep -qx "btrfs subvolume snapshot -r /var/lib/machines $NAS_BACKUP_SNAPSHOT_DIR/var-lib-machines" "$FAKE_ARGS"
}

@test "deletes the snapshots afterwards" {
  run bash "$SCRIPT"
  grep -qx "btrfs subvolume delete --commit-after $NAS_BACKUP_SNAPSHOT_DIR/root" "$FAKE_ARGS"
  [ -z "$(ls "$NAS_BACKUP_SNAPSHOT_DIR")" ]
}

@test "deletes the snapshots when the backup fails too" {
  cat >"$BATS_TEST_TMPDIR/restic" <<'EOF'
#!/bin/bash
exit 1
EOF
  chmod +x "$BATS_TEST_TMPDIR/restic"
  PATH="$BATS_TEST_TMPDIR:$PATH" run bash "$SCRIPT"
  [ "$status" -ne 0 ]
  [ -z "$(ls "$NAS_BACKUP_SNAPSHOT_DIR")" ]
}

@test "clears snapshots a crashed run left behind before taking new ones" {
  mkdir -p "$NAS_BACKUP_SNAPSHOT_DIR/root"
  run bash "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "$(grep -n 'delete --commit-after .*/root' "$FAKE_ARGS" | head -1 | cut -d: -f1)" -lt "$(grep -n 'snapshot -r / ' "$FAKE_ARGS" | cut -d: -f1)" ]
}

@test "refuses a subvolume that is not on btrfs before snapshotting anything" {
  FAKE_FSTYPE=ext2/ext3 run bash "$SCRIPT"
  [ "$status" -eq 1 ]
  [[ $output == *"not on btrfs"* ]]
  ! grep -q 'snapshot -r' "$FAKE_ARGS"
  ! grep -q '^restic' "$FAKE_ARGS"
}

@test "prunes with the retention once a day" {
  run bash "$SCRIPT"
  grep -q '^restic forget --prune --keep-hourly 24 --keep-daily 30 |' "$FAKE_ARGS"
  : >"$FAKE_ARGS"
  run bash "$SCRIPT"
  ! grep -q '^restic forget' "$FAKE_ARGS"
}

@test "prunes again when the last prune is more than a day old" {
  touch -d '25 hours ago' "$STATE_DIRECTORY/last-prune"
  run bash "$SCRIPT"
  grep -q '^restic forget --prune' "$FAKE_ARGS"
}

@test "keeps the repository's size for the panel" {
  FAKE_RESTIC_STATS='{"total_size":42}' run bash "$SCRIPT"
  [ "$(cat "$STATE_DIRECTORY/stats.json")" = '{"total_size":42}' ]
}
