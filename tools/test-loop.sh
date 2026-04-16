#!/bin/bash -ex

# Minimal test to reproduce kernel panic on container teardown with loop devices
# Tests each operation individually to find what crashes the HC4 kernel 5.11

apt-get update
apt-get install -y kpartx e2fsprogs gdisk

echo "=== Step 1: create test image ==="
truncate -s 100M /tmp/test.img
echo "=== Step 2: partition ==="
sgdisk -Z /tmp/test.img || true
sgdisk -n 1:0:+40M -t 1:8300 -c 1:part-a /tmp/test.img
sgdisk -n 2:0:0    -t 2:8300 -c 2:part-b /tmp/test.img

echo "=== Step 3: losetup ==="
LOOP=$(losetup --find --show /tmp/test.img)
echo "loop: $LOOP"

echo "=== Step 4: kpartx -avs ==="
kpartx -avs "$LOOP"
LOOP_NAME=$(basename "$LOOP")
ls -la /dev/mapper/${LOOP_NAME}*

echo "=== Step 5: mkfs ==="
mkfs.ext4 -L part-a "/dev/mapper/${LOOP_NAME}p1"
mkfs.ext4 -L part-b "/dev/mapper/${LOOP_NAME}p2"

echo "=== Step 6: mount ==="
mkdir -p /tmp/mnt
mount "/dev/mapper/${LOOP_NAME}p1" /tmp/mnt

echo "=== Step 7: write data ==="
dd if=/dev/zero of=/tmp/mnt/testfile bs=1M count=10
sync

echo "=== Step 8: umount ==="
umount /tmp/mnt

echo "=== Step 9: dd clone ==="
dd if="/dev/mapper/${LOOP_NAME}p1" of="/dev/mapper/${LOOP_NAME}p2" bs=4M
sync

echo "=== Step 10: kpartx -d ==="
kpartx -d "$LOOP"

echo "=== Step 11: losetup -d ==="
losetup -d "$LOOP"

echo "=== Step 12: sync + sleep ==="
sync
sleep 2

echo "=== ALL DONE ==="
