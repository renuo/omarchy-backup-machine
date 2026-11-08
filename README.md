# Machine backup — Omarchy plugin

The **machine** level of a Renuo laptop's backup: the whole system as it is, once a day you are at the office, to Renuo's NAS. It is the Linux take on [NAS Backup with Time Machine](https://github.com/renuo/laptop-setup-guide-for-macos/blob/main/nice_to_have/nas_backup.md).

## Three levels

Each level has its own place and its own pace. Renuo keeps the machine and the work on the office NAS and in Google Drive, each with a plugin; the config is your own dotfiles repository.

| Level | Plugin | Keeps | Where | When | Brings back |
|---|---|---|---|---|---|
| **Machine** | [renuo.backup-machine](https://github.com/renuo/omarchy-backup-machine) (this one) | The whole system: `/` and `/home` | Office NAS | Once a day at the office | This laptop as it was, after a broken disk or a bad update |
| **Config** | none: the dotfiles are yours | The dotfiles chezmoi manages: Omarchy tweaks, shell, editor, packages | Your dotfiles repository | When you commit and push | Your setup, on a new laptop |
| **Work** | [renuo.backup-work](https://github.com/renuo/omarchy-backup-work) | `~/Work`, `~/Documents`, `~/Pictures` | Your Renuo Google Drive | Every hour | Your files, on any laptop |

What lives in Google Drive already, like documents shared with colleagues, needs none of them.

The machine level is the slowest and the biggest. It is there to put this laptop back exactly as it was; the other two levels are what a new laptop starts from. It may be a day old, where the work level is at most an hour old.

| Icon | Meaning |
|---|---|
| NAS | The last backup worked |
| Spinning arrows | A backup is running |
| Alert, urgent colour | The last backup failed, the backups outgrew the quota, or none worked for 10 days |
| Dimmed | Not set up yet, or automatic backups are off |

Hover for the last backup and whether today's is done, due or waiting for the office. Click for the panel, right-click to refresh.

## How it maps from Time Machine

| Time Machine | Here |
|---|---|
| SMB share `laptop_backups`, user `backup-user` | The same share and login, through rclone's SMB backend; nothing is mounted |
| Backs up the whole Mac | Read-only btrfs snapshots of `/` and `/home`, one consistent moment, backed up with [restic](https://restic.net) |
| Encryption password | restic encrypts everything with a password of yours; the NAS login is shared by everyone |
| Disk usage limit, about 2 TB | `BACKUP_MACHINE_QUOTA_GB=2000`; the panel turns urgent above it. Old backups go by the retention, not by the quota |
| Hourly, daily for a month, weekly | Daily: `--keep-daily 7 --keep-weekly 4 --keep-monthly 6`. The hours are the work level's job |
| Backs up when the disk is there | A check every hour at a random minute; the first one each day that finds the NAS on port 445 starts the backup |
| Time Machine app | *Browse and restore* opens the snapshots in Nautilus |

## Install

```bash
bin/install
```

It asks for sudo. It installs restic and rclone, puts the run script in `/usr/local/lib/backup-machine/`, `backup-machine.service`, `backup-machine-daily.service` and `backup-machine-daily.timer` in `/etc/systemd/system/`, and a polkit rule that lets you start and stop a backup from the panel without a password. Then it copies the plugin to `~/.config/omarchy/plugins/renuo.backup-machine/` and puts it in the bar.

## Set up

Do it at the office. The panel lists the steps; each opens a terminal and asks for sudo:

1. **NAS login.** *Connect* asks for the server address, username and password of **`[Renuo-NAS] Backup User`** in 1Password, and a folder for this laptop on the share (your user and hostname, unless you change it). It tries the login, then keeps it in `/etc/backup-machine/nas.env`, readable by root only. *Settings* and *Excludes* open `/etc/backup-machine/backup.env` and `excludes.txt` with sudoedit.
2. **Encryption password.** Create one, or on a new laptop enter the one you kept. *Copy* it into 1Password, **Employee** vault. It never leaves `/etc/backup-machine/password` otherwise, and is never replaced.
3. **Repository.** *Set up* creates the repository in your folder, or connects to the one your last laptop made.
4. **Automatic backups.** The switch at the top enables `backup-machine-daily.timer`; polkit asks for your password once. *Change* edits its schedule.

The first backup takes hours. Keep the laptop plugged in, on cable if you can.

## Back up and restore files

*Back up now* runs a backup at once, if the NAS is in reach, even when today's is done. *Log* follows the service's journal and *Snapshots* lists the backups.

*Browse and restore* mounts the backups and opens them in Nautilus. In a snapshot, `/` is under `.backup-machine/root` and `/home` under `.backup-machine/home`. Copy out what you need, then press Ctrl+C in the terminal.

*restic shell* opens a root shell with the service's settings. To restore a folder in place without touching files that exist:

```bash
restic restore latest:/.backup-machine/home/$SUDO_USER/.config --target /home/$SUDO_USER/.config --overwrite never
```

## Restore this machine

Try the small way first. Limine's boot menu offers snapper's snapshots of `/` from before each update, and *Browse and restore* gets single files back. What follows replaces the whole system with a backup. It has not been tried end to end yet: do it once on a spare disk or in a VM before you rely on it.

The backup holds `/` and `/home`. The other subvolumes are not in it: `/var/log`, the package cache, `/swap` and snapper's `/.snapshots` stay on the disk. `/boot` is not on btrfs; it is rebuilt from the kernel in the backup.

At the office, boot the [Arch Linux ISO](https://archlinux.org/download/) from a USB stick, get online (cable, or `iwctl`), and have 1Password at hand on your phone:

```bash
pacman -Sy --noconfirm restic rclone
lsblk -f                                    # the crypto_LUKS partition, and the vfat one for /boot
cryptsetup open /dev/nvme0n1p2 root         # your disk password
mkdir /top && mount -o subvolid=5 /dev/mapper/root /top

export RCLONE_SMB_HOST=NAS_ADDRESS RCLONE_SMB_USER=backup-user
export RCLONE_SMB_PASS="$(rclone obscure 'password of [Renuo-NAS] Backup User')"
export RESTIC_REPOSITORY=rclone::smb:laptop_backups/YOUR_FOLDER
restic snapshots                            # asks for your encryption password

mv /top/@ /top/@broken
mv /top/@home /top/@home-broken
btrfs subvolume create /top/@
btrfs subvolume create /top/@home
restic restore latest:/.backup-machine/root --target /top/@
restic restore latest:/.backup-machine/home --target /top/@home
for sub in swap .snapshots; do rmdir "/top/@/$sub" && mv "/top/@broken/$sub" "/top/@/$sub"; done

mount -o subvol=@ /dev/mapper/root /mnt
mount /dev/nvme0n1p1 /mnt/boot              # the vfat partition
arch-chroot /mnt limine-mkinitcpio          # kernel and initramfs to /boot, as the backup has them
reboot
```

On a **new disk**, install Omarchy on it first, so it has its partitions, encryption, subvolumes and boot loader. Then do the same, but before `limine-mkinitcpio` put back the new installation's files that name the disk:

```bash
cp /top/@broken/etc/fstab /top/@broken/etc/crypttab /mnt/etc/
cp /top/@broken/etc/default/limine /mnt/etc/default/
```

Once the laptop runs as before, the work level brings `~/Work` up to the last hour, and `chezmoi update` the config. Then delete `@broken` and `@home-broken` with `btrfs subvolume delete --recursive`.

## Files

| Path | What |
|---|---|
| `/etc/backup-machine/backup.env` | Settings: NAS, repository, subvolumes, retention, quota |
| `/etc/backup-machine/excludes.txt` | What to leave out |
| `/etc/backup-machine/nas.env` | NAS login, root only |
| `/etc/backup-machine/password` | Encryption password, root only; keep a copy in 1Password |
| `/var/lib/backup-machine/` | Outcome of the last run and the size on the NAS, for the panel and the daily check |
| `/.backup-machine/` | The snapshots, only while a backup runs |

## Remove

```bash
sudo systemctl disable --now backup-machine-daily.timer
omarchy plugin remove renuo.backup-machine
sudo rm -r /etc/systemd/system/backup-machine{.service,-daily.service,-daily.timer} /etc/polkit-1/rules.d/50-backup-machine.rules /usr/local/lib/backup-machine
```

The backups on the NAS and `/etc/backup-machine` stay.

## Development

```bash
bin/setup   # checks the tools bin/check needs
bin/check   # validates the manifest and the units, runs the tests
bin/install # installs into the system and the shell
```
