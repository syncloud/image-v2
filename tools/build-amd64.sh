#!/bin/bash -ex

# Build an amd64 UEFI image using debootstrap + RAUC A/B layout
# Usage: ./tools/build-amd64.sh boards/amd64-uefi

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(dirname "$DIR")

BOARD_DIR=$1
if [[ -z "$BOARD_DIR" || ! -f "$BOARD_DIR/board.conf" ]]; then
    echo "Usage: $0 <board-dir>"
    exit 1
fi

source "$BOARD_DIR/board.conf"

OUTPUT_DIR="$ROOT/output"
WORK_DIR="$ROOT/build/amd64"
ROOTFS_DIR="$WORK_DIR/rootfs"
IMAGE="$OUTPUT_DIR/syncloud-amd64-uefi.img"

mkdir -p "$OUTPUT_DIR" "$ROOTFS_DIR"

# Create image: 256M ESP + 2G rootfs-a + 2G rootfs-b + 1G data
IMAGE_SIZE=$((256 + 2048 + 2048 + 1024))
truncate -s ${IMAGE_SIZE}M "$IMAGE"

# Partition with GPT labels
sgdisk -Z "$IMAGE"
sgdisk -n 1:0:+256M  -t 1:ef00 -c 1:esp       "$IMAGE"
sgdisk -n 2:0:+2G    -t 2:8300 -c 2:rootfs-a   "$IMAGE"
sgdisk -n 3:0:+2G    -t 3:8300 -c 3:rootfs-b   "$IMAGE"
sgdisk -n 4:0:0      -t 4:8300 -c 4:data        "$IMAGE"

# Setup loop device
LOOP=$(losetup --find --show "$IMAGE")
kpartx -avs "$LOOP"
LOOP_NAME=$(basename "$LOOP")
ESP="/dev/mapper/${LOOP_NAME}p1"
ROOTFS_A="/dev/mapper/${LOOP_NAME}p2"
ROOTFS_B="/dev/mapper/${LOOP_NAME}p3"
DATA="/dev/mapper/${LOOP_NAME}p4"

# Format
mkfs.vfat -F 32 -n ESP "$ESP"
mkfs.ext4 -L rootfs-a "$ROOTFS_A"
mkfs.ext4 -L rootfs-b "$ROOTFS_B"
mkfs.ext4 -L data "$DATA"

# Mount rootfs-a
mount "$ROOTFS_A" "$ROOTFS_DIR"

# Debootstrap
debootstrap --arch=amd64 "$RELEASE" "$ROOTFS_DIR" http://archive.ubuntu.com/ubuntu

# Install kernel, GRUB, RAUC
chroot "$ROOTFS_DIR" apt-get update
chroot "$ROOTFS_DIR" apt-get install -y \
    linux-image-generic \
    grub-efi-amd64 \
    rauc \
    systemd-sysv

# Install RAUC config
sed "s|@RAUC_COMPATIBLE@|${RAUC_COMPATIBLE}|;s|@BOOTLOADER@|grub|" \
    "$ROOT/rauc/system.conf" > "$ROOTFS_DIR/etc/rauc/system.conf"
cp "$ROOT/rauc/post-install.sh" "$ROOTFS_DIR/usr/lib/rauc/"
chmod +x "$ROOTFS_DIR/usr/lib/rauc/post-install.sh"

# Install GRUB to ESP
mount "$ESP" "$ROOTFS_DIR/boot/efi"
chroot "$ROOTFS_DIR" grub-install --target=x86_64-efi --efi-directory=/boot/efi --no-nvram
cp "$ROOT/rauc/grub.cfg" "$ROOTFS_DIR/boot/grub/grub.cfg"
umount "$ROOTFS_DIR/boot/efi"

# Clone rootfs-a to rootfs-b
umount "$ROOTFS_DIR"
dd if="$ROOTFS_A" of="$ROOTFS_B" bs=4M status=progress
e2label "$ROOTFS_B" rootfs-b

# Cleanup
kpartx -d "$LOOP"
losetup -d "$LOOP"

echo "Image built: $IMAGE"
