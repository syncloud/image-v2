#!/bin/bash -ex

# Take an Armbian image and repartition it for A/B rootfs layout
# Input: single Armbian image (1 or 2 partitions)
# Output: image with boot + rootfs-a + rootfs-b + data
#
# Armbian images come in two layouts:
#   - 2 partitions: p1=boot (vfat), p2=rootfs (ext4) — e.g. Raspberry Pi
#   - 1 partition:  p1=rootfs (ext4) with /boot inside — e.g. ODROID
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

# Cleanup handler to free loop devices on failure
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

# Mount Armbian image to extract contents
ARMBIAN_LOOP=$(losetup --find --show "$ARMBIAN_IMAGE")
kpartx -avs "$ARMBIAN_LOOP"
ARMBIAN_LOOP_NAME=$(basename "$ARMBIAN_LOOP")

# Detect partition layout: 1 or 2 partitions
PART_COUNT=$(ls /dev/mapper/${ARMBIAN_LOOP_NAME}p* 2>/dev/null | wc -l)
echo "Armbian image has $PART_COUNT partition(s)"

mkdir -p "$WORK_DIR"/{armbian-boot,armbian-root}

if [[ "$PART_COUNT" -ge 2 ]]; then
    # 2-partition layout: p1=boot, p2=rootfs
    mount "/dev/mapper/${ARMBIAN_LOOP_NAME}p1" "$WORK_DIR/armbian-boot"
    mount "/dev/mapper/${ARMBIAN_LOOP_NAME}p2" "$WORK_DIR/armbian-root"
    BOOT_SIZE=$(df -BM --output=used "$WORK_DIR/armbian-boot" | tail -1 | tr -d 'M ')
