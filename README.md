# NAS backup — Omarchy plugin

Time Machine for Omarchy: the whole system goes to Renuo's NAS every hour you are at the office. It is the Linux version of [NAS Backup with Time Machine](https://github.com/renuo/laptop-setup-guide-for-macos/blob/main/nice_to_have/nas_backup.md).

| Icon | Meaning |
|---|---|
| NAS | The last backup worked |
| Spinning arrows | A backup is running |
| Alert, urgent colour | The last backup failed, the backups outgrew the quota, or none worked for 10 days |
| Dimmed | Not set up yet, or automatic backups are off |

Hover for the last backup and whether the NAS is in reach. Click for the panel, right-click to refresh.

## How it maps from Time Machine

| Time Machine | Here |
|---|---|
| SMB share `laptop_backups`, user `backup-user` | The same share and login, through rclone's SMB backend; nothing is mounted |
| Backs up the whole Mac | Read-only btrfs snapshots of `/` and `/home`, one consistent moment, backed up with [restic](https://restic.net) |
| Encryption password | restic encrypts everything with a password of yours; the NAS login is shared by everyone |
| Disk usage limit, about 2 TB | `NAS_BACKUP_QUOTA_GB=2000`; the panel turns urgent above it. Old backups go by the retention, not by the quota |
| Hourly, daily for a month, weekly | `--keep-hourly 24 --keep-daily 30 --keep-weekly 52` |
| Backs up when the disk is there | An hourly timer; a run only starts when the NAS answers on port 445 |
| Time Machine app | *Browse and restore* opens the snapshots in Nautilus |

## Install

```bash
bin/install
```

It asks for sudo. It installs restic and rclone, puts the run script in `/usr/local/lib/nas-backup/`, `nas-backup.service` and `.timer` in `/etc/systemd/system/`, and a polkit rule that lets you start and stop a backup from the panel without a password. Then it copies the plugin to `~/.config/omarchy/plugins/renuo.nas-backup/` and puts it in the bar.

## Set up

Do it at the office. The panel lists the steps; each opens a terminal and asks for sudo:

1. **NAS login.** *Connect* asks for the server address, username and password of **`[Renuo-NAS] Backup User`** in 1Password, and a folder for this laptop on the share (your user and hostname, unless you change it). It tries the login, then keeps it in `/etc/nas-backup/nas.env`, readable by root only. *Settings* and *Excludes* open `/etc/nas-backup/backup.env` and `excludes.txt` with sudoedit.
2. **Encryption password.** Create one, or on a new laptop enter the one you kept. *Copy* it into 1Password, **Employee** vault. It never leaves `/etc/nas-backup/password` otherwise, and is never replaced.
3. **Repository.** *Set up* creates the repository in your folder, or connects to the one your last laptop made.
4. **Automatic backups.** The switch at the top enables the timer; polkit asks for your password once. *Change* edits its schedule.

The first backup takes hours. Keep the laptop plugged in, on cable if you can.

## Back up and restore

*Back up now* runs a backup at once, if the NAS is in reach. *Log* follows the service's journal and *Snapshots* lists the backups.

*Browse and restore* mounts the backups and opens them in Nautilus. In a snapshot, `/` is under `.nas-backup/root` and `/home` under `.nas-backup/home`. Copy out what you need, then press Ctrl+C in the terminal.

*restic shell* opens a root shell with the service's settings. To restore a folder in place without touching files that exist:

```bash
restic restore latest:/.nas-backup/home/$SUDO_USER/Work --target /home/$SUDO_USER/Work --overwrite never
```

A whole new laptop: install Omarchy on btrfs, install this plugin, connect, enter the kept password, *Set up* connects to the repository, then restore `/home` from a restic shell.

## Files

| Path | What |
|---|---|
| `/etc/nas-backup/backup.env` | Settings: NAS, repository, subvolumes, retention, quota |
| `/etc/nas-backup/excludes.txt` | What to leave out |
| `/etc/nas-backup/nas.env` | NAS login, root only |
| `/etc/nas-backup/password` | Encryption password, root only; keep a copy in 1Password |
| `/var/lib/nas-backup/` | Outcome of the last run and the size on the NAS, for the panel |
| `/.nas-backup/` | The snapshots, only while a backup runs |

## Remove

```bash
sudo systemctl disable --now nas-backup.timer
omarchy plugin remove renuo.nas-backup
sudo rm -r /etc/systemd/system/nas-backup.{service,timer} /etc/polkit-1/rules.d/50-nas-backup.rules /usr/local/lib/nas-backup
```

The backups on the NAS and `/etc/nas-backup` stay.

## Development

```bash
bin/setup   # checks the tools bin/check needs
bin/check   # validates the manifest and the units, runs the tests
bin/install # installs into the system and the shell
```
