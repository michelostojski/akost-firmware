# Flashing and recovery

Two ways in, and one way back. Read the recovery section before you flash
anything.

| Route | Works when | Needs |
| --- | --- | --- |
| **U-Boot SD** | always, even with a broken rootfs | reset button, FAT32 card |
| **autoupdate** | camera boots this firmware | FAT32 card |
| SPI programmer | camera doesn't boot at all | CH341A, opening the case |

U-Boot is never written by any of this, which is what keeps the first route
available no matter how badly a build goes.

---

## Before the first flash

- A verified backup — see
  [01-flash-layout-and-backup.md](01-flash-layout-and-backup.md)
- A **recovery card** prepared (below), or the stock files ready to copy onto one
- Ideally a serial console at 115200 8N1. Not required, but without it a
  camera that doesn't come back tells you nothing about why

### Preparing the recovery card

Do this now, not after something goes wrong:

```bash
mkdir -p ~/anyka-backup/recovery-card
cd ~/anyka-backup
cp mtd4.bin recovery-card/uImage
cp mtd5.bin recovery-card/root.sqsh4
cp mtd7.bin recovery-card/usr.sqsh4
echo update > recovery-card/test_file
```

Those four files on a FAT32 card restore stock firmware completely.

---

## First install: the U-Boot SD method

Stock U-Boot has a built-in updater that runs **before Linux**, so it works
regardless of what is on the camera.

**Files in the root of a FAT32 card:**

| File | Written to |
| --- | --- |
| `uImage` | KERNEL |
| `root.sqsh4` | ROOTFS |
| `usr.sqsh4` | APP |
| `test_file` | the trigger — any short text file |

```bash
B=~/anyka-build
SD=/media/$USER/XXXX-XXXX          # check with lsblk
I=$B/images

[ -n "$SD" ] && mountpoint -q "$SD" && {
  rm -f "${SD:?}"/uImage "${SD:?}"/root.sqsh4 "${SD:?}"/usr.sqsh4 "${SD:?}"/test_file
  cp $I/uImage          "$SD/uImage"
  cp $I/rootfs.squashfs "$SD/root.sqsh4"
  cp $I/app.squashfs    "$SD/usr.sqsh4"
  echo update >         "$SD/test_file"
  sync
  cmp $I/uImage "$SD/uImage" && cmp $I/rootfs.squashfs "$SD/root.sqsh4" \
    && cmp $I/app.squashfs "$SD/usr.sqsh4" && echo "all OK"
  cd ~; umount "$SD" && echo "card can be removed"
}
```

Always `cmp` after copying — a returned `sync` doesn't guarantee the card holds
what you think.

**Then:**

1. Insert the card
2. **Hold the reset button, apply power, keep holding ~10 s**
3. Wait a minute or two — the APP write is the slow one
4. Power off, **remove the card**, power on

On the serial console you'll see each partition erased and written:

```
[down_and_update_mmc] cmd: fatload mmc 0 0x82008000 usr.sqsh4
SF: 4145152 bytes @ 0x40c000 Erased: OK
SF: 2232320 bytes @ 0x40c000 Written: OK
...
** Unable to read file usr.jffs2 **
fat32 image update down
```

The `usr.jffs2` line is expected — U-Boot also looks for a CONFIG image, and we
deliberately don't supply one, so `/etc/config` is left alone.

### What not to put on that card

U-Boot will also flash `u-boot.bin`, `anyka_ev500.dtb` and `usr.jffs2` if it
finds them. **Never include `u-boot.bin`** — a failed bootloader write is
unrecoverable without an SPI programmer, and there is no reason to touch it.

---

## Updates: `autoupdate-full.bin`

Once the camera runs this firmware, updates need no button.

```bash
SD=/media/$USER/XXXX-XXXX
I=~/anyka-build/images

[ -n "$SD" ] && mountpoint -q "$SD" && {
  rm -f "${SD:?}"/uImage "${SD:?}"/root.sqsh4 "${SD:?}"/usr.sqsh4 "${SD:?}"/test_file \
        "${SD:?}"/autoupdate-full.* "${SD:?}"/autoupdate.log
  cp $I/autoupdate-full.bin $I/autoupdate-full.bin.md5 "$SD/"
  sync
  cmp $I/autoupdate-full.bin "$SD/autoupdate-full.bin" && echo "image OK"
  cd ~; umount "$SD" && echo "card can be removed"
}
```