else
    # 1-partition layout: p1=rootfs with /boot inside
    mount "/dev/mapper/${ARMBIAN_LOOP_NAME}p1" "$WORK_DIR/armbian-root"
    # Copy boot files out of rootfs
    cp -a "$WORK_DIR/armbian-root/boot"/* "$WORK_DIR/armbian-boot/" || true
    BOOT_SIZE=$(du -sm "$WORK_DIR/armbian-boot" | cut -f1)
fi

ROOT_SIZE=$(df -BM --output=used "$WORK_DIR/armbian-root" | tail -1 | tr -d 'M ')

# Add margins: boot +16M, rootfs +512M each, data 1G
BOOT_PART=$((BOOT_SIZE + 16))
ROOT_PART=$((ROOT_SIZE + 512))
DATA_PART=1024
TOTAL=$((BOOT_PART + ROOT_PART * 2 + DATA_PART + 16))

echo "Partition sizes: boot=${BOOT_PART}M rootfs=${ROOT_PART}M (x2) data=${DATA_PART}M total=${TOTAL}M"

# Create output image
truncate -s ${TOTAL}M "$OUTPUT_IMAGE"

# Partition
sgdisk -Z "$OUTPUT_IMAGE"
sgdisk -n 1:0:+${BOOT_PART}M  -t 1:0700 -c 1:boot      "$OUTPUT_IMAGE"
sgdisk -n 2:0:+${ROOT_PART}M  -t 2:8300 -c 2:rootfs-a   "$OUTPUT_IMAGE"
sgdisk -n 3:0:+${ROOT_PART}M  -t 3:8300 -c 3:rootfs-b   "$OUTPUT_IMAGE"
sgdisk -n 4:0:0               -t 4:8300 -c 4:data        "$OUTPUT_IMAGE"

# Write U-Boot to the image (board-specific offset)
# Armbian images have U-Boot at sector 1 (512 bytes in) or sector 8 (4096 bytes in)
dd if="$ARMBIAN_IMAGE" of="$OUTPUT_IMAGE" bs=512 skip=1 seek=1 count=8191 conv=notrunc

# Setup loop for output image
OUT_LOOP=$(losetup --find --show "$OUTPUT_IMAGE")
kpartx -avs "$OUT_LOOP"
OUT_LOOP_NAME=$(basename "$OUT_LOOP")
OUT_BOOT="/dev/mapper/${OUT_LOOP_NAME}p1"
OUT_ROOTFS_A="/dev/mapper/${OUT_LOOP_NAME}p2"
OUT_ROOTFS_B="/dev/mapper/${OUT_LOOP_NAME}p3"
OUT_DATA="/dev/mapper/${OUT_LOOP_NAME}p4"

# Format
mkfs.vfat -F 32 "$OUT_BOOT"
mkfs.ext4 -L rootfs-a "$OUT_ROOTFS_A"
mkfs.ext4 -L rootfs-b "$OUT_ROOTFS_B"
mkfs.ext4 -L data "$OUT_DATA"

# Copy boot partition
mkdir -p "$WORK_DIR/out-boot"
mount "$OUT_BOOT" "$WORK_DIR/out-boot"
cp -a "$WORK_DIR/armbian-boot"/* "$WORK_DIR/out-boot/"

# Install RAUC-aware boot script
mkimage -C none -A arm64 -T script -d "$ROOT/rauc/uboot-boot.cmd" "$WORK_DIR/out-boot/boot.scr"
umount "$WORK_DIR/out-boot"

# Copy rootfs to slot A
mkdir -p "$WORK_DIR/out-rootfs"
mount "$OUT_ROOTFS_A" "$WORK_DIR/out-rootfs"
cp -a "$WORK_DIR/armbian-root"/* "$WORK_DIR/out-rootfs/"

# Install RAUC on rootfs (no chroot — download arm64 .deb and extract directly)
RAUC_DEB="$WORK_DIR/rauc.deb"
RAUC_DEB_URL=$(wget -q -O - "http://ports.ubuntu.com/dists/noble/universe/binary-arm64/Packages.gz" \
    | zcat | grep -A 20 "^Package: rauc$" | grep "^Filename:" | head -1 | awk '{print $2}')
wget -O "$RAUC_DEB" "http://ports.ubuntu.com/$RAUC_DEB_URL"
dpkg-deb -x "$RAUC_DEB" "$WORK_DIR/out-rootfs"

# Install RAUC config
mkdir -p "$WORK_DIR/out-rootfs/etc/rauc"
sed "s|@RAUC_COMPATIBLE@|${RAUC_COMPATIBLE}|;s|@BOOTLOADER@|uboot|" \
    "$ROOT/rauc/system.conf" > "$WORK_DIR/out-rootfs/etc/rauc/system.conf"
mkdir -p "$WORK_DIR/out-rootfs/usr/lib/rauc"
cp "$ROOT/rauc/post-install.sh" "$WORK_DIR/out-rootfs/usr/lib/rauc/"
chmod +x "$WORK_DIR/out-rootfs/usr/lib/rauc/post-install.sh"

# Install update agent
mkdir -p "$WORK_DIR/out-rootfs/usr/lib/syncloud"
cp "$ROOT/update-agent/syncloud-update.sh" "$WORK_DIR/out-rootfs/usr/lib/syncloud/"
chmod +x "$WORK_DIR/out-rootfs/usr/lib/syncloud/syncloud-update.sh"
cp "$ROOT/update-agent/syncloud-update.service" "$WORK_DIR/out-rootfs/etc/systemd/system/"
cp "$ROOT/update-agent/syncloud-update.timer" "$WORK_DIR/out-rootfs/etc/systemd/system/"

# Enable update timer (create symlink instead of chroot systemctl)
mkdir -p "$WORK_DIR/out-rootfs/etc/systemd/system/timers.target.wants"
ln -sf /etc/systemd/system/syncloud-update.timer \
    "$WORK_DIR/out-rootfs/etc/systemd/system/timers.target.wants/syncloud-update.timer"

umount "$WORK_DIR/out-rootfs"

# Clone rootfs-a to rootfs-b
dd if="$OUT_ROOTFS_A" of="$OUT_ROOTFS_B" bs=4M status=progress
e2label "$OUT_ROOTFS_B" rootfs-b

# Cleanup is handled by trap
echo "Image built: $OUTPUT_IMAGE"
