#!/usr/bin/env bash
set -euo pipefail

CONFIG_FILE="/etc/omv-pool.conf"

usage() {
    cat >&2 <<EOF
Usage:
  sudo $(basename "$0") config <mergerfs-pool-name>   Generate and save $CONFIG_FILE
  sudo $(basename "$0") unlock                        Unlock LUKS drives and mount ext4 + MergerFS
  sudo $(basename "$0") lock                          Unmount MergerFS + ext4 and lock LUKS drives
  sudo $(basename "$0") status                        Show current lock and mount status
EOF
    exit 1
}

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
}

# ---------------------------------------------------------------------------
# 1. CONFIG: Discover LUKS UUIDs + ext4 mounts from MergerFS name & save conf
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

    local ext4_mounts=()
    local ext4_devs=()

    for branch in "${branch_list[@]}"; do
        [[ -z "$branch" ]] && continue

        local mnt
        if [[ "$branch" =~ ^(/srv/dev-disk-by-uuid-[^/]+) ]]; then
            mnt="${BASH_REMATCH[1]}"
        else
            mnt="${branch%/}"
        fi

        local already_added=0
        for existing in "${ext4_mounts[@]:-}"; do
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

        ext4_mounts+=("$mnt")
        ext4_devs+=("$fs_spec")
    done

    # Temporarily unlock LUKS drives if inner ext4 UUIDs aren't visible yet
    local missing_dev=0
    for dev in "${ext4_devs[@]}"; do
        [[ ! -e "$dev" ]] && missing_dev=1 && break
    done

    if [[ $missing_dev -eq 1 ]]; then
        echo "[INFO] LUKS drives are currently locked; unlocking to inspect inner ext4 UUIDs..."
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

    local luks_uuids=()
    for i in "${!ext4_devs[@]}"; do
        local ext4_dev="${ext4_devs[$i]}"
        local ext4_mnt="${ext4_mounts[$i]}"

        if [[ ! -e "$ext4_dev" ]]; then
            echo "Error: Inner filesystem $ext4_dev ($ext4_mnt) not found even after unlocking." >&2
            exit 1
        fi

        local pkname
        pkname="$(lsblk -ndo PKNAME "$ext4_dev")"
        if [[ -z "$pkname" ]]; then
            echo "Error: Could not find parent device for $ext4_dev." >&2
            exit 1
        fi

        local parent_dev="/dev/${pkname}"
        if ! cryptsetup isLuks "$parent_dev"; then
            echo "Error: Parent device $parent_dev ($ext4_mnt) is not a LUKS partition." >&2
            exit 1
        fi

        local luks_uuid
        luks_uuid="$(cryptsetup luksUUID "$parent_dev")"
        echo "[INFO] Mapped $ext4_mnt -> $parent_dev (LUKS UUID: $luks_uuid)"
        luks_uuids+=("$luks_uuid")
    done

    cat > "$CONFIG_FILE" <<EOF
# Auto-generated by $(basename "$0") for MergerFS pool: ${pool_name}
LUKS_UUIDS=(
$(for u in "${luks_uuids[@]}"; do printf '    "%s"\n' "$u"; done)
)

EXT4_MOUNTS=(
$(for m in "${ext4_mounts[@]}"; do printf '    "%s"\n' "$m"; done)
)

MERGERFS_MOUNT="${mergerfs_mount}"
EOF

    chmod 600 "$CONFIG_FILE"
    echo "[OK] Saved configuration to $CONFIG_FILE:"
    echo "----------------------------------------"
    cat "$CONFIG_FILE"
    echo "----------------------------------------"
}

# ---------------------------------------------------------------------------
# 2. UNLOCK: Prompt once for password, unlock LUKS, mount ext4 & MergerFS
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
    else
        echo "[OK] All LUKS drives are already unlocked."
    fi

    udevadm settle

    local newly_mounted_ext4=0
    for mnt in "${EXT4_MOUNTS[@]}"; do
        if mountpoint -q "$mnt"; then
            echo "[OK] $mnt is already mounted."
        else
            echo "Mounting $mnt..."
            mount "$mnt"
            newly_mounted_ext4=1
            echo "[OK] Mounted $mnt."
        fi
    done

    local mergerfs_unit
    mergerfs_unit="$(systemd-escape -p --suffix=mount "$MERGERFS_MOUNT")"
    if mountpoint -q "$MERGERFS_MOUNT" && [[ $newly_mounted_ext4 -eq 0 ]]; then
        echo "[OK] MergerFS pool ($MERGERFS_MOUNT) is already mounted."
    else
        echo "Mounting MergerFS pool ($MERGERFS_MOUNT)..."
        systemctl restart "$mergerfs_unit" 2>/dev/null || mount "$MERGERFS_MOUNT"
        echo "[OK] Mounted $MERGERFS_MOUNT."
    fi

    echo "Done! Pool is unlocked and mounted."
}

# ---------------------------------------------------------------------------
# 3. LOCK: Unmount MergerFS & ext4, then close LUKS devices
# ---------------------------------------------------------------------------
do_lock() {
    load_config

    local mergerfs_unit
    mergerfs_unit="$(systemd-escape -p --suffix=mount "$MERGERFS_MOUNT")"
    if mountpoint -q "$MERGERFS_MOUNT"; then
        echo "Unmounting MergerFS pool ($MERGERFS_MOUNT)..."
        if ! systemctl stop "$mergerfs_unit" 2>/dev/null && ! umount "$MERGERFS_MOUNT"; then
            echo "Error: $MERGERFS_MOUNT is busy! Active processes:" >&2
            fuser -vm "$MERGERFS_MOUNT" || true
            exit 1
        fi
        echo "[OK] Unmounted $MERGERFS_MOUNT."
    else
        echo "[OK] $MERGERFS_MOUNT is already unmounted."
    fi

    for mnt in "${EXT4_MOUNTS[@]}"; do
        if mountpoint -q "$mnt"; then
            echo "Unmounting $mnt..."
            if ! umount "$mnt"; then
                echo "Error: $mnt is busy! Active processes:" >&2
                fuser -vm "$mnt" || true
                exit 1
            fi
            echo "[OK] Unmounted $mnt."
        else
            echo "[OK] $mnt is already unmounted."
        fi
    done

    sync

    for uuid in "${LUKS_UUIDS[@]}"; do
        local dev="/dev/disk/by-uuid/${uuid}"
        [[ ! -e "$dev" ]] && continue

        local mapper
        mapper="$(get_active_mapper "$uuid")"
        if [[ -n "$mapper" ]]; then
            echo "Locking /dev/mapper/${mapper}..."
            cryptsetup close "$mapper"
            echo "[OK] Locked ${mapper}."
        else
            echo "[OK] $uuid is already locked."
        fi
    done

    echo "Done! All filesystems unmounted and LUKS drives locked."
}

# ---------------------------------------------------------------------------
# 4. STATUS: Show current state of LUKS drives, ext4 mounts, and MergerFS
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

    echo "=== Ext4 Mounts ==="
    for mnt in "${EXT4_MOUNTS[@]}"; do
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
