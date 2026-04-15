#!/bin/bash -ex

# Write rootfs tarball back into image, clone to slot B, compress with xz
# Runs after install-platform.sh exports the Docker container as a tar
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

echo "=== Mounting image ($(date)) ==="
LOOP=$(losetup --find --show "$IMAGE")
kpartx -avs "$LOOP"
LOOP_NAME=$(basename "$LOOP")

cleanup() {
    set +e
    umount "$WORK_DIR/rootfs" 2>/dev/null
    kpartx -d "$LOOP" 2>/dev/null
    losetup -d "$LOOP" 2>/dev/null
}
trap cleanup EXIT

# Write rootfs tar to partition
mkdir -p "$WORK_DIR/rootfs"
mount "/dev/mapper/${LOOP_NAME}p2" "$WORK_DIR/rootfs"

echo "=== Writing rootfs to image ($(date)) ==="
rm -rf "$WORK_DIR/rootfs"/*
tar -C "$WORK_DIR/rootfs" -xf "$ROOTFS_TAR"

umount "$WORK_DIR/rootfs"

# Clone rootfs-a to rootfs-b
echo "=== Cloning rootfs-a to rootfs-b ($(date)) ==="
dd if="/dev/mapper/${LOOP_NAME}p2" of="/dev/mapper/${LOOP_NAME}p3" bs=4M status=progress
e2label "/dev/mapper/${LOOP_NAME}p3" rootfs-b

# Cleanup loop before compression
kpartx -d "$LOOP"
losetup -d "$LOOP"
LOOP=""

# Compress
echo "=== Compressing image with xz ($(date)) ==="
xz -T0 "$IMAGE"
echo "=== Done: ${IMAGE}.xz ($(date)) ==="
