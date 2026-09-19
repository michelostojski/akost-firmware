# Flash layout and backup

**Do this first.** Everything else in this repo assumes you have a full dump of
your camera's flash. It is your only route back to stock firmware, it is where
the vendor files come from, and it carries your camera's MAC address, serial
number and certificates — which no other copy can replace.

---

## The chip

| | |
| --- | --- |
| Part | XMC **XM25QH64C**, SPI NOR |
| Size | **8 MB** (8,388,608 bytes) |
| Interface | `spi0.0`, 40 MHz, PIO mode |

The Anyka driver misreports the size at boot:

```
akspi flash ID: 0x00204017
ak-spiflash spi0.0: xm25qh64c (16384 Kbytes)
```

That `16384 Kbytes` is wrong — the part number means 64 **Mbit**, which is
8 MB, and the partition table covers `0x0`–`0x800000` exactly with no gaps. If
you read the chip with an external programmer and get a 16 MB file, check
whether the second half simply mirrors the first:

```bash
cmp <(head -c 8388608 dump.bin) <(tail -c 8388608 dump.bin) \
  && echo "mirror — the chip is really 8 MB"
```

---

## Partition table

From the kernel command line (`cat /proc/cmdline`, the `mtdparts=` argument):

| mtd | Name | Offset | Size | Contents |
| --- | --- | --- | --- | --- |
| 0 | UBOOT | `0x0` | 256K | bootloader — never written by this firmware |
| 1 | ENV | `0x40000` | 4K | U-Boot environment |
| 2 | ENVBK | `0x41000` | 4K | environment backup |
| 3 | DTB | `0x42000` | 48K | device tree |
| 4 | KERNEL | `0x4e000` | 1800K | `uImage` |
| 5 | ROOTFS | `0x210000` | 1632K | squashfs, mounted `/` |
| 6 | CONFIG | `0x3a8000` | 400K | jffs2, mounted `/etc/config` — writable |
| 7 | APP | `0x40c000` | 4048K | squashfs, mounted `/usr` |

This firmware writes only KERNEL, ROOTFS and APP. UBOOT, ENV, ENVBK and DTB
are left untouched, which is what keeps the U-Boot SD-card recovery working
whatever happens to your rootfs.

Useful constants, in bytes and in 4K blocks:

| Partition | Offset | Size | `dd skip=` | `dd count=` |
| --- | --- | --- | --- | --- |
| KERNEL | 319488 | 1843200 | 78 | 450 |
| ROOTFS | 2162688 | 1671168 | 528 | 408 |
| APP | 4243456 | 4145152 | 1036 | 1012 |

---

## Taking the backup

### Option A — from the running camera, onto an SD card

Needs no disassembly. You need a root shell first (serial console, or the
[TECKIN SD-card boot hook](https://github.com/ThatUsernameAlreadyExist/TECKIN-TC100-Anyka-AK3918-camera-hacks)
on stock firmware). With a FAT32 card mounted at `/mnt`:

```sh
cd /mnt
for i in 0 1 2 3 4 5 6 7; do
  dd if=/dev/mtd$i of=/mnt/mtd$i.bin bs=4096
done
cat mtd0.bin mtd1.bin mtd2.bin mtd3.bin mtd4.bin mtd5.bin mtd6.bin mtd7.bin > full.bin
md5sum full.bin mtd*.bin > md5.txt
sync
```

`full.bin` must be exactly **8,388,608 bytes**. The partitions cover the chip
end to end, so concatenating them in order reproduces the whole flash.

Wait for `sync` to return before pulling the card.

### Option B — read the chip with a CH341A programmer

The exact contents, and the copy you'd need if the camera ever stops booting
entirely. **The camera must be unpowered** if you read in-circuit with a clip.

```bash
sudo apt install flashrom
sudo flashrom -p ch341a_spi -r dump1.bin
sudo flashrom -p ch341a_spi -r dump2.bin
cmp dump1.bin dump2.bin && echo "reads match"
```

Two reads that don't match mean a bad connection — reseat the clip. A bad read
here would make a bad recovery image, which defeats the point.

### Doing both

```bash
cmp full.bin dump1.bin && echo identical
```

A few bytes may differ inside the CONFIG region (`0x3a8000`–`0x40c000`),
because it is a mounted, writable jffs2 filesystem during a software dump.
Differences anywhere else mean one of the reads is wrong.

---

## Verifying the dump

Check the partition boundaries by their magic numbers before trusting it:

```bash
xxd -s 0x42000  -l 4 full.bin    # d00d feed   device tree
xxd -s 0x4e000  -l 4 full.bin    # 2705 1956   uImage
xxd -s 0x210000 -l 4 full.bin    # 6873 7173   squashfs ("hsqs")
xxd -s 0x40c000 -l 4 full.bin    # 6873 7173   squashfs
```

And confirm the checksums:

```bash
cd /path/to/backup && md5sum -c md5.txt
```

---

## Where to keep it

**Two places, at least one of them not your build machine.** A USB stick or
another computer. The stock dump is the single thing in this whole project that
cannot be rebuilt.

Do not publish it. It contains vendor binaries plus your camera's identity
(MAC, serial, device certificates in the CONFIG partition).

---

## What the dump is used for

```bash
# populate the vendor files the build needs
scripts/extract-vendor-blobs.sh /path/to/full.bin
```

That unpacks ROOTFS and APP, and copies out the Anyka libraries, the stock
kernel modules, the vendor-patched `cfg80211.ko`, stock's `hostapd` and the ISP
sensor tuning — see the README for what each one is and why it's needed.

For recovery, the individual partition files are what you want:

| Backup file | Goes back as |
| --- | --- |
| `mtd4.bin` | `uImage` |
| `mtd5.bin` | `root.sqsh4` |
| `mtd7.bin` | `usr.sqsh4` |

See [03-flashing-and-recovery.md](03-flashing-and-recovery.md).

---

## Inspecting stock without flashing anything

Worth doing before you change the firmware — the stock system is the reference
for which modules load, in what order, and with what parameters.

```bash
unsquashfs -d stock_root mtd5.bin      # rootfs
unsquashfs -d stock_app  mtd7.bin      # /usr

cat stock_root/etc/init.d/rc.local     # mounts /usr and /etc/config, runs main.sh
cat stock_app/sbin/main.sh             # the module load order this firmware copies
cat stock_app/sbin/sensor_module_load.sh
cat stock_app/sbin/wifi_module_load.sh
find stock_root/lib/modules -name "*.ko"   # implies kernel options you need
```

That last command is how the `CONFIG_USB_MON` requirement was discovered — see
[05-troubleshooting.md](05-troubleshooting.md).

And the bootloader's own capabilities, read from the running camera:

```sh
strings /dev/mtd0 | grep -iE "update|fatload|mmc"
strings /dev/mtd1 | grep -iE "loadaddr|bootargs"
```
