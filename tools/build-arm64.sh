#!/bin/bash -ex

# Build an arm64 image using pre-built rootfs + Armbian board support
# Downloads rootfs tarball (with snapd+platform pre-installed) and Armbian image.
# Extracts board-specific bits (U-Boot, kernel, DTBs) from Armbian.
# Assembles A/B partition layout, enables v2 services, compresses with xz.
#
# Usage: ./tools/build-arm64.sh <board-dir>

apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq wget xz-utils gdisk u-boot-tools kpartx e2fsprogs dosfstools

DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
ROOT=$(dirname "$DIR")

BOARD_DIR=$1
if [[ -z "$BOARD_DIR" || ! -f "$BOARD_DIR/board.conf" ]]; then
    echo "Usage: $0 <board-dir>"
    exit 1
fi

source "$BOARD_DIR/board.conf"
BOARD_NAME=$(basename "$BOARD_DIR")

OUTPUT_DIR="$ROOT/output"
WORK_DIR="$ROOT/build/$BOARD_NAME"
mkdir -p "$OUTPUT_DIR" "$WORK_DIR"

# Download pre-built rootfs (from rootfs CI)
ROOTFS_URL="${ROOTFS_URL:-http://ci.syncloud.org:8081/files/rootfs/432-bookworm-arm64/rootfs-bookworm-arm64.tar.gz}"
ROOTFS_TAR="$WORK_DIR/rootfs.tar.gz"
if [[ ! -f "$ROOTFS_TAR" ]]; then
    echo "=== Downloading rootfs ($(date)) ==="
    wget -O "$ROOTFS_TAR" "$ROOTFS_URL" --progress=dot:giga
fi
echo "rootfs: $(ls -lh "$ROOTFS_TAR")"

# Download Armbian image (for U-Boot, kernel, DTBs)
ARMBIAN_IMAGE="$WORK_DIR/armbian.img"
if [[ ! -f "$ARMBIAN_IMAGE" ]]; then
    echo "=== Downloading Armbian ($(date)) ==="
    wget -O "$WORK_DIR/armbian.img.xz" "$ARMBIAN_IMAGE_URL" --progress=dot:giga
    xz -d "$WORK_DIR/armbian.img.xz"
fi
echo "armbian: $(ls -lh "$ARMBIAN_IMAGE")"

OUTPUT_IMAGE="$OUTPUT_DIR/syncloud-${BOARD_NAME}.img"

cleanup() {
    set +e
    umount "$WORK_DIR/out-rootfs/boot" 2>/dev/null
    umount "$WORK_DIR/out-rootfs" 2>/dev/null
    umount "$WORK_DIR/armbian-boot" 2>/dev/null
    umount "$WORK_DIR/armbian-root" 2>/dev/null
    [[ -n "$OUT_LOOP" ]] && { kpartx -d "$OUT_LOOP" 2>/dev/null; losetup -d "$OUT_LOOP" 2>/dev/null; }
    [[ -n "$ARMBIAN_LOOP" ]] && { kpartx -d "$ARMBIAN_LOOP" 2>/dev/null; losetup -d "$ARMBIAN_LOOP" 2>/dev/null; }
}
trap cleanup EXIT

# --- Mount Armbian to extract board-specific bits ---
echo "=== Mounting Armbian ($(date)) ==="
ARMBIAN_LOOP=$(losetup --find --show "$ARMBIAN_IMAGE")
kpartx -avs "$ARMBIAN_LOOP"
ARMBIAN_LOOP_NAME=$(basename "$ARMBIAN_LOOP")

PART_COUNT=$(ls /dev/mapper/${ARMBIAN_LOOP_NAME}p* 2>/dev/null | wc -l)
echo "Armbian has $PART_COUNT partition(s)"

mkdir -p "$WORK_DIR"/{armbian-boot,armbian-root}

