#!/bin/bash -ex

# Build a RAUC update bundle from the current rootfs
# This is what gets pushed OTA to devices
# Usage: ./tools/build-bundle.sh <board-dir> <version>

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(dirname "$DIR")

BOARD_DIR=$1
VERSION=$2

if [[ -z "$BOARD_DIR" || -z "$VERSION" ]]; then
    echo "Usage: $0 <board-dir> <version>"
    exit 1
fi

source "$BOARD_DIR/board.conf"
BOARD_NAME=$(basename "$BOARD_DIR")

OUTPUT_DIR="$ROOT/output"
BUNDLE_DIR="$ROOT/build/bundle-$BOARD_NAME"
ROOTFS_IMAGE="$OUTPUT_DIR/syncloud-${BOARD_NAME}.img"

mkdir -p "$BUNDLE_DIR"

# Extract rootfs-a from the built image
LOOP=$(losetup --find --show "$ROOTFS_IMAGE")
kpartx -avs "$LOOP"
LOOP_NAME=$(basename "$LOOP")
ROOTFS_A="/dev/mapper/${LOOP_NAME}p2"
mkdir -p "$BUNDLE_DIR/rootfs"
mount "$ROOTFS_A" "$BUNDLE_DIR/rootfs"

# Create rootfs squashfs for the bundle
mksquashfs "$BUNDLE_DIR/rootfs" "$BUNDLE_DIR/rootfs.img" -comp xz

umount "$BUNDLE_DIR/rootfs"
kpartx -d "$LOOP"
losetup -d "$LOOP"

# Create RAUC bundle manifest
cat > "$BUNDLE_DIR/manifest.raucm" <<EOF
[update]
compatible=${RAUC_COMPATIBLE}
version=${VERSION}

[image.rootfs]
filename=rootfs.img
EOF

# Build the bundle (requires signing key)
rauc bundle \
    --cert="$ROOT/rauc/keys/cert.pem" \
    --key="$ROOT/rauc/keys/key.pem" \
    "$BUNDLE_DIR" \
    "$OUTPUT_DIR/syncloud-${BOARD_NAME}-${VERSION}.raucb"

echo "Bundle built: $OUTPUT_DIR/syncloud-${BOARD_NAME}-${VERSION}.raucb"
