#!/bin/sh
# FreeBSD 15.1 bsdinstall Shell helper. See README.md before use.
set -eu
umask 077
PATH=/sbin:/bin:/usr/sbin:/usr/bin
export PATH
LC_ALL=C
export LC_ALL

fail() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }
usage() {
    cat <<'HELP'
Usage:
  sh freebsd-zfs-geli-install.sh [--dry-run] [--backup-dir DIRECTORY | --no-backup] [DISK]

Run once from bsdinstall's partitioning Shell, booted in UEFI mode.
After success, type exit and complete bsdinstall normally.
--dry-run checks prerequisites and prints a plan; it makes no disk changes.
Omit DISK to choose from the detected devices. No disk is selected by default.
Without backup options, you are asked whether and where to retain recovery files.
--backup-dir DIRECTORY selects an existing directory; --no-backup skips that question.
Without a destination, the external recovery copy is temporary and lost on reboot.
HELP
}
require_device() { [ -c "/dev/$1" ] || fail "Missing device /dev/$1."; }
need() { command -v "$1" >/dev/null 2>&1 || fail "Required tool not found: $1"; }
read_answer() { IFS= read -r ANSWER || fail 'Input cancelled.'; }
choose_disk() {
    DISKS=$(sysctl -n kern.disks) || fail 'Cannot discover disks.'
    [ -n "$DISKS" ] || fail 'No disks were detected.'
    printf '\nAvailable devices (check model, serial, capacity and partition layout):\n'
    DISK_COUNT=0
    for device in $DISKS; do
        case "$device" in *[!a-zA-Z0-9]*|'') fail 'Unsupported disk name reported by the system.' ;; esac
        DISK_COUNT=$((DISK_COUNT + 1))
        printf '\n[%s] /dev/%s\n' "$DISK_COUNT" "$device"
        diskinfo -v "/dev/$device" || printf 'Device details unavailable; this device may be unsuitable.\n'
    done
    printf '\nThe list may include the installer media. Select the installation disk carefully.\n'
    while :; do
        printf 'Disk number [q = cancel]: '
        read_answer
        case "$ANSWER" in
            q|Q) fail 'Cancelled. No disk changes were made.' ;;
            ''|*[!0-9]*|0*) printf 'Enter a listed number, or q.\n'; continue ;;
        esac
        [ "${#ANSWER}" -le 6 ] && [ "$ANSWER" -le "$DISK_COUNT" ] || { printf 'Enter a listed number, or q.\n'; continue; }
        DISK=$(printf '%s\n' "$DISKS" | awk -v n="$ANSWER" '{for(i=1;i<=NF;i++) {k++; if(k==n) print $i}}')
        [ -n "$DISK" ] || fail 'Cannot resolve selected disk.'
        return
    done
}
choose_backup() {
    [ "${BACKUP_MODE:-ask}" = ask ] || return 0
    printf '\nKeep a recovery backup outside the installer?\nThis saves GPT, EFI and GELI recovery data, not your operating systems or personal files.\n'
    while :; do
        printf 'Save a recovery backup? [y/N]: '
        read_answer
        case "$ANSWER" in
            y|Y|yes|YES|Yes|s|S|sim|SIM|Sim)
                printf 'Existing destination directory (for example /media/recovery; blank = cancel): '
                read_answer
                [ -n "$ANSWER" ] || fail 'Backup selection cancelled. No disk changes were made.'
                BACKUP_DIR=$ANSWER
                return ;;
            n|N|no|NO|No|nao|'') BACKUP_DIR=''; return ;;
            *) printf 'Enter y or n.\n' ;;
        esac
    done
}
# Restrict decimal input BEFORE shell arithmetic. Values stay below 2^53,
# allowing exact integer comparisons in awk as well as safe signed shell math.
uint() {
    case "$1" in ''|*[!0-9]*) return 1 ;; esac
    [ "${#1}" -le 16 ] && awk -v n="$1" 'BEGIN {exit !(n <= 4503599627370495)}'
}
size_bytes() {
    value=$1
    case "$value" in *[Mm]) factor=1048576 ;; *[Gg]) factor=1073741824 ;; *[Tt]) factor=1099511627776 ;; *) fail 'Use sizes such as 512M, 4G or 1T.' ;; esac
    number=${value%?}
    case "$number" in ''|0*|*[!0-9]*) fail 'Size must start with a nonzero decimal digit.' ;; esac
    [ "${#number}" -le 10 ] || fail 'Size is too large.'
    [ "$number" -le "$((4503599627370495 / factor))" ] || fail 'Size is too large.'
    printf '%s\n' "$((number * factor))"
}
align_up() { printf '%s\n' "$(( ($1 + ALIGN - 1) / ALIGN * ALIGN ))"; }
plan_sectors() {
    START=$(align_up "$FREE_START")
    END=$(( (FREE_START + FREE_SECTORS) / ALIGN * ALIGN ))
    SWAP_SECTORS=$((SWAP_BYTES / SECTOR_SIZE))
    ZFS_START=$((START + SWAP_SECTORS))
    if [ "$ZFS_BYTES" -eq 0 ]; then
        ZFS_SECTORS=$((END - ZFS_START))
    else
        ZFS_SECTORS=$((ZFS_BYTES / SECTOR_SIZE))
    fi
    [ "$ZFS_SECTORS" -ge "$((4294967296 / SECTOR_SIZE))" ] || fail 'At least 4 GiB is required for ZFS (20 GiB or more is recommended).'
    [ "$ZFS_START" -ge "$START" ] && [ "$((ZFS_START + ZFS_SECTORS))" -le "$END" ] || fail 'Requested sizes exceed the selected free region.'
}
mount_table() { MOUNTS=$(mount -p) || fail 'Cannot read mount table.'; }
path_safe() {
    case "$1" in /*) ;; *) fail "Expected an absolute path: $1" ;; esac
    case "$1" in *[!a-zA-Z0-9_./-]*|*/../*|*/..|*/./*|*/.) fail "Unsupported path: $1 (use a simple absolute path without whitespace or dot components)." ;; esac
    [ "$1" != / ] || fail 'Refusing to use / as a working directory.'
}
path_unmounted() {
    printf '%s\n' "$MOUNTS" | awk -v p="$1" '$2==p || index($2,p"/")==1 {found=1} END {exit !found}' && fail "A filesystem is mounted at or below $1."
    return 0
}
# Query partition UUIDs from GEOM metadata, independently of GPT labels.
part_uuid() {
    geom part list "$DISK" | awk -v p="$1" '
        $1 ~ /^[0-9]+\.$/ && $2=="Name:" {matchpart=($3==p)}
        matchpart && $1=="rawuuid:" {print $2; n++}
        END {if(n!=1) exit 1}'
}
valid_uuid() {
    printf '%s\n' "$1" | grep -Eq '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
}
boot_order() {
    awk '$1=="BootOrder" && $2==":" {print $3; n++} END {if(n!=1) exit 1}'
}
valid_order() {
    printf '%s\n' "$1" | grep -Eq '^[0-9A-Fa-f]{4}(,[0-9A-Fa-f]{4})*$'
}
save_field() { printf '%s\n' "$2" > "$SESSION/$1"; }
cleanup() {
    status=$?
    trap - 0
    if [ "${ORDER_PENDING:-0}" -eq 1 ]; then
        efibootmgr -o "$OLD_ORDER" || printf "WARNING: Restore BootOrder manually: efibootmgr -o %s\n" "$OLD_ORDER" >&2
    fi
    if [ "${ESP_MOUNTED:-0}" -eq 1 ]; then
        umount "$ESP_MOUNT" || printf 'WARNING: Could not unmount %s\n' "$ESP_MOUNT" >&2
    fi
    if [ "$status" -ne 0 ] && [ -n "${SESSION:-}" ]; then
        printf '\nStopped. Recovery/session files: %s\n' "$SESSION" >&2
        printf 'No automatic partition deletion or pool destruction was attempted.\n' >&2
        printf 'Do not resume bsdinstall after a failed preparation. Inspect the recorded plan and actual disk first.\n' >&2
    fi
    exit "$status"
}
preflight() {
    [ "$(uname -s)" = FreeBSD ] || fail 'Run this from the FreeBSD installer.'
    [ "$(id -u)" -eq 0 ] || fail 'Run as root.'
    case "$(freebsd-version -u)" in 15.1-*) ;; *) fail 'This helper targets FreeBSD 15.1 installer media.' ;; esac
    [ "$(sysctl -n machdep.bootmethod)" = UEFI ] || fail 'Boot the installer in UEFI mode.'
    [ "$(uname -m)" = amd64 ] || fail 'Only amd64 UEFI installations are currently supported.'
    LOADER=/boot/loader.efi
    [ -f "$LOADER" ] && [ ! -L "$LOADER" ] || fail 'Installer loader.efi is missing or is a symlink.'
    for tool in awk grep geom gpart diskinfo geli zpool zfs mount umount efibootmgr mktemp realpath df cp cmp tar uuidgen du kldload ls; do need "$tool"; done
}
read_disk() {
    LAYOUT=$(gpart show -p "$DISK") || fail 'Cannot read GPT.'
    printf '%s\n' "$LAYOUT" | awk -v d="$DISK" '$1=="=>" && $4==d && $5=="GPT" {n++} END {exit n!=1}' || fail 'Expected a healthy GPT disk.'
    case "$LAYOUT" in *CORRUPT*|*RECOVER*) fail 'GPT requires recovery; refusing to modify it.' ;; esac
}
# Require successful GEOM output and verify exact start/size/type after creation.
verify_partition() {
    actual=$(gpart show -p "$DISK") || fail 'Cannot verify partition table.'
    printf '%s\n' "$actual" | awk -v p="$1" -v s="$2" -v n="$3" -v t="$4" '$3==p && $1==s && $2==n && $4==t {ok=1} END {exit !ok}' || fail 'Created partition does not match the confirmed plan.'
    require_device "$1"
}
prepare() {
    [ -n "${BSDINSTALL_CHROOT:-}" ] && [ -n "${BSDINSTALL_TMPETC:-}" ] && [ -n "${BSDINSTALL_TMPBOOT:-}" ] && [ -n "${PATH_FSTAB:-}" ] || fail 'Use the Shell option in bsdinstall partitioning (installer variables are required).'
    [ -f "${LOADER:-/boot/loader.efi}" ] || fail 'Installer loader.efi is missing.'
    TARGET=$BSDINSTALL_CHROOT
    ETC=$BSDINSTALL_TMPETC
    BOOT=$BSDINSTALL_TMPBOOT
    FSTAB=$PATH_FSTAB
    for p in "$TARGET" "$ETC" "$BOOT" "$FSTAB"; do path_safe "$p"; done
    for p in "$TARGET" "$ETC" "$BOOT"; do
        [ -d "$p" ] && [ ! -L "$p" ] || fail "Expected an existing, non-symlink directory: $p"
        [ "$(realpath "$p")" = "$p" ] || fail "Use canonical paths: $p"
    done
    [ "$ETC" != "$BOOT" ] || fail 'Installer staging directories must differ.'
    case "$FSTAB" in "$ETC"/fstab) ;; *) fail 'PATH_FSTAB must be BSDINSTALL_TMPETC/fstab.' ;; esac
    [ ! -L "$FSTAB" ] && [ ! -s "$FSTAB" ] || fail 'An fstab already exists; refusing to append to another installation plan.'
    [ ! -e "$ETC/rc.conf.dualboot" ] && [ ! -L "$ETC/rc.conf.dualboot" ] && [ ! -e "$BOOT/loader.conf.dualboot" ] && [ ! -L "$BOOT/loader.conf.dualboot" ] || fail 'Previous dualboot configuration found.'
    require_device "$DISK"
    read_disk
    if printf '%s\n' "$LAYOUT" | awk '$4 ~ /^freebsd-/ {found=1} END {exit !found}'; then
        fail 'Existing FreeBSD partitions found. This is a fresh-install helper, not a resume or upgrade tool.'
    fi
    ESP_COUNT=$(printf '%s\n' "$LAYOUT" | awk '$4=="efi" {n++} END {print n+0}')
    [ "$ESP_COUNT" -eq 1 ] || fail 'Exactly one existing EFI partition on the selected disk is required.'
    ESP_PART=$(printf '%s\n' "$LAYOUT" | awk '$4=="efi" {print $3}')
    require_device "$ESP_PART"
    ESP_UUID=$(part_uuid "$ESP_PART") || fail 'Cannot determine ESP GPT UUID.'
    valid_uuid "$ESP_UUID" || fail 'Invalid ESP UUID.'
    mount_table
    path_unmounted "$TARGET"
    CONTENTS=$(ls -A "$TARGET") || fail 'Cannot inspect target directory.'
    [ -z "$CONTENTS" ] || fail 'Installation target directory must be empty.'
    printf '%s\n' "$MOUNTS" | awk -v p="/dev/$ESP_PART" -v u="/dev/gptid/$ESP_UUID" '$1==p || $1==u {found=1} END {exit !found}' && fail 'The selected ESP is already mounted.'
    # Load before querying: an unloaded module must not masquerade as an empty pool list.
    kldload -n zfs || fail 'Cannot load ZFS.'
    kldload -n geom_eli || fail 'Cannot load GELI.'
    POOLS=$(zpool list -H -o name) || fail 'Cannot query imported pools.'
    printf '%s\n' "$POOLS" | grep -qx zroot && fail 'A pool named zroot is already imported.'
    BOOT_BEFORE=$(efibootmgr) || fail 'Cannot read UEFI boot entries.'
    OLD_ORDER=$(printf '%s\n' "$BOOT_BEFORE" | boot_order) || fail 'Cannot read BootOrder.'
    valid_order "$OLD_ORDER" || fail 'Unsupported or empty BootOrder.'
    INFO=$(diskinfo "/dev/$DISK") || fail 'Cannot read disk geometry.'
    SECTOR_SIZE=$(printf '%s\n' "$INFO" | awk 'NR==1 {print $2}')
    case "$SECTOR_SIZE" in 512|4096) ;; *) fail 'Only 512-byte and 4096-byte logical sectors are supported.' ;; esac
    ALIGN=$((1048576 / SECTOR_SIZE))
    FREE_REGIONS=$(printf '%s\n' "$LAYOUT" | awk -v min="$((4294967296 / SECTOR_SIZE + ALIGN))" '$3=="-" && $4=="free" && $2>=min {print $1,$2}')
    [ "$(printf '%s\n' "$FREE_REGIONS" | awk 'NF {n++} END {print n+0}')" -eq 1 ] || fail 'Expected exactly one unallocated region with at least 4 GiB plus alignment space.'
    FREE_START=$(printf '%s\n' "$FREE_REGIONS" | awk '{print $1}')
    FREE_SECTORS=$(printf '%s\n' "$FREE_REGIONS" | awk '{print $2}')
    uint "$FREE_START" && uint "$FREE_SECTORS" || fail 'Unsupported disk geometry.'
    [ "$FREE_START" -le "$((4503599627370495 - FREE_SECTORS))" ] || fail 'Disk geometry exceeds supported range.'
    printf '\nTarget: /dev/%s\n' "$DISK"
    diskinfo -v "/dev/$DISK" || fail 'Cannot display disk identity.'
    printf '\n%s\n\nUEFI entries:\n%s\n' "$LAYOUT" "$BOOT_BEFORE"
    printf '\nCreate encrypted swap? [y/N]: '
    read_answer
    SWAP_BYTES=0
    case "$ANSWER" in
        y|Y|yes) printf 'Swap size [4G]: '; read_answer; SWAP_BYTES=$(size_bytes "${ANSWER:-4G}") ;;
        n|N|no|'') : ;;
        *) fail 'Enter y or n.' ;;
    esac
    printf 'ZFS partition size [Enter = remaining selected region]: '
    read_answer
    ZFS_BYTES=0
    [ -z "$ANSWER" ] || ZFS_BYTES=$(size_bytes "$ANSWER")
    plan_sectors
    printf '\nPlan (logical sectors, end exclusive):\n  Swap: start=%s size=%s\n  ZFS: start=%s size=%s end=%s\n  ESP: /dev/%s (no formatting)\n  Existing boot priority: preserved; FreeBSD appended during this execution\n' "$START" "$SWAP_SECTORS" "$ZFS_START" "$ZFS_SECTORS" "$((ZFS_START + ZFS_SECTORS))" "$ESP_PART"
    printf '  GELI: AES-XTS, 256-bit key, 4096-byte sectors\n  ZFS: zroot/ROOT/default and shared /home, /tmp, /var datasets\n'
    choose_backup
    if [ -n "$BACKUP_DIR" ]; then
        path_safe "$BACKUP_DIR"
        [ -d "$BACKUP_DIR" ] && [ ! -L "$BACKUP_DIR" ] && [ -w "$BACKUP_DIR" ] || fail 'Backup directory must already exist and be writable.'
        BACKUP_DIR=$(realpath "$BACKUP_DIR")
        case "$BACKUP_DIR/" in "$TARGET/"*|"$ETC/"*|"$BOOT/"*) fail 'Choose a backup location outside the target and installer staging directories.' ;; esac
        printf '  Recovery destination: %s (ensure this is another, persistent medium)\n' "$BACKUP_DIR"
        df -h "$BACKUP_DIR" || fail 'Cannot inspect backup destination.'
    else
        printf '\nWARNING: Recovery files will be temporary and LOST ON REBOOT.\nChoose a directory on another mounted medium to retain them.\n'
    fi
    [ "$DRY_RUN" -eq 0 ] || { printf '\nDry run complete. No partitions, pools, configuration or ESP files were written.\n'; return; }
    printf '\nType INSTALL %s to write this plan: ' "$DISK"
    read_answer
    [ "$ANSWER" = "INSTALL $DISK" ] || fail 'Cancelled. No disk changes were made.'
    # Refuse a partition-table change between planning and confirmation.
    CURRENT=$(gpart show -p "$DISK") || fail 'Cannot recheck partition table.'
    [ "$CURRENT" = "$LAYOUT" ] || fail 'Partition table changed; rerun preparation.'
    SESSION=$(mktemp -d "${BACKUP_DIR:-/tmp}/freebsd-dualboot.XXXXXXXX") || fail 'Cannot create recovery directory.'
    trap cleanup 0
    trap 'exit 130' INT
    trap 'exit 143' TERM HUP
    printf '%s\n' "$LAYOUT" > "$SESSION/layout.before"
    printf '%s\n' "$BOOT_BEFORE" > "$SESSION/uefi.before"
    gpart backup "$DISK" > "$SESSION/gpt.before" || fail 'Cannot back up GPT.'
    TOKEN=$(uuidgen) || fail 'Cannot generate unique installation ID.'
    valid_uuid "$TOKEN" || fail 'Invalid generated UUID.'
    SWAP_LABEL=swap-${TOKEN%%-*}
    ZFS_LABEL=zfs-${TOKEN%%-*}
    [ ! -e "/dev/gpt/$SWAP_LABEL" ] && [ ! -e "/dev/gpt/$ZFS_LABEL" ] || fail 'Generated GPT label already exists.'
    for key in DISK TARGET ESP_PART ESP_UUID OLD_ORDER SWAP_LABEL ZFS_LABEL; do
        case "$key" in
            DISK) val=$DISK ;; TARGET) val=$TARGET ;; ESP_PART) val=$ESP_PART ;; ESP_UUID) val=$ESP_UUID ;;
            OLD_ORDER) val=$OLD_ORDER ;; SWAP_LABEL) val=$SWAP_LABEL ;; ZFS_LABEL) val=$ZFS_LABEL ;;
        esac
        save_field "$key" "$val"
    done
    printf 'swap start=%s sectors=%s\nzfs start=%s sectors=%s\n' "$START" "$SWAP_SECTORS" "$ZFS_START" "$ZFS_SECTORS" > "$SESSION/plan"
    # Read-only mount: archive the existing ESP before any partition changes.
    ESP_MOUNT=$(mktemp -d /tmp/dualboot-esp.XXXXXXXX)
    ESP_MOUNTED=0
    mount -t msdosfs -o ro "/dev/$ESP_PART" "$ESP_MOUNT" || fail 'Cannot mount ESP read-only.'
    ESP_MOUNTED=1
    [ ! -e "$ESP_MOUNT/EFI/freebsd" ] && [ ! -e "$ESP_MOUNT/efi/freebsd" ] || fail 'An existing FreeBSD EFI directory was found; refusing to overwrite it.'
    tar -cf "$SESSION/esp.before.tar" -C "$ESP_MOUNT" . || fail 'Cannot archive ESP.'
    umount "$ESP_MOUNT" || fail 'Cannot unmount ESP.'
    ESP_MOUNTED=0
    rmdir "$ESP_MOUNT"
    step 'Creating only the confirmed new partitions'
    if [ "$SWAP_SECTORS" -gt 0 ]; then
        OUT=$(gpart add -a 1m -b "$START" -s "$SWAP_SECTORS" -l "$SWAP_LABEL" -t freebsd-swap "$DISK") || fail 'Cannot create swap.'
        SWAP_PART=$(printf '%s\n' "$OUT" | awk 'NR==1 {print $1}')
        verify_partition "$SWAP_PART" "$START" "$SWAP_SECTORS" freebsd-swap
        save_field SWAP_PART "$SWAP_PART"
    fi
    OUT=$(gpart add -a 1m -b "$ZFS_START" -s "$ZFS_SECTORS" -l "$ZFS_LABEL" -t freebsd-zfs "$DISK") || fail 'Cannot create ZFS partition.'
    ZFS_PART=$(printf '%s\n' "$OUT" | awk 'NR==1 {print $1}')
    verify_partition "$ZFS_PART" "$ZFS_START" "$ZFS_SECTORS" freebsd-zfs
    ZFS_UUID=$(part_uuid "$ZFS_PART") || fail 'Cannot read new partition UUID.'
    valid_uuid "$ZFS_UUID" || fail 'Invalid new partition UUID.'
    save_field ZFS_PART "$ZFS_PART"
    save_field ZFS_UUID "$ZFS_UUID"
    step 'Initializing GELI (passphrase is never recorded)'
    geli init -bg -e AES-XTS -l 256 -s 4096 -B "$SESSION/geli.metadata" "/dev/$ZFS_PART" || fail 'GELI initialization failed.'
    geli attach "/dev/$ZFS_PART" || fail 'GELI attach failed.'
    require_device "$ZFS_PART.eli"
    step 'Creating ZFS pool and boot environment'
    # No -f: do not override ZFS in-use/signature checks.
    zpool create -o altroot="$TARGET" -o ashift=12 -O compression=lz4 -O atime=off -m none zroot "/dev/$ZFS_PART.eli" || fail 'Cannot create zroot; no force override is performed.'
    zfs create -o mountpoint=none zroot/ROOT
    zfs create -o mountpoint=/ zroot/ROOT/default
    zfs set canmount=noauto zroot/ROOT/default
    zpool set bootfs=zroot/ROOT/default zroot
    zfs create -o mountpoint=/home zroot/home
    zfs create -o mountpoint=/tmp -o setuid=off zroot/tmp
    zfs create -o mountpoint=/usr -o canmount=off zroot/usr
    zfs create -o setuid=off zroot/usr/ports
    zfs create zroot/usr/src
    zfs create -o mountpoint=/var -o canmount=off zroot/var
    zfs create -o exec=off -o setuid=off zroot/var/audit
    zfs create -o exec=off -o setuid=off zroot/var/crash
    zfs create -o exec=off -o setuid=off zroot/var/log
    zfs create -o atime=on zroot/var/mail
    zfs create -o setuid=off zroot/var/tmp
    MOUNTED=$(zfs mount) || fail 'Cannot query ZFS mounts.'
    printf '%s\n' "$MOUNTED" | awk -v p="$TARGET" '$1=="zroot/ROOT/default" && $2==p {ok=1} END {exit !ok}' || fail 'Target is not mounted on the new root dataset.'
    [ "$(zpool get -H -o value bootfs zroot)" = zroot/ROOT/default ] || fail 'Incorrect bootfs.'
    mkdir -p "$TARGET/boot/zfs" "$TARGET/efi"
    chmod 755 "$TARGET" "$TARGET/boot" "$TARGET/boot/zfs" "$TARGET/efi" "$TARGET/home"
    chmod 1777 "$TARGET/tmp" "$TARGET/var/tmp"
    zpool set cachefile="$TARGET/boot/zfs/zpool.cache" zroot
    printf 'zfs_enable="YES"\n' > "$ETC/rc.conf.dualboot"
    printf 'geom_eli_load="YES"\nzfs_load="YES"\n' > "$BOOT/loader.conf.dualboot"
    # bootconfig recognizes /boot/efi specifically. A separate /efi mountpoint
    # keeps ESP/BootOrder management here, without a second bsdinstall writer.
    printf '/dev/gptid/%s\t/efi\tmsdosfs\trw,noauto\t0\t0\n' "$ESP_UUID" > "$FSTAB"
    if [ "$SWAP_SECTORS" -gt 0 ]; then
        printf '/dev/gpt/%s.eli\tnone\tswap\tsw\t0\t0\n' "$SWAP_LABEL" >> "$FSTAB"
    fi
    gpart backup "$DISK" > "$SESSION/gpt.after"
    install_boot
    mkdir -p "$TARGET/root/dualboot-recovery"
    chmod 700 "$TARGET/root" "$TARGET/root/dualboot-recovery"
    cp "$SESSION/gpt.before" "$SESSION/gpt.after" "$SESSION/geli.metadata" "$SESSION/plan" "$SESSION/uefi.before" "$SESSION/uefi.after" "$TARGET/root/dualboot-recovery/"
    chmod 600 "$TARGET/root/dualboot-recovery/"*
    save_field stage complete
    printf '\nPreparation and EFI setup complete. Original boot priority retained.\n'
    printf 'Recovery files: %s\nA second copy (except the ESP archive) is in the target /root/dualboot-recovery.\n' "$SESSION"
    printf 'Type exit and complete bsdinstall normally; no second script execution is needed.\n'
    printf 'Do not reboot until bsdinstall finishes. Then select %s in the firmware menu.\n' "$LABEL"
    printf 'Keep an external copy of geli.metadata; files inside the encrypted pool cannot recover that pool.\n'
}
install_boot() {
    # Called automatically by preparation. Never replaces existing EFI loaders.
    [ "$(part_uuid "$ESP_PART")" = "$ESP_UUID" ] || fail 'ESP identity changed.'
    BOOT_NOW=$(efibootmgr) || fail 'Cannot read current UEFI state.'
    CURRENT_ORDER=$(printf '%s\n' "$BOOT_NOW" | boot_order) || fail 'Cannot read current BootOrder.'
    [ "$CURRENT_ORDER" = "$OLD_ORDER" ] || fail 'BootOrder changed during preparation; inspect before proceeding.'
    step 'Installing the FreeBSD loader from the installer media'
    ESP_MOUNT=$(mktemp -d /tmp/dualboot-esp.XXXXXXXX)
    ESP_MOUNTED=0
    mount -t msdosfs "/dev/$ESP_PART" "$ESP_MOUNT" || fail 'Cannot mount ESP.'
    ESP_MOUNTED=1
    [ ! -e "$ESP_MOUNT/EFI/freebsd" ] && [ ! -e "$ESP_MOUNT/efi/freebsd" ] || fail 'FreeBSD EFI directory already exists; refusing to overwrite it.'
    # FAT free-space check, with a 1 MiB margin.
    AVAILABLE=$(df -k "$ESP_MOUNT" | awk 'END {print $4}')
    REQUIRED=$(du -k "$LOADER" | awk '{print $1}')
    uint "$AVAILABLE" && uint "$REQUIRED" || fail 'Cannot determine ESP capacity.'
    [ "$AVAILABLE" -ge "$((REQUIRED + 1024))" ] || fail 'Not enough free space in ESP.'
    mkdir -p "$ESP_MOUNT/EFI/freebsd"
    cp "$LOADER" "$ESP_MOUNT/EFI/freebsd/loader.efi"
    cmp "$LOADER" "$ESP_MOUNT/EFI/freebsd/loader.efi" || fail 'EFI loader copy verification failed.'
    sync
    # Unique label: no removal or replacement of existing NVRAM entries.
    LABEL="FreeBSD-${ZFS_UUID%%-*}"
    printf '%s\n' "$BOOT_NOW" | awk -v l="$LABEL" '$NF==l {found=1} END {exit !found}' && fail 'The installation boot label already exists.'
    ORDER_PENDING=1
    if ! efibootmgr -a -c -L "$LABEL" -l "$ESP_MOUNT/EFI/freebsd/loader.efi"; then
        # Creation can fail AFTER modifying BootOrder; attempt restoration.
        fail 'Cannot create boot entry. ESP loader remains; inspect UEFI state before retrying.'
    fi
    AFTER=$(efibootmgr) || fail 'Cannot inspect new boot entry.'
    printf '%s\n' "$AFTER" > "$SESSION/uefi.after-create"
    NEW_ENTRY=$(printf '%s\n' "$AFTER" | awk -v l="$LABEL" '$NF==l && $1 ~ /^Boot[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]/ {s=$1; sub(/^Boot/,"",s); sub(/\*$/, "",s); print s; n++} END {if(n!=1) exit 1}') || fail 'Cannot identify the new boot entry.'
    valid_order "$NEW_ENTRY" || fail 'Invalid boot entry ID.'
    efibootmgr -o "$OLD_ORDER,$NEW_ENTRY" || fail 'Cannot preserve original boot priority.'
    VERIFIED=$(efibootmgr) || fail 'Cannot verify BootOrder; inspect UEFI state before rebooting.'
    [ "$(printf '%s\n' "$VERIFIED" | boot_order)" = "$OLD_ORDER,$NEW_ENTRY" ] || fail 'BootOrder verification failed.'
    ORDER_PENDING=0
    printf '%s\n' "$VERIFIED" > "$SESSION/uefi.after"
    umount "$ESP_MOUNT" || fail 'Cannot unmount ESP.'
    ESP_MOUNTED=0
    rmdir "$ESP_MOUNT"
    printf 'No Secure Boot signing/enrollment is performed. Boot must be tested on this machine.\n'

}
main() {
    DRY_RUN=0
    BACKUP_DIR=''
    BACKUP_MODE=ask
    DISK=''
    SESSION=''
    ESP_MOUNTED=0
    ORDER_PENDING=0
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --help|-h) usage; return ;;
            --dry-run) DRY_RUN=1; shift ;;
            --backup-dir)
                [ "$#" -ge 2 ] && [ -n "$2" ] || fail 'Missing backup directory.'
                [ "$BACKUP_MODE" = ask ] || fail 'Specify only one backup option.'
                BACKUP_DIR=$2; BACKUP_MODE=directory; shift 2 ;;
            --no-backup)
                [ "$BACKUP_MODE" = ask ] || fail 'Specify only one backup option.'
                BACKUP_MODE=skip; shift ;;
            --*) fail "Unknown option: $1" ;;
            *) [ -z "$DISK" ] || fail 'Specify one disk.'; DISK=${1#/dev/}; shift ;;
        esac
    done
    case "$DISK" in *[!a-zA-Z0-9]*) fail 'Invalid disk name (example: nda0).' ;; esac
    preflight
    [ -n "$DISK" ] || choose_disk
    prepare
}
main "$@"
