#!/bin/sh
set -e
check() {
  size=$(stat -c%s "$BINARIES_DIR/$1")
  if [ "$size" -gt "$2" ]; then
    echo "ERROR: $1 is $size bytes, partition is $2"; exit 1
  fi
  echo "OK: $1 $size / $2"
}
check uImage          1843200
check rootfs.squashfs 1671168
check app.squashfs    4145152
FW="$BINARIES_DIR/autoupdate-full.bin"
head -c 8388608 /dev/zero | tr '\0' '\377' > "$FW"
dd if="$BINARIES_DIR/uImage"          of="$FW" bs=4096 seek=78   conv=notrunc status=none
dd if="$BINARIES_DIR/rootfs.squashfs" of="$FW" bs=4096 seek=528  conv=notrunc status=none
dd if="$BINARIES_DIR/app.squashfs"    of="$FW" bs=4096 seek=1036 conv=notrunc status=none
(cd "$BINARIES_DIR" && md5sum autoupdate-full.bin > autoupdate-full.bin.md5)
echo "OK: autoupdate-full.bin"
