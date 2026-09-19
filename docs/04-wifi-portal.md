# Wi-Fi setup portal

A freshly flashed camera has no credentials, so it raises an open access point,
serves a setup page, and reboots onto your network once you've filled it in.
No serial console, no app.

The portal itself — the page, the credential store, the DNS spoofer — is
**`ipcd`'s** feature, written by medevil. What this firmware adds is making it
work on this hardware, which needed stock's hostapd, a different startup order,
and a reboot to finish. Those three things are explained under *Why it's not
just `ipcd`* below.

The design follows [thingino](https://github.com/themactep/thingino-firmware)'s
provisioning flow: open AP, DHCP, wildcard DNS, redirect anything to the setup
page.

---

## Using it

1. Flash the firmware and power the camera on with no SD card.
2. After about a minute, an open network **`AKOST-xxxx`** appears — `xxxx` is
   the last four hex digits of the camera's MAC, so several cameras don't
   collide.
3. Join it from a phone or laptop. **Turn mobile data off** — Android in
   particular routes around a network with no internet, and the request never
   reaches the camera.
4. The captive-portal sheet should open by itself. If it doesn't, browse to
   **http://10.1.8.1/**.
5. Enter your Wi-Fi name and password.
6. The camera saves them and reboots, then joins your network. Find its address
   on your router; `ipcd` then serves `http://<ip>/stats`, `http://<ip>/config`
   and RTSP on 8554.

"No internet access" while you're connected to `AKOST-xxxx` is expected — the
camera is not a router.

---

## The network it serves

| | |
| --- | --- |
| SSID | `AKOST-<last 4 of MAC>` |
| Security | open |
| Camera address | `10.1.8.1` |
| DHCP range | `10.1.8.20` – `10.1.8.254` |
| DNS advertised | `10.1.8.1` (the spoofer) |

The AP is open on purpose, as thingino's is: needing a shared secret to set up
a camera that has no secrets yet is circular. It exists **only** while
`/etc/config/wifi.conf` is absent, and disappears as soon as the camera is
provisioned.

`10.1.8.1` is hardcoded in `ipcd` — it builds the portal URL from it — so
changing the address means changing `udhcpd.conf` *and* patching `ipcd`.

---

## Configuration files

Defaults ship in the rootfs and are copied into `/etc/config/` when missing, so
a wiped CONFIG partition still gets a working portal.

| Rootfs default | Copied to | Purpose |
| --- | --- | --- |
| `/etc/hostapd.conf.default` | `/etc/config/hostapd.conf` | the AP; SSID gets the MAC suffix on first copy |
| `/etc/udhcpd.conf.default` | `/etc/config/udhcpd.conf` | DHCP range and options |

`hostapd.conf`:

```
interface=wlan0
ctrl_interface=/tmp/hostapd
ssid=AKOST-0000
channel=1
hw_mode=g
ieee80211n=1
wmm_enabled=1
ht_capab=[SHORT-GI-20]
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
```

No `wpa*` lines — that's what makes it open. `ctrl_interface=/tmp/hostapd` must
stay as it is: `ipcd` has that path hardcoded and looks there to check the AP.

`udhcpd.conf` — note `opt dns` must point at the camera, or there's no wildcard
DNS and therefore no automatic popup:

```
interface wlan0
start 10.1.8.20
end 10.1.8.254
option subnet 255.255.255.0
opt router 10.1.8.1
opt dns 10.1.8.1
option lease 864000
```

Credentials end up in `/etc/config/wifi.conf`:

```
ssid=MyNetwork
psk=...
```

That file's presence is what decides everything: absent → portal; present →
station mode. To re-provision a camera, delete it and reboot.

---

## What happens at boot

`S60ipcd`, in order:

1. Exits immediately unless `/etc/config/ipcd.enable` exists.
2. Creates `/tmp/hostapd` (tmpfs, gone every boot) and the `udhcpd` leases file.
3. Copies the `hostapd.conf` / `udhcpd.conf` defaults into `/etc/config` if
   they're missing, substituting the MAC suffix into the SSID.
4. Starts `ipcd`.
5. **If `wifi.conf` is absent**, backgrounds a helper that:
   - waits for `AP start failed 3 times` in `ipcd`'s log
   - runs `hostapd -B`, assigns `10.1.8.1`, starts `udhcpd`
   - waits for `wifi.conf` to appear, then syncs and reboots

`ipcd` keeps serving HTTP on `:80` and DNS on `:53` throughout, so the portal
works even though its own AP attempt failed.

---

## Why it's not just `ipcd`

Three hardware-imposed deviations, each found the hard way.

**hostapd 2.12 cannot drive the ATBM chip.** It fails at
`nl80211: Register frame command failed (type=176): ret=-95` — the driver
doesn't implement management-frame registration. Stock's **hostapd 2.8** falls
back to a monitor interface, a path later versions dropped, and works. That
binary is extracted from your camera's APP partition.

**`ipcd`'s AP readiness check never passes.** hostapd reports `AP-ENABLED` and
the SSID is genuinely visible, but `ipcd` can't confirm it through the control
socket within its 12-second window, so it kills hostapd and retries — three
times, then gives up. Letting it fail and raising the AP behind it is the
workaround.

**The driver won't return `wlan0` from AP to station mode.** Even after
`ifconfig down`/`up` it answers `nl80211: Could not configure driver mode`, and
unloading the module panics the kernel. So provisioning ends in a reboot; since
`ipcd` writes `wifi.conf` before switching, the camera comes back up in station
mode with the new credentials.

Full detail in [05-troubleshooting.md](05-troubleshooting.md), section 5.

---

## Turning the portal off

`ipcd` only starts if the flag file exists:

```sh
touch /etc/config/ipcd.enable     # enable ipcd (and the portal)
rm /etc/config/ipcd.enable        # disable it
reboot
```

With `ipcd` disabled, `S40wifi` connects to Wi-Fi itself using
`/etc/config/wifi.conf` and starts `wpa_supplicant` and `udhcpc` directly.
Useful when you want the camera on the network without `ipcd` touching the
interface — for example while debugging.

---

## Diagnosis

`ipcd` logs to `/tmp/ipcd.log`.

```sh
grep -E "netmgr|hostapd|udhcpd|dns|http" /tmp/ipcd.log | tail -20
pgrep -a hostapd; pgrep -a udhcpd; pgrep -a ipcd
ip addr show wlan0 | grep inet
wc -c < /var/lib/misc/udhcpd.leases     # >8 means a client got a lease
```

Healthy output includes `[http] listening on :80`,
`[dns] spoofer up on UDP:53 → 10.1.8.1`, `wlan0: AP-ENABLED`, and `wlan0` at
`10.1.8.1`.

**SSID appears but won't connect / no address.** `udhcpd` isn't running.
Check the leases file exists — `/var/lib/misc` is a symlink to `/tmp`, so it's
recreated at boot by `S60ipcd`.

**Connects but no popup.** Either mobile data is stealing the request, or
`opt dns` in `udhcpd.conf` isn't `10.1.8.1`. Try `http://10.1.8.1/` directly.

**No SSID at all.** Check `/tmp/hostapd` exists and hostapd is running; then
run it in the foreground to see the real error:

```sh
killall hostapd; mkdir -p /tmp/hostapd
/usr/sbin/hostapd /etc/config/hostapd.conf
```

**`http] bind :80 failed: Address already in use`.** Two `ipcd` instances.
`killall -9 ipcd`, wait, start one.

**Provisioned but never reconnects.** Check `wifi.conf` was written
(`grep -v psk /etc/config/wifi.conf`) and that the reboot happened. If `ipcd`
is stuck in AP mode with valid credentials on disk, reboot manually.

---

## Testing the portal on an already-provisioned camera

```sh
mv /etc/config/wifi.conf /etc/config/wifi.conf.off
reboot
```

Restore with the reverse `mv` and another reboot — or just complete the portal
flow, which writes a fresh `wifi.conf`.

Do this from the serial console rather than SSH: the camera leaves your network
as soon as `ipcd` restarts.
