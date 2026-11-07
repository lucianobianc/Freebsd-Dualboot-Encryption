#!/bin/sh
# FreeBSD bsdinstall Shell partitioning: fresh GELI-encrypted ZFS root.
# Usage: sh /tmp/freebsd-clean-zfs-geli.sh nda0
# Prerequisites: UEFI boot, existing GPT + EFI partition, and unallocated space.
# Does NOT delete partitions, reuse an existing ZFS pool, or format the EFI partition.
set -eu
umask 077

fail() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
step() { printf '\n==> %s\n' "$*"; }

[ "$(uname -s)" = FreeBSD ] || fail 'Run this from the FreeBSD installer.'
[ "$(id -u)" -eq 0 ] || fail 'Run as root.'
[ "$#" -eq 1 ] || fail 'Usage: sh install.sh nda0'
DISK=${1#/dev/}
case "$DISK" in
    ''|*[!a-zA-Z0-9]*) fail 'Invalid disk name. Example: nda0' ;;
esac
[ -c "/dev/$DISK" ] || fail "Disk /dev/$DISK does not exist."

# Make sure the target is a GPT disk. The header contains: => start size nda0 GPT.
LAYOUT=$(gpart show -p "$DISK") || fail 'Cannot read partition table.'
printf '%s\n' "$LAYOUT" | awk -v d="$DISK" \
    '$1=="=>" && $4==d && $5=="GPT" {found=1} END {exit !found}' || \
    fail "Disk /dev/$DISK does not have a GPT partition table."

ESP_COUNT=$(printf '%s\n' "$LAYOUT" | awk '$4=="efi" {n++} END {print n+0}')
[ "$ESP_COUNT" -eq 1 ] || fail 'Exactly one existing EFI partition is required.'
ESP_PART=$(printf '%s\n' "$LAYOUT" | awk '$4=="efi" {print $3; exit}')
[ -c "/dev/$ESP_PART" ] || fail "EFI partition /dev/$ESP_PART is missing."

# A clean install must start from unallocated space, not existing FreeBSD partitions.
if printf '%s\n' "$LAYOUT" | awk '$4=="freebsd-zfs" || $4=="freebsd-swap" {found=1} END {exit !found}'; then
    fail 'Existing FreeBSD ZFS/swap partition detected. This fresh-install script will not reuse or erase it.'
fi
if zpool list -H -o name 2>/dev/null | grep -qx zroot; then
    fail 'A pool named zroot is already imported. No changes were made.'
fi
if mount -p | awk '$2=="/mnt" {found=1} END {exit !found}'; then
    fail '/mnt is already mounted. It must be free for the target ZFS root.'
fi

SECTOR_SIZE=$(diskinfo "/dev/$DISK" | awk 'NR==1 {print $2}')
case "$SECTOR_SIZE" in ''|*[!0-9]*|0) fail 'Cannot determine logical sector size.' ;; esac
MIN_SECTORS=$(( (2 * 1024 * 1024 * 1024 + SECTOR_SIZE - 1) / SECTOR_SIZE ))
FREE_REGIONS=$(printf '%s\n' "$LAYOUT" | awk -v min="$MIN_SECTORS" \
    '$3=="-" && $4=="free" && $2>=min {print $1, $2}')
REGION_COUNT=$(printf '%s\n' "$FREE_REGIONS" | awk 'NF {n++} END {print n+0}')
[ "$REGION_COUNT" -ge 1 ] || fail 'No suitable unallocated space (at least 2 GiB) was found.'
[ "$REGION_COUNT" -eq 1 ] || fail 'More than one large free region exists. Refusing to guess which one to use.'
FREE_START=$(printf '%s\n' "$FREE_REGIONS" | awk '{print $1}')
FREE_SECTORS=$(printf '%s\n' "$FREE_REGIONS" | awk '{print $2}')
FREE_BYTES=$((FREE_SECTORS * SECTOR_SIZE))
FREE_GIB=$(awk -v bytes="$FREE_BYTES" 'BEGIN {printf "%.2f", bytes/(1024*1024*1024)}')

# Restrict sizes to simple binary units accepted by gpart (e.g. 512M, 4G, 1T).
check_size() {
    printf '%s\n' "$1" | awk '/^[1-9][0-9]*[MmGgTt]$/ {ok=1} END {exit !ok}' || \
        fail "Invalid size '$1'. Use a value such as 512M, 4G or 1T."
}
size_bytes() {
    number=${1%?}
    unit=${1#"$number"}
    case "$unit" in
        M|m) factor=1048576 ;;
        G|g) factor=1073741824 ;;
        T|t) factor=1099511627776 ;;
    esac
    printf '%s\n' "$((number * factor))"
}

