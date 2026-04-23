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

# The build step compresses the raw image to .img.xz and removes the .img
# to avoid bloating the artifact upload. Decompress on demand for bundling.
if [ ! -f "$ROOTFS_IMAGE" ] ; then
    [ -f "${ROOTFS_IMAGE}.xz" ] || \
        { echo "ERROR: neither ${ROOTFS_IMAGE} nor ${ROOTFS_IMAGE}.xz exists — build step must run first"; exit 1; }
    echo "Decompressing ${ROOTFS_IMAGE}.xz"
    xz -T0 -dk "${ROOTFS_IMAGE}.xz"
fi

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

# Build the bundle. The cert embedded in the signature is the committed
# keyring.pem (self-signed — same file the device trusts). The private
# key is injected by CI from the rauc_signing_key secret into
# rauc/keys/key.pem before this script runs.
[ -f "$ROOT/rauc/keyring.pem" ] || \
    { echo "ERROR: rauc/keyring.pem missing — run tools/gen-keys.sh once and commit rauc/keyring.pem"; exit 1; }
[ -f "$ROOT/rauc/keys/key.pem" ] || \
    { echo "ERROR: rauc/keys/key.pem missing — CI must write it from the rauc_signing_key secret"; exit 1; }

rauc bundle \
    --cert="$ROOT/rauc/keyring.pem" \
    --key="$ROOT/rauc/keys/key.pem" \
    "$BUNDLE_DIR" \
    "$OUTPUT_DIR/syncloud-${BOARD_NAME}-${VERSION}.raucb"

echo "Bundle built: $OUTPUT_DIR/syncloud-${BOARD_NAME}-${VERSION}.raucb"