Insert the card and **power on normally** — no button. `S05autoupdate` runs
early in boot and:

1. waits for `/dev/mmcblk0p1`, mounts it
2. checks the image is 8,388,608 bytes
3. checks the magic numbers at `0x4e000`, `0x210000` and `0x40c000`
4. verifies the `.md5` if present
5. confirms the partition table matches
6. copies BusyBox and the libraries into RAM, unmounts `/usr`, and flashes
   APP, KERNEL and ROOTFS from the `chroot`
7. renames the image to `autoupdate-full.done` and reboots

Afterwards the card holds `autoupdate.log`. A rejected image becomes
`autoupdate-full.bad` and nothing is written.

Flashing from a RAM copy matters: `/` is mtd5 and `/usr` is mtd7, so
overwriting them while running from them would crash halfway through.

**Don't mix the two methods on one card.** A card holding both `test_file` and
`autoupdate-full.bin` will do different things depending on whether you hold
the button.

---

## Recovery

### The camera boots but misbehaves

Use either route above with a known-good image. If the firmware boots far
enough to run `S05autoupdate`, the no-button method works.

### The camera doesn't boot

The U-Boot method still works — it runs before Linux. Copy the four recovery
files onto a card, hold reset, power on. This restores stock firmware.

To go back to your own build afterwards, flash it the same way.

### U-Boot itself doesn't start

Nothing on the card helps; U-Boot is what reads the card. This means an SPI
programmer and opening the case.

```bash
sudo flashrom -p ch341a_spi -w full.bin
```

That's why nothing here ever writes UBOOT, ENV or DTB.

---

## Writing with an SPI programmer

If you're already inside the camera with a clip attached, you can flash
directly — but **not** with `autoupdate-full.bin`, whose bootloader region is
blank. Build a full image on top of your backup instead:

```bash
cd ~/anyka-build/images
BK=~/anyka-backup/full.bin
[ "$(stat -c%s $BK)" -eq 8388608 ] || echo "backup is not 8 MB!"
cp $BK firmware_new.bin

put() {   # put <image> <offset> <partition size>
  [ "$(stat -c%s $1)" -le "$3" ] || { echo "TOO BIG: $1"; return 1; }
  head -c $3 /dev/zero | tr '\0' '\377' | \
    dd of=firmware_new.bin bs=1 seek=$(($2)) conv=notrunc status=none
  dd if=$1 of=firmware_new.bin bs=4096 seek=$(($2/4096)) conv=notrunc status=none
}
put uImage          0x04e000 1843200
put rootfs.squashfs 0x210000 1671168
put app.squashfs    0x40c000 4145152
stat -c%s firmware_new.bin        # must still be 8388608
```

Each partition is filled with erased-flash bytes before its image is written,
so no remnants of the previous contents survive.

Verify the regions that should not have changed:

```bash
cmp -n 319488 $BK firmware_new.bin              # 0x0-0x4e000, boot area
cmp -i 3833856 -n 409600 $BK firmware_new.bin   # CONFIG
```

Both silent means only the three partitions differ. Then write just those
regions, leaving the bootloader alone:

```bash
cat > layout.txt << 'EOF'
0004e000:0020ffff kernel
00210000:003a7fff rootfs
0040c000:007fffff app
EOF

sudo flashrom -p ch341a_spi -w firmware_new.bin \
  --layout layout.txt --image kernel --image rootfs --image app
```

flashrom erases, writes and verifies only those regions and should end with
`VERIFIED`. **If it doesn't, don't power the camera on** — investigate first.

---

## After the first boot

The camera has no Wi-Fi credentials, so it provisions itself through the setup
portal — see [04-wifi-portal.md](04-wifi-portal.md).

With a serial console, check:

```sh
uname -v                              # your build date
mount | grep -E "usr|config"          # both partitions mounted
lsmod                                 # ~16 modules
ip addr show wlan0
```

If the boot log shows `rcS: applet not found`, or no modules load, or the AP
never appears, see [05-troubleshooting.md](05-troubleshooting.md) — those exact
symptoms are documented there.
