#!/bin/bash
#
# extract-vendor-blobs.sh — populate the vendor files this firmware needs from
# YOUR OWN camera's flash dump. Nothing here is redistributable, which is why
# none of it is committed to the repo.
#
#   usage: scripts/extract-vendor-blobs.sh <full.bin> [external-tree-dir]
#
# <full.bin> is an 8 MB dump of the camera's SPI flash — see the README for how
# to take one. The external tree defaults to the repo root (the directory this
# script's parent lives in).
#
set -u

DUMP="${1:-}"
EXT="${2:-$(cd "$(dirname "$0")/.." && pwd)}"

RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; OFF=$'\e[0m'
ok()   { echo "${GRN}ok${OFF}   $*"; }
warn() { echo "${YEL}warn${OFF} $*"; }
die()  { echo "${RED}error${OFF} $*" >&2; exit 1; }

[ -n "$DUMP" ] || die "usage: $0 <full.bin> [external-tree-dir]"
[ -f "$DUMP" ] || die "no such file: $DUMP"
command -v unsquashfs >/dev/null || die "unsquashfs not found (apt install squashfs-tools)"

SIZE=$(stat -c%s "$DUMP")
if [ "$SIZE" -ne 8388608 ]; then
    warn "dump is $SIZE bytes, expected 8388608 — continuing, but check your backup"
fi

# Partition offsets from the kernel command line (mtdparts).
ROOTFS_OFF=$((0x210000)); ROOTFS_LEN=$((0x198000))
APP_OFF=$((0x40c000));    APP_LEN=$((0x3f4000))

WORK=$(mktemp -d) || die "mktemp failed"
trap 'rm -rf "$WORK"' EXIT

echo "== unpacking partitions from $(basename "$DUMP")"
dd if="$DUMP" of="$WORK/rootfs.sqsh" bs=4096 skip=$((ROOTFS_OFF/4096)) \
   count=$((ROOTFS_LEN/4096)) status=none
dd if="$DUMP" of="$WORK/app.sqsh"    bs=4096 skip=$((APP_OFF/4096)) \
   count=$((APP_LEN/4096))    status=none

for p in rootfs app; do
    magic=$(dd if="$WORK/$p.sqsh" bs=1 count=4 status=none | od -An -tx1 | tr -d ' \n')
    [ "$magic" = "68737173" ] || die "$p partition is not squashfs (magic $magic) — wrong dump or layout?"
    unsquashfs -d "$WORK/$p" "$WORK/$p.sqsh" >/dev/null 2>&1 \
        || die "unsquashfs failed on $p"
done
ok "rootfs and app partitions unpacked"

STOCK_ROOT="$WORK/rootfs"
STOCK_APP="$WORK/app"

# ---------------------------------------------------------------- libraries --
LIBDIR="$EXT/package/anyka-libs/lib"
ETCDIR="$EXT/package/anyka-libs/etc"
mkdir -p "$LIBDIR" "$ETCDIR"

