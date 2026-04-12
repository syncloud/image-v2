#!/bin/bash -ex

# Install platform snap by booting rootfs in Docker with systemd
# This mirrors the v1 rootfs approach: docker run with /sbin/init, then snap install
# Runs inside docker:dind Alpine image — installs deps via apk
#
# Usage: ./tools/install-platform.sh <board-dir>

apk add --no-cache bash kpartx e2fsprogs e2fsprogs-extra

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(dirname "$DIR")

BOARD_DIR=$1
source "$BOARD_DIR/board.conf"
BOARD_NAME=$(basename "$BOARD_DIR")

IMAGE="$ROOT/output/syncloud-${BOARD_NAME}.img"
WORK_DIR="$ROOT/build/platform-$BOARD_NAME"
CONTAINER_NAME="syncloud-platform-$BOARD_NAME"

mkdir -p "$WORK_DIR"

echo "=== Mounting image to extract rootfs ==="
LOOP=$(losetup --find --show "$IMAGE")
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

# Export rootfs to Docker
echo "=== Importing rootfs into Docker ==="
tar -C "$WORK_DIR/rootfs" -cf - . | docker import - "$CONTAINER_NAME"

umount "$WORK_DIR/rootfs"

# Boot container with systemd
echo "=== Starting container with systemd ==="
docker run -d --privileged --name "$CONTAINER_NAME" "$CONTAINER_NAME" /sbin/init

# Wait for systemd to be ready
echo "=== Waiting for systemd ==="
for i in $(seq 1 60); do
    if docker exec "$CONTAINER_NAME" systemctl is-system-running 2>/dev/null | grep -qE "running|degraded"; then
        echo "systemd ready after ${i}s"
        break
    fi
    echo "waiting... ($i)"
    sleep 2
done

# Show snapd status
echo "=== snapd status ==="
docker exec "$CONTAINER_NAME" systemctl status snapd.service || true
docker exec "$CONTAINER_NAME" snap version || true

# Install platform snap
echo "=== Installing platform snap ==="
docker exec "$CONTAINER_NAME" bash -c '
for i in $(seq 1 10); do
    if snap install platform; then
        echo "platform snap installed successfully"
        break
    fi
    echo "retry $i"
    sleep 10
done
snap list
'

# Stop container
echo "=== Stopping container ==="
docker stop "$CONTAINER_NAME"

# Export container back and write to rootfs-a
echo "=== Writing back to image ==="
mount "/dev/mapper/${LOOP_NAME}p2" "$WORK_DIR/rootfs"

# Clear rootfs and replace with container export
rm -rf "$WORK_DIR/rootfs"/*
docker export "$CONTAINER_NAME" | tar -C "$WORK_DIR/rootfs" -xf -

# Clone rootfs-a to rootfs-b again (now includes platform snap)
umount "$WORK_DIR/rootfs"
echo "=== Cloning rootfs-a to rootfs-b ==="
dd if="/dev/mapper/${LOOP_NAME}p2" of="/dev/mapper/${LOOP_NAME}p3" bs=4M status=progress
e2label "/dev/mapper/${LOOP_NAME}p3" rootfs-b

echo "=== Platform snap installed into image ==="
