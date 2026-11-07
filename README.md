# FreeBSD dual boot with ZFS and GELI

Helper for **FreeBSD 15.1, amd64, UEFI**, used from the **Shell** partitioning
option in `bsdinstall`. It installs into unallocated space on a GPT disk that
already has exactly one EFI System Partition (ESP) and one or more existing
operating systems. Existing partitions are neither resized nor formatted.

This is a fresh-install helper, not an upgrader or a recovery/resume tool. It
refuses disks containing existing `freebsd-*` partitions, an imported `zroot`,
multiple suitable free regions, and an existing `EFI/freebsd` directory. Keep a
backup of your existing operating system: the optional recovery files below are
not a backup of existing operating systems or your personal data.

## Installation

Boot the **15.1 installer in UEFI mode**. Make sure your firmware can execute the
FreeBSD loader: this helper does not sign EFI binaries, enroll keys, or change
Secure Boot settings. Keep the script accessible in the installer environment,
for example at `/tmp/freebsd-zfs-geli-install.sh`.

In the installer's partitioning menu, select **Shell**, then run:

```sh
sh /tmp/freebsd-zfs-geli-install.sh
```

The script lists detected devices with their model, serial and capacity. Enter
the number of the **installation disk**; none is selected by default. The list
can include installer media and devices unsuitable for this installation. Check
the chosen disk's partition layout, which is displayed before any write. Enter
`q` at the disk menu to cancel.

It prompts for optional encrypted swap and a ZFS size, then asks whether to keep
a recovery backup. Answer `y` (or `s`/`sim`) to enter a destination directory, or
`n`/Enter to continue without a persistent external copy. All these choices are
made before the final installation confirmation.

Sizes are whole binary units such as `512M`, `4G` or `1T`. An empty ZFS size uses
the remaining selected free region. The absolute minimum partition size is 4 GiB;
allow **at least 20 GiB**, and preferably more, for a useful installation and boot
environments.

To inspect the interactive plan without writing:

```sh
sh /tmp/freebsd-zfs-geli-install.sh --dry-run
```

The dry run may load ZFS/GELI kernel modules but does not create partitions,
pools, backups, installer configuration or EFI files.

**Persistent recovery backup is optional.** If you decline, recovery files are
kept under `/tmp/freebsd-dualboot.XXXXXXXX` on the installer and disappear on
reboot. If you accept, enter an existing writable directory on the medium where
you want to retain them. The script does not mount or format backup devices;
mount a pendrive beforehand if you want to use one. `/media/recovery` is only an
example, not a required mount point.

Command-line choices remain available. Specify a disk to skip the disk menu,
`--backup-dir` to skip the backup question with a chosen directory, or
`--no-backup` to skip it without a persistent external copy. For example:

```sh
sh /tmp/freebsd-zfs-geli-install.sh --backup-dir /media/recovery nda0
sh /tmp/freebsd-zfs-geli-install.sh --no-backup nda0
```

Replace `nda0` with your disk; `/dev/nda0` is also accepted. Do not combine the
two backup options.

A new session subdirectory is created; existing backup files are not replaced.
The script displays the backing filesystem. You must ensure this is the intended
persistent destination, preferably on another physical device. A path alone does
not prove persistence or independence from the installation disk. Use a trusted,
root-owned location that is not writable by other users. FAT recovery media should
be mounted with restrictive ownership and permissions too.

Review the plan and type `INSTALL nda0` when prompted. GELI asks for a passphrase
and asks for it again when attaching the new provider. The script never stores
that passphrase.

**Run the script only once.** In that execution it prepares the partitions,
GELI and ZFS, copies `/boot/loader.efi` from the **FreeBSD 15.1 installer media**
to `EFI/freebsd/loader.efi` on the existing ESP, verifies that copy, creates a
uniquely named UEFI entry and appends it to the original `BootOrder`.
It does not replace existing operating systems' EFI loaders or the fallback
`EFI/BOOT` loader.
Use installer media for the same release you are installing; this is not a
mechanism for booting a newer installation with an older loader.

After the script succeeds, **type `exit` and complete `bsdinstall` normally**.
No Live CD detour or second script command is required. Do not reboot before
`bsdinstall` finishes installing and saving the system configuration.

The previous default boot priority is retained. Select
`FreeBSD-<installation-id>` from your firmware's boot menu to boot FreeBSD.
The helper does not add entries to other operating systems' boot menus.
Firmware-specific behavior and the first encrypted boot still require a real
machine/VM test.

## Security and layout

- GPT sector boundaries are planned before writing, aligned to 1 MiB and bounded
  by the selected free region. Both partition start and size are explicit and
  checked after creation. Sizes that overflow the supported numeric range fail
  before partition changes.
- The selected disk's partition table is checked again after confirmation. GPT
  UUIDs are recorded for the ESP and new ZFS partition; the ESP identity is
  checked again before writing its loader.
- GELI uses AES-XTS, a 256-bit key, 4096-byte sectors and its default calibrated
  passphrase derivation. Encryption does not authenticate the EFI loader or provide
  a verified boot chain. The ESP remains unencrypted.
- Swap, when requested, uses a unique GPT label and FreeBSD's ephemeral `.eli`
  swap mechanism. Its random key is recreated on boot; it is not a persistent
  encrypted crash-dump destination.
- ZFS uses `ashift=12`, `compression=lz4`, `atime=off` and an initial
  `zroot/ROOT/default` boot environment. No force flag bypasses pool-creation
  safety checks. New pools use the installed OpenZFS default feature set; booting
  with older installer/loader releases is not promised.
