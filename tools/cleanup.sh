#!/bin/bash -e

echo "===== loop cleanup ====="

echo "detaching stale loop devices (deleted files)..."
losetup -l 2>/dev/null | grep '(deleted)' | awk '{print $1}' | while read dev; do
  losetup -d "$dev" && echo "detached $dev" || true
done

losetup 2>/dev/null || true
