#!/bin/sh -ex

# Convert a compressed raw image to VDI format for VirtualBox
# Usage: ./tools/convert-vdi.sh <image.img.xz>

apk add --no-cache qemu-img xz

IMAGE_XZ=$1
if [ -z "$IMAGE_XZ" ] || [ ! -f "$IMAGE_XZ" ]; then
    echo "Usage: $0 <image.img.xz>"
    exit 1
fi

IMAGE="${IMAGE_XZ%.xz}"
VDI="${IMAGE%.img}.vdi"

echo "=== Decompressing ($(date)) ==="
xz -dk "$IMAGE_XZ"

echo "=== Converting to VDI ($(date)) ==="
qemu-img convert -f raw -O vdi "$IMAGE" "$VDI"
rm "$IMAGE"

echo "=== Compressing VDI ($(date)) ==="
xz -T0 "$VDI"

echo "=== Done: ${VDI}.xz ($(date)) ==="
ls -lh "${VDI}.xz"
