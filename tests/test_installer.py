"""Host-side regression tests. All FreeBSD/disk commands are shell mocks.

The production entry point is removed in memory; no OS guard bypass exists in
production. These tests validate control flow, not FreeBSD device/boot behavior.
"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'freebsd-zfs-geli-install.sh'
SOURCE = SCRIPT.read_text().removesuffix('main "$@"\n')


class InstallerTests(unittest.TestCase):
    def run_shell(self, code, stdin='', success=True, extra_env=None):
        env = os.environ.copy()
        env.update(extra_env or {})
        result = subprocess.run(['sh', '-s'], input=SOURCE + '\n' + code,
                                text=True, capture_output=True, env=env)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_sizes(self):
        for value, expected in [('512M', 536870912), ('4G', 4294967296), ('1t', 1099511627776)]:
            with self.subTest(value=value):
                result = self.run_shell(f'size_bytes {value}')
                self.assertEqual(result.stdout.strip(), str(expected))

    def test_invalid_sizes_and_overflow(self):
        for value in ['0G', '04G', '-1G', '1.5G', '1', '16777217T', '999999999999999999999T', '4G;id']:
            with self.subTest(value=value):
                result = self.run_shell('size_bytes "$TEST_SIZE"', success=False,
                                        extra_env={'TEST_SIZE': value})
                self.assertIn('ERROR:', result.stderr)

    def test_sector_plans(self):
        for sector in [512, 4096]:
            for swap in [0, 4294967296]:
                for requested in [0, 8589934592]:
                    with self.subTest(sector=sector, swap=swap, requested=requested):
                        code = f'''
SECTOR_SIZE={sector}; ALIGN=$((1048576 / SECTOR_SIZE))
FREE_START=2050; FREE_SECTORS=$((64 * 1024 * 1024 * 1024 / SECTOR_SIZE))
SWAP_BYTES={swap}; ZFS_BYTES={requested}
plan_sectors
[ "$((START % ALIGN))" -eq 0 ]
[ "$((ZFS_START % ALIGN))" -eq 0 ]
[ "$((ZFS_SECTORS % ALIGN))" -eq 0 ]
[ "$START" -ge "$FREE_START" ]
[ "$((ZFS_START + ZFS_SECTORS))" -le "$((FREE_START + FREE_SECTORS))" ]
[ "$ZFS_START" -eq "$((START + SWAP_SECTORS))" ]
'''
                        self.run_shell(code)

    def test_insufficient_space(self):
        self.run_shell('SECTOR_SIZE=512; ALIGN=2048; FREE_START=2048; FREE_SECTORS=16777216; SWAP_BYTES=8589934592; ZFS_BYTES=0; plan_sectors', success=False)

    def test_explicit_size_outside_region(self):
        self.run_shell('SECTOR_SIZE=512; ALIGN=2048; FREE_START=2048; FREE_SECTORS=16777216; SWAP_BYTES=4294967296; ZFS_BYTES=8589934592; plan_sectors', success=False)

    def test_mount_descendants_refused(self):
        self.run_shell("MOUNTS='/dev/nda0p4 /mnt/home zfs rw 0 0'; path_unmounted /mnt", success=False)
        self.run_shell("MOUNTS='/dev/nda0p4 /mnt-other zfs rw 0 0'; path_unmounted /mnt")

    def test_uuid_and_bootorder_parsers(self):
        self.run_shell("valid_uuid 12345678-1234-1234-1234-123456789abc; valid_order 0001,000A; [ \"$(printf 'BootOrder  : 0001,000A\\n' | boot_order)\" = 0001,000A ]")
        self.run_shell("printf 'BootCurrent: 0001\\n' | boot_order", success=False)
        self.run_shell('valid_order 0001,ZZZZ', success=False)

    def test_geom_partition_uuid(self):
        self.run_shell('''
DISK=nda0
geom() { printf 'Geom name: nda0\nProviders:\n1. Name: nda0p1\n   rawuuid: 11111111-1111-1111-1111-111111111111\n2. Name: nda0p2\n   rawuuid: 22222222-2222-2222-2222-222222222222\n'; }
[ "$(part_uuid nda0p2)" = 22222222-2222-2222-2222-222222222222 ]
''')

    def test_non_freebsd_guard(self):
        result = self.run_shell("uname() { printf 'Linux\\n'; }; preflight", success=False)
        self.assertIn('Run this from the FreeBSD installer', result.stderr)

    def test_no_installer_context(self):
        self.run_shell('unset BSDINSTALL_CHROOT BSDINSTALL_TMPETC BSDINSTALL_TMPBOOT PATH_FSTAB; prepare', success=False)

    def test_unsafe_paths(self):
        for path in ['/', 'relative', '/mnt/../etc', '/mnt/a b']:
            self.run_shell('path_safe "$TEST_PATH"', success=False, extra_env={'TEST_PATH': path})

    def mock_flow(self, fault='', dry=False, backup=False, swap=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = root / 'target'
            etc = root / 'etc'
            boot = root / 'boot'
            recovery = root / 'backup'
            for path in [target, etc, boot, recovery]:
                path.mkdir()
            env = {'TEST_ROOT': str(root), 'FAULT': fault}
            code = r'''
DISK=nda0; TARGET="$TEST_ROOT/target"
BSDINSTALL_CHROOT=$TARGET; BSDINSTALL_TMPETC="$TEST_ROOT/etc"; BSDINSTALL_TMPBOOT="$TEST_ROOT/boot"; PATH_FSTAB="$TEST_ROOT/etc/fstab"
DRY_RUN=DRY_VALUE; BACKUP_DIR=BACKUP_VALUE; SESSION=''; ESP_MOUNTED=0; ORDER_PENDING=0
LOADER="$TEST_ROOT/media-loader.efi"
printf 'installer loader\n' > "$LOADER"
log() { printf '%s\n' "$*" >> "$TEST_ROOT/commands"; }
require_device() { :; }
part_uuid() { case "$1" in nda0p1) printf '11111111-1111-1111-1111-111111111111\n';; *) printf '22222222-2222-2222-2222-222222222222\n';; esac; }
mount_table() { MOUNTS=''; }
kldload() { :; }
uuidgen() { printf '12345678-1234-1234-1234-123456789abc\n'; }
diskinfo() { if [ "$1" = -v ]; then printf 'Mock disk serial: TEST-ONLY\n'; else printf '/dev/nda0 512 68719476736\n'; fi; }
gpart() {
    log "gpart $*"
    case "$1" in
      show)
        [ "$FAULT" != changed-table ] || [ ! -f "$TEST_ROOT/confirmed" ] || { printf 'changed\n'; return; }
        printf '=> 34 134217660 nda0 GPT\n   2048 532480 nda0p1 efi\n   534528 133683132 - free -\n'
        if [ -f "$TEST_ROOT/partition" ]; then cat "$TEST_ROOT/partition"; fi
        : > "$TEST_ROOT/confirmed"
        ;;
      backup) printf 'GPT BACKUP\n';;
      add)
        [ "$FAULT" != gpart ] || return 1
        start=$5; count=$7; type=${11}
        part=nda0p2
        [ ! -f "$TEST_ROOT/partition" ] || part=nda0p3
        printf '%s %s %s %s\n' "$start" "$count" "$part" "$type" >> "$TEST_ROOT/partition"
        printf '%s added\n' "$part";;
    esac
}
zpool() {
    log "zpool $*"
    case "$1" in
      list) [ "$FAULT" != pool-query ] || return 1;;
      get) printf 'zroot/ROOT/default\n';;
      status) printf '/dev/%s.eli ONLINE\n' "$ZFS_PART";;
    esac
}
zfs() {
    log "zfs $*"
    if [ "$1" = mount ]; then printf 'zroot/ROOT/default %s\n' "$TARGET";
    elif [ "$1" = create ]; then
      mkdir -p "$TARGET/home" "$TARGET/tmp" "$TARGET/usr" "$TARGET/var/tmp" "$TARGET/root"
    fi
}
geli() {
    log "geli $*"
    [ "$FAULT" != geli ] || return 1
    if [ "$1" = init ]; then printf 'metadata\n' > "$SESSION/geli.metadata"; fi
}
mktemp() {
    case "$*" in
      '-d /tmp/dualboot-esp.XXXXXXXX') command mktemp -d "$TEST_ROOT/dualboot-esp.XXXXXXXX";;
      *) command mktemp "$@";;
    esac
}
MOUNT_NUMBER=0
mount() {
    log "mount $*"
    MOUNT_NUMBER=$((MOUNT_NUMBER + 1))
    for destination do :; done
    mkdir -p "$destination/EFI/debian" "$destination/EFI/BOOT"
    printf 'existing grub\n' > "$destination/EFI/debian/grubx64.efi"
    printf 'existing fallback\n' > "$destination/EFI/BOOT/BOOTX64.EFI"
}
umount() {
    log "umount $*"
    if [ -d "$1/EFI" ]; then mv "$1/EFI" "$TEST_ROOT/ESP_$MOUNT_NUMBER"; fi
}
sync() { :; }
efibootmgr() {
    log "efi $*"
    case "${1:-}" in
      -a)
        printf '0002,0001,000A\n' > "$TEST_ROOT/order"
        [ "$FAULT" != efi-create ] || return 1
        if [ "$FAULT" = efi-signal ]; then kill -TERM "$$"; fi
        : > "$TEST_ROOT/entry";;
      -o)
        if [ "$FAULT" = efi-order ] && [ "$2" != 0001,000A ]; then return 1; fi
        printf '%s\n' "$2" > "$TEST_ROOT/order";;
      *)
        order=0001,000A
        [ ! -f "$TEST_ROOT/order" ] || order=$(cat "$TEST_ROOT/order")
        printf 'BootOrder  : %s\n Boot0001* debian\n+Boot000A* installer\n' "$order"
        [ ! -f "$TEST_ROOT/entry" ] || printf ' Boot0002* FreeBSD-22222222\n'
        ;;
    esac
}
prepare
if [ "$DRY_RUN" -eq 1 ]; then
    ! grep -Eq '^gpart (add|backup)|^geli|^zpool create|^mount ' "$TEST_ROOT/commands"
    [ ! -e "$PATH_FSTAB" ]
    exit
fi
[ "$(cat "$TEST_ROOT/order")" = 0001,000A,0002 ]
[ "$(cat "$SESSION/stage")" = complete ]
grep -q '/dev/gptid/11111111-1111-1111-1111-111111111111.*[[:space:]]/efi[[:space:]]' "$PATH_FSTAB"
! grep -q /boot/efi "$PATH_FSTAB"
! grep -q vfs.root.mountfrom "$BSDINSTALL_TMPBOOT/loader.conf.dualboot"
[ -f "$TARGET/root/dualboot-recovery/geli.metadata" ]
[ -f "$SESSION/esp.before.tar" ]
cmp "$LOADER" "$TEST_ROOT/ESP_2/freebsd/loader.efi"
cmp "$TEST_ROOT/ESP_1/debian/grubx64.efi" "$TEST_ROOT/ESP_2/debian/grubx64.efi"
cmp "$TEST_ROOT/ESP_1/BOOT/BOOTX64.EFI" "$TEST_ROOT/ESP_2/BOOT/BOOTX64.EFI"
[ "$(grep -c '^efi -a' "$TEST_ROOT/commands")" -eq 1 ]
printf '\nFLOW VERIFIED\n'
'''
            code = code.replace('DRY_VALUE', str(int(dry))).replace('BACKUP_VALUE', '"$TEST_ROOT/backup"' if backup else "''")
            # Supply answers via read_answer, keeping stdin for the shell program.
            inputs = (['y', '4G'] if swap else ['n']) + ['', 'INSTALL nda0']
            answers = root / 'answers'
            answers.write_text('\n'.join(inputs) + '\n')
            code = 'exec 3< "$TEST_ROOT/answers"\nread_answer() { IFS= read -r ANSWER <&3 || fail "No test answer"; }\n' + code
            result = self.run_shell(code, success=not fault, extra_env=env)
            commands = (root / 'commands').read_text() if (root / 'commands').exists() else ''
            if fault == 'pool-query' or fault == 'changed-table':
                self.assertNotIn('gpart add', commands)
            if fault == 'gpart':
                self.assertNotIn('geli init', commands)
            if fault == 'geli':
                self.assertNotIn('zpool create', commands)
            if fault in ['efi-create', 'efi-signal', 'efi-order']:
                self.assertEqual((root / 'order').read_text().strip(), '0001,000A')
            if not fault and not dry:
                self.assertIn('FLOW VERIFIED', result.stdout)
            # Failure sessions also use /tmp in the optional-backup scenario.
            if not backup:
                import re
                import shutil
                for path in re.findall(r'/tmp/freebsd-dualboot\.[A-Za-z0-9]+', result.stdout + result.stderr):
                    shutil.rmtree(path, ignore_errors=True)

    def test_dry_run_writes_no_disk_or_configuration(self):
        self.mock_flow(dry=True)

    def test_single_run_temporary_backup(self):
        self.mock_flow()

    def test_single_run_external_backup(self):
        self.mock_flow(backup=True)

    def test_single_run_with_swap(self):
        self.mock_flow(backup=True, swap=True)

    def test_failures_stop_and_restore_boot_priority(self):
        for fault in ['pool-query', 'changed-table', 'gpart', 'geli', 'efi-create', 'efi-signal', 'efi-order']:
            with self.subTest(fault=fault):
                self.mock_flow(fault=fault)


if __name__ == '__main__':
    unittest.main()