printf '\nDisk partition table:\n'
printf '%s\n' "$LAYOUT"
printf '\nSelected unallocated region: %.2f GiB (starting sector %s)\n' "$FREE_GIB" "$FREE_START"
printf 'Create a swap partition? [y/N]: '
IFS= read -r ANSWER || fail 'Input cancelled.'
case "$ANSWER" in
    y|Y|yes|YES|Yes)
        printf 'Swap size [4G]: '
        IFS= read -r SWAP_SIZE || fail 'Input cancelled.'
        SWAP_SIZE=${SWAP_SIZE:-4G}
        check_size "$SWAP_SIZE"
        SWAP_BYTES=$(size_bytes "$SWAP_SIZE")
        ;;
    n|N|no|NO|No|'')
        SWAP_SIZE=''
        SWAP_BYTES=0
        ;;
    *) fail 'Enter y or n for swap.' ;;
esac

printf 'ZFS partition size [Enter = all remaining space]: '
IFS= read -r ZFS_SIZE || fail 'Input cancelled.'
if [ -n "$ZFS_SIZE" ]; then
    check_size "$ZFS_SIZE"
    ZFS_BYTES=$(size_bytes "$ZFS_SIZE")
else
    ZFS_BYTES=$((FREE_BYTES - SWAP_BYTES))
fi
# Leave a little space for alignment when a size is explicitly requested.
[ "$ZFS_BYTES" -ge 4294967296 ] || fail 'ZFS needs at least 4 GiB after swap.'
if [ -n "$ZFS_SIZE" ]; then
    [ $((SWAP_BYTES + ZFS_BYTES + 1048576)) -le "$FREE_BYTES" ] || \
        fail 'Requested sizes exceed the unallocated region (including alignment reserve).'
else
    [ $((SWAP_BYTES + 4294967296 + 1048576)) -le "$FREE_BYTES" ] || \
        fail 'Not enough free space for swap and a minimum 4 GiB ZFS root.'
fi

printf '\nInstallation plan:\n'
printf '  Disk:       /dev/%s\n' "$DISK"
printf '  EFI:        /dev/%s (preserved)\n' "$ESP_PART"
printf '  Swap:       %s\n' "${SWAP_SIZE:-none}"
printf '  ZFS:        %s\n' "${ZFS_SIZE:-all remaining space}"
printf '  Encryption: GELI with boot-time passphrase\n'
printf '  Dataset:    zroot/ROOT/default (/) and zroot/home (/usr/home)\n'
printf '\nOnly new partitions in the selected free region will be created.\n'
printf 'GELI initialization and ZFS creation overwrite data within the NEW ZFS partition.\n'
printf 'Type INSTALL to continue: '
IFS= read -r CONFIRM || fail 'Input cancelled.'
[ "$CONFIRM" = INSTALL ] || fail 'Cancelled. No changes were made.'

kldload zfs 2>/dev/null || kldstat -q -m zfs || fail 'Cannot load ZFS.'
kldload geom_eli 2>/dev/null || kldstat -q -m geom_eli || fail 'Cannot load GELI.'

# Use the selected free range, not the first arbitrary gap on the disk.
if [ -n "$SWAP_SIZE" ]; then
    step 'Creating swap partition'
    OUT=$(gpart add -a 4k -b "$FREE_START" -s "$SWAP_SIZE" -l swap0 -t freebsd-swap "$DISK") || \
        fail 'Could not create the swap partition.'
    SWAP_PART=$(printf '%s\n' "$OUT" | awk 'NR==1 {print $1}')
    [ -c "/dev/$SWAP_PART" ] || fail 'Swap partition was not found after creation.'
    # Query again: the remaining free area now starts after the new swap partition.
    LAYOUT=$(gpart show -p "$DISK") || fail 'Cannot refresh the partition table.'
    FREE_REGIONS=$(printf '%s\n' "$LAYOUT" | awk -v min="$MIN_SECTORS" \
        '$3=="-" && $4=="free" && $2>=min {print $1, $2}')
    REGION_COUNT=$(printf '%s\n' "$FREE_REGIONS" | awk 'NF {n++} END {print n+0}')
    [ "$REGION_COUNT" -eq 1 ] || fail 'Cannot identify the remaining free region after creating swap.'
    ZFS_START=$(printf '%s\n' "$FREE_REGIONS" | awk '{print $1}')
else
    ZFS_START=$FREE_START
fi

step 'Creating ZFS partition'
if [ -n "$ZFS_SIZE" ]; then
    OUT=$(gpart add -a 4k -b "$ZFS_START" -s "$ZFS_SIZE" -l zfs0 -t freebsd-zfs "$DISK") || \
        fail 'Could not create the ZFS partition.'
else
    OUT=$(gpart add -a 4k -b "$ZFS_START" -l zfs0 -t freebsd-zfs "$DISK") || \
        fail 'Could not create the ZFS partition.'
fi
ZFS_PART=$(printf '%s\n' "$OUT" | awk 'NR==1 {print $1}')
[ -c "/dev/$ZFS_PART" ] || fail 'ZFS partition was not found after creation.'
case "$ZFS_PART" in "$DISK"p*) : ;; *) fail 'Unexpected ZFS partition device name.' ;; esac

