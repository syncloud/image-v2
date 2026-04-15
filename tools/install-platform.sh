#!/bin/sh -ex

# Install platform snap by booting rootfs in Docker with systemd
# This mirrors the v1 rootfs approach: docker run with /sbin/init, then snap install
#
# ONLY does Docker operations — no losetup/kpartx (those break the Drone runner).
# Expects rootfs tarball at build/rootfs-<board>.tar (created by build step).
# Produces build/rootfs-platform-<board>.tar (with platform snap installed).
#
# Usage: ./tools/install-platform.sh <board-dir>

DIR=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$DIR")

BOARD_DIR=$1
. "$BOARD_DIR/board.conf"
BOARD_NAME=$(basename "$BOARD_DIR")

ROOTFS_TAR="$ROOT/build/rootfs-${BOARD_NAME}.tar"
OUTPUT_TAR="$ROOT/build/rootfs-platform-${BOARD_NAME}.tar"
CONTAINER_NAME="syncloud-platform-$BOARD_NAME"

if [ ! -f "$ROOTFS_TAR" ]; then
    echo "ERROR: rootfs tarball not found: $ROOTFS_TAR"
    exit 1
fi

cleanup() {
    set +e
    echo "=== Cleanup ==="
    docker stop "$CONTAINER_NAME" 2>/dev/null
    docker rm "$CONTAINER_NAME" 2>/dev/null
    docker rmi "$CONTAINER_NAME" 2>/dev/null
}
trap cleanup EXIT

# Import rootfs into Docker
echo "=== Importing rootfs into Docker ($(date)) ==="
docker import "$ROOTFS_TAR" "$CONTAINER_NAME"

# Boot container with systemd
echo "=== Starting container with systemd ($(date)) ==="
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
echo "=== Starting snapd ($(date)) ==="
docker exec "$CONTAINER_NAME" systemctl start snapd.socket
docker exec "$CONTAINER_NAME" systemctl start snapd.service
sleep 5
echo "=== snapd status ==="
docker exec "$CONTAINER_NAME" systemctl status snapd.service || true
docker exec "$CONTAINER_NAME" snap version

# Install platform snap
echo "=== Installing platform snap ($(date)) ==="
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

# Stop and export
echo "=== Stopping container ($(date)) ==="
docker stop "$CONTAINER_NAME"

echo "=== Exporting container ($(date)) ==="
docker export "$CONTAINER_NAME" > "$OUTPUT_TAR"
echo "=== Export done: $(ls -lh "$OUTPUT_TAR") ==="