- `/home`, `/tmp`, `/usr/ports`, `/usr/src` and selected `/var` datasets follow
  the current installer's layout. `/home` and those shared datasets are outside
  the root boot environment; switching a BE does not roll them back. `/tmp` is a
  ZFS dataset, not RAM-backed tmpfs. No fixed `vfs.root.mountfrom` pins subsequent
  boots to the initial BE.
- The ESP is listed at **`/efi`**, with its GPT UUID and `rw,noauto`, rather than
  `/boot/efi`. The reviewed 15.1 `bsdinstall bootconfig` manages the ESP only when
  it finds a `/boot/efi` entry. This avoids a second writer changing the loader
  or boot priority later in installation. After boot, use `mount /efi` for
  explicit loader maintenance, then `umount /efi`. Preserve existing operating
  systems' EFI loaders and the fallback EFI loader during maintenance too.
- Standard `BSDINSTALL_CHROOT`, `BSDINSTALL_TMPETC`, `BSDINSTALL_TMPBOOT` and
  `PATH_FSTAB` paths are respected. Paths must be absolute/canonical and have no
  whitespace. Existing installer plans/configuration are not silently reused.

## Recovery files and failures

The session contains the GPT before/after preparation, the original partition
layout and UEFI entries, an archive of the existing ESP, the confirmed sector
plan, and GELI metadata. During the same execution, a second copy of the
small recovery files (not the ESP archive) is placed in the target
`/root/dualboot-recovery`.

That internal copy **cannot recover an encrypted pool whose GELI metadata is
lost**. Save an external copy of `geli.metadata` and the ESP archive if you want
that protection. Treat metadata backups as sensitive; a backup made before a
passphrase change can retain access using that old passphrase. Follow `geli(8)`
when updating or retiring backups.

If the script fails, stop and inspect its error, session files, `gpart show -p`,
`geli status`, `zpool status` and `efibootmgr`. Do not continue `bsdinstall` after
failed preparation. Do not blindly rerun the helper: it deliberately refuses
partial installations and existing EFI files. No automatic partition deletion,
`zpool destroy`, GPT restoration or deletion of pre-existing boot entries occurs.
A created partition or EFI file can remain after a failure.

During UEFI entry creation, the helper tries to restore the original `BootOrder`
on failure or a catchable interruption. Firmware write failures, power loss or
`SIGKILL` cannot be recovered automatically. The original order is recorded in
`OLD_ORDER` and `uefi.before`; inspect the current entries before using
`efibootmgr -o` to restore it. An unsuccessful creation may leave an unreferenced
entry. GPT restore and GELI restore are recovery operations that require checking
the exact destination; they are intentionally not automated here.

## Validation

On a development host, no FreeBSD installation commands are executed by these
checks:

```sh
sh -n freebsd-zfs-geli-install.sh
python3 -B -m unittest discover -s tests -v
```

The host regression suite mocks FreeBSD commands. It covers size overflow,
512/4096-byte sector plans, bounds, mount checks, identifier parsing, interactive disk and backup selection, cancellation,
dry-run behavior, single-execution installation setup with and without swap and persistent backups,
preservation of existing OS and fallback EFI files, and failures of pool queries,
partition creation, GELI and UEFI writes (including a catchable interruption).
These checks do not establish that GELI, firmware, FAT, ZFS mounts or booting
work on a real FreeBSD system.

Before using this revision on a machine with valuable data, validate in a UEFI
VM with a disposable GPT disk containing an existing operating system and its ESP:

1. Install with/without swap and with a fixed/remaining-space ZFS size.
2. Compare all pre-existing partition boundaries and hashes of the existing EFI files;
   confirm existing boot priority and the fallback loader are unchanged.
3. Boot the existing operating system(s), then select FreeBSD in the firmware menu and unlock GELI.
4. Create and activate another BE with `bectl`; verify that it boots and `/home`
   remains shared.
5. Exercise insufficient ESP space, existing FreeBSD EFI files, a changed GPT,
   interrupted preparation and failed NVRAM writes. Review partial-state recovery.
6. Repeat on a 4Kn disk and verify the chosen firmware/Secure Boot configuration.

## Official references

Reviewed against the FreeBSD project's `releng/15.1` sources and documentation:

- [15.1 release notes](https://github.com/freebsd/freebsd-doc/blob/main/website/content/en/releases/15.1R/relnotes.adoc)
- [bsdinstall(8)](https://github.com/freebsd/freebsd-src/blob/releng/15.1/usr.sbin/bsdinstall/bsdinstall.8)
- [Installer flow](https://github.com/freebsd/freebsd-src/blob/releng/15.1/usr.sbin/bsdinstall/scripts/auto)
- [Installer boot configuration](https://github.com/freebsd/freebsd-src/blob/releng/15.1/usr.sbin/bsdinstall/scripts/bootconfig)
- [Installer unmount stage](https://github.com/freebsd/freebsd-src/blob/releng/15.1/usr.sbin/bsdinstall/scripts/umount)
- [Official ZFS/GELI setup](https://github.com/freebsd/freebsd-src/blob/releng/15.1/usr.sbin/bsdinstall/scripts/zfsboot)
- [gpart(8)](https://github.com/freebsd/freebsd-src/blob/releng/15.1/lib/geom/part/gpart.8)
- [geli(8)](https://github.com/freebsd/freebsd-src/blob/releng/15.1/lib/geom/eli/geli.8)
- [efibootmgr(8)](https://github.com/freebsd/freebsd-src/blob/releng/15.1/usr.sbin/efibootmgr/efibootmgr.8)
