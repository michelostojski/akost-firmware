# akost-firmware
# Anyka AK39EV330 Open-Source Firmware

Open-source Linux firmware for **Anyka AK39EV330 IP cameras**.
Buildroot firmware for **Anyka AK39EV330** cameras — currently the **GNCC GK2**
and **GNCC GT1 Pro** (and their Nooie / AK\_IPC rebadges). Replaces the stock
cloud firmware entirely:
a Buildroot rootfs with SSH, an SD-card update mechanism, the vendor kernel and
media drivers, and [`ipcd`](https://github.com/medevil84/ipcd) providing RTSP,
ONVIF and Wi-Fi provisioning.

No cloud, no vendor app, no account.

> **Built on two projects.** [`ipcd`](https://github.com/medevil84/ipcd) by
> medevil (MIT) is the daemon that does the actual camera work — this repo
> packages it, boots it, and adds PTZ support for the GK2's pan/tilt hardware.
> [thingino](https://github.com/themactep/thingino-firmware) is the model for
> how a camera firmware should provision and update itself; the SD-card
> `autoupdate-full.bin` convention here follows theirs.

> **Educational purpose.** This touches raw SPI flash, vendor kernel modules and
> the bootloader. You can brick hardware. Do it only on cameras you own and are
> willing to lose. Nothing here is warranted.

**Related:** to keep stock firmware and only add local ONVIF PTZ and Frigate
autotracking, see
[gncc-gk2-anyka-ak39ev330-ipcd-ptz](https://github.com/michelostojski/gncc-gk2-anyka-ak39ev330-ipcd-ptz)
— that runs `ipcd` from an SD card with no flashing. This repo replaces the
firmware.

---

## Supported cameras

| | GNCC GK2 | GNCC GT1 Pro |
| --- | --- | --- |
| Sensor | JX-F37, 1920x1080 | JX-Q03, 2304x1296 |
| MIPI lanes | 1 | 2 |
| DMA reservation | 20 MB | 28 MB |
| Pan/tilt | yes, ONVIF PTZ | fixed camera |
| Status | working | working |

Both run the **same firmware and the same `ipcd`**. Resolution and DMA pool
sizes are detected at runtime; the sensor module and ISP tuning come from your
own flash dump. Only a few things have to be set per camera — orientation, the
IR day/night threshold and the exposure cap — and those are documented in
[docs/06-supported-cameras.md](docs/06-supported-cameras.md), along with the
open questions where help would be welcome.

Adding a third camera on this SoC should mostly be steps 1 to 4 of that
document; the vendor ships byte-identical libraries and modules across these
boards, with only the sensor driver differing.

## What works

| Feature | Status | Notes |
| --- | --- | --- |
| Buildroot 2025.02 rootfs | ✅ | BusyBox init, read-only squashfs |
| 1080p H.264 main + 360p sub RTSP | ✅ | `ipcd`, `rtsp://<ip>:8554/main` |
| Audio (G.711 μ-law) | ✅ | `ipcd` |
| Wi-Fi client (WPA2 / WPA3) | ✅ | ATBM603x, vendor `cfg80211` |
| **Captive-portal setup** | ✅ | `ipcd`'s portal, working on this driver |
| **ONVIF PTZ** | ✅ | fork additions: pan/tilt steppers, Frigate autotracking |
| SSH (dropbear) | ✅ | host key regenerated each boot — see limitations |
| SD-card firmware update | ✅ | `autoupdate-full.bin`, power on, no button |
| U-Boot SD recovery | ✅ | works even when the rootfs is broken |
| Sensor / ISP / motors | ✅ | stock vendor modules, unmodified |
| Persistent config | ✅ | jffs2 CONFIG partition at `/etc/config` |

### Known limitations

- **No dropbear host-key persistence** — SSH warns about a changed key after
  every reboot. Fixable by storing the key on the CONFIG partition.
- **Low entropy at boot.** No hwrng on this SoC; `seedrng` has no writable
  `/var/lib` this early. Harmless with an open portal AP, but a WPA-protected
  AP can stall on the group-key handshake at cold boot.
- **Provisioning ends in a reboot** rather than an in-place switch — the ATBM
  driver refuses `nl80211` mode changes on a live interface. Deliberate.
- **Kernel is the vendor 4.4.192**, not mainline. The prebuilt vendor modules
  bind to it, so this is unlikely to change.
- **Edge colour fringing** on the GK2 from ISP sharpening baked into the JX-F37
  sensor config; not overridable at runtime. Cosmetic.
- **The GK2's colour is sensitive to any ISP call.** `isp_set_flip_mirror()` or
  `AK_ISP_set_sharp_attr()` — even with neutral values — leave the picture pink
  and washed out; leaving both out gives a correct image. The GT1 Pro is
  unaffected by the same calls. Not understood; see
  [docs/06-supported-cameras.md](docs/06-supported-cameras.md).
- **Day/night chroma switch disabled**, because `ak_venc_set_attr()` is fatal
  with the reverse-engineered `encode_param` layout. Costs the IR tint
  correction at night.

---

## Hardware

- **SoC:** Anyka AK39EV330 (`ak3918ev330`), kernel `4.4.192V2.1`
- **Sensor:** GK2 — JX-F37 (probes as `jxfxx`), MIPI 1-lane;
  GT1 Pro — JX-Q03 (probes as `q03p`), MIPI 2-lane
- **Motors:** GK2 only — two `HZF-24BYJ48` steppers via `ak_motor`
  (`/dev/motor0` pan, `/dev/motor1` tilt). The GT1 Pro is a fixed camera and
  its device tree declares no motor pins.
- **Wi-Fi:** AltoBeam ATBM603x, USB-attached (`atbm603x_x_usb`, creates
  `wlan0` + `wlan1`)
- **Flash:** XMC **XM25QH64C, 8 MB** SPI NOR. The Anyka driver prints
  `xm25qh64c (16384 Kbytes)` — that size is wrong; the part is 64 Mbit and the
  partition table covers `0x0`–`0x800000` exactly.

### Partition layout

| mtd | Name | Offset | Size | Contents |
| --- | --- | --- | --- | --- |
| 0 | UBOOT | `0x0` | 256K | never written by this firmware |
| 1 | ENV | `0x40000` | 4K | never written |
| 2 | ENVBK | `0x41000` | 4K | never written |
| 3 | DTB | `0x42000` | 48K | never written |
| 4 | KERNEL | `0x4e000` | 1800K | `uImage` |
| 5 | ROOTFS | `0x210000` | 1632K | `rootfs.squashfs` |
| 6 | CONFIG | `0x3a8000` | 400K | jffs2, mounted `/etc/config` |
| 7 | APP | `0x40c000` | 4048K | `app.squashfs`, mounted `/usr` |

ROOTFS alone is too small for the whole system, so the build splits `/usr` into
its own squashfs for APP — the same division stock uses. `post-fakeroot.sh`
does the split; `post-image.sh` fails the build if any image exceeds its
partition.

---

## What this repo contains — and what it does not

Everything here is original work: Buildroot package recipes, board scripts,
init scripts, kernel config, helper scripts and documentation.

`ipcd` is **not** vendored — it is fetched from a
[fork](https://github.com/michelostojski/ipcd) of medevil's repo (MIT), so the
GK2-specific additions stay visible as a diff against upstream rather than
buried in a copy. See *Credits* for what the fork changes.

**No vendor binaries are included.** Anyka's shared libraries, the stock kernel
modules, the vendor-patched `cfg80211.ko` and stock's `hostapd` are not mine to
redistribute — and you already have them, on the camera in front of you. The
build extracts them from **your own** flash dump.

`scripts/extract-vendor-blobs.sh` does this from a `full.bin` dump and verifies
what it finds. The next section documents each file by hand, both so the script
is auditable and so you can do it yourself if your camera differs.

---

## Vendor files: what's needed and where it comes from

All of these come out of a full flash backup of your own camera (see
`docs/01-flash-layout-and-backup.md`). Unpack the two squashfs partitions
first:

```bash
unsquashfs -d stock_root mtd5.bin    # ROOTFS
unsquashfs -d stock_app  mtd7.bin    # APP
```

### 1. Anyka userspace libraries → `external/package/anyka-libs/lib/`

`ipcd` links against the vendor media stack: `libplat_*.so`, `libmpi_*.so`,
`libapp_*.so`, `libak*.so` — 23 libraries. Copy `lib/*.so*` from `stock_app`,
plus `etc/isp_f37p_mipi_1lane_h3b.conf` (the ISP tuning for the JXF37 sensor)
from the same place.

The package installs these to **both** `target/` and `staging/` —
`ANYKA_LIBS_INSTALL_STAGING = YES` — because `ipcd` links against staging. Omit
that and the build fails at the link step with missing symbols.

`librt.so` is a separate trap: it has no SONAME, so Buildroot's external
toolchain step never copies it to the target even though `ipcd` declares it
`NEEDED`. The `ipcd` package installs it explicitly from `STAGING_DIR`.

### 2. Stock kernel modules → `external/package/anyka-modules/files/`

Fifteen `.ko` files from `stock_app/modules/`:

```
ak_rtc ak_i2c ak_pcm ak_gpio_keys ak_ion ak_leds ak_mci ak_uio
exfat ak_motor ak_saradc ak_isp sensor_f37p ak_hcd atbm603x_x_usb
```

Do **not** take them from a vendor SDK tarball — SDK builds target a different
camera (`sensor_sc2336`, `rtl8188ftv`) and lack `ak_motor`, `ak_leds`,
`ak_saradc` and `exfat`.

`ak_mci.ko` (SD card) is installed into the **rootfs** rather than APP, so the
SD-card updater still works if the APP partition is broken. The rest go to
`/usr/modules`, as on stock.

Check compatibility before building: every module's `vermagic` must read
`4.4.192V2.1 mod_unload ARMv5`, and `scripts/check-module-symbols.sh` compares
each module's undefined symbols against your kernel's `System.map`. Note that a
passing symbol check proves *names* exist, not that structures match — see the
USB bug below.

### 3. Vendor-patched `cfg80211.ko` → `external/board/anyka/stock/`

**From `stock_root`**, not from APP:

```
stock_root/lib/modules/4.4.192V2.1/kernel/net/wireless/cfg80211.ko
```

Your kernel builds its own `cfg80211` from the SDK source, and it does not
work. The vendor patched their wireless stack — their build exports
`cfg80211_external_auth_request`, `nl80211_external_auth` and
`cfg80211_autodisconnect_wk`, which the SDK source lacks — and those patches
change the shared Wi-Fi structures. Loading `atbm603x_x_usb` against the
SDK-built `cfg80211` faults in `wiphy_update_regulatory` and takes the kernel
with it.

`post-build.sh` installs the stock module over the one the kernel built. No
kernel config option fixes this.

### 4. Stock `hostapd` (v2.8) → `external/board/anyka/stock/`

From `stock_app/sbin/hostapd`. Needed only for the setup portal.

Modern hostapd (2.12, what Buildroot ships) cannot drive this chip:

```
nl80211: Register frame command failed (type=176): ret=-95 (Operation not supported)
nl80211: Could not configure driver mode
```

The ATBM driver doesn't implement management-frame registration and reports
`device_ap_sme=0`, so hostapd must handle authentication itself. Stock's 2.8
falls back to a monitor interface (`use_monitor=1`) — a path later versions
dropped — and brings the AP up fine. Both `wlan0` and `wlan1` behave the same
way, so this isn't an interface-selection problem.

With this in place you can drop `BR2_PACKAGE_HOSTAPD` from the build and
recover ~900 KB in the APP partition.

hostapd is BSD-licensed, so its binary could in principle be redistributed;
it's extracted like everything else for consistency.

---

## Building

```bash
# Buildroot 2025.02.18, built out of tree
B=/path/to/output
F=/path/to/akost-firmware/external
cd /path/to/buildroot-2025.02.18
make O=$B BR2_EXTERNAL=$F gncc_gk2_defconfig
make O=$B BR2_EXTERNAL=$F
```

Before the first build, extract the vendor files:

```bash
scripts/extract-vendor-blobs.sh ~/anyka-backup/full.bin $F
```

The build fails early and loudly if they're missing.

**Set a root password.** The shipped defconfig has
`BR2_TARGET_GENERIC_ROOT_PASSWD=""`, and dropbear refuses empty-password
logins, so set your own before building or you'll have no SSH access.

Output in `$B/images/`:

| File | Purpose |
| --- | --- |
| `uImage` | kernel |
| `rootfs.squashfs` | ROOTFS partition |
| `app.squashfs` | APP partition (`/usr`) |
| `autoupdate-full.bin` | 8 MB image for the SD-card updater |

`autoupdate-full.bin` has **blank (0xFF) UBOOT, ENV, DTB and CONFIG regions** —
only KERNEL, ROOTFS and APP carry data. It is for the SD-card updater only.
**Never write it to the chip with an SPI programmer**; that would erase your
bootloader. For programmer use, build a full image on top of your own
`full.bin` (see `docs/03-flashing-and-recovery.md`).

`scripts/gk2-update.sh` wraps build, image verification and SD-card copying,
with guards against writing to the wrong path.

---

## Flashing

### First install: U-Boot SD method

Stock U-Boot has a built-in updater that runs before Linux, so it works
regardless of what's on the camera. FAT32 card, files in the root:

| File | Written to |
| --- | --- |
| `uImage` | KERNEL |
| `root.sqsh4` | ROOTFS |
| `usr.sqsh4` | APP |
| `test_file` | trigger (any short text) |

Hold the **reset button while powering on**, keep holding ~10 s. Power off,
remove the card, power on.

U-Boot also accepts `u-boot.bin`, `anyka_ev500.dtb` and `usr.jffs2`. **Never
put those on the card** — a bad U-Boot write is unrecoverable without an SPI
programmer.

This is also your recovery path: put your stock `mtd4.bin` / `mtd5.bin` /
`mtd7.bin` on a card as `uImage` / `root.sqsh4` / `usr.sqsh4` and you're back
to stock.

### Later updates: `autoupdate-full.bin`

Copy `autoupdate-full.bin` and its `.md5` to the card, insert, **power on
normally** — no button. `S05autoupdate` verifies size, partition magic numbers
and checksum, flashes from a RAM copy of BusyBox, renames the image to `.done`
and reboots. It writes `autoupdate.log` to the card and renames a rejected
image to `.bad`.

---

## Wi-Fi setup portal

The captive portal is **`ipcd`'s own feature** — upstream implements AP
fallback, the setup page, credential storage and a DNS spoofer. What this repo
adds is making it work on the GK2's hardware, which needed three things:

- **Stock hostapd 2.8**, because 2.12 cannot drive the ATBM chip (above).
- **`S60ipcd` owns the AP, not `ipcd`.** `ipcd` verifies its AP through
  hostapd's control socket and times out after 12 s even though hostapd reports
  `AP-ENABLED`, then tears it down. Starting `ipcd` first, letting its AP
  attempt fail, and raising hostapd + `udhcpd` behind it sidesteps the check.
- **Provisioning ends in a reboot**, because the driver won't return `wlan0`
  from AP to station mode in place (`nl80211: Could not configure driver mode`,
  even after `ifconfig down`/`up`). A watcher in `S60ipcd` reboots once
  `wifi.conf` appears.

What a freshly flashed camera does, unattended:

1. Boots with no `/etc/config/wifi.conf`.
2. `ipcd` starts, attempts AP mode, fails, then keeps serving HTTP on `:80` and
   DNS on `:53`.
3. `S60ipcd` raises the AP: `hostapd` (open, SSID `AKOST-xxxx` from the MAC),
   `wlan0` at `10.1.8.1`, `udhcpd` serving `10.1.8.20`–`.254` with DNS pointed
   at the camera.
4. The DNS spoofer answers every query with `10.1.8.1`, so the phone's
   captive-portal probe fails and the setup page opens by itself.
5. You enter your network's credentials; `ipcd` writes `wifi.conf`; the watcher
   reboots.
6. The camera comes up in station mode and joins your network.

The AP is **open**, as thingino's is, so no shared secret is needed to set up a
camera. It exists only while the camera has no credentials.

`hostapd.conf` and `udhcpd.conf` defaults ship in the rootfs at `/etc/` and are
copied to `/etc/config/` when missing, so a wiped CONFIG partition still gets a
working portal.

---

## Four bugs worth knowing about

Each cost hours and pointed somewhere other than its cause. Full write-ups in
`docs/05-troubleshooting.md`.

**1. `rcS: applet not found` — nothing ran at boot.**
`CONFIG_BINFMT_SCRIPT` was off, so the kernel couldn't execute `#!/bin/sh`
files. Init's attempt fell back to `/bin/sh` named `rcS`, and BusyBox looked
for an applet by that name. Scripts run from an interactive shell still worked,
which hid the cause.

**2. Wi-Fi chip never enumerated — the `io mem 0x00000000` tell.**
`ak_hcd` logged `####connent happen` (chip connected) but no `usb 1-1` ever
appeared. One `dmesg` line differed from stock: stock printed
`io mem 0x20200000`, ours `0x00000000`. Cause: stock builds `CONFIG_USB_MON=m`,
which adds two fields near the start of `struct usb_bus` and shifts everything
after it. The prebuilt module wrote one offset, the kernel read another. Found
by listing the modules in the stock rootfs — the presence of `usbmon.ko`
revealed the option.

**3. Kernel fault in `wiphy_update_regulatory`.**
The vendor-patched `cfg80211`, described above.

**4. `ipcd` fell back to AP mode with Wi-Fi working.**
Its log said `association failed … likely entropy issue at cold boot`. The real
message was two lines earlier: `Line 5: invalid key_mgmt 'SAE'`. `ipcd` writes
a WPA3-capable `wpa_supplicant` block, and `wpa_supplicant` had been built
without WPA3, so it rejected the whole network block. Fixed with
`BR2_PACKAGE_WPA_SUPPLICANT_WPA3=y` — which pulls in OpenSSL and overflows the
APP partition, so `libssl` moves to the rootfs and unused ciphers are trimmed.

---

## Repo layout

```
external/                      BR2_EXTERNAL tree
  Config.in  external.mk
  configs/gncc_gk2_defconfig
  board/anyka/
    linux.config               kernel config (derived from the vendor SDK's)
    post-build.sh              fstab, module pruning, stock cfg80211/hostapd,
                               libssl relocation
    post-fakeroot.sh           splits /usr into app.squashfs
    post-image.sh              partition size checks, autoupdate-full.bin
    busybox-extra.fragment     udhcpd, pgrep, pkill
    hostapd.conf.default       open portal AP
    udhcpd.conf.default        10.1.8.x, DNS → 10.1.8.1
    rootfs-overlay/etc/init.d/
      S03modules               quiet console, modules in stock order, CONFIG mount
      S05autoupdate            SD-card firmware update
      S40wifi                  wifi drivers (+ station mode when ipcd is off)
      S60ipcd                  ipcd, portal AP, reboot-on-credentials watcher
    stock/                     (empty — vendor blobs go here, see above)
  package/
    anyka-libs/                vendor media libraries (lib/ is gitignored)
    anyka-modules/             stock kernel modules (files/ is gitignored)
    ipcd/                      fetches the fork by tag; no vendored source
scripts/
  extract-vendor-blobs.sh      pull vendor files from your own full.bin
  check-module-symbols.sh      verify modules against your kernel
  gk2-update.sh                build, verify, copy to SD card
docs/
  01-flash-layout-and-backup.md
  02-building.md
  03-flashing-and-recovery.md
  04-wifi-portal.md
  05-troubleshooting.md
```

---

## Credits

- **[ipcd](https://github.com/medevil84/ipcd)** by medevil (MIT) — the daemon
  this firmware runs, and the larger part of what makes the camera work:
  capture, H.264/H.265 encoding, RTSP, ONVIF, the HTTP UI, Wi-Fi provisioning
  with captive portal, NTP, LEDs and button handling. Written for Surfola
  cameras on the same SoC.

  This build uses a [fork](https://github.com/michelostojski/ipcd) (tag
  `v0.3.1-gk2`) adding ONVIF PTZ for the GK2's pan/tilt hardware
  (`onvif_ptz.c`, `ptz_motor.c/.h` — a reverse-engineered `/dev/motor0`/`1`
  ioctl protocol), plus fixes that apply to any AK39EV330 board:

  - DMA pools sized from the device tree's `dma_reserved` node.
    `ak_mem_dma_pool_activate()` does not check the total against the
    reservation, so oversized pools activate and then corrupt memory once the
    encoders run — the board dies seconds after capture starts.
  - Main stream follows the sensor's native resolution instead of a hardcoded
    1920x1080.
  - `isp_set_flip_mirror()` takes `(dev_id, info*)`; the old one-argument call
    always failed silently.
  - The watchdog is armed after `vi_init()` and fed for the life of the
    process. Arming it earlier reset the board mid-startup on large sensors,
    and a capture restart used to stop the feeder.
  - Night-to-day detection peeks with the IR LED off, for boards with no
    ambient light sensor.

  Everything else is upstream's.

- **[thingino](https://github.com/themactep/thingino-firmware)** — the model
  for camera-firmware provisioning and the SD-card auto-update convention. A
  far larger project covering many SoCs; use it if it supports your camera.

- **[TECKIN-TC100 Anyka hacks](https://github.com/ThatUsernameAlreadyExist/TECKIN-TC100-Anyka-AK3918-camera-hacks)**
  — the SD-card boot hook that gives a root shell on stock firmware without
  flashing anything, which made the whole investigation reversible.

- Anyka and the camera vendor, for a GPL kernel drop that made this possible.

---

## License

Original work in this repo — Buildroot recipes, board and init scripts, kernel
config, helper scripts, documentation — is MIT (see `LICENSE`).

`ipcd` and the fork are MIT, Copyright (c) 2026 medevil.

Nothing here redistributes vendor property. Anyka's libraries, the stock kernel
modules, the vendor `cfg80211.ko` and stock's `hostapd` are **not** included and
must come from your own device. Do not redistribute stock firmware images or
flash dumps.