if [[ "$PART_COUNT" -ge 2 ]]; then
    SEPARATE_BOOT=true
    mount "/dev/mapper/${ARMBIAN_LOOP_NAME}p1" "$WORK_DIR/armbian-boot"
    mount "/dev/mapper/${ARMBIAN_LOOP_NAME}p2" "$WORK_DIR/armbian-root"
    BOOT_SIZE=$(df -BM --output=used "$WORK_DIR/armbian-boot" | tail -1 | tr -d 'M ')
else
    SEPARATE_BOOT=false
    mount "/dev/mapper/${ARMBIAN_LOOP_NAME}p1" "$WORK_DIR/armbian-root"
    BOOT_SIZE=1
fi

# --- Calculate partition sizes ---
# rootfs size: estimate from tar (compressed ~500M, uncompressed ~1.5G, add headroom)
ROOT_PART=2048
BOOT_PART=$((BOOT_SIZE + 16))
DATA_PART=1024
TOTAL=$((BOOT_PART + ROOT_PART * 2 + DATA_PART + 16))

echo "Partition sizes: boot=${BOOT_PART}M rootfs=${ROOT_PART}M (x2) data=${DATA_PART}M total=${TOTAL}M"

# --- Create output image ---
echo "=== Creating image ($(date)) ==="
truncate -s ${TOTAL}M "$OUTPUT_IMAGE"

sgdisk -Z "$OUTPUT_IMAGE"
sgdisk -n 1:0:+${BOOT_PART}M  -t 1:0700 -c 1:boot      "$OUTPUT_IMAGE"
sgdisk -n 2:0:+${ROOT_PART}M  -t 2:8300 -c 2:rootfs-a   "$OUTPUT_IMAGE"
sgdisk -n 3:0:+${ROOT_PART}M  -t 3:8300 -c 3:rootfs-b   "$OUTPUT_IMAGE"
sgdisk -n 4:0:0               -t 4:8300 -c 4:data        "$OUTPUT_IMAGE"

# Copy U-Boot from Armbian (raw sectors 1-8191)
dd if="$ARMBIAN_IMAGE" of="$OUTPUT_IMAGE" bs=512 skip=1 seek=1 count=8191 conv=notrunc

# --- Setup output partitions ---
echo "=== Setting up partitions ($(date)) ==="
OUT_LOOP=$(losetup --find --show "$OUTPUT_IMAGE")
kpartx -avs "$OUT_LOOP"
OUT_LOOP_NAME=$(basename "$OUT_LOOP")

mkfs.vfat -F 32 "/dev/mapper/${OUT_LOOP_NAME}p1"
mkfs.ext4 -L rootfs-a "/dev/mapper/${OUT_LOOP_NAME}p2"
mkfs.ext4 -L rootfs-b "/dev/mapper/${OUT_LOOP_NAME}p3"
mkfs.ext4 -L data "/dev/mapper/${OUT_LOOP_NAME}p4"

