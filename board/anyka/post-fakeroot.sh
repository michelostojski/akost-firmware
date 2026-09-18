#!/bin/sh
set -e
TARGET_DIR="$1"
rm -f "$BINARIES_DIR/app.squashfs"
"$HOST_DIR/bin/mksquashfs" "$TARGET_DIR/usr" "$BINARIES_DIR/app.squashfs" \
  -noappend -comp xz -Xbcj arm -b 128K -all-root
rm -rf "$TARGET_DIR/usr"
mkdir -p "$TARGET_DIR/usr"
