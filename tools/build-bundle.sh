#!/bin/bash -ex

# Build a RAUC update bundle from the board's built .img.
#
# Usage: ./tools/build-bundle.sh <board-dir> <version>
#
# Env overrides (used by tests):
#   IMAGE_PATH   path to source .img / .img.xz (default: output/syncloud-<board>.img)
#   BUNDLE_OUT   output .raucb path (default: output/syncloud-<board>-<version>.raucb)
#   BUNDLE_CERT  signing cert    (default: rauc/keyring.pem)
#   BUNDLE_KEY   signing key     (default: rauc/keys/key.pem)
#   INJECT_DIR   extra files to overlay into the bundled rootfs before
#                packaging (cp -a INJECT_DIR/. into the rootfs mount).
#                Tests use this to drop /etc/syncloud-test-version sentinels.

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(dirname "$DIR")

BOARD_DIR=$1
VERSION=$2
: "${BOARD_DIR:?usage: $0 <board-dir> <version>}"
: "${VERSION:?usage: $0 <board-dir> <version>}"
[ -f "$BOARD_DIR/board.conf" ] || { echo "ERROR: $BOARD_DIR/board.conf not found"; exit 1; }

apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq xz-utils kpartx rauc e2fsprogs

source "$BOARD_DIR/board.conf"
BOARD_NAME=$(basename "$BOARD_DIR")

OUTPUT_DIR="$ROOT/output"
BUNDLE_DIR="$ROOT/build/bundle-$BOARD_NAME-$VERSION"
mkdir -p "$OUTPUT_DIR" "$BUNDLE_DIR"

ROOTFS_IMAGE=${IMAGE_PATH:-$OUTPUT_DIR/syncloud-${BOARD_NAME}.img}
OUT_BUNDLE=${BUNDLE_OUT:-$OUTPUT_DIR/syncloud-${BOARD_NAME}-${VERSION}.raucb}
CERT=${BUNDLE_CERT:-$ROOT/rauc/keyring.pem}
KEY=${BUNDLE_KEY:-$ROOT/rauc/keys/key.pem}

# The build step compresses the raw image to .img.xz and removes the .img
# to avoid bloating the artifact upload. Decompress on demand.
if [ ! -f "$ROOTFS_IMAGE" ]; then
    if [ -f "${ROOTFS_IMAGE}.xz" ]; then
        echo "Decompressing ${ROOTFS_IMAGE}.xz"
        xz -T0 -dk "${ROOTFS_IMAGE}.xz"
    else
        echo "ERROR: neither $ROOTFS_IMAGE nor ${ROOTFS_IMAGE}.xz exists — build step must run first"
        exit 1
    fi
fi
[ -f "$CERT" ] || { echo "ERROR: signing cert missing: $CERT"; exit 1; }
[ -f "$KEY" ]  || { echo "ERROR: signing key missing: $KEY"; exit 1; }

LOOP=""
MNT=""
cleanup() {
    set +e
    [ -n "$MNT" ] && umount "$MNT" 2>/dev/null
    [ -n "$LOOP" ] && { kpartx -d "$LOOP" 2>/dev/null; losetup -d "$LOOP" 2>/dev/null; }
}
trap cleanup EXIT

echo "=== Loop-attach $ROOTFS_IMAGE ==="
LOOP=$(losetup --find --show "$ROOTFS_IMAGE")
kpartx -avs "$LOOP"
LOOP_NAME=$(basename "$LOOP")
ROOTFS_A="/dev/mapper/${LOOP_NAME}p2"
[ -b "$ROOTFS_A" ] || { echo "ERROR: $ROOTFS_A not present after kpartx"; exit 1; }

# RAUC's `type=ext4` slot handler dd's the bundle image bytes raw onto the
# slot partition. The image must therefore *be* an ext4 filesystem image.
# A previous version of this script wrote a squashfs into rootfs.img, which
# left the slot containing squashfs bytes after install — kernel mount
# (rootfstype=ext4) then failed with "Invalid argument" and the device dropped
# to initramfs. Always dd the slot-A partition raw.
#
# dd before any optional INJECT overlay so the source image stays unchanged
# (otherwise repeated calls with different INJECT_DIRs would leave residue
# on the live slot A and make sentinel-based tests meaningless).
echo "=== dd slot-A partition → $BUNDLE_DIR/rootfs.img ==="
dd if="$ROOTFS_A" of="$BUNDLE_DIR/rootfs.img" bs=4M status=progress

kpartx -d "$LOOP"
losetup -d "$LOOP"
LOOP=""

if [ -n "$INJECT_DIR" ]; then
    [ -d "$INJECT_DIR" ] || { echo "ERROR: INJECT_DIR=$INJECT_DIR not a directory"; exit 1; }
    echo "=== Overlaying INJECT_DIR=$INJECT_DIR into bundle copy ==="
    MNT="$BUNDLE_DIR/inject-mnt"
    mkdir -p "$MNT"
    mount -o loop "$BUNDLE_DIR/rootfs.img" "$MNT"
    cp -a "$INJECT_DIR/." "$MNT/"
    sync
    umount "$MNT"
    MNT=""
fi

# Sanity-check: confirm we wrote a real ext4 image, not garbage. dumpe2fs
# returns non-zero on anything that's not an ext2/3/4 superblock — catches
# the squashfs-shaped regression that previously bricked installs.
dumpe2fs -h "$BUNDLE_DIR/rootfs.img" 2>&1 | head -20 || {
    echo "ERROR: bundled rootfs.img is not a valid ext2/3/4 filesystem"
    exit 1
}

cat > "$BUNDLE_DIR/manifest.raucm" <<EOF
[update]
compatible=${RAUC_COMPATIBLE}
version=${VERSION}

[image.rootfs]
filename=rootfs.img
EOF

echo "=== rauc bundle → $OUT_BUNDLE ==="
rauc bundle --cert="$CERT" --key="$KEY" "$BUNDLE_DIR" "$OUT_BUNDLE"

# Self-verify: parse the bundle we just produced. Catches signing/format
# regressions before the artifact is uploaded.
echo "=== Verifying bundle parses ==="
rauc --keyring="$CERT" info "$OUT_BUNDLE"

echo "Bundle built: $OUT_BUNDLE ($(ls -lh "$OUT_BUNDLE" | awk '{print $5}'))"