# --- Boot partition ---
echo "=== Writing boot partition ($(date)) ==="
mkdir -p "$WORK_DIR/out-boot"
mount "/dev/mapper/${OUT_LOOP_NAME}p1" "$WORK_DIR/out-boot"
if [[ "$SEPARATE_BOOT" == "true" ]]; then
    cp -rL --no-preserve=ownership "$WORK_DIR/armbian-boot"/* "$WORK_DIR/out-boot/"
fi
mkimage -C none -A arm64 -T script -d "$ROOT/rauc/uboot-boot.cmd" "$WORK_DIR/out-boot/boot.scr"

# Board-specific: RPi pivots Pi firmware's direct-kernel boot to U-Boot,
# so boot.scr (our A/B selector) actually runs. Without this, Pi firmware
# loads vmlinuz straight from vfat and our A/B design is bypassed.
if [[ "${NEEDS_UBOOT_PIVOT:-}" == "yes" ]]; then
    echo "=== Pivoting Pi firmware to U-Boot ($(date)) ==="
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq u-boot-rpi
    : "${UBOOT_RPI_BIN:?UBOOT_RPI_BIN must be set in board.conf when NEEDS_UBOOT_PIVOT=yes}"
    [ -f "$UBOOT_RPI_BIN" ] || { echo "ERROR: missing $UBOOT_RPI_BIN (from u-boot-rpi package)"; exit 1; }

    # Assert Armbian shipped the Pi firmware files we rely on — fail if
    # the upstream layout changed and we're about to build an unbootable image.
    for f in bootcode.bin start4.elf fixup4.dat config.txt bcm2711-rpi-4-b.dtb; do
        [ -f "$WORK_DIR/out-boot/$f" ] || { echo "ERROR: expected Armbian file missing on vfat: $f"; exit 1; }
    done

    # Drop U-Boot and overwrite config.txt so Pi firmware chainloads U-Boot
    cp "$UBOOT_RPI_BIN" "$WORK_DIR/out-boot/u-boot.bin"
    cp "$ROOT/rauc/rpi-config.txt" "$WORK_DIR/out-boot/config.txt"

    # Remove Armbian's vfat-resident kernel/initrd/cmdline — kernel now
    # lives on the A/B rootfs and boot args come from boot.scr.
    rm -f "$WORK_DIR/out-boot/vmlinuz" \
          "$WORK_DIR/out-boot/initrd.img" \
          "$WORK_DIR/out-boot/cmdline.txt"

    # Final assertions: vfat has U-Boot, no direct-kernel leftovers
    [ -f "$WORK_DIR/out-boot/u-boot.bin" ]
    [ -f "$WORK_DIR/out-boot/boot.scr" ]
    grep -q '^kernel=u-boot.bin' "$WORK_DIR/out-boot/config.txt"
    [ ! -e "$WORK_DIR/out-boot/vmlinuz" ]
    [ ! -e "$WORK_DIR/out-boot/initrd.img" ]
fi

umount "$WORK_DIR/out-boot"

# --- Rootfs partition A ---
echo "=== Extracting rootfs to slot A ($(date)) ==="
mkdir -p "$WORK_DIR/out-rootfs"
mount "/dev/mapper/${OUT_LOOP_NAME}p2" "$WORK_DIR/out-rootfs"

tar xzf "$ROOTFS_TAR" -C "$WORK_DIR/out-rootfs"

# Copy kernel + DTBs from Armbian rootfs /boot into our rootfs /boot
# (U-Boot loads /boot/vmlinuz from the slot partition, not from the vfat boot)
echo "=== Copying kernel from Armbian ($(date)) ==="
ls "$WORK_DIR/armbian-root/boot/vmlinuz"* >/dev/null
cp -a "$WORK_DIR/armbian-root/boot"/* "$WORK_DIR/out-rootfs/boot/"

# Copy kernel modules
[ -d "$WORK_DIR/armbian-root/lib/modules" ]
cp -a "$WORK_DIR/armbian-root/lib/modules"/* "$WORK_DIR/out-rootfs/lib/modules/"

# Post-copy assertion: our rootfs must have a bootable kernel + initrd
ls "$WORK_DIR/out-rootfs/boot/vmlinuz"* >/dev/null
ls "$WORK_DIR/out-rootfs/boot/initrd.img"* >/dev/null

# Done with Armbian source
if [[ "$SEPARATE_BOOT" == "true" ]]; then
    umount "$WORK_DIR/armbian-boot"
fi
umount "$WORK_DIR/armbian-root"
kpartx -d "$ARMBIAN_LOOP"
losetup -d "$ARMBIAN_LOOP"
ARMBIAN_LOOP=""

# --- Enable v2 services (unmask) ---
echo "=== Enabling v2 services ($(date)) ==="
rm -f "$WORK_DIR/out-rootfs/etc/systemd/system/syncloud-data-init.service"
rm -f "$WORK_DIR/out-rootfs/etc/systemd/system/syncloud-update.service"
rm -f "$WORK_DIR/out-rootfs/etc/systemd/system/syncloud-update.timer"
rm -f "$WORK_DIR/out-rootfs/etc/systemd/system/syncloud-boot-ok.service"

# Enable services via symlinks (like systemctl enable)
mkdir -p "$WORK_DIR/out-rootfs/etc/systemd/system/local-fs.target.wants"
mkdir -p "$WORK_DIR/out-rootfs/etc/systemd/system/timers.target.wants"
mkdir -p "$WORK_DIR/out-rootfs/etc/systemd/system/multi-user.target.wants"
ln -sf /usr/lib/systemd/system/syncloud-data-init.service \
    "$WORK_DIR/out-rootfs/etc/systemd/system/local-fs.target.wants/syncloud-data-init.service"
ln -sf /usr/lib/systemd/system/syncloud-update.timer \
    "$WORK_DIR/out-rootfs/etc/systemd/system/timers.target.wants/syncloud-update.timer"
# rauc.service runs the RAUC daemon (D-Bus server). Required for 'rauc install'
# and 'rauc status' — without it calls fail with "name not provided by .service files".
# syncloud-boot-ok marks the current slot as good after a successful boot — without
# this, RAUC would fall back to the previous slot after the boot-attempts counter expires.
ln -sf /lib/systemd/system/rauc.service \
    "$WORK_DIR/out-rootfs/etc/systemd/system/multi-user.target.wants/rauc.service"
ln -sf /usr/lib/systemd/system/syncloud-boot-ok.service \
    "$WORK_DIR/out-rootfs/etc/systemd/system/multi-user.target.wants/syncloud-boot-ok.service"
# Assert the target unit files exist (catch Debian renames / missing packages fast).
[ -f "$WORK_DIR/out-rootfs/lib/systemd/system/rauc.service" ] || \
    [ -f "$WORK_DIR/out-rootfs/usr/lib/systemd/system/rauc.service" ] || \
    { echo "ERROR: rauc.service not found in rootfs (install rauc-service pkg)"; exit 1; }
[ -f "$WORK_DIR/out-rootfs/usr/lib/systemd/system/syncloud-boot-ok.service" ] || \
    { echo "ERROR: syncloud-boot-ok.service not found in rootfs"; exit 1; }

# Write board-specific RAUC config
echo "=== Writing RAUC config ($(date)) ==="
mkdir -p "$WORK_DIR/out-rootfs/etc/rauc"
BOOTLOADER_TYPE=${BOOTLOADER:-uboot}
sed "s|@RAUC_COMPATIBLE@|${RAUC_COMPATIBLE}|;s|@BOOTLOADER@|${BOOTLOADER_TYPE}|" \
    "$ROOT/rauc/system.conf" > "$WORK_DIR/out-rootfs/etc/rauc/system.conf"
mkdir -p "$WORK_DIR/out-rootfs/usr/lib/rauc"
cp "$ROOT/rauc/post-install.sh" "$WORK_DIR/out-rootfs/usr/lib/rauc/"
chmod +x "$WORK_DIR/out-rootfs/usr/lib/rauc/post-install.sh"

# Add data partition to fstab
echo "=== Configuring fstab ($(date)) ==="
mkdir -p "$WORK_DIR/out-rootfs/mnt/data"
grep -q 'by-partlabel/data' "$WORK_DIR/out-rootfs/etc/fstab" || \
    echo '/dev/disk/by-partlabel/data  /mnt/data  ext4  defaults,nofail  0  2' >> "$WORK_DIR/out-rootfs/etc/fstab"
echo "fstab:"
cat "$WORK_DIR/out-rootfs/etc/fstab"

umount "$WORK_DIR/out-rootfs"

# --- Clone A to B ---
echo "=== Cloning rootfs-a to rootfs-b ($(date)) ==="
dd if="/dev/mapper/${OUT_LOOP_NAME}p2" of="/dev/mapper/${OUT_LOOP_NAME}p3" bs=4M status=progress
e2label "/dev/mapper/${OUT_LOOP_NAME}p3" rootfs-b

# --- Cleanup loop devices ---
echo "=== Cleaning up loop devices ($(date)) ==="
kpartx -d "$OUT_LOOP"
losetup -d "$OUT_LOOP"
OUT_LOOP=""

# --- Compress ---
echo "=== Compressing with xz ($(date)) ==="
xz -T0 "$OUTPUT_IMAGE"

echo "=== Done: ${OUTPUT_IMAGE}.xz ($(date)) ==="
