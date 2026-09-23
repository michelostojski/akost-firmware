# Supported cameras

Two cameras, one source tree. Everything that differs between them is either
detected at runtime or supplied by the camera's own flash dump — except a
handful of settings that cannot be probed, listed per camera below.

| | GNCC GK2 | GNCC GT1 Pro |
| --- | --- | --- |
| SoC | Anyka AK3918EV330 | same |
| Kernel | vendor 4.4.192V2.1 | same |
| Flash | XMC XM25QH64C, 8 MB | same |
| Partition layout | identical | identical |
| Wi-Fi | AltoBeam ATBM6012B-X (USB `007a:888b`) | same |
| Sensor | JX-F37 (`sensor_f37p.ko`) | JX-Q03 (`sensor_q03p.ko`) |
| ISP tuning | `isp_f37p_mipi_1lane_h3b.conf` | `isp_q03p_mipi_2lane_h3b.conf` |
| Native resolution | 1920x1080 | 2304x1296 |
| MIPI lanes | 1 | 2 |
| DMA reservation (DT) | `0x1400000` (20 MB) | `0x1c00000` (28 MB) |
| Pan/tilt motors | 2 x HZF-24BYJ48 | none (DT declares no motor pins) |
| LEDs | blue, red, IR, white | blue, red, IR |
| SAR ADC (light sensor) | enabled in DT | **disabled** — no ambient sensor |

The vendor ships **byte-identical** userspace libraries, `ak_isp.ko`,
`cfg80211.ko` and `hostapd` for both cameras. The only differing binary is the
sensor module. That is why one build serves both: the extraction script pulls
whichever sensor module and ISP config your own dump contains, and the rest is
the same everywhere.

---

## Per-camera settings

These are the things the firmware cannot work out for itself. They live on each
camera's CONFIG partition, so they survive firmware updates.

### GNCC GK2

```
/etc/config/ipcd.args      (empty — no flip, no mirror)
/etc/config/sensor.init    i2ctransfer -f -y 0 w2@0x40 0x12 0x30
/etc/config/ipcd.conf      fps        = 15
                           ir_d2n_lum = 8600
                           ir_n2d_lum = 1024
                           (max_exp_lines and no_sharpen unset)
```

**Leave the ISP alone on this camera.** Any `isp_set_flip_mirror()` call — even
`flip=0 mirror=0` — and any `AK_ISP_set_sharp_attr()` call turns the picture
pink and washed out. Orientation is done at the sensor instead (see below). See
*Open questions* for what is not understood here.

### GNCC GT1 Pro

```
/etc/config/ipcd.args      --main-kbps 2000
/etc/config/sensor.init    i2ctransfer -f -y 0 w2@0x40 0x12 0x30
/etc/config/ipcd.conf      fps           = 10
                           max_exp_lines = 2700
                           ir_d2n_lum    = 6000
                           ir_n2d_lum    = 1024
```

`fps = 10` and `max_exp_lines = 2700` together let the sensor use the full
exposure its ISP config allows at night, which visibly reduces noise. At 15 fps
the exposure is capped to 2152 lines and the night image is noticeably grainier
— see *Open questions*.

### Orientation

Both cameras mount the sensor rotated 180 degrees. The fix is a single sensor
register write, run by `S60ipcd` from `/etc/config/sensor.init`:

```sh
i2ctransfer -f -y 0 w2@0x40 0x12 0x30
```

Two details worth knowing. The sensor answers at 7-bit address **`0x40`**, not
the `0x30` its device-tree node declares. And the Anyka I2C adapter rejects
SMBus transfers, so `i2cget`/`i2cset` return `Connection refused` — only
`i2ctransfer` (raw `I2C_RDWR`) works.

`ipcd`'s own `--flip` / `--mirror` options drive the ISP instead. They are
correct as far as they go (see below) but do not rotate the picture on either
of these sensors, and on the GK2 they wreck the colour.

---

## Things fixed along the way

