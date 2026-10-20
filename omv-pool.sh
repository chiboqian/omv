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
    [[ -e "$dev" ]] || return 0
    lsblk -nlo NAME,TYPE "$dev" 2>/dev/null | awk '$2=="crypt"{print $1; exit}' || true
}

load_config() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        echo "Error: Config file $CONFIG_FILE not found." >&2
        echo "Run 'sudo $(basename "$0") config <mergerfs-pool-name>' first." >&2
        exit 1
    fi
    LUKS_UUIDS=()
    FS_MOUNTS=()
    EXT4_MOUNTS=()
    MERGERFS_MOUNT=""
    EXPORT_MOUNTS=()
    SHARE_SERVICES=()

    # shellcheck source=/dev/null
    source "$CONFIG_FILE"

    # Backwards compatibility with configs that used EXT4_MOUNTS
    if [[ ${#FS_MOUNTS[@]} -eq 0 && ${#EXT4_MOUNTS[@]} -gt 0 ]]; then
        FS_MOUNTS=("${EXT4_MOUNTS[@]}")
    fi

    MERGERFS_MOUNT="${MERGERFS_MOUNT%/}"
    for i in "${!FS_MOUNTS[@]}"; do
        FS_MOUNTS[$i]="${FS_MOUNTS[$i]%/}"
    done

    if [[ ${#LUKS_UUIDS[@]} -eq 0 || ${#FS_MOUNTS[@]} -eq 0 || -z "$MERGERFS_MOUNT" ]]; then
        echo "Error: $CONFIG_FILE is incomplete (missing LUKS_UUIDS, FS_MOUNTS, or MERGERFS_MOUNT)." >&2
        exit 1
    fi
}

read_passphrase() {
    luks_pass=""
    if [[ -t 0 ]]; then
        IFS= read -rsp "Enter LUKS passphrase: " luks_pass || [[ -n "$luks_pass" ]]
        echo
    else
        IFS= read -r luks_pass || [[ -n "$luks_pass" ]]
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

    local pool_name="$input_name"
    pool_name="${pool_name#/etc/systemd/system/}"
    if [[ "$pool_name" == srv-mergerfs-* ]]; then
        pool_name="${pool_name%.mount}"
        pool_name="$(systemd-escape -u -p "$pool_name" 2>/dev/null || printf '%s' "$pool_name")"
    fi
    pool_name="${pool_name#/srv/mergerfs/}"
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
        [[ -n "$where_path" ]] && mergerfs_mount="${where_path%/}"
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

    # Normalize newline-separated paths from config.xml into colon-separated branches
    raw_branches="${raw_branches//$'\n'/:}"
    IFS=':' read -r -a raw_branch_list <<< "$raw_branches"

    # Expand any wildcard branch patterns (e.g. /srv/dev-disk-by-uuid-*) against /etc/fstab
    local branch_list=()
    for branch in "${raw_branch_list[@]}"; do
        branch="${branch%%=*}"
        [[ -z "$branch" ]] && continue

        local mnt_pattern
        if [[ "$branch" =~ ^(/srv/dev-disk-by-uuid-[^/]+) ]]; then
            mnt_pattern="${BASH_REMATCH[1]}"
        else
            mnt_pattern="${branch%/}"
        fi

        if [[ "$mnt_pattern" == *"*"* || "$mnt_pattern" == *"?"* ]]; then
            while read -r fstab_mnt; do
                [[ -z "$fstab_mnt" ]] && continue
                # shellcheck disable=SC2254
                case "$fstab_mnt" in
                    $mnt_pattern) branch_list+=("$fstab_mnt") ;;
                esac
            done < <(awk '$1 !~ /^#/ && NF >= 2 {print $2}' /etc/fstab 2>/dev/null)
        else
            branch_list+=("$mnt_pattern")
        fi
    done

    local fs_mounts=()
    local fs_devs=()

    for mnt in "${branch_list[@]}"; do
        [[ -z "$mnt" ]] && continue

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

        # Strip optional quotes around UUID=... or LABEL=... in /etc/fstab
        fs_spec="${fs_spec//\"/}"
        fs_spec="${fs_spec//\'/}"
        if [[ "$fs_spec" =~ ^UUID=(.+)$ ]]; then
            fs_spec="/dev/disk/by-uuid/${BASH_REMATCH[1]}"
        elif [[ "$fs_spec" =~ ^LABEL=(.+)$ ]]; then
            fs_spec="/dev/disk/by-label/${BASH_REMATCH[1]}"
        fi

        fs_mounts+=("$mnt")
        fs_devs+=("$fs_spec")
    done

    if [[ ${#fs_mounts[@]} -eq 0 ]]; then
        echo "Error: No valid branch mounts found for MergerFS pool '${pool_name}'." >&2
        exit 1
    fi

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
                active_crypt="$(lsblk -nlo NAME,TYPE "$luks_dev" 2>/dev/null | awk '$2=="crypt"{print $1; exit}' || true)"
                if [[ -z "$active_crypt" ]]; then
                    local kname mapper
                    kname="$(lsblk -ndo KNAME "$luks_dev")"
                    mapper="${kname}-crypt"
                    echo "[DRY-RUN] Would unlock $luks_dev as /dev/mapper/${mapper}"
                fi
            done < <(blkid -t TYPE=crypto_LUKS -o device 2>/dev/null || true)
        else
            echo "[INFO] LUKS drives are currently locked; unlocking to inspect inner filesystem UUIDs..."
            local max_attempts=3
            [[ ! -t 0 ]] && max_attempts=1
            for (( attempt=1; attempt<=max_attempts; attempt++ )); do
                local luks_pass
                read_passphrase

                while read -r luks_dev; do
                    [[ -z "$luks_dev" ]] && continue
                    local active_crypt
                    active_crypt="$(lsblk -nlo NAME,TYPE "$luks_dev" 2>/dev/null | awk '$2=="crypt"{print $1; exit}' || true)"
                    if [[ -z "$active_crypt" ]]; then
                        local kname mapper
                        kname="$(lsblk -ndo KNAME "$luks_dev")"
                        mapper="${kname}-crypt"
                        echo "Unlocking $luks_dev as /dev/mapper/${mapper}..."
                        printf '%s' "$luks_pass" | cryptsetup open "$luks_dev" "$mapper" - || true
                    fi
                done < <(blkid -t TYPE=crypto_LUKS -o device 2>/dev/null || true)

                unset luks_pass
                udevadm settle

                missing_dev=0
                for dev in "${fs_devs[@]}"; do
                    [[ ! -e "$dev" ]] && missing_dev=1 && break
                done
                [[ $missing_dev -eq 0 ]] && break
                [[ $attempt -lt $max_attempts ]] && echo "Try again ($attempt/$max_attempts)..."
            done
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

        local resolved_fs_dev cur_dev parent_dev="" pkname
        resolved_fs_dev="$(readlink -f "$fs_dev")"
        cur_dev="$resolved_fs_dev"
        for _ in 1 2 3 4; do
            pkname="$(lsblk -ndo PKNAME "$cur_dev" 2>/dev/null | awk 'NR==1{print; exit}' || true)"
            [[ -z "$pkname" ]] && break
            cur_dev="/dev/${pkname}"
            if cryptsetup isLuks "$cur_dev" 2>/dev/null; then
                parent_dev="$cur_dev"
                break
            fi
        done

        if [[ -z "$parent_dev" ]]; then
            echo "Error: Could not find a parent LUKS partition for $fs_dev ($resolved_fs_dev)." >&2
            exit 1
        fi

        local luks_uuid
        luks_uuid="$(cryptsetup luksUUID "$parent_dev")"
        echo "[INFO] Mapped $fs_mnt -> $parent_dev (LUKS UUID: $luks_uuid)"

        local uuid_exists=0
        for existing_uuid in "${luks_uuids[@]:-}"; do
            [[ "$existing_uuid" == "$luks_uuid" ]] && uuid_exists=1 && break
        done
        [[ $uuid_exists -eq 0 ]] && luks_uuids+=("$luks_uuid")
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
        (umask 077 && printf '%s\n' "$config_content" > "$CONFIG_FILE")
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
            local max_attempts=3
            [[ ! -t 0 ]] && max_attempts=1
            for (( attempt=1; attempt<=max_attempts; attempt++ )); do
                local luks_pass
                read_passphrase

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
                [[ $attempt -lt $max_attempts ]] && echo "Try again ($attempt/$max_attempts)..."
            done

            if [[ $unlocked_all -ne 1 ]]; then
                echo "Error: Could not unlock drives after $max_attempts attempt(s)." >&2
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
        systemctl reset-failed "$mergerfs_unit" 2>/dev/null || true
        if [[ -f "/etc/systemd/system/${mergerfs_unit}" ]] || systemctl list-unit-files "$mergerfs_unit" &>/dev/null; then
            systemctl restart "$mergerfs_unit"
        else
            mount "$MERGERFS_MOUNT"
        fi
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

    # Unmount any /export/* NFS bind mounts backed by the pool (in reverse order)
    local exports=()
    while read -r exp_mnt; do
        [[ -n "$exp_mnt" ]] && exports+=("$exp_mnt")
    done < <(get_export_mounts)

    for (( idx=${#exports[@]}-1 ; idx>=0 ; idx-- )); do
        local exp_mnt="${exports[$idx]}"
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
    done

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

    for (( idx=${#FS_MOUNTS[@]}-1 ; idx>=0 ; idx-- )); do
        local mnt="${FS_MOUNTS[$idx]}"
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

    for (( idx=${#LUKS_UUIDS[@]}-1 ; idx>=0 ; idx-- )); do
        local uuid="${LUKS_UUIDS[$idx]}"
        local dev="/dev/disk/by-uuid/${uuid}"
        [[ ! -e "$dev" ]] && continue

        local mapper
        mapper="$(get_active_mapper "$uuid")"
        if [[ -n "$mapper" ]]; then
            if [[ $DRY_RUN -eq 1 ]]; then
                echo "[DRY-RUN] Would lock /dev/mapper/${mapper}."
            else
                echo "Locking /dev/mapper/${mapper}..."
                if ! cryptsetup close "$mapper"; then
                    echo "Error: /dev/mapper/${mapper} is busy! Active processes:" >&2
                    fuser -vm "/dev/mapper/${mapper}" || true
                    exit 1
                fi
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
        if [[ ! -e "/dev/disk/by-uuid/${uuid}" ]]; then
            echo "  [MISSING]  $uuid"
            continue
        fi
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
