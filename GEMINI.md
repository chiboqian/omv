# OpenMediaVault 8 LUKS + Filesystem + MergerFS Pool Manager

## Overview
This directory contains [`omv-pool.sh`](./omv-pool.sh), a unified bash script for **OpenMediaVault 8 (OMV 8)** that manages a MergerFS pool layered over underlying branch filesystems (`ext4`, `xfs`, `btrfs`, `f2fs`, etc.) on top of `crypto_LUKS` encrypted drives sharing the same passphrase, along with any associated NFS `/export/*` bind mounts and SMB/NFS sharing services.

---

## Architecture & OMV 8 Conventions

1. **LUKS Layer (`LUKS_UUIDS`)**
   - References raw encrypted partitions by immutable UUID (`/dev/disk/by-uuid/<LUKS_UUID>`).
   - Unlocks drives using the `<kname>-crypt` mapper naming convention (e.g., `sda-crypt`, `sdb-crypt`) so the OMV 8 `openmediavault-luksencryption` Web UI accurately reflects the unlocked state.
   - Prompts once interactively for the shared passphrase (with up to 3 retry attempts) and pipes it via `stdin` to `cryptsetup open`.
   - Dynamically resolves active `crypt` child mappers via `lsblk` when locking, so drives unlocked via the OMV 8 Web UI can also be locked by the script.

2. **Filesystem Layer (`FS_MOUNTS`)**
   - Filesystem-agnostic: supports any Linux filesystem (`ext4`, `xfs`, `btrfs`, `f2fs`, etc., including mixed filesystems across drives) automatically (and maintains backwards compatibility with `EXT4_MOUNTS` in existing config files).
   - Works whether or not the filesystems are in `/etc/fstab`: resolves and mounts `/srv/dev-disk-by-uuid-<FS_UUID>` via `/etc/fstab`, systemd `.mount` units (`/etc/systemd/system/srv-*.mount`), `/etc/openmediavault/config.xml` (`mntent`), or direct `/dev/disk/by-uuid/<FS_UUID>` device mounts.

3. **MergerFS Layer (`MERGERFS_MOUNT`)**
   - Starts/stops the OMV 8 `openmediavault-mergerfs` systemd mount unit (`srv-mergerfs-<pool>.mount` via `systemd-escape`), resetting any boot-time failed state (`systemctl reset-failed`) and restarting the unit if underlying branch filesystems were newly mounted after boot.

4. **Shared Folders Layer (`EXPORT_MOUNTS` & `SHARE_SERVICES`)**
   - Automatically discovers `/export/*` NFS bind mounts backed by the MergerFS pool (or its underlying branch mounts) from `/etc/fstab`, systemd `export-*.mount` units, or `/etc/openmediavault/config.xml`, mounting them after MergerFS on `unlock` and unmounting them before MergerFS on `lock`.
   - Detects enabled OMV file-sharing services (`smbd.service`, `nfs-server.service`) via `systemctl` and `/etc/openmediavault/config.xml`:
     - On `unlock`: starts or reloads `smbd.service` / `nfs-server.service` after the pool and exports are mounted.
     - On `lock`: stops `smbd.service` / `nfs-server.service` before unmounting so open SMB/NFS file handles do not block `umount` with `target is busy`, then starts `smbd.service` / `nfs-server.service` back up after locking so other shares remain active.

5. **Configuration (`/etc/omv-pool.conf`)**
   - Generated automatically by inspecting `/etc/systemd/system/srv-mergerfs-*.mount` (or `/etc/openmediavault/config.xml`), `/etc/fstab`, and `lsblk`/`cryptsetup luksUUID`.
   - Stored with `0600` permissions at `/etc/omv-pool.conf`.

---

## Usage

