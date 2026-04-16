#!/bin/bash -ex

# Reproduce kernel crash with N2-sized image + dind running
# Creates same partition layout as real N2 build

apt-get update
apt-get install -y kpartx e2fsprogs gdisk xz-utils

echo "=== Step 1: create 4.8GB image (same as N2) ==="
truncate -s 4800M /tmp/test.img

echo "=== Step 2: partition (same layout as N2) ==="
sgdisk -Z /tmp/test.img || true
sgdisk -n 1:0:+17M   -t 1:0700 -c 1:boot    /tmp/test.img
sgdisk -n 2:0:+1756M -t 2:8300 -c 2:rootfs-a /tmp/test.img
sgdisk -n 3:0:+1756M -t 3:8300 -c 3:rootfs-b /tmp/test.img
sgdisk -n 4:0:0      -t 4:8300 -c 4:data     /tmp/test.img

echo "=== Step 3: losetup ==="
LOOP=$(losetup --find --show /tmp/test.img)
echo "loop: $LOOP"

echo "=== Step 4: kpartx ==="
kpartx -avs "$LOOP"
LOOP_NAME=$(basename "$LOOP")
ls -la /dev/mapper/${LOOP_NAME}*

echo "=== Step 5: mkfs ==="
mkfs.ext4 -L rootfs-a "/dev/mapper/${LOOP_NAME}p2"
mkfs.ext4 -L rootfs-b "/dev/mapper/${LOOP_NAME}p3"

echo "=== Step 6: mount ==="
mkdir -p /tmp/mnt
mount "/dev/mapper/${LOOP_NAME}p2" /tmp/mnt

echo "=== Step 7: write 1.3GB (simulate rootfs) ==="
dd if=/dev/urandom of=/tmp/mnt/testfile bs=1M count=1300
sync

echo "=== Step 8: umount ==="
umount /tmp/mnt

echo "=== Step 9: dd clone 1.7GB p2->p3 ==="
dd if="/dev/mapper/${LOOP_NAME}p2" of="/dev/mapper/${LOOP_NAME}p3" bs=4M status=progress
sync

echo "=== Step 10: kpartx -d ==="
kpartx -d "$LOOP"

echo "=== Step 11: losetup -d ==="
losetup -d "$LOOP"

echo "=== Step 12: xz compress 4.8GB ==="
xz -T0 /tmp/test.img

echo "=== ALL DONE ==="
