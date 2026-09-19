# Troubleshooting

Problems hit while building this firmware, how each was diagnosed, and the
commands that did the diagnosing. Most of it applies to any Anyka AK39xx board
where you're running prebuilt vendor modules against your own kernel.

The recurring theme: **a symptom at one layer almost always had its cause one
layer down**, and the way to find it was to compare against stock rather than
to reason about the symptom.

- [Nothing runs at boot](#1-nothing-runs-at-boot--rcs-applet-not-found)
- [Wi-Fi chip never enumerates](#2-wi-fi-chip-never-enumerates--io-mem-0x00000000)
- [Kernel fault loading the Wi-Fi driver](#3-kernel-fault-in-wiphy_update_regulatory)
- [ipcd falls back to AP mode with Wi-Fi working](#4-ipcd-falls-back-to-ap-mode-with-wi-fi-working)
- [The setup AP never comes up](#5-the-setup-ap-never-comes-up)
- [Diagnostic command reference](#diagnostic-command-reference)
- [Habits worth keeping](#habits-worth-keeping)

---

## 1. Nothing runs at boot — `rcS: applet not found`

**Symptom.** The kernel boots, the rootfs mounts, you get a login prompt — but
no modules are loaded, `/etc/config` isn't mounted, no network. Running the
same init scripts by hand from the shell works perfectly.

**In the boot log:**

```
VFS: Mounted root (squashfs filesystem) readonly on device 31:5.
devtmpfs: mounted
Freeing unused kernel memory: 136K
rcS: applet not found
```

**Cause.** `CONFIG_BINFMT_SCRIPT` was not set in the kernel. Without it the
kernel cannot execute files beginning `#!/bin/sh` — it refuses the `execve`,
the C library falls back to running `/bin/sh` with the program name `rcS`, and
BusyBox looks for an applet called `rcS`, which doesn't exist.

Scripts still work from an interactive shell because the shell has its own
fallback for a failed `execve`. That difference is what makes this confusing:
every script you test by hand behaves, and nothing runs at boot.

**Fix.**

```
CONFIG_BINFMT_SCRIPT=y
```

Then `make ... linux-reconfigure` — **not** `linux-rebuild`, which ignores
edits to `linux.config`.

**How it was found.** By reading the boot log rather than the scripts. The
message is one line among hundreds and says nothing about scripts.

---

## 2. Wi-Fi chip never enumerates — `io mem 0x00000000`

**Symptom.** `ak_hcd.ko` loads, the USB root hub registers, and the driver even
reports the Wi-Fi chip connecting — but the device never enumerates, no
`wlan0` appears, and `/sys/bus/usb/devices/` holds only `usb1` and `1-0:1.0`.

```
ak-hshcd 20200000.usb: Anyka usb host controller
ak-hshcd 20200000.usb: new USB bus registered, assigned bus number 1
ak-hshcd 20200000.usb: irq 18, io mem 0x00000000        <-- wrong
hub 1-0:1.0: USB hub found
####connent happen @ 136176                              <-- chip IS connected
[atbm_log]:atbm_usb_module_init 0
usbcore: registered new interface driver atbm_wlan
```

Nothing follows. On stock the next lines are:

```
usb 1-1: new high-speed USB device number 2 using ak-hshcd
usb 1-1: Product: AltoBeam_WIFI
```

**The tell.** One line differs from stock:

| Kernel | `ak-hshcd` line |
| --- | --- |
| stock | `irq 18, io mem 0x20200000` |
| ours | `irq 18, io mem 0x00000000` |

`ak_hcd` stores the controller's address in `struct usb_hcd`, and the USB core
reads it back to print that line. Reading zero means the module wrote to one
offset and the kernel read from another — the structure layouts don't match.

**Cause.** Stock builds `CONFIG_USB_MON=m`. That option adds two fields
(`mon_bus`, `monitored`) near the start of `struct usb_bus`, which is embedded
at the top of `struct usb_hcd`. Without the option, every field after them
shifts, including `rsrc_start`. The prebuilt `ak_hcd.ko` was compiled against a
kernel that had it.

**Fix.**

```
CONFIG_USB_MON=m
```

The `usbmon.ko` module itself is not needed on the target — only the option's
effect on the structure layout matters — so `post-build.sh` deletes it.

**How it was found.** By listing the modules in the stock rootfs:

```bash
find stock_root/lib/modules -name "*.ko" | sed 's|.*/kernel/||'
```

`drivers/usb/mon/usbmon.ko` in that list revealed the option. Nothing else
pointed at it — and note that the symbol check in
[the reference below](#module-compatibility) **passed** for `ak_hcd.ko`,
because every function it needs exists. Symbol checks prove names, not layouts.

**Generalisation.** Any kernel option that adds fields to a structure shared
between a prebuilt module and the kernel will do this, silently. When a vendor
module loads cleanly but behaves as though it's reading garbage, compare your
config against the vendor's for options in that subsystem.

---

## 3. Kernel fault in `wiphy_update_regulatory`

**Symptom.** With USB fixed, the chip enumerates and `atbm603x_x_usb.ko`
registers — then the kernel dies as the driver registers with `cfg80211`:

```
[<bf0ab25c>] (wiphy_update_regulatory [cfg80211]) from
[<bf0ad380>] (wiphy_regulatory_register+0x2c/0x34 [cfg80211])
Unable to handle kernel paging request at virtual address ...
```

**Cause.** The vendor patched their wireless stack. Their `cfg80211.ko` exports
three symbols the SDK source doesn't have:

```
cfg80211_external_auth_request
nl80211_external_auth
cfg80211_autodisconnect_wk
```

These are WPA3 external-auth support backported from a later kernel. The patch
also changes the structures `cfg80211` shares with drivers, so the prebuilt
ATBM driver — built against the patched version — hands your `cfg80211` a
`struct wiphy` whose fields sit elsewhere.

No kernel config option fixes this, because the difference is in source you
don't have.

**Fix.** Use the vendor's `cfg80211.ko` instead of the one your kernel builds.
It lives in the **ROOTFS** partition, not APP:

```
stock_root/lib/modules/4.4.192V2.1/kernel/net/wireless/cfg80211.ko
```

`post-build.sh` installs it over the kernel's own build. Keep
`CONFIG_CFG80211=m` set — the kernel still needs to build a module for
`modules.dep` and the module tree to exist.

**How it was found.** By diffing the exported symbols of both modules:

```bash
NM=$B/host/bin/arm-anykav500-linux-uclibcgnueabi-nm
diff <($NM stock_cfg80211.ko | awk '$2~/[TtDdBbRr]/{print $3}' | sort -u) \
     <($NM built_cfg80211.ko | awk '$2~/[TtDdBbRr]/{print $3}' | sort -u)
```

Three real symbols only in stock's, among a lot of compiler-generated noise
(`__warned.NNNNN`, `__key.NNNNN`) that can be ignored.

---

## 4. `ipcd` falls back to AP mode with Wi-Fi working

**Symptom.** `ipcd` reports it can't associate, retries three times, and drops
into AP mode — on a network that works fine when you connect by hand:

```
[netmgr] STA: connecting to 'MyNetwork'
[netmgr] STA: association failed (attempt 1/3) — retrying in 3s
         (likely entropy issue at cold boot)
```

**The trap.** That "likely entropy issue" is the daemon guessing, and it's
wrong. The real message is two lines earlier in the raw log:

```
Line 5: failed to parse key_mgmt 'WPA-PSK SAE'.
Line 5: invalid key_mgmt 'SAE'
Line 12: failed to parse network block.
Failed to read or parse configuration '/var/run/ipcd_wpa.conf'.
```

**Cause.** `ipcd` always writes a WPA3-capable network block:

```
network={
    ssid="..."
    key_mgmt=WPA-PSK SAE
    pairwise=CCMP CCMP-256
    group=CCMP CCMP-256
    ieee80211w=1
    psk="..."
    sae_password="..."
}
```

Buildroot's `wpa_supplicant` without `BR2_PACKAGE_WPA_SUPPLICANT_WPA3=y`
rejects `SAE`, and one bad line invalidates the whole block — so it won't
connect to WPA2 either.

**Fix.**

```
BR2_PACKAGE_WPA_SUPPLICANT_WPA3=y
```

then `make ... wpa_supplicant-dirclean` and rebuild. **Buildroot does not
rebuild a package when you change its options** — without the dirclean the old
binary stays and nothing appears to change.

**Consequence.** WPA3 pulls in OpenSSL, which grew the APP partition by ~1.85 MB
and overflowed it by 127 KB. Three changes brought it back:

- `libssl.so` moved to the rootfs (`/lib` is on the loader path) in
  `post-build.sh`
- unused OpenSSL ciphers and protocols disabled (QUIC, SSL3, IDEA, SEED,
  CAST, MDC2, MD2, WHIRLPOOL, engines, the `openssl` binary)
- `-Xbcj arm` added to `mksquashfs`, worth roughly 10% on ARM executables

**How it was found.** By *not* filtering the log. An over-eager `grep -v psk`,
added to avoid pasting a password, was hiding the only line that named the
problem.

---

## 5. The setup AP never comes up

Three separate problems, all presenting as "no Wi-Fi network appears".

### 5a. hostapd 2.12 cannot drive the ATBM chip

```
nl80211: Setup AP(wlan0) - device_ap_sme=0
nl80211: Register frame type=0xb0 (WLAN_FC_STYPE_AUTH) ...
nl80211: Register frame command failed (type=176): ret=-95 (Operation not supported)
nl80211: Could not configure driver mode
nl80211 driver initialization failed.
```

The driver doesn't implement `nl80211` management-frame registration and
reports `device_ap_sme=0`, meaning hostapd must handle authentication itself.
Modern hostapd treats the failed registration as fatal.

Stock's **hostapd 2.8** falls back to a monitor interface — later versions
dropped that path — and works:

```
nl80211: Setup AP(wlan0) - device_ap_sme=0 use_monitor=1
wlan0: interface state UNINITIALIZED->ENABLED
wlan0: AP-ENABLED
```

Both `wlan0` and `wlan1` behave identically, so this isn't about which
interface you pick. Extract `stock_app/sbin/hostapd` and use that;
`BR2_PACKAGE_HOSTAPD` can then be dropped, recovering ~900 KB.

### 5b. `ctrl_interface` directory missing

```
Could not unlink existing ctrl_iface socket '/tmp/hostapd/wlan0': Not a directory
Failed to setup control interface for wlan0
wlan0: Unable to setup interface.
```

`hostapd.conf` has `ctrl_interface=/tmp/hostapd`, which must be a **directory**
— and `/tmp` is a tmpfs, emptied at every boot. Worse, hostapd removes the
directory when it exits, so each retry fails the same way.

`ipcd` has `/tmp/hostapd` hardcoded, so changing the config to a path that
persists doesn't help: it looks in `/tmp/hostapd` regardless. `S60ipcd` creates
the directory before starting anything.

### 5c. `ipcd`'s AP readiness check never passes

```
wlan0: AP-ENABLED
[wifi] AP did not become ready within 12s
[netmgr] AP start failed (attempt 1/3) — retrying in 5s
```

hostapd reports the AP enabled, and the SSID is genuinely visible on a phone —
but `ipcd` can't confirm it through the control socket within its 12-second
window, so it kills hostapd and retries. After three attempts it gives up and
the SSID disappears.

**Workaround.** Let `ipcd` start first and fail its own AP attempt, then raise
the AP behind it. `S60ipcd` waits for `AP start failed 3 times` in the log,
then runs hostapd, assigns `10.1.8.1` and starts `udhcpd`. `ipcd`'s HTTP server
and DNS spoofer keep running throughout, so the portal works.

### 5d. And once provisioned, the driver won't go back to station mode

```
nl80211: Could not configure driver mode
wlan0: Failed to initialize driver interface
```

Even after `ifconfig wlan0 down; ifconfig wlan0 up`, the ATBM driver refuses to
return an interface from AP to station mode. Unloading the module is not an
option either — `rmmod ak_hcd` panics the kernel.

**Workaround.** Reboot. `ipcd` writes `wifi.conf` before it tries to switch, so
a watcher in `S60ipcd` waits for that file to appear and reboots; the camera
comes up in station mode with the new credentials.

---

## Diagnostic command reference

### Reading the stock firmware

```bash
unsquashfs -d stock_root mtd5.bin       # ROOTFS
unsquashfs -d stock_app  mtd7.bin       # APP
unsquashfs -l  image.squashfs           # list contents
unsquashfs -ll image.squashfs           # with permissions and symlink targets

strings /dev/mtd0 | grep -iE "update|fatload|mmc"   # U-Boot capabilities
strings /dev/mtd1 | grep -iE "loadaddr|bootargs"    # U-Boot environment

file mtd4.bin                            # kernel type, load address, entry point
mkimage -l uImage                        # same, from the uImage header
scripts/extract-ikconfig mtd4.bin        # embedded kernel config, if present
```

`extract-vmlinux` only works on compressed kernels; these images are
uncompressed, so `strings` on the `uImage` directly is the way to inspect them.

### Module compatibility

```bash
NM=$B/host/bin/arm-anykav500-linux-uclibcgnueabi-nm
RE=$B/host/bin/arm-anykav500-linux-uclibcgnueabi-readelf

$RE -d binary | grep NEEDED              # shared libraries required
$NM -u module.ko                         # symbols the module needs
$NM module.ko | awk '/ __ksymtab_/{sub("__ksymtab_","",$3); print $3}'   # exports
grep -o ' __ksymtab_[A-Za-z0-9_]*' System.map | sed 's/ __ksymtab_//'    # kernel exports

# what's missing
$NM -u module.ko | awk '{print $2}' | sort -u | comm -23 - exported.txt
```

Every module must also match `vermagic`:

```bash
strings module.ko | grep vermagic        # 4.4.192V2.1 mod_unload ARMv5
```

Checking a binary's libraries are all present on the target:

```bash
for l in $($RE -d $B/target/usr/bin/ipcd | awk -F'[][]' '/NEEDED/{print $2}'); do
  [ -e $B/target/lib/$l ] || [ -e $B/target/usr/lib/$l ] || echo "MISSING: $l"
done; echo "check done"
```

Write it as `[ -e ... ] || echo`, not `ls ... || echo` — `||` after a pipe
never fires, and that bug hid a missing `librt.so` for an entire build cycle.

### On the camera

```bash
sh -x /etc/init.d/S03modules start 2>&1 | tail -30    # trace an init script
dmesg -n 1                                            # silence a console flood
cat /proc/mtd /proc/cmdline; uname -v
mount | grep -E "usr|config"

wpa_supplicant -dd -Dnl80211 -i wlan0 -c conf         # -dd names the failing line
hostapd -dd /etc/config/hostapd.conf                  # same for the AP
udhcpd -f /etc/config/udhcpd.conf                     # foreground, shows errors

od -c file        # every byte, including \r and truncation
cat -A file       # line endings and tabs
```

Starting something over SSH that restarts Wi-Fi kills your session. Run it
detached and have it restore the working state if it fails:

```bash
start-stop-daemon -S -b -x /tmp/test.sh
```

Log to `/etc/config/` (jffs2, persistent) rather than `/tmp` (tmpfs, cleared on
reboot) when the test might end in a reboot.

### Flash images

```bash
# dump, on the camera
for i in 0 1 2 3 4 5 6 7; do dd if=/dev/mtd$i of=/mnt/mtd$i.bin bs=4096; done
cat mtd0.bin mtd1.bin ... mtd7.bin > full.bin
md5sum full.bin mtd*.bin > md5.txt; sync

# verify partition boundaries
xxd -s 0x42000  -l 4 full.bin    # d00d feed  device tree
xxd -s 0x4e000  -l 4 full.bin    # 2705 1956  uImage
xxd -s 0x210000 -l 4 full.bin    # 6873 7173  squashfs
xxd -s 0x40c000 -l 4 full.bin    # 6873 7173  squashfs

# compare regions that should not have changed
cmp -n 319488 full.bin new.bin                # 0x0-0x4e000, boot area
cmp -i 3833856 -n 409600 full.bin new.bin     # CONFIG
```

Prefer `cmp -i/-n` on specific regions over parsing `cmp -l` output — the
latter needs `gawk --non-decimal-data` for hex offsets and silently reports
everything as changed without it.

### Buildroot

```bash
M="make O=$B BR2_EXTERNAL=$F"
$M <pkg>-dirclean      # REQUIRED after changing a package's options
$M linux-reconfigure   # re-applies linux.config; linux-rebuild does NOT
$M target-post-image   # re-run image scripts only
$M savedefconfig BR2_DEFCONFIG=.../gncc_gk2_defconfig
```

Verify a config change actually took effect rather than assuming:

```bash
grep -E "^CONFIG_USB_MON=" $B/build/linux-custom/.config
grep " usb_mon_register" $B/build/linux-custom/System.map
$B/host/bin/unsquashfs -l $B/images/app.squashfs | grep -E "sbin/(hostapd|udhcpd)$"
```

---

## Habits worth keeping

**Guard destructive commands.** `rm -f $SD/*` with `SD` unset runs as
`rm -f /*`. Use `${SD:?}` (aborts if empty) plus `mountpoint -q "$SD"`, and name
files explicitly instead of globbing.

**Paste one line at a time over serial.** The UART drops characters when
several lines arrive together. This cost hours: a missing `printf` line made
`wpa_supplicant` look broken when the config file simply didn't exist, and a
dropped `ssid=` line produced a parse error blamed on the password. When a
result makes no sense, check the file with `od -c` before theorising.

**Read the unfiltered log first.** Two of the four bugs above were solved by
removing a `grep` that was hiding the answer.

**Compare against stock at the layer below the symptom.** The stock firmware is
the working reference: which modules it loads, in what order, with what
parameters, and which kernel options its module set implies.

**Verify the image, not the intent.** `unsquashfs -l` after every build.
Timestamps and sizes lie less than assumptions do.

**Keep a route in that doesn't depend on your changes.** The U-Boot SD method
flashes before Linux starts and survives any broken rootfs. The serial console
survives a broken network. Both were needed more than once.
