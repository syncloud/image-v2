#!/bin/bash -ex

# Take an Armbian image and repartition it for A/B rootfs layout
# Input: single Armbian image (1 or 2 partitions)
# Output: image with boot + rootfs-a + rootfs-b + data
#
# Usage: ./tools/repartition-ab.sh <armbian-image> <board-dir> <output-dir>

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(dirname "$DIR")

ARMBIAN_IMAGE=$1
BOARD_DIR=$2
OUTPUT_DIR=$3

source "$BOARD_DIR/board.conf"
BOARD_NAME=$(basename "$BOARD_DIR")

WORK_DIR="$ROOT/build/work-$BOARD_NAME"
mkdir -p "$WORK_DIR" "$OUTPUT_DIR"

OUTPUT_IMAGE="$OUTPUT_DIR/syncloud-${BOARD_NAME}.img"

cleanup() {
    set +e
    umount "$WORK_DIR/out-rootfs" 2>/dev/null
    umount "$WORK_DIR/out-boot" 2>/dev/null
    umount "$WORK_DIR/armbian-boot" 2>/dev/null
    umount "$WORK_DIR/armbian-root" 2>/dev/null
    [[ -n "$OUT_LOOP" ]] && { kpartx -d "$OUT_LOOP" 2>/dev/null; losetup -d "$OUT_LOOP" 2>/dev/null; }
    [[ -n "$ARMBIAN_LOOP" ]] && { kpartx -d "$ARMBIAN_LOOP" 2>/dev/null; losetup -d "$ARMBIAN_LOOP" 2>/dev/null; }
}
trap cleanup EXIT

# Mount Armbian image
ARMBIAN_LOOP=$(losetup --find --show "$ARMBIAN_IMAGE")
kpartx -avs "$ARMBIAN_LOOP"
ARMBIAN_LOOP_NAME=$(basename "$ARMBIAN_LOOP")

# Detect partition layout
PART_COUNT=$(ls /dev/mapper/${ARMBIAN_LOOP_NAME}p* 2>/dev/null | wc -l)
echo "Armbian image has $PART_COUNT partition(s)"

mkdir -p "$WORK_DIR"/{armbian-boot,armbian-root}

if [[ "$PART_COUNT" -ge 2 ]]; then
    SEPARATE_BOOT=true
    mount "/dev/mapper/${ARMBIAN_LOOP_NAME}p1" "$WORK_DIR/armbian-boot"
    mount "/dev/mapper/${ARMBIAN_LOOP_NAME}p2" "$WORK_DIR/armbian-root"
    BOOT_SIZE=$(df -BM --output=used "$WORK_DIR/armbian-boot" | tail -1 | tr -d 'M ')
else
    SEPARATE_BOOT=false
    mount "/dev/mapper/${ARMBIAN_LOOP_NAME}p1" "$WORK_DIR/armbian-root"
    BOOT_SIZE=1
fi

ROOT_SIZE=$(df -BM --output=used "$WORK_DIR/armbian-root" | tail -1 | tr -d 'M ')

BOOT_PART=$((BOOT_SIZE + 16))
ROOT_PART=$((ROOT_SIZE + 512))
DATA_PART=1024
TOTAL=$((BOOT_PART + ROOT_PART * 2 + DATA_PART + 16))

echo "Partition sizes: boot=${BOOT_PART}M rootfs=${ROOT_PART}M (x2) data=${DATA_PART}M total=${TOTAL}M"

# Create output image
truncate -s ${TOTAL}M "$OUTPUT_IMAGE"

sgdisk -Z "$OUTPUT_IMAGE"
sgdisk -n 1:0:+${BOOT_PART}M  -t 1:0700 -c 1:boot      "$OUTPUT_IMAGE"
sgdisk -n 2:0:+${ROOT_PART}M  -t 2:8300 -c 2:rootfs-a   "$OUTPUT_IMAGE"
sgdisk -n 3:0:+${ROOT_PART}M  -t 3:8300 -c 3:rootfs-b   "$OUTPUT_IMAGE"
sgdisk -n 4:0:0               -t 4:8300 -c 4:data        "$OUTPUT_IMAGE"

# Copy U-Boot
dd if="$ARMBIAN_IMAGE" of="$OUTPUT_IMAGE" bs=512 skip=1 seek=1 count=8191 conv=notrunc

# Setup output loop
OUT_LOOP=$(losetup --find --show "$OUTPUT_IMAGE")
kpartx -avs "$OUT_LOOP"
OUT_LOOP_NAME=$(basename "$OUT_LOOP")

# Format
mkfs.vfat -F 32 "/dev/mapper/${OUT_LOOP_NAME}p1"
mkfs.ext4 -L rootfs-a "/dev/mapper/${OUT_LOOP_NAME}p2"
mkfs.ext4 -L rootfs-b "/dev/mapper/${OUT_LOOP_NAME}p3"
mkfs.ext4 -L data "/dev/mapper/${OUT_LOOP_NAME}p4"

# Copy boot partition
mkdir -p "$WORK_DIR/out-boot"
mount "/dev/mapper/${OUT_LOOP_NAME}p1" "$WORK_DIR/out-boot"
if [[ "$SEPARATE_BOOT" == "true" ]]; then
    cp -rL --no-preserve=ownership "$WORK_DIR/armbian-boot"/* "$WORK_DIR/out-boot/"
fi
mkimage -C none -A arm64 -T script -d "$ROOT/rauc/uboot-boot.cmd" "$WORK_DIR/out-boot/boot.scr"
umount "$WORK_DIR/out-boot"

# Copy rootfs to slot A
mkdir -p "$WORK_DIR/out-rootfs"
mount "/dev/mapper/${OUT_LOOP_NAME}p2" "$WORK_DIR/out-rootfs"
cp -a "$WORK_DIR/armbian-root"/* "$WORK_DIR/out-rootfs/"

# Unmount Armbian source (no longer needed)
if [[ "$SEPARATE_BOOT" == "true" ]]; then
    umount "$WORK_DIR/armbian-boot"
fi
umount "$WORK_DIR/armbian-root"
kpartx -d "$ARMBIAN_LOOP"
losetup -d "$ARMBIAN_LOOP"
ARMBIAN_LOOP=""

# Install services via chroot (works because runner arch matches target)
"$ROOT/tools/install-services.sh" "$WORK_DIR/out-rootfs" "$BOARD_DIR"

umount "$WORK_DIR/out-rootfs"

# Clone rootfs-a to rootfs-b
dd if="/dev/mapper/${OUT_LOOP_NAME}p2" of="/dev/mapper/${OUT_LOOP_NAME}p3" bs=4M status=progress
e2label "/dev/mapper/${OUT_LOOP_NAME}p3" rootfs-b

echo "Image built: $OUTPUT_IMAGE"
