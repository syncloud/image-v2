#!/bin/bash
# Called by RAUC after writing a slot image to a block device.
# Env provided by rauc: RAUC_SLOT_NAME (rootfs.0 / rootfs.1),
#                       RAUC_SLOT_BOOTNAME (A / B),
#                       RAUC_SLOT_DEVICE (/dev/disk/by-partlabel/rootfs-{a,b}).

set -e

echo "RAUC post-install: slot ${RAUC_SLOT_NAME} (bootname ${RAUC_SLOT_BOOTNAME}) on ${RAUC_SLOT_DEVICE}"

# The bundle's rootfs.img carries the filesystem label from whichever
# slot it was built from (typically 'rootfs-a'). After writing it to
# the destination slot the FS label is wrong, and grub's
# `search --label rootfs-b` misses it. Relabel to match the slot.
case "$RAUC_SLOT_BOOTNAME" in
    A) e2label "$RAUC_SLOT_DEVICE" rootfs-a ;;
    B) e2label "$RAUC_SLOT_DEVICE" rootfs-b ;;
    *) echo "ERROR: unexpected RAUC_SLOT_BOOTNAME=$RAUC_SLOT_BOOTNAME"; exit 1 ;;
esac
echo "Relabeled $RAUC_SLOT_DEVICE to rootfs-${RAUC_SLOT_BOOTNAME,,}"
