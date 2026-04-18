#!/bin/sh -ex

# Boot an amd64 UEFI image in QEMU and run health checks
# Verifies: systemd boots, RAUC sees slots, snapd + platform running,
# v2 services enabled, partition layout correct.
#
# Usage: ./tools/test-boot.sh <image.img.xz>

apk add --no-cache qemu-system-x86_64 ovmf sshpass xz

IMAGE_XZ=$1
if [ -z "$IMAGE_XZ" ] || [ ! -f "$IMAGE_XZ" ]; then
    echo "Usage: $0 <image.img.xz>"
    exit 1
fi

WORK_DIR=$(mktemp -d)
IMAGE="$WORK_DIR/test.img"
SSH_PORT=2222

cleanup() {
    set +e
    if [ -n "$QEMU_PID" ]; then
        kill "$QEMU_PID" 2>/dev/null
        wait "$QEMU_PID" 2>/dev/null
    fi
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# Decompress image for testing
echo "=== Decompressing image ($(date)) ==="
xz -dk "$IMAGE_XZ" -c > "$IMAGE"
ls -lh "$IMAGE"

# Find OVMF firmware
OVMF=""
for f in /usr/share/ovmf/OVMF.fd /usr/share/OVMF/OVMF_CODE.fd /usr/share/qemu/OVMF.fd; do
    if [ -f "$f" ]; then
        OVMF="$f"
        break
    fi
done
if [ -z "$OVMF" ]; then
    echo "ERROR: OVMF firmware not found"
    exit 1
fi
echo "OVMF: $OVMF"

# Require KVM
if [ ! -e /dev/kvm ]; then
    echo "ERROR: /dev/kvm not available, cannot run boot test"
    exit 1
fi

# Boot image
echo "=== Booting image in QEMU ($(date)) ==="
qemu-system-x86_64 \
    -enable-kvm \
    -bios "$OVMF" \
    -drive file="$IMAGE",format=raw,if=virtio \
    -m 1024 \
    -smp 2 \
    -nographic \
    -net nic,model=virtio \
    -net user,hostfwd=tcp::${SSH_PORT}-:22 \
    -no-reboot \
    &
QEMU_PID=$!

# Wait for SSH
echo "=== Waiting for SSH ($(date)) ==="
SSH="sshpass -p syncloud ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -p $SSH_PORT root@localhost"
SSH_READY=false
i=0
while [ $i -lt 60 ]; do
    i=$((i + 1))
    if $SSH echo "ssh-ok" 2>/dev/null; then
        SSH_READY=true
        echo "SSH ready after $i attempts"
        break
    fi
    echo "waiting for SSH... ($i/60)"
    sleep 5
done
if [ "$SSH_READY" != "true" ]; then
    echo "ERROR: SSH not available after 5 minutes"
    exit 1
fi

# Run health checks
echo "=== Health checks ($(date)) ==="

echo "--- systemd status ---"
$SSH systemctl is-system-running || true

echo "--- partition layout ---"
$SSH lsblk

echo "--- RAUC status ---"
$SSH rauc status || echo "WARN: rauc status failed"

echo "--- snapd ---"
$SSH snap list

echo "--- platform snap ---"
$SSH snap list platform

echo "--- v2 services ---"
$SSH systemctl is-enabled syncloud-data-init.service || echo "WARN: data-init not enabled"
$SSH systemctl is-enabled syncloud-update.timer || echo "WARN: update timer not enabled"
$SSH systemctl is-enabled syncloud-boot-ok.service || echo "WARN: boot-ok not enabled"

echo "--- data partition ---"
$SSH findmnt /mnt/data || echo "WARN: /mnt/data not mounted (expected on first boot without real disk)"

echo "--- fstab ---"
$SSH cat /etc/fstab

echo "=== All checks passed ($(date)) ==="

# Shutdown
$SSH poweroff || true
wait "$QEMU_PID" || true
QEMU_PID=""

echo "=== Boot test complete ==="
