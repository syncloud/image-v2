#!/bin/bash -ex

# Build an amd64 UEFI image using pre-built rootfs + debootstrap kernel/GRUB
# Downloads rootfs tarball (with snapd+platform pre-installed).
# Installs kernel + GRUB via chroot (native amd64).
# Assembles A/B partition layout, enables v2 services, compresses with xz.
#
# Usage: ./tools/build-amd64.sh boards/amd64-uefi

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(dirname "$DIR")

BOARD_DIR=$1
if [[ -z "$BOARD_DIR" || ! -f "$BOARD_DIR/board.conf" ]]; then
    echo "Usage: $0 <board-dir>"
    exit 1
fi

source "$BOARD_DIR/board.conf"
BOARD_NAME=$(basename "$BOARD_DIR")

OUTPUT_DIR="$ROOT/output"
WORK_DIR="$ROOT/build/$BOARD_NAME"
ROOTFS_DIR="$WORK_DIR/rootfs"
IMAGE="$OUTPUT_DIR/syncloud-${BOARD_NAME}.img"

mkdir -p "$OUTPUT_DIR" "$ROOTFS_DIR"

# Download pre-built rootfs (from rootfs CI)
ROOTFS_URL="${ROOTFS_URL:-http://ci.syncloud.org:8081/files/rootfs/432-bookworm-amd64/rootfs-bookworm-amd64.tar.gz}"
ROOTFS_TAR="$WORK_DIR/rootfs.tar.gz"
if [[ ! -f "$ROOTFS_TAR" ]]; then
    echo "=== Downloading rootfs ($(date)) ==="
    wget -O "$ROOTFS_TAR" "$ROOTFS_URL" --progress=dot:giga
fi
echo "rootfs: $(ls -lh "$ROOTFS_TAR")"

cleanup() {
    set +e
    umount "$ROOTFS_DIR/boot/efi" 2>/dev/null
    umount "$ROOTFS_DIR/sys" 2>/dev/null
    umount "$ROOTFS_DIR/proc" 2>/dev/null
    umount "$ROOTFS_DIR/dev" 2>/dev/null
    umount "$ROOTFS_DIR" 2>/dev/null
    [[ -n "$LOOP" ]] && { kpartx -d "$LOOP" 2>/dev/null; losetup -d "$LOOP" 2>/dev/null; }
}
trap cleanup EXIT

# Create image: 256M ESP + 4G rootfs-a + 4G rootfs-b + 1G data
echo "=== Creating image ($(date)) ==="
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

# --- Extract rootfs ---
echo "=== Extracting rootfs to slot A ($(date)) ==="
mount "$ROOTFS_A" "$ROOTFS_DIR"
tar xzf "$ROOTFS_TAR" -C "$ROOTFS_DIR"

# --- Install kernel + GRUB via chroot (native amd64) ---
echo "=== Installing kernel and GRUB ($(date)) ==="
# Fix DNS
rm -f "$ROOTFS_DIR/etc/resolv.conf"
cp /etc/resolv.conf "$ROOTFS_DIR/etc/resolv.conf" 2>/dev/null || echo "nameserver 8.8.8.8" > "$ROOTFS_DIR/etc/resolv.conf"

mount --bind /dev "$ROOTFS_DIR/dev"
mount --bind /proc "$ROOTFS_DIR/proc"
mount --bind /sys "$ROOTFS_DIR/sys"

chroot "$ROOTFS_DIR" apt-get update
chroot "$ROOTFS_DIR" bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y linux-image-amd64 grub-efi-amd64 systemd-sysv"

# Install GRUB to ESP
echo "=== Installing GRUB to ESP ($(date)) ==="
mkdir -p "$ROOTFS_DIR/boot/efi"
mount "$ESP" "$ROOTFS_DIR/boot/efi"
chroot "$ROOTFS_DIR" grub-install --target=x86_64-efi --efi-directory=/boot/efi --no-nvram
cp "$ROOT/rauc/grub.cfg" "$ROOTFS_DIR/boot/grub/grub.cfg"
umount "$ROOTFS_DIR/boot/efi"

umount "$ROOTFS_DIR/sys"
umount "$ROOTFS_DIR/proc"
umount "$ROOTFS_DIR/dev"

# --- Enable v2 services ---
echo "=== Enabling v2 services ($(date)) ==="
rm -f "$ROOTFS_DIR/etc/systemd/system/syncloud-data-init.service"
rm -f "$ROOTFS_DIR/etc/systemd/system/syncloud-update.service"
rm -f "$ROOTFS_DIR/etc/systemd/system/syncloud-update.timer"
rm -f "$ROOTFS_DIR/etc/systemd/system/syncloud-boot-ok.service"

mkdir -p "$ROOTFS_DIR/etc/systemd/system/local-fs.target.wants"
mkdir -p "$ROOTFS_DIR/etc/systemd/system/timers.target.wants"
ln -sf /usr/lib/systemd/system/syncloud-data-init.service \
    "$ROOTFS_DIR/etc/systemd/system/local-fs.target.wants/syncloud-data-init.service"
ln -sf /usr/lib/systemd/system/syncloud-update.timer \
    "$ROOTFS_DIR/etc/systemd/system/timers.target.wants/syncloud-update.timer"

# Write board-specific RAUC config
echo "=== Writing RAUC config ($(date)) ==="
mkdir -p "$ROOTFS_DIR/etc/rauc"
BOOTLOADER_TYPE=${BOOTLOADER:-grub}
sed "s|@RAUC_COMPATIBLE@|${RAUC_COMPATIBLE}|;s|@BOOTLOADER@|${BOOTLOADER_TYPE}|" \
    "$ROOT/rauc/system.conf" > "$ROOTFS_DIR/etc/rauc/system.conf"
mkdir -p "$ROOTFS_DIR/usr/lib/rauc"
cp "$ROOT/rauc/post-install.sh" "$ROOTFS_DIR/usr/lib/rauc/"
chmod +x "$ROOTFS_DIR/usr/lib/rauc/post-install.sh"

# Add data partition to fstab
echo "=== Configuring fstab ($(date)) ==="
mkdir -p "$ROOTFS_DIR/mnt/data"
grep -q 'by-partlabel/data' "$ROOTFS_DIR/etc/fstab" || \
    echo '/dev/disk/by-partlabel/data  /mnt/data  ext4  defaults,nofail  0  2' >> "$ROOTFS_DIR/etc/fstab"

umount "$ROOTFS_DIR"

# --- Clone A to B ---
echo "=== Cloning rootfs-a to rootfs-b ($(date)) ==="
dd if="$ROOTFS_A" of="$ROOTFS_B" bs=4M status=progress
e2label "$ROOTFS_B" rootfs-b

# --- Cleanup loop devices ---
echo "=== Cleaning up loop devices ($(date)) ==="
kpartx -d "$LOOP"
losetup -d "$LOOP"
LOOP=""

# --- Compress ---
echo "=== Compressing with xz ($(date)) ==="
xz -T0 "$IMAGE"

echo "=== Done: ${IMAGE}.xz ($(date)) ==="
