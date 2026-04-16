#!/bin/bash -ex

# Test with actual N2 image from artifacts to reproduce kernel crash

apt-get update
apt-get install -y kpartx e2fsprogs gdisk wget xz-utils

echo "=== Step 1: download real N2 image ==="
wget -q --progress=dot:giga -O /tmp/test.img "http://ci.syncloud.org:8081/files/image-v2/output/syncloud-odroid-n2.img"
ls -lh /tmp/test.img

echo "=== Step 2: losetup ==="
LOOP=$(losetup --find --show /tmp/test.img)
echo "loop: $LOOP"

echo "=== Step 3: kpartx ==="
kpartx -avs "$LOOP"
LOOP_NAME=$(basename "$LOOP")
ls -la /dev/mapper/${LOOP_NAME}*

echo "=== Step 4: mount p2 ==="
mkdir -p /tmp/mnt
mount "/dev/mapper/${LOOP_NAME}p2" /tmp/mnt
df -h /tmp/mnt

echo "=== Step 5: write 1GB to simulate tar extract ==="
dd if=/dev/zero of=/tmp/mnt/testfile bs=1M count=1024
sync

echo "=== Step 6: umount ==="
umount /tmp/mnt

echo "=== Step 7: dd clone p2->p3 ==="
dd if="/dev/mapper/${LOOP_NAME}p2" of="/dev/mapper/${LOOP_NAME}p3" bs=4M status=progress
sync

echo "=== Step 8: e2label ==="
e2label "/dev/mapper/${LOOP_NAME}p3" rootfs-b

echo "=== Step 9: kpartx -d ==="
kpartx -d "$LOOP"

echo "=== Step 10: losetup -d ==="
losetup -d "$LOOP"

echo "=== Step 11: xz compress ==="
xz -T0 /tmp/test.img

echo "=== ALL DONE ==="
