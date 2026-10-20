#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/etc/omv-pool.conf"
DRY_RUN=0

usage() {
    cat >&2 <<EOF
Usage:
  sudo $(basename "$0") [-n|--dry-run] config <mergerfs-pool-name>   Generate and save $CONFIG_FILE
  sudo $(basename "$0") [-n|--dry-run] unlock                        Unlock LUKS, mount filesystems + MergerFS + exports, and start SMB/NFS
  sudo $(basename "$0") [-n|--dry-run] lock                          Stop SMB/NFS, unmount exports + MergerFS + filesystems, and lock LUKS
  sudo $(basename "$0") status                                       Show current LUKS, mount, and SMB/NFS share status

Options:
  -n, --dry-run   Show what actions would be taken without making any changes
  -h, --help      Show this help message
EOF
    exit 1
}

POSITIONAL_ARGS=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            POSITIONAL_ARGS+=("$1")
            shift
            ;;
    esac
done
if [[ ${#POSITIONAL_ARGS[@]} -gt 0 ]]; then
    set -- "${POSITIONAL_ARGS[@]}"
else
    set --
fi

[[ $# -eq 0 ]] && usage

if [[ $EUID -ne 0 ]]; then
    echo "Error: Please run as root (sudo $0 ...)." >&2
    exit 1
fi

get_active_mapper() {
    local dev="/dev/disk/by-uuid/$1"
    lsblk -nlo NAME,TYPE "$dev" 2>/dev/null | awk '$2=="crypt"{print $1; exit}'
}

load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "Error: Config file $CONFIG_FILE not found." >&2
        echo "Run 'sudo $(basename "$0") config <mergerfs-pool-name>' first." >&2
        exit 1
    fi
    # shellcheck source=/dev/null
    source "$CONFIG_FILE"

    # Backwards compatibility with configs that used EXT4_MOUNTS
    if [[ ${#FS_MOUNTS[@]:-0} -eq 0 && ${#EXT4_MOUNTS[@]:-0} -gt 0 ]]; then
        FS_MOUNTS=("${EXT4_MOUNTS[@]}")
    fi
}

# Discover /export/* bind mounts from config and /etc/fstab matching the pool or underlying drives
get_export_mounts() {
    local exports=()
    for m in "${EXPORT_MOUNTS[@]:-}"; do
        [[ -n "$m" ]] && exports+=("$m")
    done

    while read -r src dst; do
        [[ -z "$dst" ]] && continue
        local match=0
        if [[ "$src" == "$MERGERFS_MOUNT" || "$src" == "${MERGERFS_MOUNT}/"* ]]; then
            match=1
        fi
        for fs_mnt in "${FS_MOUNTS[@]:-}"; do
            if [[ "$src" == "$fs_mnt" || "$src" == "${fs_mnt}/"* ]]; then
                match=1
            fi
        done
        if [[ $match -eq 1 ]]; then
            local already=0
            for existing in "${exports[@]:-}"; do
                [[ "$existing" == "$dst" ]] && already=1 && break
            done
            [[ $already -eq 0 ]] && exports+=("$dst")
        fi
    done < <(awk '$1 !~ /^#/ && $2 ~ /^\/export\// {print $1, $2}' /etc/fstab 2>/dev/null)

    for m in "${exports[@]:-}"; do
        [[ -n "$m" ]] && printf '%s\n' "$m"
    done
}

# Discover enabled SMB/NFS services from config, OMV config.xml, or systemd
get_share_services() {
    local services=()
    for s in "${SHARE_SERVICES[@]:-}"; do
        [[ -n "$s" ]] && services+=("$s")
    done

    local candidates=("smbd.service" "nfs-server.service")
    for svc in "${candidates[@]}"; do
        local enabled=0
        if systemctl is-enabled --quiet "$svc" 2>/dev/null || systemctl is-active --quiet "$svc" 2>/dev/null; then
            enabled=1
        elif command -v xmlstarlet &>/dev/null && [[ -f /etc/openmediavault/config.xml ]]; then
            local xpath=""
            [[ "$svc" == "smbd.service" ]] && xpath="//services/smb/enable"
            [[ "$svc" == "nfs-server.service" ]] && xpath="//services/nfs/enable"
            if [[ -n "$xpath" ]] && [[ "$(xmlstarlet sel -t -v "$xpath" /etc/openmediavault/config.xml 2>/dev/null || true)" == "1" ]]; then
                enabled=1
            fi
        fi

        if [[ $enabled -eq 1 ]]; then
            local already=0
            for existing in "${services[@]:-}"; do
                [[ "$existing" == "$svc" ]] && already=1 && break
            done
            [[ $already -eq 0 ]] && services+=("$svc")
        fi
    done

    for s in "${services[@]:-}"; do
        [[ -n "$s" ]] && printf '%s\n' "$s"
    done
}

# ---------------------------------------------------------------------------
# 1. CONFIG: Discover LUKS UUIDs, filesystem mounts, exports & share services
# ---------------------------------------------------------------------------
do_config() {
    local input_name="${1:-}"
    [[ -z "$input_name" ]] && usage

    local pool_name="${input_name#/srv/mergerfs/}"
    pool_name="${pool_name%/}"
    pool_name="${pool_name#srv-mergerfs-}"
    pool_name="${pool_name%.mount}"

    local mergerfs_mount="/srv/mergerfs/${pool_name}"
    local unit_name
    unit_name="$(systemd-escape -p --suffix=mount "$mergerfs_mount")"
    local unit_path="/etc/systemd/system/${unit_name}"
    local raw_branches=""

    if [[ -f "$unit_path" ]]; then
        echo "[INFO] Reading systemd unit: $unit_path"
        raw_branches="$(awk -F'[[:space:]]*=[[:space:]]*' '$1=="What"{print $2; exit}' "$unit_path")"
        local where_path
        where_path="$(awk -F'[[:space:]]*=[[:space:]]*' '$1=="Where"{print $2; exit}' "$unit_path")"
        [[ -n "$where_path" ]] && mergerfs_mount="$where_path"
    elif command -v xmlstarlet &>/dev/null && [[ -f /etc/openmediavault/config.xml ]]; then
        echo "[INFO] Unit $unit_path not found; querying /etc/openmediavault/config.xml..."
        raw_branches="$(xmlstarlet sel -t -m "//services/mergerfs/pools/pool[name='${pool_name}']" -v "paths" -n /etc/openmediavault/config.xml || true)"
    fi

    if [[ -z "$raw_branches" ]]; then
        echo "Error: MergerFS pool '${pool_name}' not found." >&2
        echo "Available MergerFS units:" >&2
        ls -1 /etc/systemd/system/srv-mergerfs-*.mount 2>/dev/null >&2 || echo "  (none found)" >&2
        exit 1
    fi

    IFS=':' read -r -a branch_list <<< "$raw_branches"

    local fs_mounts=()
    local fs_devs=()

    for branch in "${branch_list[@]}"; do
        [[ -z "$branch" ]] && continue

        local mnt
        if [[ "$branch" =~ ^(/srv/dev-disk-by-uuid-[^/]+) ]]; then
            mnt="${BASH_REMATCH[1]}"
        else
            mnt="${branch%/}"
        fi

        local already_added=0
        for existing in "${fs_mounts[@]:-}"; do
            [[ "$existing" == "$mnt" ]] && already_added=1 && break
        done
        [[ $already_added -eq 1 ]] && continue

        local fs_spec
        fs_spec="$(awk -v m="$mnt" '$1 !~ /^#/ && $2 == m {print $1; exit}' /etc/fstab)"
        if [[ -z "$fs_spec" ]]; then
            if [[ "$mnt" =~ ^/srv/dev-disk-by-uuid-(.+)$ ]]; then
                fs_spec="/dev/disk/by-uuid/${BASH_REMATCH[1]}"
            else
                echo "Error: Could not find $mnt in /etc/fstab." >&2
                exit 1
            fi
        fi

        if [[ "$fs_spec" =~ ^UUID=(.+)$ ]]; then
            fs_spec="/dev/disk/by-uuid/${BASH_REMATCH[1]}"
        fi

        fs_mounts+=("$mnt")
        fs_devs+=("$fs_spec")
    done

    # Temporarily unlock LUKS drives if inner filesystem UUIDs aren't visible yet
    local missing_dev=0
    for dev in "${fs_devs[@]}"; do
        [[ ! -e "$dev" ]] && missing_dev=1 && break
    done

    if [[ $missing_dev -eq 1 ]]; then
        if [[ $DRY_RUN -eq 1 ]]; then
            echo "[DRY-RUN] LUKS drives are currently locked; would prompt for LUKS passphrase and temporarily unlock crypto_LUKS devices:"
            while read -r luks_dev; do
                [[ -z "$luks_dev" ]] && continue
                local active_crypt
                active_crypt="$(lsblk -nlo NAME,TYPE "$luks_dev" 2>/dev/null | awk '$2=="crypt"{print $1; exit}')"
                if [[ -z "$active_crypt" ]]; then
                    local kname mapper
                    kname="$(lsblk -ndo KNAME "$luks_dev")"
                    mapper="${kname}-crypt"
                    echo "[DRY-RUN] Would unlock $luks_dev as /dev/mapper/${mapper}"
                fi
            done < <(blkid -t TYPE=crypto_LUKS -o device)
        else
            echo "[INFO] LUKS drives are currently locked; unlocking to inspect inner filesystem UUIDs..."
            local luks_pass
            read -rsp "Enter LUKS passphrase: " luks_pass
            echo

            while read -r luks_dev; do
                [[ -z "$luks_dev" ]] && continue
                local active_crypt
                active_crypt="$(lsblk -nlo NAME,TYPE "$luks_dev" 2>/dev/null | awk '$2=="crypt"{print $1; exit}')"
                if [[ -z "$active_crypt" ]]; then
                    local kname mapper
                    kname="$(lsblk -ndo KNAME "$luks_dev")"
                    mapper="${kname}-crypt"
                    echo "Unlocking $luks_dev as /dev/mapper/${mapper}..."
                    printf '%s' "$luks_pass" | cryptsetup open "$luks_dev" "$mapper" - || true
                fi
            done < <(blkid -t TYPE=crypto_LUKS -o device)

            unset luks_pass
            udevadm settle
        fi
    fi

    local luks_uuids=()
    for i in "${!fs_devs[@]}"; do
        local fs_dev="${fs_devs[$i]}"
        local fs_mnt="${fs_mounts[$i]}"

        if [[ ! -e "$fs_dev" ]]; then
            if [[ $DRY_RUN -eq 1 ]]; then
                echo "[DRY-RUN] Inner filesystem $fs_dev ($fs_mnt) is currently locked; skipping parent LUKS UUID resolution."
                luks_uuids+=("<locked-luks-uuid-for-${fs_mnt##*/}>")
                continue
            fi
            echo "Error: Inner filesystem $fs_dev ($fs_mnt) not found even after unlocking." >&2
            exit 1
        fi

        local pkname
        pkname="$(lsblk -ndo PKNAME "$fs_dev")"
        if [[ -z "$pkname" ]]; then
            echo "Error: Could not find parent device for $fs_dev." >&2
            exit 1
        fi

        local parent_dev="/dev/${pkname}"
        if ! cryptsetup isLuks "$parent_dev"; then
            echo "Error: Parent device $parent_dev ($fs_mnt) is not a LUKS partition." >&2
            exit 1
        fi

        local luks_uuid
        luks_uuid="$(cryptsetup luksUUID "$parent_dev")"
        echo "[INFO] Mapped $fs_mnt -> $parent_dev (LUKS UUID: $luks_uuid)"
        luks_uuids+=("$luks_uuid")
    done

    # Discover /export/* bind mounts and enabled SMB/NFS services
    MERGERFS_MOUNT="$mergerfs_mount"
    FS_MOUNTS=("${fs_mounts[@]}")
    EXPORT_MOUNTS=()
    SHARE_SERVICES=()

    local export_list=()
    while read -r exp; do
        [[ -n "$exp" ]] && export_list+=("$exp")
    done < <(get_export_mounts)

    local service_list=()
    while read -r svc; do
        [[ -n "$svc" ]] && service_list+=("$svc")
    done < <(get_share_services)

    local config_content
    config_content="$(cat <<EOF
# Auto-generated by $(basename "$0") for MergerFS pool: ${pool_name}
LUKS_UUIDS=(
$(for u in "${luks_uuids[@]}"; do printf '    "%s"\n' "$u"; done)
)

FS_MOUNTS=(
$(for m in "${fs_mounts[@]}"; do printf '    "%s"\n' "$m"; done)
)

MERGERFS_MOUNT="${mergerfs_mount}"

EXPORT_MOUNTS=(
$(for e in "${export_list[@]:-}"; do [[ -n "$e" ]] && printf '    "%s"\n' "$e"; done)
)

SHARE_SERVICES=(
$(for s in "${service_list[@]:-}"; do [[ -n "$s" ]] && printf '    "%s"\n' "$s"; done)
)
EOF
)"

    if [[ $DRY_RUN -eq 1 ]]; then
        echo "[DRY-RUN] Would write configuration to $CONFIG_FILE (mode 0600):"
        echo "----------------------------------------"
        printf '%s\n' "$config_content"
        echo "----------------------------------------"
    else
        printf '%s\n' "$config_content" > "$CONFIG_FILE"
        chmod 600 "$CONFIG_FILE"
        echo "[OK] Saved configuration to $CONFIG_FILE:"
        echo "----------------------------------------"
        cat "$CONFIG_FILE"
        echo "----------------------------------------"
    fi
}

# ---------------------------------------------------------------------------
# 2. UNLOCK: Unlock LUKS, mount filesystems + MergerFS + exports, and start SMB/NFS
# ---------------------------------------------------------------------------
do_unlock() {
    load_config

    for uuid in "${LUKS_UUIDS[@]}"; do
        if [[ ! -e "/dev/disk/by-uuid/${uuid}" ]]; then
            echo "Error: LUKS disk /dev/disk/by-uuid/${uuid} not found!" >&2
            exit 1
        fi
    done

    local needs_unlock=0
    for uuid in "${LUKS_UUIDS[@]}"; do
        if [[ -z "$(get_active_mapper "$uuid")" ]]; then
            needs_unlock=1
            break
        fi
    done

    if [[ $needs_unlock -eq 1 ]]; then
        if [[ $DRY_RUN -eq 1 ]]; then
            echo "[DRY-RUN] Would prompt for LUKS passphrase."
            for uuid in "${LUKS_UUIDS[@]}"; do
                local active_mapper
                active_mapper="$(get_active_mapper "$uuid")"
                if [[ -n "$active_mapper" ]]; then
                    echo "[OK] $uuid is already unlocked (/dev/mapper/${active_mapper})."
                else
                    local dev="/dev/disk/by-uuid/${uuid}"
                    local kname mapper
                    kname="$(lsblk -ndo KNAME "$dev")"
                    mapper="${kname}-crypt"
                    echo "[DRY-RUN] Would unlock $dev as /dev/mapper/${mapper}."
                fi
            done
        else
            local unlocked_all=0
            for attempt in 1 2 3; do
                local luks_pass
                read -rsp "Enter LUKS passphrase: " luks_pass
                echo

                local failed=0
                for uuid in "${LUKS_UUIDS[@]}"; do
                    local active_mapper
                    active_mapper="$(get_active_mapper "$uuid")"
                    if [[ -n "$active_mapper" ]]; then
                        echo "[OK] $uuid is already unlocked (/dev/mapper/${active_mapper})."
                        continue
                    fi

                    local dev="/dev/disk/by-uuid/${uuid}"
                    local kname mapper
                    kname="$(lsblk -ndo KNAME "$dev")"
                    mapper="${kname}-crypt"

                    echo "Unlocking $dev as /dev/mapper/${mapper}..."
                    if printf '%s' "$luks_pass" | cryptsetup open "$dev" "$mapper" -; then
                        echo "[OK] Unlocked /dev/mapper/${mapper}."
                    else
                        echo "Error: Failed to unlock $uuid (wrong passphrase?)." >&2
                        failed=1
                        break
                    fi
                done

                unset luks_pass
                if [[ $failed -eq 0 ]]; then
                    unlocked_all=1
                    break
                fi
                echo "Try again ($attempt/3)..."
            done

            if [[ $unlocked_all -ne 1 ]]; then
                echo "Error: Could not unlock drives after 3 attempts." >&2
                exit 1
            fi
        fi
    else
        echo "[OK] All LUKS drives are already unlocked."
    fi

    if [[ $DRY_RUN -eq 0 ]]; then
        udevadm settle
    fi

    local newly_mounted_fs=0
    for mnt in "${FS_MOUNTS[@]}"; do
        if mountpoint -q "$mnt"; then
            echo "[OK] $mnt is already mounted."
        elif [[ $DRY_RUN -eq 1 ]]; then
            echo "[DRY-RUN] Would mount $mnt."
            newly_mounted_fs=1
        else
            echo "Mounting $mnt..."
            mount "$mnt"
            newly_mounted_fs=1
            echo "[OK] Mounted $mnt."
        fi
    done

    local mergerfs_unit
    mergerfs_unit="$(systemd-escape -p --suffix=mount "$MERGERFS_MOUNT")"
    if mountpoint -q "$MERGERFS_MOUNT" && [[ $newly_mounted_fs -eq 0 ]]; then
        echo "[OK] MergerFS pool ($MERGERFS_MOUNT) is already mounted."
    elif [[ $DRY_RUN -eq 1 ]]; then
        echo "[DRY-RUN] Would mount MergerFS pool ($MERGERFS_MOUNT) via $mergerfs_unit."
    else
        echo "Mounting MergerFS pool ($MERGERFS_MOUNT)..."
        systemctl restart "$mergerfs_unit" 2>/dev/null || mount "$MERGERFS_MOUNT"
        echo "[OK] Mounted $MERGERFS_MOUNT."
    fi

    # Mount any /export/* NFS bind mounts backed by the pool
    while read -r exp_mnt; do
        [[ -z "$exp_mnt" ]] && continue
        if mountpoint -q "$exp_mnt"; then
            echo "[OK] Export bind mount $exp_mnt is already mounted."
        elif [[ $DRY_RUN -eq 1 ]]; then
            echo "[DRY-RUN] Would mount export bind mount $exp_mnt."
        else
            echo "Mounting export bind mount $exp_mnt..."
            mount "$exp_mnt"
            echo "[OK] Mounted $exp_mnt."
        fi
    done < <(get_export_mounts)

    # Start or reload SMB/NFS services so shared folders are immediately available
    while read -r svc; do
        [[ -z "$svc" ]] && continue
        if systemctl is-active --quiet "$svc"; then
            if [[ $DRY_RUN -eq 1 ]]; then
                echo "[DRY-RUN] Would reload $svc."
            else
                echo "Reloading $svc..."
                systemctl reload-or-restart "$svc"
                echo "[OK] Reloaded $svc."
            fi
        else
            if [[ $DRY_RUN -eq 1 ]]; then
                echo "[DRY-RUN] Would start $svc."
            else
                echo "Starting $svc..."
                systemctl start "$svc"
                echo "[OK] Started $svc."
            fi
        fi
    done < <(get_share_services)

    if [[ $DRY_RUN -eq 1 ]]; then
        echo "[DRY-RUN] Done! No changes were made."
    else
        echo "Done! Pool is unlocked, mounted, and shared folders are active."
    fi
}

# ---------------------------------------------------------------------------
# 3. LOCK: Stop SMB/NFS, unmount exports + MergerFS + filesystems, then close LUKS
# ---------------------------------------------------------------------------
do_lock() {
    load_config

    # Stop SMB/NFS share services first so open handles don't block unmounting
    local services=()
    while read -r svc; do
        [[ -n "$svc" ]] && services+=("$svc")
    done < <(get_share_services)

    for (( idx=${#services[@]}-1 ; idx>=0 ; idx-- )); do
        local svc="${services[$idx]}"
        if systemctl is-active --quiet "$svc"; then
            if [[ $DRY_RUN -eq 1 ]]; then
                echo "[DRY-RUN] Would stop $svc."
            else
                echo "Stopping $svc..."
                systemctl stop "$svc"
                echo "[OK] Stopped $svc."
            fi
        else
            echo "[OK] $svc is already stopped."
        fi
    done

    # Unmount any /export/* NFS bind mounts backed by the pool
    while read -r exp_mnt; do
        [[ -z "$exp_mnt" ]] && continue
        if mountpoint -q "$exp_mnt"; then
            if [[ $DRY_RUN -eq 1 ]]; then
                echo "[DRY-RUN] Would unmount export bind mount $exp_mnt."
            else
                echo "Unmounting export bind mount $exp_mnt..."
                if ! umount "$exp_mnt"; then
                    echo "Error: $exp_mnt is busy! Active processes:" >&2
                    fuser -vm "$exp_mnt" || true
                    exit 1
                fi
                echo "[OK] Unmounted $exp_mnt."
            fi
        else
            echo "[OK] Export bind mount $exp_mnt is already unmounted."
        fi
    done < <(get_export_mounts)

    local mergerfs_unit
    mergerfs_unit="$(systemd-escape -p --suffix=mount "$MERGERFS_MOUNT")"
    if mountpoint -q "$MERGERFS_MOUNT"; then
        if [[ $DRY_RUN -eq 1 ]]; then
            echo "[DRY-RUN] Would unmount MergerFS pool ($MERGERFS_MOUNT) via $mergerfs_unit."
        else
            echo "Unmounting MergerFS pool ($MERGERFS_MOUNT)..."
            if ! systemctl stop "$mergerfs_unit" 2>/dev/null && ! umount "$MERGERFS_MOUNT"; then
                echo "Error: $MERGERFS_MOUNT is busy! Active processes:" >&2
                fuser -vm "$MERGERFS_MOUNT" || true
                exit 1
            fi
            echo "[OK] Unmounted $MERGERFS_MOUNT."
        fi
    else
        echo "[OK] $MERGERFS_MOUNT is already unmounted."
    fi

    for mnt in "${FS_MOUNTS[@]}"; do
        if mountpoint -q "$mnt"; then
            if [[ $DRY_RUN -eq 1 ]]; then
                echo "[DRY-RUN] Would unmount $mnt."
            else
                echo "Unmounting $mnt..."
                if ! umount "$mnt"; then
                    echo "Error: $mnt is busy! Active processes:" >&2
                    fuser -vm "$mnt" || true
                    exit 1
                fi
                echo "[OK] Unmounted $mnt."
            fi
        else
            echo "[OK] $mnt is already unmounted."
        fi
    done

    if [[ $DRY_RUN -eq 1 ]]; then
        echo "[DRY-RUN] Would flush filesystem buffers (sync)."
    else
        sync
    fi

    for uuid in "${LUKS_UUIDS[@]}"; do
        local dev="/dev/disk/by-uuid/${uuid}"
        [[ ! -e "$dev" ]] && continue

        local mapper
        mapper="$(get_active_mapper "$uuid")"
        if [[ -n "$mapper" ]]; then
            if [[ $DRY_RUN -eq 1 ]]; then
                echo "[DRY-RUN] Would lock /dev/mapper/${mapper}."
            else
                echo "Locking /dev/mapper/${mapper}..."
                cryptsetup close "$mapper"
                echo "[OK] Locked ${mapper}."
            fi
        else
            echo "[OK] $uuid is already locked."
        fi
    done

    if [[ $DRY_RUN -eq 1 ]]; then
        echo "[DRY-RUN] Done! No changes were made."
    else
        echo "Done! Shared folders stopped, filesystems unmounted, and LUKS drives locked."
    fi
}

# ---------------------------------------------------------------------------
# 4. STATUS: Show current state of LUKS, filesystems, MergerFS, exports, and SMB/NFS
# ---------------------------------------------------------------------------
do_status() {
    load_config
    echo "=== LUKS Drives ==="
    for uuid in "${LUKS_UUIDS[@]}"; do
        local mapper
        mapper="$(get_active_mapper "$uuid")"
        if [[ -n "$mapper" ]]; then
            echo "  [UNLOCKED] $uuid (/dev/mapper/${mapper})"
        else
            echo "  [LOCKED]   $uuid"
        fi
    done

    echo "=== Filesystem Mounts ==="
    for mnt in "${FS_MOUNTS[@]}"; do
        if mountpoint -q "$mnt"; then
            echo "  [MOUNTED]   $mnt"
        else
            echo "  [UNMOUNTED] $mnt"
        fi
    done

    echo "=== MergerFS Pool ==="
    if mountpoint -q "$MERGERFS_MOUNT"; then
        echo "  [MOUNTED]   $MERGERFS_MOUNT"
    else
        echo "  [UNMOUNTED] $MERGERFS_MOUNT"
    fi

    local exports=()
    while read -r exp; do
        [[ -n "$exp" ]] && exports+=("$exp")
    done < <(get_export_mounts)

    if [[ ${#exports[@]} -gt 0 ]]; then
        echo "=== NFS Export Bind Mounts ==="
        for exp in "${exports[@]}"; do
            if mountpoint -q "$exp"; then
                echo "  [MOUNTED]   $exp"
            else
                echo "  [UNMOUNTED] $exp"
            fi
        done
    fi

    local services=()
    while read -r svc; do
        [[ -n "$svc" ]] && services+=("$svc")
    done < <(get_share_services)

    if [[ ${#services[@]} -gt 0 ]]; then
        echo "=== Share Services (SMB/NFS) ==="
        for svc in "${services[@]}"; do
            if systemctl is-active --quiet "$svc"; then
                echo "  [ACTIVE]    $svc"
            else
                echo "  [STOPPED]   $svc"
            fi
        done
    fi
}

# ---------------------------------------------------------------------------
# Main CLI Dispatcher
# ---------------------------------------------------------------------------
ACTION="${1:-}"
case "$ACTION" in
    config|--config)
        shift
        do_config "${1:-}"
        ;;
    unlock|--unlock)
        do_unlock
        ;;
    lock|--lock)
        do_lock
        ;;
    status|--status)
        do_status
        ;;
    *)
        usage
        ;;
esac