All of these are in the [ipcd fork](https://github.com/michelostojski/ipcd) and
affect any AK39EV330 board, not just these two cameras.

**DMA pools sized from the device tree.** `ak_mem_dma_pool_activate()` does not
check the requested total against the board's reservation: 28 MB of pools on
the GK2's 20 MB region activates happily, and then the encoders write past the
end of it and the board dies seconds after capture starts. The size now comes
from `/proc/device-tree/reserved-memory/dma_reserved@*/size`.

**Main stream follows the sensor.** It was hardcoded to 1920x1080; a 2304x1296
sensor then failed `ak_vi_enable_dev()` with `0xffffffff` and no kernel
message.

**`isp_set_flip_mirror()` signature.** It takes `(int dev_id, info*)`, not
`(info*)` — verified by disassembling `libplat_vpss.so`, which compares `r0`
against 1 before using `r1` as the struct pointer. The old call always returned
-1, silently, on every camera.

**Watchdog no longer resets the board during startup.** It was armed before
`mem_pool_init()`, and bringing up a 2304x1296 pipeline keeps the CPU in the
kernel for longer than the 10-second hardware timeout, so the feeder thread
never got to run: a 43-second reboot loop. It is now armed after `vi_init()`
succeeds, and the feeder runs for the life of the process rather than only
while `cap_run` is set — a capture restart used to stop it, and the Anyka
watchdog ignores magic close.

**Day/night without a light sensor.** Night-to-day detection reads the scene
through the camera, but with the IR LED on the scene *is* the LED: luma reads
like daylight (~30), the camera switches to day, turns the LED off, sees
darkness, and switches back. In night mode `ir.c` now switches the LED off once
a minute, waits 3 s for AE to settle, samples the real ambient light, and
either switches to day or turns the LED back on.

**Chroma switch disabled.** `ak_venc_set_attr()` kills the process on the
mono-to-colour transition. `struct encode_param` is reverse-engineered and
evidently does not match the vendor layout closely enough to write back;
`get_attr` into a padded buffer is safe, handing it back is not. The cost is
the IR pink-tint correction at night.

---

## Open questions — help wanted

If you know the Anyka ISP SDK, or run another AK39EV330 board, any of these
would be useful.

### 1. Why does touching the ISP wreck the GK2's colour?

On the GK2 (JX-F37), a *successful* `isp_set_flip_mirror(0, &fm)` — even with
both flags zero — leaves the picture pink and washed out, blacks grey, contrast
flat. So does `AK_ISP_set_sharp_attr()`. Leaving both calls out entirely gives
a correct picture. The GT1 Pro (JX-Q03) is unaffected by the same calls.

Four sensor/ISP flip combinations were tried on the GK2; all produced some
colour error except "never call the ISP at all". The pattern (magenta, or blue
violet, depending on combination) looks like a Bayer phase shift, but the
correct combination is not among the four.

`libplat_isp_sdk.so` exports a full white-balance API —
`AK_ISP_set_wb_type`, `set_awb_attr`, `set_mwb_attr`, `Ak_ISP_Get_Work_Scene` —
that `ipcd` never calls. The stock app presumably does, through
`libakmedia.so`, but its binary is stripped and has no relocations naming those
functions, so this has not been traced.

**Is there a white-balance or scene call that must follow
`ak_vi_load_sensor_cfg()`?**

### 2. Exposure cap is global, not per fps level

The ISP keeps a table with separate day and night entries (GT1 Pro:
`hi=20/1350 low=10/2700`). `ipcd` applies one `max_exp_lines` to every level,
so you can have 15 fps by day with a grainy night image, or 10 fps day and
night with a clean one, but not 15/10. Capping each level against its own frame
period would give both. Straightforward to write; not yet done.

### 3. `struct encode_param` layout

Needed to re-enable the day/night chroma switch, and probably useful elsewhere.
Currently `ak_venc_set_attr()` is fatal.

### 4. Night image quality on 3 MP sensors

The GT1 Pro at 2304x1296 with one small IR LED is noisy at night even at full
exposure. Partly physics, but the ISP's 3D-NR settings have not been looked at
at all.

### 5. Other AK39EV330 boards

The extraction script assumes the GK2/GT1 Pro layout: sensor module and ISP
config in the APP partition, `cfg80211.ko` in ROOTFS, `hostapd` in APP. It
reports what it finds, so it should say clearly if your camera differs. Reports
from other boards — especially different sensors — would be welcome.

---

## Adding another camera

Roughly, in order:

1. Back up its flash (`docs/01-flash-layout-and-backup.md`). This is also where
   its vendor blobs come from.
2. `scripts/extract-vendor-blobs.sh /path/to/its/full.bin` — it clears the
   previous camera's sensor module and ISP config and copies this one's.
3. Build and flash (`docs/02-building.md`, `docs/03-flashing-and-recovery.md`).
4. Check the boot log for `[vi] sensor native resolution` and
   `[mem] DT dma_reserved` — both should match the hardware.
5. Set orientation, IR threshold and exposure per the tables above, adjusted by
   what you see.

Steps 1 to 4 need no per-camera knowledge at all. Step 5 is where the time
goes, and where the tables above came from.
