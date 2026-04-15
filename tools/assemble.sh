#!/bin/bash -ex

# Write rootfs tarball back into image, clone to slot B, compress with xz
# Each step has echo markers to identify hangs in CI logs
#
# Usage: ./tools/assemble.sh <board-dir>

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(dirname "$DIR")

BOARD_DIR=$1
source "$BOARD_DIR/board.conf"
BOARD_NAME=$(basename "$BOARD_DIR")

IMAGE="$ROOT/output/syncloud-${BOARD_NAME}.img"
ROOTFS_TAR="$ROOT/build/rootfs-platform-${BOARD_NAME}.tar"
WORK_DIR="$ROOT/build/assemble-$BOARD_NAME"

if [ ! -f "$ROOTFS_TAR" ]; then
    echo "ERROR: rootfs tarball not found: $ROOTFS_TAR"
    exit 1
fi

mkdir -p "$WORK_DIR"

echo "=== losetup ($(date)) ==="
LOOP=$(losetup --find --show "$IMAGE")
echo "loop: $LOOP"

echo "=== kpartx ($(date)) ==="
kpartx -avs "$LOOP"
LOOP_NAME=$(basename "$LOOP")

cleanup() {
    set +e
    umount "$WORK_DIR/rootfs" 2>/dev/null
    kpartx -d "$LOOP" 2>/dev/null
    losetup -d "$LOOP" 2>/dev/null
}
trap cleanup EXIT

echo "=== mount ($(date)) ==="
mkdir -p "$WORK_DIR/rootfs"
mount "/dev/mapper/${LOOP_NAME}p2" "$WORK_DIR/rootfs"

echo "=== tar extract ($(date)) ==="
rm -rf "$WORK_DIR/rootfs"/*
echo "=== skipping tar/dd/xz to isolate hang ==="

echo "=== umount ($(date)) ==="
umount "$WORK_DIR/rootfs"

echo "=== kpartx cleanup ($(date)) ==="
kpartx -d "$LOOP"
echo "=== losetup cleanup ($(date)) ==="
losetup -d "$LOOP"
LOOP=""

echo "=== done ($(date)) ==="
