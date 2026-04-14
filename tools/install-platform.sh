#!/bin/sh -ex

# Install platform snap by booting rootfs in Docker with systemd
# This mirrors the v1 rootfs approach: docker run with /sbin/init, then snap install
# Runs inside docker:dind Alpine image — installs deps via apk
#
# Usage: ./tools/install-platform.sh <board-dir>

apk add --no-cache multipath-tools e2fsprogs e2fsprogs-extra util-linux losetup

DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$DIR")

BOARD_DIR=$1
. "$BOARD_DIR/board.conf"
BOARD_NAME=$(basename "$BOARD_DIR")

IMAGE="$ROOT/output/syncloud-${BOARD_NAME}.img"
WORK_DIR="$ROOT/build/platform-$BOARD_NAME"
CONTAINER_NAME="syncloud-platform-$BOARD_NAME"

mkdir -p "$WORK_DIR"

echo "=== Mounting image to extract rootfs ==="
LOOP=$(losetup --find --show "$IMAGE")
echo "loop device: $LOOP"
kpartx -avs "$LOOP"
LOOP_NAME=$(basename "$LOOP")

cleanup() {
    set +e
    echo "=== Cleanup ==="
    docker stop "$CONTAINER_NAME" 2>/dev/null
    docker rm "$CONTAINER_NAME" 2>/dev/null
    docker rmi "$CONTAINER_NAME" 2>/dev/null
    umount "$WORK_DIR/rootfs" 2>/dev/null
    kpartx -d "$LOOP" 2>/dev/null
    losetup -d "$LOOP" 2>/dev/null
}
trap cleanup EXIT

# Mount rootfs-a (partition 2)
mkdir -p "$WORK_DIR/rootfs"
mount "/dev/mapper/${LOOP_NAME}p2" "$WORK_DIR/rootfs"

# Prepare rootfs for Docker: strip fstab and mask services that break in containers
# Must be done BEFORE docker run so systemd never starts them
echo "=== Preparing rootfs for Docker ==="
echo "tmpfs /tmp tmpfs defaults,nosuid 0 0" > "$WORK_DIR/rootfs/etc/fstab"
for svc in armbian-resize-filesystem syncloud-data-init systemd-remount-fs systemd-networkd systemd-networkd-wait-online; do
    ln -sf /dev/null "$WORK_DIR/rootfs/etc/systemd/system/${svc}.service" 2>/dev/null || true
done
ln -sf /dev/null "$WORK_DIR/rootfs/etc/systemd/system/systemd-networkd.socket" 2>/dev/null || true

# Export rootfs to Docker
echo "=== Importing rootfs into Docker ==="
tar -C "$WORK_DIR/rootfs" -cf - . | docker import - "$CONTAINER_NAME"

umount "$WORK_DIR/rootfs"

# Boot container with systemd
echo "=== Starting container with systemd ==="
docker run -d --privileged --name "$CONTAINER_NAME" "$CONTAINER_NAME" /sbin/init

# Wait for systemd to be ready
echo "=== Waiting for systemd ==="
SYSTEMD_READY=false
i=0
while [ $i -lt 120 ]; do
    i=$((i + 1))
    STATUS=$(docker exec "$CONTAINER_NAME" systemctl is-system-running 2>/dev/null | head -1 | tr -d '[:space:]' || echo "not-ready")
    echo "systemd status: $STATUS ($i)"
    if [ "$STATUS" = "running" ] || [ "$STATUS" = "degraded" ]; then
        SYSTEMD_READY=true
        echo "systemd ready after ${i} attempts (status: $STATUS)"
        break
    fi
    sleep 2
done
if [ "$SYSTEMD_READY" = "false" ]; then
    echo "ERROR: systemd failed to reach running/degraded state"
    docker exec "$CONTAINER_NAME" systemctl list-jobs 2>/dev/null | head -20 || true
    docker exec "$CONTAINER_NAME" systemctl list-units --failed 2>/dev/null || true
    exit 1
fi

# Start snapd
echo "=== Starting snapd ==="
docker exec "$CONTAINER_NAME" systemctl start snapd.socket
docker exec "$CONTAINER_NAME" systemctl start snapd.service
sleep 5
echo "=== snapd status ==="
docker exec "$CONTAINER_NAME" systemctl status snapd.service || true
docker exec "$CONTAINER_NAME" snap version

# Install platform snap
echo "=== Installing platform snap ==="
PLATFORM_INSTALLED=false
i=0
while [ $i -lt 10 ]; do
    i=$((i + 1))
    if docker exec "$CONTAINER_NAME" snap install platform; then
        echo "platform snap installed successfully"
        PLATFORM_INSTALLED=true
        break
    fi
    echo "retry $i"
    sleep 10
done
if [ "$PLATFORM_INSTALLED" = "false" ]; then
    echo "ERROR: failed to install platform snap"
    docker exec "$CONTAINER_NAME" snap list || true
    docker exec "$CONTAINER_NAME" journalctl -u snapd --no-pager -n 50 || true
    exit 1
fi
docker exec "$CONTAINER_NAME" snap list

# Stop container
echo "=== Stopping container ($(date)) ==="
docker stop "$CONTAINER_NAME"

# Export container back and write to rootfs-a
echo "=== Writing back to image ($(date)) ==="
mount "/dev/mapper/${LOOP_NAME}p2" "$WORK_DIR/rootfs"

# Clear rootfs and replace with container export
echo "=== Clearing rootfs ($(date)) ==="
rm -rf "$WORK_DIR/rootfs"/*
echo "=== Docker export ($(date)) ==="
docker export "$CONTAINER_NAME" | tar -C "$WORK_DIR/rootfs" -xf -
echo "=== Docker export done ($(date)) ==="

# Clone rootfs-a to rootfs-b again (now includes platform snap)
umount "$WORK_DIR/rootfs"
echo "=== Cloning rootfs-a to rootfs-b ($(date)) ==="
dd if="/dev/mapper/${LOOP_NAME}p2" of="/dev/mapper/${LOOP_NAME}p3" bs=4M
e2label "/dev/mapper/${LOOP_NAME}p3" rootfs-b
echo "=== Clone done ($(date)) ==="

# Compress image
echo "=== Compressing image with xz ($(date)) ==="
apk add --no-cache xz
xz -T0 "$IMAGE"
echo "=== Compression done ($(date)) ==="
echo "=== Done: ${IMAGE}.xz ==="
