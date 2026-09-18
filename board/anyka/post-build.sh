#!/bin/sh
set -e
TARGET_DIR="$1"
grep -q mtdblock7 "$TARGET_DIR/etc/fstab" || \
  echo "/dev/mtdblock7	/usr	squashfs	ro	0	0" >> "$TARGET_DIR/etc/fstab"
K="$TARGET_DIR/lib/modules/4.4.192V2.1/kernel"
find "$K" -name "*.ko" ! -name "cfg80211.ko" -delete
find "$K" -type d -empty -delete
# vendor-patched cfg80211 (matches the prebuilt ATBM driver)
install -m 0644 "$(dirname "$0")/stock/cfg80211.ko" \
  "$TARGET_DIR/lib/modules/4.4.192V2.1/kernel/net/wireless/cfg80211.ko"
# trim OpenSSL leftovers
rm -rf "$TARGET_DIR/usr/bin/openssl" "$TARGET_DIR/usr/bin/c_rehash" \
       "$TARGET_DIR/usr/lib/engines-3" "$TARGET_DIR/usr/lib/ossl-modules" \
       "$TARGET_DIR/etc/ssl/misc"
RE=$(ls "$HOST_DIR"/bin/*-readelf | head -1)
if ! find "$TARGET_DIR" -type f -perm -u+x -exec "$RE" -d {} \; 2>/dev/null | grep -q "libssl.so"; then
  rm -f "$TARGET_DIR"/usr/lib/libssl.so*
fi
# APP partition is full: libssl goes to the rootfs (/lib is in the loader path)
for f in "$TARGET_DIR"/usr/lib/libssl.so*; do
  [ -e "$f" ] && mv -f "$f" "$TARGET_DIR/lib/"
done
# stock hostapd 2.8: v2.12 fails nl80211 frame registration on the ATBM driver
install -m 0755 "$(dirname "$0")/stock/hostapd" "$TARGET_DIR/usr/sbin/hostapd"
mkdir -p "$TARGET_DIR/var/lib/misc"
