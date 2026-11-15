# nas-infra

Ansible for a NAS (Raspberry Pi 5, OpenMediaVault 8). OMV stays in charge of the Docker stacks (*Services → Compose*). This repo only manages what OMV does not.

## Layout

| Path | Content |
| :--- | :--- |
| `inventory.yml` | The NAS (SSH port 2222) |
| `group_vars/nas/vars.yml` | Paths, retention, alert thresholds |
| `group_vars/nas/vault.yml` | restic password, site-specific backup paths; ansible-vault encrypted |
| `roles/restic_backup/` | Backup in two stages (below) |
| `roles/raid_check/` | Fixed times for the monthly RAID check (below) |

## Setup

Put the vault password from KeePass into `.ansible_vault_pass`. To create the vault initially, see `group_vars/nas/vault.yml.example`.

```sh
ansible-playbook site.yml --check --diff   # dry run
ansible-playbook site.yml --diff           # apply
```

## Backup

| Stage | Where | When | Retention |
| :--- | :--- | :--- | :--- |
| 0 (OMV) | `ComposeBackup/` on md0: mirror of each stack, stopped during the copy, no history | 03:00, OMV compose job | none |
| 1 | `ResticRepo/` on md0 | right after stage 0 (post-backup hook of the OMV job) | 7 daily, 5 weekly, 12 monthly, 3 yearly |
| 2 | USB disk `nas-offsite`, stored offsite | when plugged in (udev), about every 6 months | 24 monthly, 10 yearly |

Stage 1 contains `ComposeBackup/`, `ComposeFiles/`, the `:ro` mounts the OMV backup skips (`vault_restic_extra_paths`) and the SD card's config: `/etc` (incl. `/etc/openmediavault/config.xml`), `/root`, `/home/admin`, `/opt`, `/usr/local`, `/boot/firmware`, plus package/disk/image lists in `/var/lib/nas-backup/sysinfo/`.

Mails go to the primary address of OMV's notification settings (*System → Notification*): failed runs, weekly check results, newest snapshot older than 36 h, offsite disk due (> 190 days). Mail must be set up in OMV, this repo does not touch it.

The restic password is in the vault and in KeePass. **Without it, both repos are unreadable.**

### Commands on the NAS

```sh
sudo journalctl -u nas-backup              # last daily runs
sudo systemctl start nas-backup-maint      # prune + check now
sudo nas-backup --manual                   # backup now (skips the "ComposeBackup is from tonight" check)
sudo -i; . /etc/nas-backup/config.sh       # then plain restic commands work on stage 1:
restic snapshots
restic restore latest --target /tmp/restore --include /etc/openmediavault/config.xml
restic -r "$OFFSITE_REPO" snapshots          # stage 2, disk mounted at /mnt/nas-offsite
```

### Offsite disk

Plug it in. The sync starts by itself and mails «läuft», then «fertig, Platte kann abgezogen werden». It copies all new snapshots, prunes, reads back all data, unmounts and powers off the disk. On failure, a mail with the log is sent and the disk is unmounted.

New disk: ext4 with label `nas-offsite`, then once `sudo nas-offsite-sync --init`.

Restore from the disk on the NAS, without starting a sync (`systemctl mask` does not work, the unit is in `/etc`):

```sh
sudo touch /run/nas-offsite-hold          # gone after a reboot
# plug in the disk
sudo -i; . /etc/nas-backup/config.sh
mount /dev/disk/by-label/nas-offsite /mnt/nas-offsite
restic -r "$OFFSITE_REPO" snapshots
umount /mnt/nas-offsite; rm /run/nas-offsite-hold
```

### Restore without the NAS

Any machine with restic ≥ 0.14: mount the offsite disk, `restic -r <mount>/restic snapshots` with the password from KeePass. Then rebuild: install OMV and the plugins, create RAID, filesystem and shared folders (`/etc/openmediavault/config.xml` from the backup is the reference for all settings), restore `ComposeBackup/` and recreate the stacks via *Compose → Restore*, then run this playbook.

## RAID check

Debian's `mdcheck` reads all sectors of md0 once a month, at most 6 h per night. The stock timers start at a random time within 24 h (12 h for the continuation). The drop-ins fix them: start on the first Thursday of the month at 21:00, continue at 21:00 on the following nights until done. Weak sectors found by the check raise the SMART counters, and smartd (enabled in OMV, *Storage → S.M.A.R.T.*) mails about them.

```sh
systemctl list-timers 'mdcheck*'
cat /proc/mdstat                           # progress while running
```
