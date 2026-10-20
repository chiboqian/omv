# OpenMediaVault 8 LUKS + Filesystem + MergerFS Pool Manager

[`omv-pool.sh`](./omv-pool.sh) is a unified Bash script for **OpenMediaVault 8 (OMV 8)** that manages a MergerFS pool layered over underlying branch filesystems (`ext4`, `xfs`, `btrfs`, `f2fs`, etc.) on top of `crypto_LUKS` encrypted drives sharing the same passphrase, along with any associated NFS `/export/*` bind mounts and SMB/NFS sharing services.

---

## Features & OMV 8 Conventions

1. **LUKS Layer (`LUKS_UUIDS`)**
   - References raw encrypted partitions by immutable UUID (`/dev/disk/by-uuid/<LUKS_UUID>`).
   - Unlocks drives using the `<kname>-crypt` mapper naming convention (e.g., `sde-crypt`, `sdf-crypt`) so the OMV 8 `openmediavault-luksencryption` Web UI accurately reflects the unlocked state.
   - Prompts once interactively for the shared passphrase (with up to 3 retry attempts, or reads from non-TTY `stdin`) and pipes it via `stdin` to `cryptsetup open`.
   - Dynamically resolves active `crypt` child mappers via `lsblk` when locking, so drives unlocked via the OMV 8 Web UI can also be locked by the script.

2. **Filesystem Layer (`FS_MOUNTS`)**
   - Filesystem-agnostic: supports any Linux filesystem (`ext4`, `xfs`, `btrfs`, `f2fs`, etc., including mixed filesystems across drives) automatically.
   - Works whether or not the filesystems are in `/etc/fstab`: resolves and mounts `/srv/dev-disk-by-uuid-<FS_UUID>` via `/etc/fstab`, systemd `.mount` units (`/etc/systemd/system/srv-*.mount`), `/etc/openmediavault/config.xml` (`mntent`), or direct `/dev/disk/by-uuid/<FS_UUID>` device mounts.

3. **MergerFS Layer (`MERGERFS_MOUNT`)**
   - Discovers pool branch paths from `/etc/systemd/system/srv-mergerfs-<pool>.mount` (`Options=branches=...`, `What=`, or `RequiresMountsFor=`) or `/etc/openmediavault/config.xml`.
   - Starts/stops the OMV 8 `openmediavault-mergerfs` systemd mount unit (`srv-mergerfs-<pool>.mount`), resetting any boot-time failed state (`systemctl reset-failed`) and restarting the unit if underlying branch filesystems were newly mounted after boot.

4. **Shared Folders Layer (`EXPORT_MOUNTS` & `SHARE_SERVICES`)**
   - Automatically discovers `/export/*` NFS bind mounts backed by the MergerFS pool (or its underlying branch mounts) from `/etc/fstab`, systemd `export-*.mount` units, or `/etc/openmediavault/config.xml`, mounting them after MergerFS on `unlock` and unmounting them before MergerFS on `lock`.
   - Detects enabled OMV file-sharing services (`smbd.service`, `nfs-server.service`) via `systemctl` and `/etc/openmediavault/config.xml`:
     - On `unlock`: starts or reloads `smbd.service` / `nfs-server.service` after the pool and exports are mounted.
     - On `lock`: stops `smbd.service` / `nfs-server.service` before unmounting so open SMB/NFS file handles do not block `umount` with `target is busy`, then starts `smbd.service` / `nfs-server.service` back up after locking so other shares remain active.

5. **Configuration (`/etc/omv-pool.conf`)**
   - Generated automatically by inspecting `/etc/systemd/system/srv-mergerfs-*.mount` (or `/etc/openmediavault/config.xml`), `/etc/fstab` / systemd `.mount` units / `config.xml`, and `lsblk -s` / sysfs slaves / `cryptsetup luksUUID`.
   - Stored with `0600` permissions at `/etc/omv-pool.conf`.

---

## Usage

```bash
# 1. Generate and save /etc/omv-pool.conf from the MergerFS pool name
sudo ./omv-pool.sh config <mergerfs-pool-name>

# 2. Unlock LUKS drives (prompts once), mount filesystems + MergerFS + exports, and start SMB/NFS
sudo ./omv-pool.sh unlock

# 3. Check current LUKS, filesystem, MergerFS, export bind mount, and SMB/NFS status (-s, --status, or status)
sudo ./omv-pool.sh status
sudo ./omv-pool.sh -s

# 4. Stop SMB/NFS, unmount exports + MergerFS + filesystems, lock LUKS drives, and restart SMB/NFS
sudo ./omv-pool.sh lock

# 5. Preview any action without making changes (-n or --dry-run)
sudo ./omv-pool.sh --dry-run config <mergerfs-pool-name>
sudo ./omv-pool.sh --dry-run unlock
sudo ./omv-pool.sh --dry-run lock
```
