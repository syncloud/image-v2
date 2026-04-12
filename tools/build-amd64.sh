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

cleanup() {
    set +e
    umount "$ROOTFS_DIR/boot/efi" 2>/dev/null
    umount "$ROOTFS_DIR" 2>/dev/null
    [[ -n "$LOOP" ]] && { kpartx -d "$LOOP" 2>/dev/null; losetup -d "$LOOP" 2>/dev/null; }
}
trap cleanup EXIT

# Create image: 256M ESP + 4G rootfs-a + 4G rootfs-b + 1G data
IMAGE_SIZE=$((256 + 4096 + 4096 + 1024))
truncate -s ${IMAGE_SIZE}M "$IMAGE"

sgdisk -Z "$IMAGE"
sgdisk -n 1:0:+256M  -t 1:ef00 -c 1:esp       "$IMAGE"
sgdisk -n 2:0:+4G    -t 2:8300 -c 2:rootfs-a   "$IMAGE"
sgdisk -n 3:0:+4G    -t 3:8300 -c 3:rootfs-b   "$IMAGE"
sgdisk -n 4:0:0      -t 4:8300 -c 4:data        "$IMAGE"

LOOP=$(losetup --find --show "$IMAGE")
kpartx -avs "$LOOP"
LOOP_NAME=$(basename "$LOOP")
ESP="/dev/mapper/${LOOP_NAME}p1"
ROOTFS_A="/dev/mapper/${LOOP_NAME}p2"
ROOTFS_B="/dev/mapper/${LOOP_NAME}p3"
DATA="/dev/mapper/${LOOP_NAME}p4"

mkfs.vfat -F 32 -n ESP "$ESP"
mkfs.ext4 -L rootfs-a "$ROOTFS_A"
mkfs.ext4 -L rootfs-b "$ROOTFS_B"
mkfs.ext4 -L data "$DATA"

mount "$ROOTFS_A" "$ROOTFS_DIR"

# Debootstrap
debootstrap --arch=amd64 "$RELEASE" "$ROOTFS_DIR" http://archive.ubuntu.com/ubuntu

# Enable universe repo (rauc is in universe)
cat > "$ROOTFS_DIR/etc/apt/sources.list.d/ubuntu.sources" <<SOURCES
Types: deb
URIs: http://archive.ubuntu.com/ubuntu
Suites: noble noble-updates
Components: main universe
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
SOURCES

# Install kernel and GRUB via chroot
mount --bind /dev "$ROOTFS_DIR/dev"
mount --bind /proc "$ROOTFS_DIR/proc"
mount --bind /sys "$ROOTFS_DIR/sys"

chroot "$ROOTFS_DIR" apt-get update
chroot "$ROOTFS_DIR" apt-get install -y \
    linux-image-generic \
    grub-efi-amd64 \
    systemd-sysv

umount "$ROOTFS_DIR/sys"
umount "$ROOTFS_DIR/proc"
umount "$ROOTFS_DIR/dev"

# Install all Syncloud services (rauc, snapd, platform snap, data-init, update agent)
"$ROOT/tools/install-services.sh" "$ROOTFS_DIR" "$BOARD_DIR"

# Install GRUB to ESP
mkdir -p "$ROOTFS_DIR/boot/efi"
mount "$ESP" "$ROOTFS_DIR/boot/efi"
mount --bind /dev "$ROOTFS_DIR/dev"
mount --bind /proc "$ROOTFS_DIR/proc"
mount --bind /sys "$ROOTFS_DIR/sys"
chroot "$ROOTFS_DIR" grub-install --target=x86_64-efi --efi-directory=/boot/efi --no-nvram
cp "$ROOT/rauc/grub.cfg" "$ROOTFS_DIR/boot/grub/grub.cfg"
umount "$ROOTFS_DIR/boot/efi"
umount "$ROOTFS_DIR/sys"
umount "$ROOTFS_DIR/proc"
umount "$ROOTFS_DIR/dev"

# Clone rootfs-a to rootfs-b
umount "$ROOTFS_DIR"
dd if="$ROOTFS_A" of="$ROOTFS_B" bs=4M status=progress
e2label "$ROOTFS_B" rootfs-b

echo "Image built: $IMAGE"