echo "== Anyka userspace libraries -> package/anyka-libs/lib/"
n=$(find "$STOCK_APP/lib" -maxdepth 1 -name "*.so*" 2>/dev/null | wc -l)
[ "$n" -gt 0 ] || die "no .so files in the APP partition's lib/ — unexpected layout"
cp -a "$STOCK_APP"/lib/*.so* "$LIBDIR/"
ok "$n libraries"

for want in libplat_mem.so libplat_vi.so libmpi_venc.so libakv_encode.so; do
    [ -e "$LIBDIR/$want" ] || warn "expected library missing: $want"
done

echo "== ISP sensor tuning -> package/anyka-libs/etc/"
isp=$(find "$STOCK_APP/etc" "$STOCK_ROOT/etc" -maxdepth 1 -name "isp_*.conf" 2>/dev/null | head -1)
if [ -n "$isp" ]; then
    cp -a "$isp" "$ETCDIR/"
    ok "$(basename "$isp")"
    case "$(basename "$isp")" in
        isp_f37p_*) : ;;
        *) warn "that is not the JXF37 tuning file this build expects — your camera may have a different sensor" ;;
    esac
else
    warn "no isp_*.conf found; ipcd will need --sensor-cfg pointing elsewhere"
fi

# ------------------------------------------------------------------ modules --
MODDIR="$EXT/package/anyka-modules/files"
mkdir -p "$MODDIR"

MODULES="ak_rtc ak_i2c ak_pcm ak_gpio_keys ak_ion ak_leds ak_mci ak_uio
         exfat ak_motor ak_saradc ak_isp sensor_f37p ak_hcd atbm603x_x_usb"

echo "== stock kernel modules -> package/anyka-modules/files/"
missing=0
for m in $MODULES; do
    src="$STOCK_APP/modules/$m.ko"
    if [ -f "$src" ]; then
        cp -a "$src" "$MODDIR/"
    else
        warn "missing module: $m.ko"
        missing=$((missing+1))
    fi
done
[ "$missing" -eq 0 ] && ok "15 modules" || warn "$missing module(s) missing — your camera may differ"

# sensor modules vary per camera; say which one is actually present
sensors=$(ls "$STOCK_APP/modules" 2>/dev/null | grep '^sensor_' | tr '\n' ' ')
[ -n "$sensors" ] && echo "     sensor modules on this camera: $sensors"

# ------------------------------------------------------- vendor cfg80211.ko --
STOCKDIR="$EXT/board/anyka/stock"
mkdir -p "$STOCKDIR"

echo "== vendor-patched cfg80211.ko -> board/anyka/stock/"
cfg=$(find "$STOCK_ROOT/lib/modules" -name "cfg80211.ko" 2>/dev/null | head -1)
if [ -n "$cfg" ]; then
    cp -a "$cfg" "$STOCKDIR/"
    ok "cfg80211.ko from $(echo "$cfg" | sed "s|$STOCK_ROOT||")"
else
    die "cfg80211.ko not found in the ROOTFS partition — wifi will not work"
fi

# ---------------------------------------------------------- stock hostapd ----
echo "== stock hostapd -> board/anyka/stock/"
hap=$(find "$STOCK_APP" -name "hostapd" -type f 2>/dev/null | head -1)
if [ -n "$hap" ]; then
    cp -a "$hap" "$STOCKDIR/"
    chmod +x "$STOCKDIR/hostapd"
    ver=$(strings "$STOCKDIR/hostapd" | grep -m1 -oE "^hostapd v[0-9.]+" || true)
    if [ -n "$ver" ]; then
        ok "$ver"
    else
        ok "hostapd (version string not embedded; check with ./hostapd -v on the camera)"
    fi
else
    warn "no hostapd in the APP partition — the setup portal AP will not work"
fi

# ------------------------------------------------------------ verification ---
echo
echo "== verification"

VM_EXPECTED="4.4.192V2.1"
bad=0
for ko in "$MODDIR"/*.ko "$STOCKDIR/cfg80211.ko"; do
    [ -f "$ko" ] || continue
    vm=$(strings "$ko" | grep -m1 "^vermagic=" | sed 's/^vermagic=//')
    case "$vm" in
        "$VM_EXPECTED"*) ;;
        *) warn "$(basename "$ko"): vermagic '$vm' (expected $VM_EXPECTED)"; bad=$((bad+1)) ;;
    esac
done
[ "$bad" -eq 0 ] && ok "all modules report vermagic $VM_EXPECTED"

# the vendor cfg80211 patch: these symbols are absent from the SDK build
for sym in cfg80211_external_auth_request cfg80211_autodisconnect_wk; do
    if strings "$STOCKDIR/cfg80211.ko" | grep -q "$sym"; then
        ok "cfg80211.ko carries the vendor patch ($sym)"
        break
    else
        warn "cfg80211.ko does not export $sym — this may be an unpatched build"
        break
    fi
done

echo
echo "extracted into $EXT:"
printf '  %-38s %s\n' \
    "package/anyka-libs/lib/"        "$(ls "$LIBDIR" 2>/dev/null | wc -l) files" \
    "package/anyka-libs/etc/"        "$(ls "$ETCDIR" 2>/dev/null | wc -l) files" \
    "package/anyka-modules/files/"   "$(ls "$MODDIR" 2>/dev/null | wc -l) files" \
    "board/anyka/stock/"             "$(ls "$STOCKDIR" 2>/dev/null | wc -l) files"
echo
echo "None of this is committed — .gitignore keeps it out of the repo."
echo "Next: set BR2_TOOLCHAIN_EXTERNAL_PATH and a root password in"
echo "      configs/gncc_gk2_defconfig, then build (see README)."
