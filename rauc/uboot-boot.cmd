# U-Boot boot script with RAUC A/B support
# This gets compiled to boot.scr via mkimage

# Default to slot A
test -n "${BOOT_ORDER}" || setenv BOOT_ORDER "A B"
test -n "${BOOT_A_LEFT}" || setenv BOOT_A_LEFT 3
test -n "${BOOT_B_LEFT}" || setenv BOOT_B_LEFT 3

setenv bootpart
for slot in ${BOOT_ORDER}; do
    if test "x${slot}" = "xA"; then
        if test ${BOOT_A_LEFT} -gt 0; then
            setexpr BOOT_A_LEFT ${BOOT_A_LEFT} - 1
            setenv bootpart 2
            setenv slot_name A
        fi
    elif test "x${slot}" = "xB"; then
        if test ${BOOT_B_LEFT} -gt 0; then
            setexpr BOOT_B_LEFT ${BOOT_B_LEFT} - 1
            setenv bootpart 3
            setenv slot_name B
        fi
    fi
    if test -n "${bootpart}"; then
        saveenv
        echo "Booting slot ${slot_name} from partition ${bootpart}"
        # panic=10: kernel/initramfs auto-reboots 10s after panic or
        # mount-fail (Debian initramfs-tools' panic() honors this), so a
        # broken slot consumes a TRY counter and GRUB/U-Boot eventually
        # falls back to the good slot — no manual power cycle needed.
        setenv bootargs "root=/dev/mmcblk0p${bootpart} rootfstype=ext4 rootwait rauc.slot=${slot_name} panic=10"
        load mmc 0:${bootpart} ${kernel_addr_r} /boot/vmlinuz
        load mmc 0:${bootpart} ${fdt_addr_r} /boot/dtb/${fdtfile}
        load mmc 0:${bootpart} ${ramdisk_addr_r} /boot/initrd.img
        booti ${kernel_addr_r} ${ramdisk_addr_r}:${filesize} ${fdt_addr_r}
    fi
done

echo "No bootable slot found!"
reset
