#!/bin/bash -e

echo "===== loop cleanup ====="

echo "detaching stale loop devices (deleted files)..."
losetup -l | grep '(deleted)' | awk '{print $1}' | while read dev; do
  losetup -d "$dev" && echo "detached $dev" || true
done

dmsetup remove -f /dev/mapper/loop* 2>/dev/null || true

losetup || true
