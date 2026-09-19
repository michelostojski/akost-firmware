# Building

What you need, in order: a flash dump of your camera, the vendor SDK (for the
toolchain and kernel source), Buildroot, and about 20 minutes for a first
build.

---

## Prerequisites

### Host packages

```bash
sudo apt install build-essential git wget cpio unzip rsync bc \
                 libncurses-dev squashfs-tools file gawk
```

`squashfs-tools` is needed by the extraction script; Buildroot builds its own
`mksquashfs` for the images.

### Buildroot

Tested with **2025.02.18**:

```bash
cd ~
wget https://buildroot.org/downloads/buildroot-2025.02.18.tar.gz
tar xf buildroot-2025.02.18.tar.gz
```

### The vendor SDK

The Anyka/Tuya GPL drop supplies two things this build needs: the
`arm-anykav500-linux-uclibcgnueabi` toolchain and the 4.4.192 kernel source.
Find the GPL source release for your camera's vendor — for the GNCC GK2 that is
the Tuya BSP public components package. Unpack it somewhere stable; the
toolchain path goes into the defconfig.

### Your flash dump

See [01-flash-layout-and-backup.md](01-flash-layout-and-backup.md). Nothing
below works without it.

---

## Getting the sources in place

```bash
git clone https://github.com/michelostojski/akost-firmware.git
cd akost-firmware
F=$(pwd)
B=~/anyka-build          # output directory, anywhere you like
```

### Vendor files

```bash
scripts/extract-vendor-blobs.sh ~/anyka-backup/full.bin
```

This unpacks the ROOTFS and APP partitions from your dump and populates:

| Destination | What |
| --- | --- |
| `package/anyka-libs/lib/` | ~23 Anyka media libraries |
| `package/anyka-libs/etc/` | ISP sensor tuning (`isp_f37p_*.conf`) |
| `package/anyka-modules/files/` | 15 stock kernel modules |
| `board/anyka/stock/cfg80211.ko` | vendor-patched wireless module |
| `board/anyka/stock/hostapd` | stock hostapd 2.8 |

None of it is committed — `.gitignore` keeps it out. The script verifies
`vermagic` on every module and reports which sensor modules your camera
actually has, which matters if you're not on a JXF37 board.

### Kernel source

The defconfig expects the vendor kernel tarball here:

```bash
mkdir -p dl
cp /path/to/sdk/linux-ak-4.4.192.tar.gz dl/
```

(~140 MB, which is why it isn't in the repo.)

---

## Configuration

```bash
cd ~/buildroot-2025.02.18
make O=$B BR2_EXTERNAL=$F gncc_gk2_defconfig
```

Two settings **must** be edited before building — either in
`configs/gncc_gk2_defconfig` before the command above, or in `$B/.config`
after it:

**Toolchain path.** Points into your unpacked SDK:

```
BR2_TOOLCHAIN_EXTERNAL_PATH="/path/to/sdk/arm-anykav500-linux-uclibcgnueabi/arm-anykav500-linux-uclibcgnueabi"
```

**Root password.** Ships empty, and dropbear refuses empty-password logins, so
leaving it means no SSH access:

```
BR2_TARGET_GENERIC_ROOT_PASSWD="something"
```

It is stored in plain text in `.config` and in any defconfig you save, so don't
reuse a password that matters.

After editing `.config` directly:

```bash
make O=$B BR2_EXTERNAL=$F olddefconfig
```

---

## Building

```bash
make O=$B BR2_EXTERNAL=$F
```

First build takes 15–30 minutes, mostly kernel and OpenSSL. It ends with the
partition size checks:

```
OK: uImage 1679288 / 1843200
OK: rootfs.squashfs 1015808 / 1671168
OK: app.squashfs 3858432 / 4145152
OK: autoupdate-full.bin
```

A failure there means an image outgrew its partition — see *Size pressure*
below.

### Output

| `$B/images/` | Purpose |
| --- | --- |
| `uImage` | KERNEL partition |
| `rootfs.squashfs` | ROOTFS partition |
| `app.squashfs` | APP partition (`/usr`) |
| `autoupdate-full.bin` | 8 MB image for the SD-card updater |
| `autoupdate-full.bin.md5` | checksum the updater verifies |

`autoupdate-full.bin` has **blank (0xFF) UBOOT, ENV, DTB and CONFIG regions** —
only the three partitions this firmware owns carry data. It is for the SD-card
updater only. **Never write it with an SPI programmer**; that would erase your
bootloader.

---

## How the build is put together

Worth knowing if you need to change something.

**The `/usr` split.** ROOTFS is 1632K, which isn't enough for the whole system,
so `post-fakeroot.sh` moves `/usr` into its own squashfs for the APP partition
— the same division stock uses — and leaves an empty `/usr` in the rootfs for
the mount. `S03modules`' fstab entry mounts `/dev/mtdblock7` there at boot.

**Board scripts**, wired in through `BR2_ROOTFS_POST_*_SCRIPT`:

| Script | Does |
| --- | --- |
| `post-build.sh` | fstab entry, prunes unneeded kernel modules, installs stock `cfg80211.ko` and `hostapd`, moves `libssl` to the rootfs |
| `post-fakeroot.sh` | splits `/usr` into `app.squashfs` |
| `post-image.sh` | partition size checks, assembles `autoupdate-full.bin` |

**Packages:**

| Package | Installs |
| --- | --- |
| `anyka-libs` | vendor libraries to **both** target and staging (`ipcd` links against staging), plus the ISP config |
| `anyka-modules` | `ak_mci.ko` into the rootfs (so SD updates survive a broken APP), the other 14 into `/usr/modules` |
| `ipcd` | fetched from the [gk2-ptz fork](https://github.com/michelostojski/ipcd) by tag; installs the binary and `librt.so` |

**BusyBox** gets `udhcpd`, `pgrep` and `pkill` from
`board/anyka/busybox-extra.fragment` — the first two are needed by the setup
portal.

---

## Common build problems

**A config change appears to do nothing.** Buildroot does not rebuild a package
when its options change:

```bash
make O=$B BR2_EXTERNAL=$F <pkg>-dirclean
```

For the kernel, `linux-rebuild` ignores edits to `linux.config` — use
`linux-reconfigure`.

**`ipcd` fails to link with missing symbols.** `anyka-libs` must install to
staging (`ANYKA_LIBS_INSTALL_STAGING = YES`). Check:

```bash
ls $B/staging/usr/lib | grep plat_mem
```

**Size pressure.** APP has ~280 KB free and ROOTFS ~650 KB. If you add
packages and overflow APP, the tricks already used are: move a library to the
rootfs in `post-build.sh` (`/lib` is on the loader path — that's how `libssl`
is handled), disable unused OpenSSL ciphers, and `-Xbcj arm` on `mksquashfs`.

**Verify what's actually in the images**, rather than what should be:

```bash
$B/host/bin/unsquashfs -l $B/images/app.squashfs | grep -E "sbin/(hostapd|udhcpd)$"
$B/host/bin/unsquashfs -l $B/images/rootfs.squashfs | grep "init.d/S"
```

More in [05-troubleshooting.md](05-troubleshooting.md).

---

## Saving your configuration

```bash
make O=$B BR2_EXTERNAL=$F savedefconfig BR2_DEFCONFIG=$F/configs/gncc_gk2_defconfig
```

This writes your settings back so a wiped output directory rebuilds the same.
Remember it also writes your root password and toolchain path — check before
committing.

Next: [03-flashing-and-recovery.md](03-flashing-and-recovery.md).