```bash
# 1. Generate and save /etc/omv-pool.conf from the MergerFS pool name
sudo ./omv-pool.sh config <mergerfs-pool-name>

# 2. Unlock LUKS drives (prompts once), mount filesystems + MergerFS + exports, and start SMB/NFS
sudo ./omv-pool.sh unlock

# 3. Check current LUKS, filesystem, MergerFS, export bind mount, and SMB/NFS status
sudo ./omv-pool.sh status

# 4. Stop SMB/NFS, unmount exports + MergerFS + filesystems, and lock LUKS drives
sudo ./omv-pool.sh lock

# 5. Preview any action without making changes (-n or --dry-run)
sudo ./omv-pool.sh --dry-run config <mergerfs-pool-name>
sudo ./omv-pool.sh --dry-run unlock
sudo ./omv-pool.sh --dry-run lock
```

---

## Guardrails for Future Modifications
- **Never hardcode `/dev/sdX` paths**: Drive letters can shift across reboots; always resolve from `/dev/disk/by-uuid/`.
- **Safe unmounting**: Always tear down in reverse dependency order (`SMB/NFS services` -> `/export/* bind mounts` -> `MergerFS` -> `branch filesystems` -> `sync` -> `cryptsetup close`) and report active processes with `fuser -vm` if any mount point is busy.
- **Passphrase handling**: Never pass LUKS passphrases as command-line arguments (`ps`-visible); always pipe via `stdin` (`printf '%s' "$luks_pass" | cryptsetup open ... -`) and `unset` immediately after use.

---

## Future Roadmap: Packaging as an OMV 8 Plugin (`openmediavault-lukspool`)

When ready to package `omv-pool.sh` as a native OMV 8 `.deb` plugin, use OMV's declarative Workbench YAML frontend and PHP RPC backend:

### 1. Package Layout
```text
openmediavault-lukspool/
├── debian/
│   ├── control
│   ├── install
│   └── postinst
└── usr/
    ├── sbin/
    │   └── omv-pool.sh
    └── share/openmediavault/
        ├── engined/rpc/
        │   └── lukspool.inc
        └── workbench/
            ├── navigation.d/
            │   └── storage.lukspool.yaml
            ├── route.d/
            │   └── storage.lukspool.yaml
            └── component.d/
                └── omv-storage-lukspool-page.yaml
```

### 2. Backend RPC (`usr/share/openmediavault/engined/rpc/lukspool.inc`)
- Define `OMVRpcServiceLuksPool extends \OMV\Rpc\ServiceAbstract` under `namespace Engined\Rpc`.
- Register RPC methods:
  - `getStatus`: runs `/usr/sbin/omv-pool.sh status` and returns `["statusText" => ...]`.
  - `configure`: runs `/usr/sbin/omv-pool.sh config <poolName>`.
  - `unlock`: spawns `/usr/sbin/omv-pool.sh unlock` via `proc_open()` and writes `$params['passphrase'] . "\n"` to `stdin` pipe `0` (update `omv-pool.sh` to support non-TTY stdin via `if [[ -t 0 ]]; then read -rsp ...; else read -r ...; fi`).
  - `lock`: runs `/usr/sbin/omv-pool.sh lock`.

### 3. Workbench UI YAML (`usr/share/openmediavault/workbench/`)
- **Navigation (`navigation.d/storage.lukspool.yaml`)**: Adds `storage.lukspool` ("LUKS Pool") at `/storage/lukspool`.
- **Route (`route.d/storage.lukspool.yaml`)**: Maps `/storage/lukspool` to component `omv-storage-lukspool-page`.
- **Component (`component.d/omv-storage-lukspool-page.yaml`)**:
  - `formPage` calling `LuksPool.getStatus` into a readonly `textarea` (`statusText`).
  - **Unlock & Mount** button opening a `formDialog` with a `passwordInput` (`passphrase`) that submits to `LuksPool.unlock`.
  - **Unmount & Lock** button with `confirmationDialogConfig` that calls `LuksPool.lock`.

### 4. Build & Activation (`debian/postinst`)
- In `debian/postinst` (`configure` stage), run:
  ```bash
  omv-mkworkbench all
  systemctl restart openmediavault-engined || true
  ```
- Build and install with:
  ```bash
  dpkg-deb --build openmediavault-lukspool
  sudo dpkg -i openmediavault-lukspool.deb
  ```