step "Initializing GELI on /dev/$ZFS_PART"
geli init -bg -l 256 -s 4096 "/dev/$ZFS_PART" || fail 'geli init failed.'
geli attach "/dev/$ZFS_PART" || fail 'geli attach failed.'
[ -c "/dev/$ZFS_PART.eli" ] || fail 'Encrypted device was not created.'

step 'Creating ZFS pool and datasets'
mkdir -p /mnt
zpool create -f -o altroot=/mnt -o ashift=12 \
    -O compression=lz4 -O atime=off -m none \
    zroot "/dev/$ZFS_PART.eli" || fail 'zpool create failed.'
zfs create -o mountpoint=none zroot/ROOT || fail 'Cannot create zroot/ROOT.'
zfs create -o mountpoint=/ zroot/ROOT/default || fail 'Cannot create root dataset.'
zfs set canmount=noauto zroot/ROOT/default || fail 'Cannot set canmount.'
zpool set bootfs=zroot/ROOT/default zroot || fail 'Cannot set bootfs.'
zfs create -o mountpoint=/usr/home zroot/home || fail 'Cannot create home dataset.'

# Guard against repeating the previous error: /mnt MUST be on the ZFS root,
# not on tmpfs or the installer's RAM filesystem.
zfs mount | awk '$1=="zroot/ROOT/default" && $2=="/mnt" {found=1} END {exit !found}' || \
    fail 'The ZFS root is not mounted at /mnt. Do not continue bsdinstall.'
[ "$(zpool get -H -o value bootfs zroot)" = zroot/ROOT/default ] || \
    fail 'Incorrect bootfs: aborting before installation.'
ln -s /usr/home /mnt/home
mkdir -p /mnt/tmp /mnt/var/tmp /mnt/boot/efi
chmod 1777 /mnt/tmp /mnt/var/tmp

step 'Preparing bsdinstall configuration files'
mkdir -p /tmp/bsdinstall_etc /tmp/bsdinstall_boot
printf 'zfs_enable="YES"\n' >> /tmp/bsdinstall_etc/rc.conf
printf 'geom_eli_load="YES"\nzfs_load="YES"\n' >> /tmp/bsdinstall_boot/loader.conf
printf 'vfs.root.mountfrom="zfs:zroot/ROOT/default"\n' >> /tmp/bsdinstall_boot/loader.conf
printf 'tmpfs\t/tmp\ttmpfs\trw,mode=1777\t0\t0\n' >> /tmp/bsdinstall_etc/fstab
printf '/dev/%s\t/boot/efi\tmsdosfs\trw\t2\t2\n' "$ESP_PART" >> /tmp/bsdinstall_etc/fstab
if [ -n "$SWAP_SIZE" ]; then
    # FreeBSD automatically creates an ephemeral GELI provider for .eli swap.
    printf '/dev/gpt/swap0.eli\tnone\tswap\tsw\t0\t0\n' >> /tmp/bsdinstall_etc/fstab
fi

step 'Installing FreeBSD UEFI loader into the existing EFI partition'
ESP_MOUNT=/media
[ -z "$(mount -p | awk '$2=="/media" {print $1; exit}')" ] || \
    fail '/media is already mounted; refusing to overwrite another mount.'
[ -f /boot/loader.efi ] || fail 'FreeBSD loader.efi is missing on the installer media.'
mkdir -p "$ESP_MOUNT"
ESP_MOUNTED=0
cleanup() {
    if [ "$ESP_MOUNTED" -eq 1 ]; then
        umount "$ESP_MOUNT" >/dev/null 2>&1 || true
    fi
}
trap cleanup 0
mount -t msdosfs "/dev/$ESP_PART" "$ESP_MOUNT" || fail 'Cannot mount EFI partition.'
ESP_MOUNTED=1
mkdir -p "$ESP_MOUNT/EFI/freebsd"
cp /boot/loader.efi "$ESP_MOUNT/EFI/freebsd/loader.efi" || fail 'Cannot copy EFI loader.'
sync
if command -v efibootmgr >/dev/null 2>&1; then
    if ! efibootmgr -a -c -l "$ESP_MOUNT/EFI/freebsd/loader.efi" -L FreeBSD; then
        printf 'WARNING: EFI loader was copied, but NVRAM registration failed.\n' >&2
    fi
else
    printf 'WARNING: efibootmgr not available; EFI loader was copied.\n' >&2
fi
umount "$ESP_MOUNT" || fail 'Unable to unmount EFI partition.'
ESP_MOUNTED=0
trap - 0

step 'Final verification'
zfs list -r zroot
zpool get bootfs zroot
printf '\nRoot mounted at /mnt: verified.\n'
printf 'Partitioning is finished. Type exit to resume bsdinstall.\n'
printf 'Do not reboot before the FreeBSD installer finishes.\n'
