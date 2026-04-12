#!/bin/bash -ex

# Install all Syncloud services into a mounted rootfs via chroot
# Works natively when builder arch matches target arch
#
# Usage: ./tools/install-services.sh <rootfs-mount> <board-dir>

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(dirname "$DIR")

ROOTFS=$1
BOARD_DIR=$2

source "$BOARD_DIR/board.conf"

echo "=== Setting up chroot for $ROOTFS ==="

# Bind mount for chroot
mount --bind /dev "$ROOTFS/dev"
mount --bind /proc "$ROOTFS/proc"
mount --bind /sys "$ROOTFS/sys"

# Fix DNS in chroot (Armbian has resolv.conf as symlink to systemd-resolved stub)
echo "Host resolv.conf:"
cat /etc/resolv.conf || true
echo "Rootfs resolv.conf before fix:"
ls -la "$ROOTFS/etc/resolv.conf" 2>/dev/null || echo "does not exist"
cat "$ROOTFS/etc/resolv.conf" 2>/dev/null || echo "cannot read"
rm -f "$ROOTFS/etc/resolv.conf"
cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf" 2>/dev/null || echo "nameserver 8.8.8.8" > "$ROOTFS/etc/resolv.conf"
echo "Rootfs resolv.conf after fix:"
cat "$ROOTFS/etc/resolv.conf"

cleanup_chroot() {
    umount "$ROOTFS/sys" 2>/dev/null || true
    umount "$ROOTFS/proc" 2>/dev/null || true
    umount "$ROOTFS/dev" 2>/dev/null || true
}
trap cleanup_chroot EXIT

# Verify DNS works in chroot
echo "=== Testing DNS in chroot ==="
chroot "$ROOTFS" cat /etc/resolv.conf
chroot "$ROOTFS" getent hosts ports.ubuntu.com || echo "DNS test failed, trying nslookup"
chroot "$ROOTFS" nslookup ports.ubuntu.com 2>/dev/null || echo "nslookup not available"

# Install rauc
echo "=== Installing rauc ==="
chroot "$ROOTFS" apt-get update
chroot "$ROOTFS" apt-get install -y rauc

# Install snapd (syncloud fork)
echo "=== Installing snapd ==="
SNAPD_VERSION=$(wget -q -O - "http://apps.syncloud.org/releases/stable/snapd2.version")
echo "snapd version: $SNAPD_VERSION"
ARCH=$(chroot "$ROOTFS" dpkg --print-architecture)
echo "arch: $ARCH"
wget -O "$ROOTFS/tmp/snapd.tar.gz" "http://apps.syncloud.org/apps/snapd-${SNAPD_VERSION}-${ARCH}.tar.gz"
chroot "$ROOTFS" bash -c "cd /tmp && tar xzf snapd.tar.gz && ./snapd/install.sh"

# Cleanup temp files
rm -rf "$ROOTFS/tmp/snapd" "$ROOTFS/tmp/snapd.tar.gz"
# Platform snap is installed in a separate Docker-based step (install-platform.sh)

# Install RAUC config
echo "=== Installing RAUC config ==="
mkdir -p "$ROOTFS/etc/rauc"
BOOTLOADER_TYPE=${BOOTLOADER:-uboot}
sed "s|@RAUC_COMPATIBLE@|${RAUC_COMPATIBLE}|;s|@BOOTLOADER@|${BOOTLOADER_TYPE}|" \
    "$ROOT/rauc/system.conf" > "$ROOTFS/etc/rauc/system.conf"
mkdir -p "$ROOTFS/usr/lib/rauc"
cp "$ROOT/rauc/post-install.sh" "$ROOTFS/usr/lib/rauc/"
chmod +x "$ROOTFS/usr/lib/rauc/post-install.sh"

# Install data-init service
echo "=== Installing data-init service ==="
mkdir -p "$ROOTFS/usr/lib/syncloud"
cp "$ROOT/update-agent/data-init.sh" "$ROOTFS/usr/lib/syncloud/"
chmod +x "$ROOTFS/usr/lib/syncloud/data-init.sh"
cp "$ROOT/update-agent/syncloud-data-init.service" "$ROOTFS/etc/systemd/system/"
mkdir -p "$ROOTFS/etc/systemd/system/local-fs.target.wants"
ln -sf /etc/systemd/system/syncloud-data-init.service \
    "$ROOTFS/etc/systemd/system/local-fs.target.wants/syncloud-data-init.service"

# Install update agent
echo "=== Installing update agent ==="
cp "$ROOT/update-agent/syncloud-update.sh" "$ROOTFS/usr/lib/syncloud/"
chmod +x "$ROOTFS/usr/lib/syncloud/syncloud-update.sh"
cp "$ROOT/update-agent/syncloud-update.service" "$ROOTFS/etc/systemd/system/"
cp "$ROOT/update-agent/syncloud-update.timer" "$ROOTFS/etc/systemd/system/"
mkdir -p "$ROOTFS/etc/systemd/system/timers.target.wants"
ln -sf /etc/systemd/system/syncloud-update.timer \
    "$ROOTFS/etc/systemd/system/timers.target.wants/syncloud-update.timer"

# Create mount point and fstab entry for data partition
echo "=== Configuring data partition ==="
mkdir -p "$ROOTFS/mnt/data"
grep -q 'by-partlabel/data' "$ROOTFS/etc/fstab" || \
    echo '/dev/disk/by-partlabel/data  /mnt/data  ext4  defaults,nofail  0  2' >> "$ROOTFS/etc/fstab"
echo "fstab:"
cat "$ROOTFS/etc/fstab"

# Ensure dirs exist for bind mounts
mkdir -p "$ROOTFS/var/lib/snapd" "$ROOTFS/var/snap" "$ROOTFS/snap"

echo "=== Services installed ==="
